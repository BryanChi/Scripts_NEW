#!/usr/bin/env python3
"""
Transcribe audio with WhisperX (word-level timestamps) and write JSON for REAPER / lyric tooling.

One-shot mode: loads models, transcribes, exits.
For repeat dictation without reload time, use reaper_whisperx_server.py (Load model in settings GUI).
"""

from __future__ import annotations

import argparse
import atexit
import sys

from reaper_whisperx_core import (
    PipelineConfig,
    TranscribeJob,
    WhisperXPipeline,
    ensure_ffmpeg_on_path,
    write_progress,
)


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
    ap.add_argument(
        "--chunk-size",
        type=int,
        default=None,
        metavar="SEC",
        help="VAD merge chunk length (seconds). Smaller ⇒ shorter Whisper segments ⇒ less stress on JA wav2vec alignment (often try 10–18 vs default ~30). Also forwarded to vad_options.",
    )
    ap.add_argument(
        "--vad-method",
        choices=("pyannote", "silero"),
        default="pyannote",
        help="VAD backend for splitting audio before ASR (silero avoids pyannote’s HF model download when pyannote is unused elsewhere).",
    )
    ap.add_argument(
        "--vad-onset",
        type=float,
        default=None,
        metavar="X",
        help="Optional VAD onset (WhisperX default ~0.5). Lower tends to lengthen detected speech spans.",
    )
    ap.add_argument(
        "--vad-offset",
        type=float,
        default=None,
        metavar="X",
        help="Optional VAD offset (WhisperX default ~0.363).",
    )
    ap.add_argument(
        "--beam-size",
        type=int,
        default=None,
        metavar="N",
        help="Optional faster-whisper beam_size (WhisperX default 5). Changes decoding quality/speed; indirect effect on segments.",
    )
    ap.add_argument(
        "--align-model",
        default=None,
        metavar="HF_MODEL_ID",
        help="Optional Hugging Face wav2vec2 checkpoint for forced alignment (overrides WhisperX default for that language).",
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
        write_progress(args.progress_file, pct, msg)

    dlog(f"argv={sys.argv!r}")
    dlog(f"input={args.input!r} exists={__import__('os').path.isfile(args.input)}")
    dlog(f"output={args.output!r}")

    report_progress(1, "starting")
    if not ensure_ffmpeg_on_path(dlog):
        return 1

    report_progress(4, "importing WhisperX")
    try:
        import whisperx  # noqa: F401
    except BaseException:
        import traceback

        dlog(traceback.format_exc())
        raise

    cfg = PipelineConfig(
        model=args.model,
        device=args.device,
        compute_type=args.compute_type,
        batch_size=max(1, int(args.batch_size)),
        language=(args.language or "").strip() or None,
        interpolate_method=args.interpolate_method,
        chunk_size=args.chunk_size,
        vad_method=args.vad_method,
        vad_onset=args.vad_onset,
        vad_offset=args.vad_offset,
        beam_size=args.beam_size,
        align_model=(args.align_model or "").strip() or None,
        diarize=args.diarize,
        hf_token=args.hf_token,
        min_speakers=args.min_speakers,
        max_speakers=args.max_speakers,
    )

    job = TranscribeJob(
        input_path=args.input,
        output_path=args.output,
        mirror_json=args.mirror_json,
        mirror_tsv=args.mirror_tsv,
        mirror_plain=args.mirror_plain,
        debug_log=args.debug_log,
        progress_file=args.progress_file,
        done_flag=args.done_flag,
    )

    pipeline = WhisperXPipeline()

    def load_report(pct: int, msg: str) -> None:
        report_progress(pct, msg)

    pipeline.load(cfg, report=load_report, dlog=dlog)
    code = pipeline.transcribe(job, cfg, dlog=dlog)
    pipeline.unload(dlog=dlog)

    mark_exit(code)
    return code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except BaseException:
        import traceback

        tb = traceback.format_exc()
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
