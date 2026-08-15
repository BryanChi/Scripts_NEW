#!/usr/bin/env python3
"""Groove MIDI Dataset sidecar for the Sample Map Browser sequencer.

Downloads Magenta's Groove MIDI Dataset (MIDI-only, ~3 MB) once, indexes
info.csv, and returns drum patterns as role -> sixteenth-note positions so the
Lua sequencer can load them with the same contract as SampleMapDrumAI.py.

I/O contract
------------
argv[1] = path to a JSON request file.

Actions
  {"action": "status"}
  {"action": "ensure"}                         # download + unpack if needed
  {"action": "styles"}                         # list primary style names
  {"action": "list", "style": "funk", "beat_type": "beat",
   "bpm_min": 90, "bpm_max": 140, "limit": 40, "offset": 0}
  {"action": "get", "id": "<gmd id>", "bars": 1, "bar_offset": 0}
  {"action": "random", "style": "rock", "styles": ["rock","punk"],
   "beat_type": "beat", "bars": 1, "seed": 123}

stdout = JSON response. Errors: {"error": "..."}.
"""

from __future__ import annotations

import csv
import json
import os
import random
import struct
import sys
import urllib.request
import zipfile

DATASET_URL = (
    "https://storage.googleapis.com/magentadata/datasets/groove/"
    "groove-v1.0.0-midionly.zip"
)
DATASET_ZIP_NAME = "groove-v1.0.0-midionly.zip"
CACHE_DIRNAME = ".groove_midi"
ENGINE = "groove-midi-v1"

# Roland TD-11 / Magenta Groove pitch -> sequencer role.
# Matches Magenta's documented mapping, collapsed into Sample Map Browser roles.
PITCH_TO_ROLE = {
    36: "kick",
    38: "snare",
    40: "snare",
    37: "rim",
    48: "tom",
    50: "tom",
    45: "tom",
    47: "tom",
    43: "tom",
    58: "tom",
    46: "hat",
    26: "hat",
    42: "hat",
    22: "hat",
    44: "hat",
    49: "crash",
    55: "crash",
    57: "crash",
    52: "crash",
    51: "ride",
    59: "ride",
    53: "ride",
}

# Map Sample Map Browser genre presets -> GMD primary style names.
STYLE_TO_GMD = {
    "house": ["dance"],
    "techno": ["dance"],
    "disco": ["dance", "soul", "funk"],
    "basic": ["pop", "rock"],
    "rock": ["rock", "punk"],
    "hiphop": ["hiphop"],
    "trap": ["hiphop"],
    "funk": ["funk", "soul"],
    "dnb": ["funk", "hiphop"],
    "breakbeat": ["funk", "hiphop"],
    "reggaeton": ["latin", "reggae"],
    "afrobeat": ["afrobeat", "afrocuban", "highlife"],
}

GMD_PRIMARY_STYLES = {
    "afrobeat", "afrocuban", "blues", "country", "dance", "funk", "gospel",
    "highlife", "hiphop", "jazz", "latin", "middleeastern", "neworleans",
    "pop", "punk", "reggae", "rock", "soul",
}


def script_dir():
    return os.path.dirname(os.path.abspath(__file__))


def cache_dir():
    return os.path.join(script_dir(), CACHE_DIRNAME)


def zip_path():
    return os.path.join(cache_dir(), DATASET_ZIP_NAME)


def extract_root():
    return os.path.join(cache_dir(), "groove")


def info_csv_path():
    return os.path.join(extract_root(), "info.csv")


def ensure_cache_dir():
    os.makedirs(cache_dir(), exist_ok=True)


def is_ready():
    return os.path.isfile(info_csv_path())


def download_and_extract():
    ensure_cache_dir()
    zpath = zip_path()
    if not os.path.isfile(zpath):
        tmp = zpath + ".partial"
        try:
            with urllib.request.urlopen(DATASET_URL, timeout=120) as resp, open(tmp, "wb") as out:
                while True:
                    chunk = resp.read(1024 * 256)
                    if not chunk:
                        break
                    out.write(chunk)
            os.replace(tmp, zpath)
        except Exception:
            if os.path.isfile(tmp):
                try:
                    os.remove(tmp)
                except OSError:
                    pass
            raise

    root = extract_root()
    if not os.path.isdir(root):
        with zipfile.ZipFile(zpath, "r") as zf:
            zf.extractall(cache_dir())

    if not is_ready():
        raise RuntimeError("Groove MIDI Dataset extracted but info.csv is missing")


def primary_style(style_field):
    s = (style_field or "").strip().lower()
    if not s:
        return ""
    return s.split("/", 1)[0].strip()


