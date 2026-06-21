#!/usr/bin/env python3
"""
Persistent WhisperX server for REAPER — keeps ASR (and align) models in memory.

IPC directory (default): ../.whisperx_server/ next to WhisperX Lyrics/
  state.json     — server status (polled by Lua)
  request.json   — command from Lua (atomic write via request.tmp rename)
  response.json  — result of last command
  pid.txt        — server PID
  server.log     — append-only debug log

Commands (request.json):
  {"cmd": "load", "config": {...PipelineConfig fields...}}
  {"cmd": "unload"}
  {"cmd": "transcribe", "config": {...}, "job": {...TranscribeJob fields...}}
  {"cmd": "ping"}
  {"cmd": "shutdown"}
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
import traceback
from typing import Any

from reaper_whisperx_core import PipelineConfig, TranscribeJob, WhisperXPipeline, write_progress


def _server_dir_from_argv() -> str:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--server_dir", default=None)
    known, _ = ap.parse_known_args()
    if known.server_dir:
        return os.path.abspath(known.server_dir)
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", ".whisperx_server"))


SERVER_DIR = _server_dir_from_argv()
STATE_PATH = os.path.join(SERVER_DIR, "state.json")
REQUEST_PATH = os.path.join(SERVER_DIR, "request.json")
REQUEST_TMP = os.path.join(SERVER_DIR, "request.tmp")
RESPONSE_PATH = os.path.join(SERVER_DIR, "response.json")
PID_PATH = os.path.join(SERVER_DIR, "pid.txt")
LOG_PATH = os.path.join(SERVER_DIR, "server.log")

POLL_INTERVAL_S = 0.25


def dlog(msg: str) -> None:
    line = time.strftime("%Y-%m-%d %H:%M:%S") + " " + msg
    try:
        os.makedirs(SERVER_DIR, exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def write_state(
    phase: str,
    *,
    loaded: bool = False,
    load_config: dict[str, Any] | None = None,
    progress_pct: int = 0,
    progress_msg: str = "",
    last_error: str = "",
    busy: bool = False,
) -> None:
    payload: dict[str, Any] = {
        "phase": phase,
        "pid": os.getpid(),
        "loaded": loaded,
        "load_config": load_config,
        "progress_pct": max(0, min(100, int(progress_pct))),
        "progress_msg": progress_msg,
        "last_error": last_error,
        "busy": busy,
        "server_dir": SERVER_DIR,
    }
    try:
        os.makedirs(SERVER_DIR, exist_ok=True)
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.replace(tmp, STATE_PATH)
    except OSError as exc:
        dlog(f"write_state failed: {exc!r}")


def write_response(ok: bool, *, exit_code: int = 0, error: str = "", extra: dict[str, Any] | None = None) -> None:
    payload: dict[str, Any] = {
        "ok": ok,
        "exit_code": exit_code,
        "error": error,
        "ts": time.time(),
    }
    if extra:
        payload.update(extra)
    try:
        tmp = RESPONSE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.replace(tmp, RESPONSE_PATH)
    except OSError as exc:
        dlog(f"write_response failed: {exc!r}")


def read_request() -> dict[str, Any] | None:
    if not os.path.isfile(REQUEST_PATH):
        return None
    try:
        with open(REQUEST_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        os.remove(REQUEST_PATH)
        if isinstance(data, dict):
            return data
    except (OSError, json.JSONDecodeError) as exc:
        dlog(f"read_request failed: {exc!r}")
        try:
            os.remove(REQUEST_PATH)
        except OSError:
            pass
    return None


def main() -> int:
    os.makedirs(SERVER_DIR, exist_ok=True)
    with open(PID_PATH, "w", encoding="utf-8") as pf:
        pf.write(str(os.getpid()))

    pipeline = WhisperXPipeline()
    shutdown = False
    load_cfg_dict: dict[str, Any] | None = None

    def on_signal(_signum: int, _frame: Any) -> None:
        nonlocal shutdown
        shutdown = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    write_state("starting", loaded=False, progress_msg="server starting")
    dlog(f"WhisperX server pid={os.getpid()} dir={SERVER_DIR!r}")

    try:
        import whisperx  # noqa: F401
    except BaseException:
        tb = traceback.format_exc()
        dlog(tb)
        write_state("error", last_error=tb, progress_msg="WhisperX import failed")
        return 1

    write_state("idle", loaded=False, progress_msg="waiting for load command")

    while not shutdown:
        req = read_request()
        if req is None:
            time.sleep(POLL_INTERVAL_S)
            continue

        cmd = str(req.get("cmd") or "").strip().lower()
        dlog(f"command: {cmd!r}")

        if cmd == "ping":
            write_response(
                True,
                extra={
                    "loaded": pipeline.is_loaded(),
                    "load_config": load_cfg_dict,
                    "phase": "busy" if pipeline.is_loaded() else "idle",
                },
            )
            continue

        if cmd == "shutdown":
            pipeline.unload(dlog=dlog)
            write_response(True, exit_code=0)
            write_state("stopped", loaded=False, progress_msg="shutting down")
            dlog("shutdown requested")
            return 0

        if cmd == "unload":
            write_state(
                "unloading",
                loaded=pipeline.is_loaded(),
                load_config=load_cfg_dict,
                progress_msg="unloading models",
            )
            pipeline.unload(dlog=dlog)
            load_cfg_dict = None
            write_response(True, exit_code=0)
            write_state("idle", loaded=False, progress_msg="models unloaded — ready to load")
            continue

        if cmd == "load":
            cfg = PipelineConfig.from_dict(req.get("config") or {})
            load_cfg_dict = cfg.to_dict()

            def report(pct: int, msg: str) -> None:
                write_state(
                    "loading",
                    loaded=False,
                    load_config=load_cfg_dict,
                    progress_pct=pct,
                    progress_msg=msg,
                )

            write_state("loading", load_config=load_cfg_dict, progress_pct=5, progress_msg="loading models")
            try:
                pipeline.load(cfg, report=report, dlog=dlog)
            except BaseException:
                tb = traceback.format_exc()
                dlog(tb)
                load_cfg_dict = None
                write_response(False, exit_code=1, error=tb)
                write_state("error", loaded=False, last_error=tb, progress_msg="load failed")
                continue

            write_response(True, exit_code=0, extra={"loaded": True, "load_config": load_cfg_dict})
            write_state(
                "ready",
                loaded=True,
                load_config=load_cfg_dict,
                progress_pct=100,
                progress_msg="models loaded — ready for dictation",
            )
            continue

        if cmd == "transcribe":
            cfg = PipelineConfig.from_dict(req.get("config") or {})
            job = TranscribeJob.from_dict(req.get("job") or {})

            if not pipeline.is_loaded():
                err = "models not loaded — use load command first"
                write_response(False, exit_code=1, error=err)
                write_state("error", loaded=False, last_error=err, progress_msg=err)
                continue

            if not pipeline.config_matches(cfg):
                err = "job config does not match loaded models — unload and reload with current settings"
                write_response(False, exit_code=1, error=err)
                write_state(
                    "ready",
                    loaded=True,
                    load_config=load_cfg_dict,
                    last_error=err,
                    progress_msg=err,
                )
                continue

            if job.done_flag and os.path.isfile(job.done_flag):
                try:
                    os.remove(job.done_flag)
                except OSError:
                    pass

            write_state(
                "busy",
                loaded=True,
                load_config=load_cfg_dict,
                busy=True,
                progress_pct=1,
                progress_msg="transcribing",
            )

            def job_dlog(msg: str) -> None:
                dlog(msg)
                if job.progress_file and os.path.isfile(job.progress_file):
                    try:
                        with open(job.progress_file, "r", encoding="utf-8") as pf:
                            l1 = pf.readline().strip()
                            l2 = pf.readline().strip()
                        pct = int(l1) if l1.isdigit() else 0
                        write_state(
                            "busy",
                            loaded=True,
                            load_config=load_cfg_dict,
                            busy=True,
                            progress_pct=pct,
                            progress_msg=l2 or "transcribing",
                        )
                    except (OSError, ValueError):
                        pass

            code = pipeline.transcribe(job, cfg, dlog=job_dlog)
            write_response(True, exit_code=code)
            write_state(
                "ready" if code == 0 else "error",
                loaded=True,
                load_config=load_cfg_dict,
                busy=False,
                progress_pct=100 if code == 0 else 0,
                progress_msg="done" if code == 0 else f"transcribe failed (exit {code})",
                last_error="" if code == 0 else f"exit {code}",
            )
            continue

        err = f"unknown command: {cmd!r}"
        write_response(False, exit_code=1, error=err)
        dlog(err)

    pipeline.unload(dlog=dlog)
    write_state("stopped", loaded=False, progress_msg="stopped")
    dlog("server loop exited")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        write_progress(None, 0, "")
        raise SystemExit(130) from None
