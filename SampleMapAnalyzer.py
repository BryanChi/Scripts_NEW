#!/usr/bin/env python3
"""
Lightweight external analyzer for Sample Map Browser.

Reads an audio file and returns JSON with optional fields:
  - dominant_freq: estimated dominant frequency in Hz
  - rms_energy: root-mean-square amplitude (0.0-1.0 when float data)
  - sample_type: "Drum" or "Swell" if detected
  - snap_offset: time in seconds for drum hit point or swell peak
  - effective_duration: seconds from file start to last audible audio (trailing silence cropped)
  - onset: first audible time in seconds (transient/sustain scan)
  - transient_end: attack/click end, sustain start (seconds)
  - playback_type: "oneshot", "loop", or "unknown" from a cheap envelope/onset
    check on the same ~2s buffer (full analysis only)

Pass --transient to compute only onset + transient_end (skip FFT / swell / crop).

Supports PCM and IEEE-float WAV via a manual RIFF reader (Python's wave
module cannot open format-3 float WAVs). Non-WAV formats fall back to
afconvert on macOS when available. Unsupported formats produce partial
or empty metrics rather than exiting with an error.
"""

from __future__ import annotations

import cmath
import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import wave
from typing import Dict, List, Optional, Tuple

try:
    import audioop  # type: ignore
except Exception:  # pragma: no cover - removed in some Python builds
    audioop = None  # type: ignore