def load_index():
    if not is_ready():
        return []
    rows = []
    with open(info_csv_path(), "r", newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            midi_rel = (row.get("midi_filename") or "").strip()
            if not midi_rel:
                continue
            style = (row.get("style") or "").strip()
            entry = {
                "id": (row.get("id") or "").strip() or midi_rel,
                "drummer": (row.get("drummer") or "").strip(),
                "session": (row.get("session") or "").strip(),
                "style": style,
                "style_primary": primary_style(style),
                "bpm": _to_int(row.get("bpm"), 120),
                "beat_type": (row.get("beat_type") or "").strip().lower(),
                "time_signature": (row.get("time_signature") or "").strip(),
                "duration": _to_float(row.get("duration"), 0.0),
                "midi_filename": midi_rel,
                "split": (row.get("split") or "").strip(),
            }
            rows.append(entry)
    return rows


def _to_int(val, default=0):
    try:
        return int(float(val))
    except (TypeError, ValueError):
        return default


def _to_float(val, default=0.0):
    try:
        return float(val)
    except (TypeError, ValueError):
        return default


def resolve_styles(req):
    """Return a list of GMD primary styles to filter on, or None for all."""
    styles = req.get("styles")
    if isinstance(styles, list) and styles:
        return [str(s).strip().lower() for s in styles if str(s).strip()]

    style = req.get("style")
    if style is None or style == "" or str(style).lower() in ("all", "*"):
        return None

    key = str(style).strip().lower()
    if key in STYLE_TO_GMD:
        return list(STYLE_TO_GMD[key])
    if key in GMD_PRIMARY_STYLES:
        return [key]
    # Unknown Sample Map presets (abstract etc.) → no style filter.
    return None


def filter_index(rows, req):
    styles = resolve_styles(req)
    beat_type = (req.get("beat_type") or "all").strip().lower()
    bpm_min = req.get("bpm_min")
    bpm_max = req.get("bpm_max")
    out = []
    for row in rows:
        if styles is not None and row["style_primary"] not in styles:
            continue
        if beat_type in ("beat", "fill") and row["beat_type"] != beat_type:
            continue
        if bpm_min is not None and row["bpm"] < int(bpm_min):
            continue
        if bpm_max is not None and row["bpm"] > int(bpm_max):
            continue
        out.append(row)
    return out


def read_vlq(data, i):
    value = 0
    while True:
        if i >= len(data):
            raise ValueError("truncated VLQ")
        b = data[i]
        i += 1
        value = (value << 7) | (b & 0x7F)
        if not (b & 0x80):
            break
    return value, i


def parse_midi_notes(path):
    """Return (notes, ticks_per_quarter, tempos, time_sigs).

    notes: list of (abs_tick, pitch, velocity)
    tempos: list of (abs_tick, us_per_quarter)
    time_sigs: list of (abs_tick, numerator, denominator)
    """
    with open(path, "rb") as fh:
        data = fh.read()

    if data[:4] != b"MThd":
        raise ValueError("not a MIDI file")
    header_len = struct.unpack(">I", data[4:8])[0]
    header = data[8 : 8 + header_len]
    _fmt, ntrks, division = struct.unpack(">HHH", header[:6])
    if division & 0x8000:
        # SMPTE time division — rare in this dataset; treat as 480 TPQ fallback.
        ticks_per_quarter = 480
    else:
        ticks_per_quarter = division

    notes = []
    tempos = []
    time_sigs = []
    offset = 8 + header_len

    for _ in range(ntrks):
        if data[offset : offset + 4] != b"MTrk":
            break
        track_len = struct.unpack(">I", data[offset + 4 : offset + 8])[0]
        track = data[offset + 8 : offset + 8 + track_len]
        offset += 8 + track_len

        i = 0
        abs_tick = 0
        running = None
        while i < len(track):
            delta, i = read_vlq(track, i)
            abs_tick += delta
            if i >= len(track):
                break
            status = track[i]
            if status & 0x80:
                running = status
                i += 1
            else:
                if running is None:
                    break
                status = running

            if status == 0xFF:
                if i >= len(track):
                    break
                meta_type = track[i]
                i += 1
                length, i = read_vlq(track, i)
                meta_data = track[i : i + length]
                i += length
                if meta_type == 0x51 and length == 3:
                    uspq = (meta_data[0] << 16) | (meta_data[1] << 8) | meta_data[2]
                    tempos.append((abs_tick, uspq))
                elif meta_type == 0x58 and length >= 2:
                    time_sigs.append((abs_tick, meta_data[0], 2 ** meta_data[1]))
            elif status in (0xF0, 0xF7):
                length, i = read_vlq(track, i)
                i += length
            else:
                kind = status & 0xF0
                if kind in (0xC0, 0xD0):
                    i += 1
                else:
                    if i + 1 >= len(track):
                        break
                    d1 = track[i]
                    d2 = track[i + 1]
                    i += 2
                    if kind == 0x90 and d2 > 0:
                        notes.append((abs_tick, d1, d2))
                    # note-off / other channel messages ignored

    notes.sort(key=lambda n: n[0])
    return notes, ticks_per_quarter, tempos, time_sigs


def ticks_per_bar(ticks_per_quarter, time_sigs, default_num=4, default_den=4):
    num, den = default_num, default_den
    if time_sigs:
        _t, num, den = time_sigs[0]
        if den <= 0:
            den = 4
    # bar length in quarter notes = num * (4/den)
    quarters = num * (4.0 / float(den))
    return max(1, int(round(ticks_per_quarter * quarters))), num, den


def extract_bar_pattern(notes, ticks_per_quarter, time_sigs, bars=1, bar_offset=0):
    """Quantize notes inside [bar_offset, bar_offset+bars) into role -> 16th positions.

    Positions are flattened across the requested bars into a single 0..15*bars
    list, then folded into one bar (mod 16) so the Lua writer can repeat it —
    matching the built-in template contract. Velocities are averaged per role/step
    and returned alongside for future use.
    """
    bars = max(1, int(bars or 1))
    bar_offset = max(0, int(bar_offset or 0))
    tpb, _num, _den = ticks_per_bar(ticks_per_quarter, time_sigs)
    start_tick = bar_offset * tpb
    end_tick = (bar_offset + bars) * tpb
    # Sixteenth-note size relative to the bar (16 slots per 4/4 bar).
    tick_per_16 = tpb / 16.0

    role_steps = {}  # role -> {pos16: [vel, ...]}
    for abs_tick, pitch, vel in notes:
        if abs_tick < start_tick or abs_tick >= end_tick:
            continue
        role = PITCH_TO_ROLE.get(pitch)
        if not role:
            continue
        local = abs_tick - start_tick
        step = int(round(local / tick_per_16))
        # Fold multi-bar extraction into one bar of 16ths.
        pos16 = step % 16
        bucket = role_steps.setdefault(role, {})
        bucket.setdefault(pos16, []).append(vel)

    pattern = {}
    velocities = {}
    for role, steps in role_steps.items():
        pattern[role] = sorted(steps.keys())
        velocities[role] = {
            str(pos): int(round(sum(vs) / float(len(vs)))) for pos, vs in steps.items()
        }
    return pattern, velocities, tpb


def find_entry(rows, entry_id):
    for row in rows:
        if row["id"] == entry_id or row["midi_filename"] == entry_id:
            return row
    return None


def midi_abs_path(rel):
    return os.path.join(extract_root(), rel)


def estimate_bar_count(entry, tpb, notes):
    if notes:
        last = notes[-1][0]
        return max(1, int(last // tpb) + 1)
    # Fallback from duration + bpm
    bpm = entry.get("bpm") or 120
    dur = entry.get("duration") or 0.0
    if bpm > 0 and dur > 0:
        beats = dur * (bpm / 60.0)
        return max(1, int(round(beats / 4.0)))
    return 1


def action_status():
    ready = is_ready()
    count = len(load_index()) if ready else 0
    return {
        "ready": ready,
        "cache_dir": cache_dir(),
        "count": count,
        "engine": ENGINE,
        "url": DATASET_URL,
    }


def action_ensure():
    download_and_extract()
    rows = load_index()
    styles = sorted({r["style_primary"] for r in rows if r["style_primary"]})
    return {
        "ready": True,
        "cache_dir": cache_dir(),
        "count": len(rows),
        "styles": styles,
        "engine": ENGINE,
    }


def action_styles():
    if not is_ready():
        return {"error": "dataset not ready; call ensure first"}
    rows = load_index()
    styles = sorted({r["style_primary"] for r in rows if r["style_primary"]})
    return {"styles": styles, "count": len(rows), "style_map": STYLE_TO_GMD}


def summarize(row):
    return {
        "id": row["id"],
        "style": row["style"],
        "style_primary": row["style_primary"],
        "bpm": row["bpm"],
        "beat_type": row["beat_type"],
        "time_signature": row["time_signature"],
        "duration": row["duration"],
        "drummer": row["drummer"],
        "midi_filename": row["midi_filename"],
    }


def action_list(req):
    if not is_ready():
        return {"error": "dataset not ready; call ensure first"}
    rows = filter_index(load_index(), req)
    rows.sort(key=lambda r: (r["style_primary"], r["bpm"], r["id"]))
    # limit <= 0 means return the full filtered list (dataset is only ~1150 rows).
    limit = int(req.get("limit") if req.get("limit") is not None else 0)
    offset = max(0, int(req.get("offset") or 0))
    if limit <= 0:
        page = rows[offset:]
        limit = len(page)
    else:
        limit = max(1, min(5000, limit))
        page = rows[offset : offset + limit]
    return {
        "total": len(rows),
        "offset": offset,
        "limit": limit,
        "items": [summarize(r) for r in page],
        "engine": ENGINE,
    }


def build_pattern_response(entry, bars=1, bar_offset=None, seed=None):
    path = midi_abs_path(entry["midi_filename"])
    if not os.path.isfile(path):
        return {"error": "MIDI file missing: %s" % entry["midi_filename"]}

    notes, tpq, _tempos, time_sigs = parse_midi_notes(path)
    tpb, num, den = ticks_per_bar(tpq, time_sigs)
    total_bars = estimate_bar_count(entry, tpb, notes)
    bars = max(1, int(bars or 1))

    if bar_offset is None:
        rng = random.Random(int(seed) if seed else None)
        max_start = max(0, total_bars - bars)
        bar_offset = rng.randint(0, max_start) if max_start > 0 else 0
    else:
        bar_offset = max(0, int(bar_offset))
        if bar_offset >= total_bars:
            bar_offset = max(0, total_bars - 1)

    pattern, velocities, _ = extract_bar_pattern(
        notes, tpq, time_sigs, bars=bars, bar_offset=bar_offset
    )
    if not pattern:
        # Empty bar — try from the start once.
        if bar_offset != 0:
            pattern, velocities, _ = extract_bar_pattern(
                notes, tpq, time_sigs, bars=bars, bar_offset=0
            )
            bar_offset = 0

    roles = [r for r in ("kick", "snare", "rim", "tom", "hat", "ride", "crash", "perc") if r in pattern]
    return {
        "pattern": pattern,
        "velocities": velocities,
        "roles": roles,
        "meta": summarize(entry),
        "bars": bars,
        "bar_offset": bar_offset,
        "total_bars": total_bars,
        "time_signature": "%d-%d" % (num, den),
        "engine": ENGINE,
    }


def action_get(req):
    if not is_ready():
        return {"error": "dataset not ready; call ensure first"}
    entry_id = req.get("id")
    if not entry_id:
        return {"error": "missing id"}
    entry = find_entry(load_index(), str(entry_id))
    if not entry:
        return {"error": "unknown id: %s" % entry_id}
    bar_offset = req.get("bar_offset")
    return build_pattern_response(
        entry,
        bars=req.get("bars", 1),
        bar_offset=bar_offset,
        seed=req.get("seed"),
    )


def action_random(req):
    if not is_ready():
        return {"error": "dataset not ready; call ensure first"}
    rows = filter_index(load_index(), req)
    if not rows:
        # Soft fallback: ignore beat_type, then ignore style.
        soft = dict(req)
        soft["beat_type"] = "all"
        rows = filter_index(load_index(), soft)
    if not rows:
        soft = dict(req)
        soft["style"] = "all"
        soft["styles"] = None
        soft["beat_type"] = req.get("beat_type") or "beat"
        rows = filter_index(load_index(), soft)
    if not rows:
        return {"error": "no matching grooves"}

    seed = int(req.get("seed") or 0) or random.randint(1, 2_000_000_000)
    rng = random.Random(seed)
    entry = rng.choice(rows)
    return build_pattern_response(
        entry,
        bars=req.get("bars", 1),
        bar_offset=req.get("bar_offset"),
        seed=seed,
    )


def main():
    try:
        in_path = sys.argv[1]
        with open(in_path, "r", encoding="utf-8") as fh:
            req = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"error": "bad input: %s" % exc}))
        return

    action = str(req.get("action") or "status").strip().lower()
    try:
        if action == "status":
            result = action_status()
        elif action == "ensure":
            result = action_ensure()
        elif action == "styles":
            result = action_styles()
        elif action == "list":
            result = action_list(req)
        elif action == "get":
            result = action_get(req)
        elif action == "random":
            result = action_random(req)
        else:
            result = {"error": "unknown action: %s" % action}
    except Exception as exc:  # noqa: BLE001
        result = {"error": str(exc)}

    print(json.dumps(result))


if __name__ == "__main__":
    main()
