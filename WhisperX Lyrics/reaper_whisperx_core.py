"""Shared WhisperX transcription pipeline for one-shot CLI and persistent REAPER server."""

from __future__ import annotations

import gc
import json
import os
import shutil
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable


def sidecar_paths(json_out: str) -> tuple[str, str]:
    """foo.whisperx.json -> foo.words.tsv / foo.plain.txt (not foo.whisperx.words.tsv)."""
    suf = ".whisperx.json"
    if json_out.endswith(suf):
        stem = json_out[: -len(suf)]
    else:
        stem = os.path.splitext(json_out)[0]
    return stem + ".words.tsv", stem + ".plain.txt"


def ensure_ffmpeg_on_path(dlog: Callable[[str], None]) -> bool:
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
        return False
    return True


def serialize_segment(seg: dict[str, Any]) -> dict[str, Any]:
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


def is_single_ascii_letter(s: str) -> bool:
    s = s.strip()
    return len(s) == 1 and s.isascii() and s.isalpha()


def merge_latin_letter_runs_in_words(
    words: list[dict[str, Any]], *, max_gap_s: float = 0.22
) -> list[dict[str, Any]]:
    if len(words) < 2:
        return words
    out: list[dict[str, Any]] = []
    i = 0
    n = len(words)
    while i < n:
        w = words[i]
        text = (w.get("word") or "").replace("\t", " ").replace("\n", " ").strip()
        if not is_single_ascii_letter(text):
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
            if not is_single_ascii_letter(t2):
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


def write_progress(path: str | None, pct: int, msg: str) -> None:
    if not path:
        return
    pct = max(0, min(100, int(pct)))
    try:
        with open(path, "w", encoding="utf-8") as pf:
            pf.write(f"{pct}\n{msg}\n")
    except OSError:
        pass


def start_progress_pulse(
    report: Callable[[int, str], None], pct: int, prefix: str
) -> tuple[threading.Event, threading.Thread]:
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
            report(pct, f"{prefix} ({elapsed}s){hint}")

    th = threading.Thread(target=_body, daemon=True, name="whisperx-reaper-pulse")
    th.start()
    return stop, th


def stop_progress_pulse(stop: threading.Event, th: threading.Thread) -> None:
    stop.set()
    th.join(timeout=2.0)


def empty_cuda_cache(device: str) -> None:
    if device != "cuda":
        return
    try:
        import torch

        torch.cuda.empty_cache()
    except Exception:
        pass


@dataclass
class PipelineConfig:
    model: str = "small"
    device: str = "cpu"
    compute_type: str = "int8"
    batch_size: int = 8
    language: str | None = None
    interpolate_method: str = "linear"
    chunk_size: int | None = None
    vad_method: str = "pyannote"
    vad_onset: float | None = None
    vad_offset: float | None = None
    beam_size: int | None = None
    align_model: str | None = None
    diarize: bool = False
    hf_token: str | None = None
    min_speakers: int | None = None
    max_speakers: int | None = None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> PipelineConfig:
        return cls(
            model=str(d.get("model") or "small"),
            device=str(d.get("device") or "cpu"),
            compute_type=str(d.get("compute_type") or "int8"),
            batch_size=max(1, int(d.get("batch_size") or 8)),
            language=(str(d["language"]).strip() or None) if d.get("language") else None,
            interpolate_method=str(d.get("interpolate_method") or "linear"),
            chunk_size=int(d["chunk_size"]) if d.get("chunk_size") is not None else None,
            vad_method=str(d.get("vad_method") or "pyannote"),
            vad_onset=float(d["vad_onset"]) if d.get("vad_onset") is not None else None,
            vad_offset=float(d["vad_offset"]) if d.get("vad_offset") is not None else None,
            beam_size=int(d["beam_size"]) if d.get("beam_size") is not None else None,
            align_model=(str(d["align_model"]).strip() or None) if d.get("align_model") else None,
            diarize=bool(d.get("diarize")),
            hf_token=(str(d["hf_token"]).strip() or None) if d.get("hf_token") else None,
            min_speakers=int(d["min_speakers"]) if d.get("min_speakers") is not None else None,
            max_speakers=int(d["max_speakers"]) if d.get("max_speakers") is not None else None,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "model": self.model,
            "device": self.device,
            "compute_type": self.compute_type,
            "batch_size": self.batch_size,
            "language": self.language,
            "interpolate_method": self.interpolate_method,
            "chunk_size": self.chunk_size,
            "vad_method": self.vad_method,
            "vad_onset": self.vad_onset,
            "vad_offset": self.vad_offset,
            "beam_size": self.beam_size,
            "align_model": self.align_model,
            "diarize": self.diarize,
            "hf_token": self.hf_token,
            "min_speakers": self.min_speakers,
            "max_speakers": self.max_speakers,
        }

    def load_signature(self) -> dict[str, Any]:
        """Fields that must match for a cached ASR model to be reused."""
        return {
            "model": self.model,
            "device": self.device,
            "compute_type": self.compute_type,
            "language": self.language,
            "vad_method": self.vad_method,
            "vad_onset": self.vad_onset,
            "vad_offset": self.vad_offset,
            "beam_size": self.beam_size,
            "chunk_size": self.chunk_size,
            "align_model": self.align_model,
        }


