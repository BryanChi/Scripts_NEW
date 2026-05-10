#!/usr/bin/env python3
"""
Transcribe audio with WhisperX (word-level timestamps) and write JSON for REAPER / lyric tooling.

Typical Mac / no-GPU:
  python reaper_whisperx_transcribe.py --input vocal.wav --output out.json --device cpu --compute_type int8

CUDA (Linux/Windows):
  python reaper_whisperx_transcribe.py --input vocal.wav --output out.json --device cuda --compute_type float16
"""

from __future__ import annotations

import argparse
import atexit
import gc
import json
import os
import shutil
import sys
import threading
import time
import threading
import time
from typing import Any


def _sidecar_paths(json_out: str) -> tuple[str, str]:
    """Match REAPER Lua: foo.whisperx.json -> foo.words.tsv / foo.plain.txt (not foo.whisperx.words.tsv)."""
    suf = ".whisperx.json"
    if json_out.endswith(suf):
        stem = json_out[: -len(suf)]
    else:
        stem = os.path.splitext(json_out)[0]
    return stem + ".words.tsv", stem + ".plain.txt"


def _ensure_ffmpeg_on_path(dlog) -> bool:
    """REAPER / GUI launches often inherit a tiny PATH; WhisperX calls `ffmpeg` via subprocess."""
    if sys.platform == "win32":
        dirs = [
            os.path.expandvars(r"%ProgramFiles%\ffmpeg\bin"),
            os.path.expandvars(r"%LocalAppData%\Microsoft\WinGet\Links"),
            r"C:\ffmpeg\bin",
        ]
        prefix = os.pathsep.join(d for d in dirs if d) + os.pathsep
    else:
        prefix = (
            "/opt/homebrew/bin"
            + os.pathsep
            + "/usr/local/bin"
            + os.pathsep
            + "/usr/bin"
            + os.pathsep
        )
    os.environ["PATH"] = prefix + os.environ.get("PATH", "")
    resolved = shutil.which("ffmpeg")
    dlog(f"PATH augmented; shutil.which(ffmpeg)={resolved!r}")
    if not resolved:
        msg = (
            "ffmpeg not found in PATH. WhisperX needs ffmpeg to decode audio.\n"
            "macOS: brew install ffmpeg (then re-run; this script prepends Homebrew bin dirs).\n"
            "Windows: install ffmpeg and add its bin folder to the system PATH, or use WinGet/Chocolatey."
        )
        dlog(msg)
        print(msg, file=sys.stderr, flush=True)
        return False
    return True