def simple_fft(samples: List[float]) -> List[complex]:
    """Simple FFT implementation using Cooley-Tukey algorithm."""
    n = len(samples)
    if n <= 1:
        return [complex(s, 0) for s in samples]

    n_padded = 1
    while n_padded < n:
        n_padded <<= 1

    x = [complex(samples[i] if i < n else 0.0, 0.0) for i in range(n_padded)]

    def fft_rec(x_in):
        n_in = len(x_in)
        if n_in <= 1:
            return x_in
        even = fft_rec([x_in[i] for i in range(0, n_in, 2)])
        odd = fft_rec([x_in[i] for i in range(1, n_in, 2)])
        result = [0] * n_in
        for k in range(n_in // 2):
            t = cmath.exp(-2j * math.pi * k / n_in) * odd[k]
            result[k] = even[k] + t
            result[k + n_in // 2] = even[k] - t
        return result

    return fft_rec(x)


def detect_swell_cue_point(
    samples: List[float],
    sr: int,
    energy_envelope: List[float],
    window_size: int = 512,
    hop_size: int = 256,
) -> Optional[float]:
    """Find swell drop-off after peak energy."""
    if not energy_envelope or len(energy_envelope) < 3:
        return None

    max_energy = max(energy_envelope) if energy_envelope else 1.0
    if max_energy == 0:
        return None
    energy_norm = [e / max_energy for e in energy_envelope]

    peak_idx = max(range(len(energy_norm)), key=lambda i: energy_norm[i])
    peak_energy = energy_norm[peak_idx]
    drop_threshold = peak_energy * 0.7
    search_end = min(len(energy_norm), peak_idx + int(len(energy_norm) * 0.2))

    drop_off_idx = None
    for i in range(peak_idx + 1, search_end):
        if energy_norm[i] <= drop_threshold:
            drop_off_idx = i
            break

    if drop_off_idx is None:
        max_drop = 0.0
        for i in range(peak_idx + 1, min(len(energy_norm) - 1, search_end)):
            drop = energy_norm[i] - energy_norm[i + 1]
            if drop > max_drop:
                max_drop = drop
                drop_off_idx = i + 1
        if drop_off_idx is None:
            drop_off_idx = min(peak_idx + max(1, int(len(energy_norm) * 0.1)), len(energy_norm) - 1)

    return (drop_off_idx * hop_size + window_size / 2) / float(sr)


def samples_from_pcm_raw(raw: bytes, sampwidth: int) -> List[float]:
    """Convert integer PCM bytes to float samples in [-1, 1]."""
    samples: List[float] = []
    max_val = float(2 ** (8 * sampwidth - 1))

    if sampwidth == 1:
        for i in range(0, len(raw), sampwidth):
            samples.append((raw[i] - 128) / 128.0)
    elif sampwidth == 2:
        for i in range(0, len(raw) - 1, sampwidth):
            val = int.from_bytes(raw[i : i + 2], byteorder="little", signed=True)
            samples.append(val / max_val)
    elif sampwidth == 3:
        for i in range(0, len(raw) - 2, sampwidth):
            b0, b1, b2 = raw[i], raw[i + 1], raw[i + 2]
            val = b0 | (b1 << 8) | (b2 << 16)
            if val & 0x800000:
                val -= 0x1000000
            samples.append(val / max_val)
    elif sampwidth == 4:
        for i in range(0, len(raw) - 3, sampwidth):
            val = int.from_bytes(raw[i : i + 4], byteorder="little", signed=True)
            samples.append(val / max_val)
    else:
        return []
    return samples


def samples_from_float32_raw(raw: bytes) -> List[float]:
    """Convert little-endian IEEE float32 bytes to samples."""
    n = len(raw) // 4
    if n <= 0:
        return []
    return list(struct.unpack("<" + ("f" * n), raw[: n * 4]))


def to_mono(samples: List[float], channels: int) -> List[float]:
    if channels <= 1 or not samples:
        return samples
    mono: List[float] = []
    frames = len(samples) // channels
    for i in range(frames):
        acc = 0.0
        base = i * channels
        for c in range(channels):
            acc += samples[base + c]
        mono.append(acc / channels)
    return mono


def sample_peak(samples: List[float]) -> float:
    peak = 0.0
    for x in samples:
        ax = abs(x)
        if ax > peak:
            peak = ax
    return peak


# Trailing-silence crop: last window >= max(absolute floor, peak * relative).
_AUDIBLE_ABS_THRESH = 10 ** (-50.0 / 20.0)  # -50 dBFS
_AUDIBLE_REL = 10 ** (-40.0 / 20.0)  # -40 dB below peak
_AUDIBLE_WINDOW_SEC = 0.008
_AUDIBLE_HANG_SEC = 0.040
_AUDIBLE_CHUNK_SEC = 0.5


def audible_threshold(peak: float) -> float:
    return max(_AUDIBLE_ABS_THRESH, peak * _AUDIBLE_REL)


def audible_end_from_samples(
    samples: List[float], sr: int, peak: float = 0.0
) -> Optional[float]:
    """Last audible time (seconds) within an in-memory mono buffer, plus hang."""
    if not samples or sr <= 0:
        return None
    window = max(32, int(sr * _AUDIBLE_WINDOW_SEC))
    if peak <= 0.0:
        peak = sample_peak(samples)
    thresh = audible_threshold(peak)
    i = len(samples)
    last = None
    while i > 0:
        w0 = max(0, i - window)
        wpeak = 0.0
        for x in samples[w0:i]:
            ax = abs(x)
            if ax > wpeak:
                wpeak = ax
        if wpeak >= thresh:
            last = i
            break
        i = w0
    if last is None:
        return None
    end_sec = last / float(sr) + _AUDIBLE_HANG_SEC
    max_sec = len(samples) / float(sr)
    return min(max_sec, max(1.0 / float(sr), end_sec))


def parse_wav_info(path: str) -> Optional[dict]:
    """fmt + data-chunk location for PCM / float32 WAV. None if unsupported."""
    try:
        with open(path, "rb") as f:
            header = f.read(12)
            if len(header) < 12 or header[0:4] != b"RIFF" or header[8:12] != b"WAVE":
                return None
            fmt_tag = channels = sr = bits = None
            data_offset = data_size = None
            while True:
                chunk_hdr = f.read(8)
                if len(chunk_hdr) < 8:
                    break
                cid, size = chunk_hdr[0:4], struct.unpack("<I", chunk_hdr[4:8])[0]
                if cid == b"fmt ":
                    fmt = f.read(size)
                    if size & 1:
                        f.read(1)
                    if len(fmt) < 16:
                        return None
                    fmt_tag, channels, sr, _br, _ba, bits = struct.unpack(
                        "<HHIIHH", fmt[:16]
                    )
                elif cid == b"data":
                    data_offset = f.tell()
                    data_size = size
                    break
                else:
                    f.seek(size + (size & 1), 1)
            if (
                data_offset is None
                or not fmt_tag
                or not channels
                or not sr
                or not bits
                or channels < 1
                or sr <= 0
            ):
                return None
            if fmt_tag == 1:
                sampwidth = bits // 8
                if sampwidth not in (1, 2, 3, 4):
                    return None
            elif fmt_tag == 3 and bits == 32:
                sampwidth = 4
            else:
                return None
            bytes_per_frame = channels * sampwidth
            if bytes_per_frame <= 0:
                return None
            total_frames = data_size // bytes_per_frame
            if total_frames <= 0:
                return None
            return {
                "fmt_tag": fmt_tag,
                "channels": channels,
                "sr": int(sr),
                "bits": bits,
                "sampwidth": sampwidth,
                "data_offset": data_offset,
                "bytes_per_frame": bytes_per_frame,
                "total_frames": total_frames,
            }
    except Exception:
        return None


def read_wav_mono_frames(path: str, info: dict, start_frame: int, nframes: int) -> List[float]:
    start_frame = max(0, start_frame)
    nframes = min(nframes, info["total_frames"] - start_frame)
    if nframes <= 0:
        return []
    bpf = info["bytes_per_frame"]
    try:
        with open(path, "rb") as f:
            f.seek(info["data_offset"] + start_frame * bpf)
            raw = f.read(nframes * bpf)
    except Exception:
        return []
    if info["fmt_tag"] == 1:
        samples = samples_from_pcm_raw(raw, info["sampwidth"])
    else:
        samples = samples_from_float32_raw(raw)
    return to_mono(samples, info["channels"])


def detect_audible_end_wav(path: str, peak_hint: float = 0.0) -> Optional[float]:
    """Scan a WAV from the end in chunks; return last audible time + hang."""
    info = parse_wav_info(path)
    if not info:
        return None
    sr = info["sr"]
    total = info["total_frames"]
    file_dur = total / float(sr)
    window = max(32, int(sr * _AUDIBLE_WINDOW_SEC))
    chunk = max(window, int(sr * _AUDIBLE_CHUNK_SEC))
    peak = max(0.0, peak_hint)
    last_audible = None
    pos = total
    while pos > 0:
        start = max(0, pos - chunk)
        samples = read_wav_mono_frames(path, info, start, pos - start)
        if samples:
            chunk_peak = sample_peak(samples)
            if chunk_peak > peak:
                peak = chunk_peak
            thresh = audible_threshold(peak)
            i = len(samples)
            while i > 0:
                w0 = max(0, i - window)
                wpeak = 0.0
                for x in samples[w0:i]:
                    ax = abs(x)
                    if ax > wpeak:
                        wpeak = ax
                if wpeak >= thresh:
                    last_audible = start + i
                    break
                i = w0
        if last_audible is not None:
            break
        pos = start
    if last_audible is None:
        return file_dur
    end_sec = last_audible / float(sr) + _AUDIBLE_HANG_SEC
    return min(file_dur, max(1.0 / float(sr), end_sec))


# Drum transient / sustain split (one-shots). Times in seconds from file start.
_TRANSIENT_WIN_SEC = 0.003
_TRANSIENT_MIN_SEC = 0.003
_TRANSIENT_MAX_SEC = 0.080
_TRANSIENT_HF_SEARCH_SEC = 0.040
_TRANSIENT_HF_LOOK_SEC = 0.080
_TRANSIENT_HF_DROP = 0.32  # ~-10 dB of high-band peak
_TRANSIENT_FALLBACK_SEC = 0.012
_ONSET_REL = 0.08


def detect_transient_sustain(samples: List[float], sr: int) -> Dict[str, float]:
    """Locate onset and the transient/sustain split for a drum one-shot.

    High-band energy (first-difference RMS) tracks the click/crack; the split is
    where that band falls after its peak. Falls back to a short post-peak window
    when the high band never drops (hats, noisy snares).
    """
    if not samples or sr <= 0 or len(samples) < 32:
        return {}

    n = len(samples)
    dur = n / float(sr)
    window = max(16, int(sr * _TRANSIENT_WIN_SEC))
    hop = max(8, window // 2)
    if n < window:
        onset = 0.0
        end = min(dur, onset + _TRANSIENT_FALLBACK_SEC)
        return {"onset": onset, "transient_end": max(_TRANSIENT_MIN_SEC, end)}

    # First-difference highpass: emphasises click vs body/sub.
    prev = samples[0]
    hp = [0.0] * n
    for i, x in enumerate(samples):
        hp[i] = x - prev
        prev = x

    def rms_env(buf: List[float]) -> List[float]:
        env: List[float] = []
        i = 0
        while i + window <= len(buf):
            acc = 0.0
            for x in buf[i : i + window]:
                acc += x * x
            env.append(math.sqrt(acc / window))
            i += hop
        return env

    env_full = rms_env(samples)
    env_hf = rms_env(hp)
    if not env_full:
        return {"onset": 0.0, "transient_end": min(dur, _TRANSIENT_FALLBACK_SEC)}

    peak_full = 0.0
    for e in env_full:
        if e > peak_full:
            peak_full = e
    if peak_full <= 1e-8:
        return {"onset": 0.0, "transient_end": min(dur, _TRANSIENT_FALLBACK_SEC)}

    onset_thresh = max(_AUDIBLE_ABS_THRESH, peak_full * _ONSET_REL)
    onset_idx = 0
    for i, e in enumerate(env_full):
        if e >= onset_thresh:
            onset_idx = i
            break
    onset = (onset_idx * hop) / float(sr)

    search_frames = max(1, int(_TRANSIENT_HF_SEARCH_SEC * sr / hop))
    look_frames = max(1, int(_TRANSIENT_HF_LOOK_SEC * sr / hop))
    search_end = min(len(env_hf), onset_idx + search_frames)

    hf_peak_idx = onset_idx
    hf_peak = 0.0
    if env_hf:
        for i in range(onset_idx, search_end):
            if env_hf[i] > hf_peak:
                hf_peak = env_hf[i]
                hf_peak_idx = i

    transient_idx = None
    if hf_peak > 1e-10 and env_hf:
        drop_thresh = hf_peak * _TRANSIENT_HF_DROP
        look_end = min(len(env_hf), hf_peak_idx + look_frames)
        for i in range(hf_peak_idx + 1, look_end):
            if env_hf[i] <= drop_thresh:
                transient_idx = i
                break

    if transient_idx is None:
        full_peak_idx = onset_idx
        full_p = 0.0
        full_search_end = min(len(env_full), onset_idx + search_frames)
        for i in range(onset_idx, full_search_end):
            if env_full[i] > full_p:
                full_p = env_full[i]
                full_peak_idx = i
        half = full_p * 0.5
        full_look_end = min(len(env_full), full_peak_idx + look_frames)
        for i in range(full_peak_idx + 1, full_look_end):
            if env_full[i] <= half:
                transient_idx = i
                break
        if transient_idx is None:
            transient_idx = hf_peak_idx + max(1, int(_TRANSIENT_FALLBACK_SEC * sr / hop))

    transient_end = (transient_idx * hop + window * 0.5) / float(sr)
    min_end = onset + _TRANSIENT_MIN_SEC
    max_end = min(dur, onset + _TRANSIENT_MAX_SEC)
    if max_end < min_end:
        max_end = dur
    transient_end = min(max(transient_end, min_end), max_end)
    if transient_end <= 0.0:
        transient_end = min(dur, _TRANSIENT_FALLBACK_SEC)

    return {"onset": float(onset), "transient_end": float(transient_end)}


def attach_transient_sustain(
    result: Dict[str, float], samples: List[float], sr: int
) -> Dict[str, float]:
    ts = detect_transient_sustain(samples, sr)
    for k, v in ts.items():
        if v is not None:
            result[k] = v
    return result


def attach_effective_duration(
    result: Dict[str, float],
    path: str,
    samples: Optional[List[float]] = None,
    sr: int = 0,
) -> Dict[str, float]:
    """Add effective_duration (trailing silence cropped). Prefer file-end WAV scan."""
    peak = sample_peak(samples) if samples else 0.0
    end = detect_audible_end_wav(path, peak_hint=peak)
    if end is None and samples and sr > 0:
        end = audible_end_from_samples(samples, sr, peak)
    if end is not None:
        result["effective_duration"] = float(end)
    return result


def wav_file_duration(path: str) -> Optional[float]:
    """Full file length from WAV header (not the truncated analysis buffer)."""
    info = parse_wav_info(path)
    if info and info.get("sr") and info.get("total_frames"):
        return info["total_frames"] / float(info["sr"])
    try:
        with wave.open(path, "rb") as wf:
            frames = wf.getnframes()
            sr = wf.getframerate()
            if frames > 0 and sr > 0:
                return frames / float(sr)
    except Exception:
        return None
    return None


def _rms_envelope(
    samples: List[float], sr: int, window_sec: float = 0.012, hop_sec: float = 0.006
) -> Tuple[List[float], int]:
    window = max(16, int(sr * window_sec))
    hop = max(8, int(sr * hop_sec))
    env: List[float] = []
    i = 0
    n = len(samples)
    while i + window <= n:
        acc = 0.0
        for x in samples[i : i + window]:
            acc += x * x
        env.append(math.sqrt(acc / window))
        i += hop
    return env, hop


def detect_playback_type(
    samples: List[float],
    sr: int,
    file_dur: Optional[float] = None,
    effective_dur: Optional[float] = None,
) -> str:
    """Classify loop vs one-shot from the in-memory buffer (typically first ~2s).

    Conservative: return "unknown" rather than guess pads, crashes, or 808 tails.
    """
    if not samples or sr <= 0 or len(samples) < 32:
        return "unknown"

    buf_dur = len(samples) / float(sr)
    file_len = file_dur if file_dur and file_dur > 0 else buf_dur
    audible = effective_dur if effective_dur and effective_dur > 0 else file_len

    if min(file_len, audible) < 0.40:
        return "oneshot"

    env, hop = _rms_envelope(samples, sr)
    if not env:
        return "unknown"

    peak = max(env)
    if peak <= 1e-8:
        return "unknown"

    env_n = [e / peak for e in env]
    peak_idx = max(range(len(env_n)), key=lambda i: env_n[i])
    peak_t = (peak_idx * hop) / float(sr)

    onset_thresh = 0.18
    min_gap = max(1, int(0.045 * sr / hop))
    onsets: List[int] = []
    below = True
    last = -999
    for i, e in enumerate(env_n):
        prev = env_n[i - 1] if i > 0 else 0.0
        if below and e >= onset_thresh and (i - last) >= min_gap:
            if (e - prev) >= 0.08 or e >= 0.35:
                onsets.append(i)
                last = i
                below = False
        elif e < onset_thresh * 0.55:
            below = True
    n_onsets = len(onsets)

    tail_start = int(len(env_n) * 0.75)
    if tail_start < len(env_n):
        tail_max = max(env_n[tail_start:])
        tail_mean = sum(env_n[tail_start:]) / float(len(env_n) - tail_start)
    else:
        tail_max = env_n[-1]
        tail_mean = env_n[-1]

    one_sec = max(1, int(1.0 * sr / hop))
    check_idx = min(len(env_n) - 1, peak_idx + one_sec)
    decayed = env_n[check_idx] < 0.20 and tail_max < 0.25
    if not decayed and buf_dur >= 0.8 and n_onsets <= 2 and tail_max < 0.18:
        decayed = True

    regular_loop = False
    if n_onsets >= 3:
        gaps = [onsets[i + 1] - onsets[i] for i in range(n_onsets - 1)]
        mean_gap = sum(gaps) / float(len(gaps))
        if mean_gap > 0:
            var = sum((g - mean_gap) ** 2 for g in gaps) / float(len(gaps))
            cv = math.sqrt(var) / mean_gap
            min_onsets = 4 if cv >= 0.22 else 3
            if n_onsets >= min_onsets and cv < 0.30:
                # Ignore a decaying flutter after a single hit.
                span_t = ((onsets[-1] - onsets[0]) * hop) / float(sr)
                if span_t >= 0.35 and (n_onsets >= 4 or file_len >= 1.2):
                    regular_loop = True

    cropped = bool(effective_dur and file_len > 0.5 and effective_dur < file_len * 0.65)

    if regular_loop:
        return "loop"

    if decayed and n_onsets <= 2 and peak_t < 0.40:
        return "oneshot"
    if file_len < 1.2 and decayed and n_onsets <= 2:
        return "oneshot"
    if cropped and n_onsets <= 2 and tail_max < 0.30:
        return "oneshot"
    if n_onsets <= 1 and tail_max < 0.22 and peak_t < 0.50:
        return "oneshot"

    # Many hits across a longer file, even if spacing is sloppy (live loops).
    if n_onsets >= 6 and buf_dur >= 1.2 and tail_mean > 0.12:
        return "loop"
    if file_len >= 4.0 and n_onsets >= 3 and tail_mean > 0.35:
        return "loop"

    return "unknown"


def attach_playback_type(
    result: Dict[str, float],
    path: str,
    samples: List[float],
    sr: int,
) -> Dict[str, float]:
    file_dur = wav_file_duration(path)
    if file_dur is None and samples and sr > 0:
        file_dur = len(samples) / float(sr)
    effective = result.get("effective_duration")
    if not isinstance(effective, (int, float)):
        effective = None
    result["playback_type"] = detect_playback_type(  # type: ignore[assignment]
        samples, sr, file_dur, effective
    )
    return result


def estimate_dominant_freq(samples: List[float], sr: int) -> Optional[float]:
    """Estimate dominant frequency; always take spectral peak when signal has energy."""
    if not samples or sr <= 0 or len(samples) < 256:
        return None

    dominant_freq = None
    try:
        window_len = min(sr, len(samples), 8192)
        if window_len < 256:
            window_len = min(len(samples), 512)
        step = max(256, window_len // 4)
        best_start, best_energy = 0, -1.0
        for start in range(0, max(1, len(samples) - window_len + 1), step):
            window_samples = samples[start : start + window_len]
            energy = sum(x * x for x in window_samples)
            if energy > best_energy:
                best_energy = energy
                best_start = start

        analysis_samples = samples[best_start : best_start + window_len]
        if not analysis_samples:
            analysis_samples = samples[:window_len]

        rms_energy = math.sqrt(sum(x * x for x in analysis_samples) / len(analysis_samples))
        if rms_energy > 1e-8:
            fft_size = 1
            while fft_size < len(analysis_samples):
                fft_size <<= 1
            fft_size = min(fft_size, 8192)

            fft_input = analysis_samples[:fft_size]
            if len(fft_input) < fft_size:
                fft_input = fft_input + [0.0] * (fft_size - len(fft_input))

            if fft_size > 1:
                window = [0.5 * (1 - math.cos(2 * math.pi * i / (fft_size - 1))) for i in range(fft_size)]
                fft_input_windowed = [fft_input[i] * window[i] for i in range(fft_size)]
            else:
                fft_input_windowed = fft_input

            fft_result = simple_fft(fft_input_windowed)
            magnitude = [abs(x) for x in fft_result]
            half_mag = magnitude[: fft_size // 2]

            min_bin = max(1, int(40 * fft_size / sr))
            max_bin = min(len(half_mag) - 1, int(6000 * fft_size / sr))

            if max_bin > min_bin:
                hps = half_mag[: max_bin + 1]
                for ratio in (2, 3, 4):
                    for i in range(min_bin, max_bin // ratio):
                        hps[i] *= half_mag[i * ratio]

                peak_bin = min_bin
                peak_val = 0.0
                for i in range(min_bin, max_bin + 1):
                    if hps[i] > peak_val:
                        peak_val = hps[i]
                        peak_bin = i

                # Always accept the strongest bin when there is audible energy.
                # (Old median*4 threshold dropped most percussive / noisy samples.)
                if peak_val > 0:
                    dominant_freq = (peak_bin * sr) / float(fft_size)
                    dominant_freq = max(40.0, min(8000.0, dominant_freq))

        if dominant_freq is None and len(samples) >= 256:
            zc_samples = samples[: min(len(samples), sr)]
            zero_crossings = 0
            for i in range(1, len(zc_samples)):
                prev, curr = zc_samples[i - 1], zc_samples[i]
                if (prev >= 0 and curr < 0) or (prev <= 0 and curr > 0):
                    zero_crossings += 1
            if zero_crossings > 2:
                freq_est = (zero_crossings * sr) / (2 * len(zc_samples))
                if 40.0 <= freq_est <= 8000.0:
                    dominant_freq = freq_est
    except Exception:
        return dominant_freq

    return dominant_freq


def read_wav_manual(path: str, max_seconds: float = 2.0) -> Optional[Tuple[List[float], int]]:
    """
    Read mono float samples from PCM (1) or IEEE-float (3) WAV.
    Returns (samples, sample_rate) or None.
    """
    try:
        with open(path, "rb") as f:
            header = f.read(12)
            if len(header) < 12 or header[0:4] != b"RIFF" or header[8:12] != b"WAVE":
                return None

            fmt_tag = None
            channels = None
            sr = None
            bits = None
            data = None

            while True:
                chunk_hdr = f.read(8)
                if len(chunk_hdr) < 8:
                    break
                cid, size = chunk_hdr[0:4], struct.unpack("<I", chunk_hdr[4:8])[0]
                # Chunk sizes are word-aligned
                payload_size = size + (size & 1)

                if cid == b"fmt ":
                    fmt = f.read(size)
                    if size & 1:
                        f.read(1)
                    if len(fmt) < 16:
                        return None
                    fmt_tag, channels, sr, _byte_rate, _block_align, bits = struct.unpack(
                        "<HHIIHH", fmt[:16]
                    )
                elif cid == b"data":
                    max_bytes = None
                    if sr and channels and bits and max_seconds > 0:
                        bytes_per_frame = max(1, channels * ((bits + 7) // 8))
                        max_bytes = int(sr * max_seconds) * bytes_per_frame
                    to_read = size if max_bytes is None else min(size, max_bytes)
                    data = f.read(to_read)
                    # Skip remainder of chunk if truncated read
                    remaining = size - to_read
                    if remaining > 0:
                        f.seek(remaining, 1)
                    if size & 1:
                        f.read(1)
                    break
                else:
                    f.seek(payload_size, 1)

            if data is None or not fmt_tag or not channels or not sr or not bits:
                return None
            if channels < 1 or sr <= 0:
                return None

            if fmt_tag == 1:
                # PCM integer
                sampwidth = bits // 8
                if sampwidth not in (1, 2, 3, 4):
                    return None
                samples = samples_from_pcm_raw(data, sampwidth)
            elif fmt_tag == 3 and bits == 32:
                samples = samples_from_float32_raw(data)
            else:
                return None

            samples = to_mono(samples, channels)
            if not samples:
                return None
            return samples, int(sr)
    except Exception:
        return None


def finish_analysis(
    result: Dict[str, float],
    path: str,
    samples: List[float],
    sr: int,
    mode: str,
) -> Dict[str, float]:
    if mode == "transient":
        return attach_transient_sustain(result, samples, sr)
    attach_effective_duration(result, path, samples, sr)
    return attach_playback_type(result, path, samples, sr)


def analyze_samples(
    samples: List[float], sr: int, path: str, mode: str = "full"
) -> Dict[str, float]:
    """Build analyzer result dict from mono float samples."""
    if not samples or sr <= 0:
        return {}

    if mode == "transient":
        return attach_transient_sustain({}, samples, sr)

    sum_sq = 0.0
    for x in samples:
        sum_sq += x * x
    rms_norm = math.sqrt(sum_sq / len(samples))

    dominant_freq = estimate_dominant_freq(samples, sr)

    result: Dict[str, float] = {"rms_energy": float(rms_norm)}
    if dominant_freq is not None:
        result["dominant_freq"] = float(dominant_freq)

    path_lower = path.lower()
    if "swell" in path_lower:
        result["sample_type"] = "Swell"  # type: ignore[assignment]
        window_size = 512
        hop_size = 256
        energy_envelope = []
        for i in range(0, len(samples) - window_size + 1, hop_size):
            window = samples[i : i + window_size]
            energy = math.sqrt(sum(x * x for x in window) / len(window))
            energy_envelope.append(energy)
        if energy_envelope:
            snap = detect_swell_cue_point(samples, sr, energy_envelope, window_size, hop_size)
            if snap is not None:
                result["snap_offset"] = float(snap)

    return result


def analyze_with_wave_module(
    path: str, mode: str = "full"
) -> Optional[Dict[str, float]]:
    """Fallback for standard PCM WAV via stdlib wave (+ optional audioop)."""
    try:
        with wave.open(path, "rb") as wf:
            frames = wf.getnframes()
            sr = wf.getframerate()
            sampwidth = wf.getsampwidth()
            n_channels = wf.getnchannels()
            if frames == 0 or sr <= 0 or sampwidth == 0:
                return None

            max_frames = min(frames, sr * 2)
            raw = wf.readframes(max_frames)
            if not raw:
                return None

            if n_channels > 1 and audioop is not None:
                try:
                    raw = audioop.tomono(raw, sampwidth, 0.5, 0.5)
                    n_channels = 1
                except Exception:
                    pass

            samples = samples_from_pcm_raw(raw, sampwidth)
            samples = to_mono(samples, n_channels)
            if not samples:
                return None
            result = analyze_samples(samples, int(sr), path, mode)
            return finish_analysis(result, path, samples, int(sr), mode)
    except Exception:
        return None


def analyze_wav(path: str, mode: str = "full") -> Optional[Dict[str, float]]:
    """Prefer manual reader (PCM + float), then stdlib wave."""
    manual = read_wav_manual(path)
    if manual is not None:
        samples, sr = manual
        result = analyze_samples(samples, sr, path, mode)
        return finish_analysis(result, path, samples, sr, mode)
    return analyze_with_wave_module(path, mode)


def analyze_via_afconvert(path: str, mode: str = "full") -> Optional[Dict[str, float]]:
    """Convert any CoreAudio-readable file to a temp PCM WAV, then analyze."""
    if sys.platform != "darwin":
        return None
    afconvert = "/usr/bin/afconvert"
    if not os.path.isfile(afconvert):
        return None

    tmp_path = None
    try:
        fd, tmp_path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        # 16-bit PCM mono, first few seconds is enough (afconvert converts whole file;
        # still OK for typical one-shots; long files may be slower).
        proc = subprocess.run(
            [afconvert, path, tmp_path, "-f", "WAVE", "-d", "LEI16", "-c", "1"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if proc.returncode != 0 or not os.path.isfile(tmp_path) or os.path.getsize(tmp_path) < 44:
            return None
        return analyze_wav(tmp_path, mode)
    except Exception:
        return None
    finally:
        if tmp_path and os.path.isfile(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


def analyze_file(path: str, mode: str = "full") -> Dict[str, float]:
    ext = os.path.splitext(path)[1].lower()
    data = None
    if ext in (".wav", ".wave"):
        data = analyze_wav(path, mode)
    elif ext in (".aif", ".aiff"):
        # Try wave-compatible path first (rarely works), then afconvert
        data = analyze_with_wave_module(path, mode)
        need_convert = not data or (
            mode == "transient" and data.get("transient_end") is None
        ) or (
            mode != "transient" and data.get("dominant_freq") is None
        )
        if need_convert:
            converted = analyze_via_afconvert(path, mode)
            if converted:
                data = converted
    else:
        data = analyze_via_afconvert(path, mode)

    if not data:
        return {}
    # If WAV path got RMS but no freq, still try afconvert once (odd encodings)
    if mode != "transient" and data.get("dominant_freq") is None and ext in (".wav", ".wave"):
        converted = analyze_via_afconvert(path, mode)
        if converted and converted.get("dominant_freq") is not None:
            data = converted
    return data


def parse_cli(argv: List[str]) -> Tuple[Optional[str], str]:
    mode = "full"
    path = None
    for arg in argv:
        if arg in ("--transient", "-t"):
            mode = "transient"
        elif arg in ("-h", "--help"):
            continue
        elif not arg.startswith("-"):
            path = arg
    return path, mode


def main() -> int:
    path, mode = parse_cli(sys.argv[1:])
    if not path:
        sys.stderr.write("Usage: SampleMapAnalyzer.py [--transient] /path/to/audio\n")
        return 1

    if not os.path.isfile(path):
        sys.stderr.write(f"File not found: {path}\n")
        return 1

    data = analyze_file(path, mode)
    result = {}
    for k, v in data.items():
        if v is not None:
            result[k] = v

    sys.stdout.write(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