@dataclass
class TranscribeJob:
    input_path: str
    output_path: str
    mirror_json: str | None = None
    mirror_tsv: str | None = None
    mirror_plain: str | None = None
    debug_log: str | None = None
    progress_file: str | None = None
    done_flag: str | None = None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> TranscribeJob:
        return cls(
            input_path=str(d["input"]),
            output_path=str(d["output"]),
            mirror_json=d.get("mirror_json"),
            mirror_tsv=d.get("mirror_tsv"),
            mirror_plain=d.get("mirror_plain"),
            debug_log=d.get("debug_log"),
            progress_file=d.get("progress_file"),
            done_flag=d.get("done_flag"),
        )


class WhisperXPipeline:
    """Keeps ASR (and per-language align) models in memory between jobs."""

    def __init__(self) -> None:
        self._whisperx: Any = None
        self.asr_model: Any = None
        self.align_cache: dict[str, tuple[Any, Any]] = {}
        self.load_config: PipelineConfig | None = None
        self._vad_options: dict[str, Any] = {}
        self._asr_options: dict[str, Any] | None = None
        self._vad_method: str = "pyannote"

    def is_loaded(self) -> bool:
        return self.asr_model is not None and self.load_config is not None

    def config_matches(self, cfg: PipelineConfig) -> bool:
        if not self.is_loaded() or self.load_config is None:
            return False
        return self.load_config.load_signature() == cfg.load_signature()

    def _ensure_whisperx(self) -> Any:
        if self._whisperx is None:
            import whisperx

            self._whisperx = whisperx
        return self._whisperx

    def _build_vad_asr_options(self, cfg: PipelineConfig) -> None:
        vad_options: dict[str, Any] = {}
        if cfg.chunk_size is not None:
            vad_options["chunk_size"] = max(4, min(int(cfg.chunk_size), 120))
        if cfg.vad_onset is not None:
            vad_options["vad_onset"] = float(cfg.vad_onset)
        if cfg.vad_offset is not None:
            vad_options["vad_offset"] = float(cfg.vad_offset)
        self._vad_options = vad_options

        asr_options: dict[str, Any] | None = None
        if cfg.beam_size is not None:
            asr_options = {"beam_size": max(1, min(int(cfg.beam_size), 50))}
        self._asr_options = asr_options

        vad_method = (cfg.vad_method or "pyannote").strip().lower()
        if vad_method not in ("pyannote", "silero"):
            vad_method = "pyannote"
        self._vad_method = vad_method

    def load(
        self,
        cfg: PipelineConfig,
        *,
        report: Callable[[int, str], None] | None = None,
        dlog: Callable[[str], None] | None = None,
    ) -> None:
        dlog = dlog or (lambda _m: None)
        report = report or (lambda _p, _m: None)

        if self.is_loaded() and self.config_matches(cfg):
            dlog("models already loaded with matching config")
            report(100, "models ready (cached)")
            return

        self.unload(dlog=dlog)

        whisperx = self._ensure_whisperx()
        self._build_vad_asr_options(cfg)
        device = cfg.device
        compute_type = cfg.compute_type

        dlog(
            "load_model… "
            f"model={cfg.model!r} device={device!r} compute_type={compute_type!r} "
            "(first run may download multi-GB weights into the Hugging Face cache)"
        )
        pulse_stop, pulse_th = start_progress_pulse(report, 22, "loading ASR model")
        try:
            self.asr_model = whisperx.load_model(
                cfg.model,
                device,
                language=cfg.language,
                compute_type=compute_type,
                vad_method=self._vad_method,
                vad_options=self._vad_options if self._vad_options else None,
                asr_options=self._asr_options,
            )
        finally:
            stop_progress_pulse(pulse_stop, pulse_th)

        if cfg.language:
            self._ensure_align_model(cfg.language, cfg, report=report, dlog=dlog)

        self.load_config = cfg
        report(100, "models ready")
        dlog("load complete")

    def unload(self, *, dlog: Callable[[str], None] | None = None) -> None:
        dlog = dlog or (lambda _m: None)
        self.asr_model = None
        self.align_cache.clear()
        self.load_config = None
        self._vad_options = {}
        self._asr_options = None
        gc.collect()
        empty_cuda_cache("cuda")
        dlog("models unloaded")

    def _ensure_align_model(
        self,
        lang: str,
        cfg: PipelineConfig,
        *,
        report: Callable[[int, str], None] | None = None,
        dlog: Callable[[str], None] | None = None,
    ) -> tuple[Any, Any]:
        report = report or (lambda _p, _m: None)
        dlog = dlog or (lambda _m: None)
        lang = (lang or "en").strip() or "en"
        if lang in self.align_cache:
            return self.align_cache[lang]

        whisperx = self._ensure_whisperx()
        report(58, f"loading align model ({lang})")
        pulse_stop, pulse_th = start_progress_pulse(report, 58, f"loading align model ({lang})")
        try:
            align_kw: dict[str, Any] = {"language_code": lang, "device": cfg.device}
            if cfg.align_model and str(cfg.align_model).strip():
                align_kw["model_name"] = str(cfg.align_model).strip()
            align_model, align_meta = whisperx.load_align_model(**align_kw)
        finally:
            stop_progress_pulse(pulse_stop, pulse_th)

        self.align_cache[lang] = (align_model, align_meta)
        dlog(f"align model cached for language={lang!r}")
        return align_model, align_meta

    def transcribe(
        self,
        job: TranscribeJob,
        cfg: PipelineConfig,
        *,
        dlog: Callable[[str], None] | None = None,
    ) -> int:
        dlog = dlog or (lambda _m: None)
        exit_code = 1

        def report(pct: int, msg: str) -> None:
            write_progress(job.progress_file, pct, msg)

        def mark_exit(code: int) -> None:
            nonlocal exit_code
            exit_code = int(code)
            if job.done_flag:
                try:
                    with open(job.done_flag, "w", encoding="utf-8") as ef:
                        ef.write(str(exit_code))
                except OSError:
                    pass

        try:
            if not self.is_loaded():
                raise RuntimeError("models not loaded — call load() first")
            if not self.config_matches(cfg):
                raise RuntimeError("loaded model config does not match job config")

            whisperx = self._ensure_whisperx()
            device = cfg.device
            batch_size = max(1, int(cfg.batch_size))

            report(1, "starting")
            if not ensure_ffmpeg_on_path(dlog):
                mark_exit(1)
                return 1

            report(10, "loading audio")
            dlog(f"loading audio from {job.input_path!r}")
            audio = whisperx.load_audio(job.input_path)

            pulse_stop, pulse_th = start_progress_pulse(report, 32, "transcribing")
            try:
                report(32, "transcribing")
                transcribe_kw: dict[str, Any] = dict(batch_size=batch_size, language=cfg.language)
                if cfg.chunk_size is not None:
                    transcribe_kw["chunk_size"] = max(4, min(int(cfg.chunk_size), 120))
                result = self.asr_model.transcribe(audio, **transcribe_kw)
            finally:
                stop_progress_pulse(pulse_stop, pulse_th)

            lang = (cfg.language or "").strip() or None
            if not lang:
                detected = result.get("language")
                if isinstance(detected, str) and detected.strip():
                    lang = detected.strip()
                else:
                    lang = "en"

            align_model, align_meta = self._ensure_align_model(lang, cfg, report=report, dlog=dlog)

            pulse_stop, pulse_th = start_progress_pulse(report, 68, "aligning words")
            try:
                report(68, "aligning words")
                result = whisperx.align(
                    result["segments"],
                    align_model,
                    align_meta,
                    audio,
                    device,
                    return_char_alignments=False,
                    interpolate_method=cfg.interpolate_method,
                )
            finally:
                stop_progress_pulse(pulse_stop, pulse_th)

            if cfg.diarize:
                if not cfg.hf_token:
                    dlog("ERROR: diarize requires hf_token.")
                    mark_exit(2)
                    return 2
                from whisperx.diarize import DiarizationPipeline

                report(78, "diarizing")
                diarize_model = DiarizationPipeline(token=cfg.hf_token, device=device)
                try:
                    diarize_segments = diarize_model(
                        audio,
                        min_speakers=cfg.min_speakers,
                        max_speakers=cfg.max_speakers,
                    )
                finally:
                    del diarize_model
                    gc.collect()

                result = whisperx.assign_word_speakers(diarize_segments, result)

            segments = result.get("segments") or []
            serialized = [serialize_segment(s) for s in segments if isinstance(s, dict)]
            merged_drop = 0
            for seg in serialized:
                ws = seg.get("words")
                if isinstance(ws, list) and len(ws) >= 2:
                    new_ws = merge_latin_letter_runs_in_words(ws)
                    merged_drop += len(ws) - len(new_ws)
                    seg["words"] = new_ws
            if merged_drop:
                dlog(f"merged per-letter Latin tokens into words: net −{merged_drop} rows")

            pipeline_opts: dict[str, Any] = {
                "vad_method": self._vad_method,
                "interpolate_method": cfg.interpolate_method,
            }
            if self._vad_options:
                pipeline_opts["vad_options"] = dict(self._vad_options)
            if cfg.chunk_size is not None:
                pipeline_opts["chunk_size_seconds"] = max(4, min(int(cfg.chunk_size), 120))
            if self._asr_options:
                pipeline_opts["asr_options"] = dict(self._asr_options)
            if cfg.align_model and str(cfg.align_model).strip():
                pipeline_opts["align_model"] = str(cfg.align_model).strip()

            payload: dict[str, Any] = {
                "language": lang,
                "model": cfg.model,
                "source_file": job.input_path,
                "segments": serialized,
                "pipeline_options": pipeline_opts,
            }

            report(86, "writing JSON and sidecars")
            out_dir = os.path.dirname(os.path.abspath(job.output_path))
            if out_dir:
                os.makedirs(out_dir, exist_ok=True)

            with open(job.output_path, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=2)

            words_tsv, plain_path = sidecar_paths(job.output_path)
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

            for src, dst in (
                (job.output_path, job.mirror_json),
                (words_tsv, job.mirror_tsv),
                (plain_path, job.mirror_plain),
            ):
                if not dst:
                    continue
                try:
                    md = os.path.dirname(os.path.abspath(dst))
                    if md:
                        os.makedirs(md, exist_ok=True)
                    shutil.copy2(src, dst)
                except OSError as exc:
                    dlog(f"mirror failed {dst!r}: {exc!r}")

            report(100, "done")
            dlog("transcribe done exit 0")
            mark_exit(0)
            return 0

        except BaseException:
            import traceback

            tb = traceback.format_exc()
            dlog(tb)
            mark_exit(1)
            return 1