def _serialize_segment(seg: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {
        "start": float(seg.get("start", 0.0)),
        "end": float(seg.get("end", 0.0)),
        "text": (seg.get("text") or "").strip(),
    }
    if "speaker" in seg and seg["speaker"] is not None:
        out["speaker"] = seg["speaker"]
    words_in = seg.get("words")
    words_out: list[dict[str, Any]] = []
    if isinstance(words_in, list):
        for w in words_in:
            if not isinstance(w, dict):
                continue
            word = (w.get("word") or "").strip()
            entry: dict[str, Any] = {
                "word": word,
                "start": float(w.get("start", 0.0)),
                "end": float(w.get("end", 0.0)),
            }
            if w.get("score") is not None:
                try:
                    entry["score"] = float(w["score"])
                except (TypeError, ValueError):
                    pass
            if w.get("speaker") is not None:
                entry["speaker"] = w["speaker"]
            words_out.append(entry)
    out["words"] = words_out
    return out
def _is_single_ascii_letter(s: str) -> bool:
    s = s.strip()
    return len(s) == 1 and s.isascii() and s.isalpha()


def _merge_latin_letter_runs_in_words(
    words: list[dict[str, Any]], *, max_gap_s: float = 0.22
) -> list[dict[str, Any]]:
    """WhisperX alignment sometimes emits one timing row per Latin letter; REAPER then gets one marker per letter.

    Merge consecutive single-letter ASCII tokens when their starts are close in time (same spoken word).
    Standalone one-letter words (\"I\", \"a\") stay a single row when not followed by another letter token
    within the gap threshold.
    """
    if len(words) < 2:
        return words
    out: list[dict[str, Any]] = []
    i = 0
    n = len(words)
    while i < n:
        w = words[i]
        text = (w.get("word") or "").replace("\t", " ").replace("\n", " ").strip()
        if not _is_single_ascii_letter(text):
            out.append(dict(w))
            i += 1
            continue
        start = float(w.get("start", 0.0))
        end = float(w.get("end", 0.0))
        chars = [text]
        j = i + 1
        while j < n:
            w2 = words[j]
            t2 = (w2.get("word") or "").replace("\t", " ").replace("\n", " ").strip()
            if not _is_single_ascii_letter(t2):
                break
            t2_start = float(w2.get("start", 0.0))
            if t2_start - end > max_gap_s:
                break
            chars.append(t2)
            end = max(end, float(w2.get("end", 0.0)))
            j += 1
        if len(chars) >= 2:
            merged: dict[str, Any] = {"word": "".join(chars), "start": start, "end": end}
            if w.get("score") is not None:
                try:
                    merged["score"] = float(w["score"])
                except (TypeError, ValueError):
                    pass
            if w.get("speaker") is not None:
                merged["speaker"] = w["speaker"]
            out.append(merged)
            i = j
        else:
            out.append(dict(w))
            i += 1
    return out




def main() -> int:
    ap = argparse.ArgumentParser(description="WhisperX → JSON (segments + words)")
    ap.add_argument("--input", required=True, help="Path to WAV/MP3/etc.")
    ap.add_argument("--output", required=True, help="Path to write JSON")
    ap.add_argument("--model", default="small", help="Whisper model name (e.g. tiny, base, small, medium, large-v2)")
    ap.add_argument("--device", default="cpu", help="cpu | cuda | mps (if supported)")
    ap.add_argument("--compute_type", default="int8", help="int8 | float16 | float32 (GPU often float16)")
    ap.add_argument("--batch_size", type=int, default=8, help="Lower if you run out of VRAM/RAM")
    ap.add_argument("--language", default=None, help="Force ISO language code (e.g. en, ja). Default: auto-detect.")
    ap.add_argument(
        "--interpolate_method",
        default="linear",
        help="WhisperX align NaN fill: linear|nearest|quadratic|… (pandas). linear often gives smoother word edges than nearest.",
    )
    ap.add_argument("--diarize", action="store_true", help="Speaker labels (needs --hf_token)")
    ap.add_argument("--hf_token", default=None, help="Hugging Face read token for diarization models")
    ap.add_argument("--min_speakers", type=int, default=None)
    ap.add_argument("--max_speakers", type=int, default=None)
    ap.add_argument(
        "--mirror_json",
        default=None,
        help="Optional ASCII-safe path: copy JSON here after write (Finder / REAPER path quirks).",
    )
    ap.add_argument("--mirror_tsv", default=None, help="Optional path: copy .words.tsv here.")
    ap.add_argument("--mirror_plain", default=None, help="Optional path: copy .plain.txt here.")
    ap.add_argument(
        "--debug_log",
        default=None,
        help="Append-only debug log path (ASCII recommended); REAPER reads this if stdout capture fails.",
    )
    ap.add_argument(
        "--progress_file",
        default=None,
        help="Optional path: overwrite with two lines (0-100 percent, status text) for REAPER UI.",
    )
    ap.add_argument(
        "--done_flag",
        default=None,
        help="Optional path: write exit code (0/1/2) on process exit (atexit) so REAPER can poll.",
    )
    args = ap.parse_args()

    exit_code_holder: list[int] = [1]

    def mark_exit(code: int) -> None:
        exit_code_holder[0] = int(code)

    done_flag_path = args.done_flag
    if done_flag_path:

        def _write_done_flag() -> None:
            try:
                with open(done_flag_path, "w", encoding="utf-8") as ef:
                    ef.write(str(exit_code_holder[0]))
            except OSError:
                pass

        atexit.register(_write_done_flag)

    dbg = args.debug_log

    def dlog(msg: str) -> None:
        if not dbg:
            return
        with open(dbg, "a", encoding="utf-8") as df:
            df.write(msg + "\n")

    if dbg:
        with open(dbg, "w", encoding="utf-8") as df:
            df.write("=== whisperx reaper script ===\n")

    def report_progress(pct: int, msg: str) -> None:
        path = args.progress_file
        if not path:
            return
        pct = max(0, min(100, int(pct)))
        try:
            with open(path, "w", encoding="utf-8") as pf:
                pf.write(f"{pct}\n{msg}\n")
        except OSError:
    def start_progress_pulse(pct: int, prefix: str) -> tuple[threading.Event, threading.Thread]:
        """WhisperX has no hooks inside load_model/transcribe/align; pulse so REAPER UI does not look frozen."""

        stop = threading.Event()
        t0 = time.monotonic()

        def _body() -> None:
            while not stop.wait(3.0):
                elapsed = int(time.monotonic() - t0)
                hint = ""
                if elapsed > 20:
                    hint = " — large models on CPU or first-time Hugging Face download can take many minutes"
                if elapsed > 120:
                    hint = " — if still here, check RAM/swap and ~/.cache/huggingface (HF_HOME); try a smaller MODEL"
                report_progress(pct, f"{prefix} ({elapsed}s){hint}")

        th = threading.Thread(target=_body, daemon=True, name="whisperx-reaper-pulse")
        th.start()
        return stop, th

    def stop_progress_pulse(stop: threading.Event, th: threading.Thread) -> None:
        stop.set()
        th.join(timeout=2.0)

            pass

    dlog(f"argv={sys.argv!r}")
    dlog(f"input={args.input!r} exists={os.path.isfile(args.input)}")
    dlog(f"output={args.output!r}")

    print(f"reaper_whisperx_transcribe: input={args.input!r}", flush=True)
    print(f"reaper_whisperx_transcribe: output={args.output!r}", flush=True)

    report_progress(1, "starting")
    if not _ensure_ffmpeg_on_path(dlog):
        return 1

    report_progress(4, "importing WhisperX")
    try:
        import whisperx
    except BaseException:
        import traceback

        dlog(traceback.format_exc())
        raise

    device = args.device
    compute_type = args.compute_type
    batch_size = max(1, int(args.batch_size))

    report_progress(10, "loading audio")
    dlog("loading audio…")
    dlog(
        "load_model… "
        f"model={args.model!r} device={device!r} compute_type={compute_type!r} "
        "(first run may download multi-GB weights into the Hugging Face cache)"
    )
    pulse_stop, pulse_th = start_progress_pulse(22, "loading ASR model")
    try:
        asr_model = whisperx.load_model(args.model, device, language=args.language, compute_type=compute_type)
    finally:
        stop_progress_pulse(pulse_stop, pulse_th)
    try:
        report_progress(32, "transcribing")
        pulse_stop, pulse_th = start_progress_pulse(32, "transcribing")
        try:
            result = asr_model.transcribe(audio, batch_size=batch_size, language=args.language)
        finally:
            stop_progress_pulse(pulse_stop, pulse_th)
        report_progress(32, "transcribing")
        result = asr_model.transcribe(audio, batch_size=batch_size, language=args.language)
    finally:
        del asr_model
        gc.collect()
        try:
            import torch

            if device == "cuda":
                torch.cuda.empty_cache()
        except Exception:
            pass

    report_progress(58, "loading align model")
    pulse_stop, pulse_th = start_progress_pulse(58, "loading align model")
    try:
        align_model, align_meta = whisperx.load_align_model(language_code=lang, device=device)
    finally:
        stop_progress_pulse(pulse_stop, pulse_th)
    try:
        report_progress(68, "aligning words")
        pulse_stop, pulse_th = start_progress_pulse(68, "aligning words")
        try:
            result = whisperx.align(
                result["segments"],
                align_model,
                align_meta,
                audio,
                device,
                return_char_alignments=False,
                interpolate_method=args.interpolate_method,
            )
        finally:
            stop_progress_pulse(pulse_stop, pulse_th)
            interpolate_method=args.interpolate_method,
        )
    finally:
        del align_model
        gc.collect()
        try:
            import torch

            if device == "cuda":
                torch.cuda.empty_cache()
        except Exception:
            pass

    if args.diarize:
        if not args.hf_token:
            print("ERROR: --diarize requires --hf_token (Hugging Face read token).", file=sys.stderr)
            mark_exit(2)
            return 2
        from whisperx.diarize import DiarizationPipeline

        report_progress(78, "diarizing")
        diarize_model = DiarizationPipeline(token=args.hf_token, device=device)
        try:
            diarize_segments = diarize_model(
                audio,
                min_speakers=args.min_speakers,
                max_speakers=args.max_speakers,
            )
        finally:
            del diarize_model
            gc.collect()

        result = whisperx.assign_word_speakers(diarize_segments, result)

    segments = result.get("segments") or []
    payload: dict[str, Any] = {
        "language": lang,
        "model": args.model,
        "source_file": args.input,
        "segments": [_serialize_segment(s) for s in segments if isinstance(s, dict)],
    merged_drop = 0
    for seg in payload["segments"]:
        ws = seg.get("words")
        if isinstance(ws, list) and len(ws) >= 2:
            new_ws = _merge_latin_letter_runs_in_words(ws)
            merged_drop += len(ws) - len(new_ws)
            seg["words"] = new_ws
    if merged_drop:
        dlog(f"merged per-letter Latin tokens into words: net −{merged_drop} rows (fewer take markers)")

    }

    report_progress(86, "writing JSON and sidecars")
    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    words_tsv, plain_path = _sidecar_paths(args.output)
    dlog(f"sidecars: words_tsv={words_tsv!r} plain={plain_path!r}")

    plain_lines: list[str] = []
    with open(words_tsv, "w", encoding="utf-8") as tsv:
        for seg in payload["segments"]:
            txt = (seg.get("text") or "").strip()
            if txt:
                plain_lines.append(txt)
            for w in seg.get("words") or []:
                if not isinstance(w, dict):
                    continue
                word = (w.get("word") or "").replace("\t", " ").replace("\n", " ").strip()
                if not word:
                    continue
                try:
                    ws = float(w.get("start", 0.0))
                    we = float(w.get("end", 0.0))
                except (TypeError, ValueError):
                    continue
                tsv.write(f"{ws:.9f}\t{we:.9f}\t{word}\n")

    with open(plain_path, "w", encoding="utf-8") as pf:
        pf.write("\n\n".join(plain_lines))
        if plain_lines:
            pf.write("\n")

    abs_json = os.path.abspath(args.output)
    print(f"Wrote JSON {abs_json} ({len(payload['segments'])} segments)", flush=True)
    print(f"Wrote words TSV {os.path.abspath(words_tsv)}", flush=True)
    print(f"Wrote plain transcript {os.path.abspath(plain_path)}", flush=True)

    for src, dst in (
        (args.output, args.mirror_json),
        (words_tsv, args.mirror_tsv),
        (plain_path, args.mirror_plain),
    ):
        if not dst:
            continue
        try:
            md = os.path.dirname(os.path.abspath(dst))
            if md:
                os.makedirs(md, exist_ok=True)
            shutil.copy2(src, dst)
            print(f"Mirrored -> {os.path.abspath(dst)}", flush=True)
        except OSError as exc:
            print(f"Mirror failed ({dst}): {exc}", flush=True)
            dlog(f"mirror failed {dst!r}: {exc!r}")

    report_progress(100, "done")
    dlog("done exit 0")
    mark_exit(0)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stdout, flush=True)
        raise SystemExit(130) from None
    except BaseException:
        import traceback

        tb = traceback.format_exc()
        traceback.print_exc(file=sys.stdout)
        sys.stdout.flush()
        try:
            ap2 = argparse.ArgumentParser(add_help=False)
            ap2.add_argument("--debug_log", default=None)
            known, _ = ap2.parse_known_args()
            if known.debug_log:
                with open(known.debug_log, "a", encoding="utf-8") as df:
                    df.write(tb + "\n")
        except OSError:
            pass
        raise SystemExit(1) from None
