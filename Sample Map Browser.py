# @description Sample Map Browser (Python + ReaImGui)
# @version 0.1.0
# @author bryan
# @about Scans user folders for audio files, derives simple metadata, and shows an interactive 2D map where each file is a dot. Click a dot to preview the file.

# Try to import REAPER Python - this must work or script fails
try:
    from reaper_python import *
except ImportError:
    try:
        import reaper_python
        # Import all RPR_ functions into global namespace
        for attr in dir(reaper_python):
            if attr.startswith('RPR_'):
                globals()[attr] = getattr(reaper_python, attr)
    except ImportError:
        # Write error to a file since we can't use REAPER console yet
        import traceback
        with open('/tmp/reaper_python_error.txt', 'w') as f:
            f.write("Failed to import reaper_python\n")
            f.write(traceback.format_exc())
        raise

import json
import math
import os
import random
import subprocess
import sys
import time
import traceback

# Logging helper
def log(msg):
    try:
        RPR_ShowConsoleMsg("[SampleMap] " + str(msg) + "\n")
    except:
        try:
            print("[SampleMap] " + str(msg))
        except:
            pass

# Test that we can call REAPER functions
try:
    log("Script starting...")
except:
    # If logging fails, try writing to file
    try:
        with open('/tmp/reaper_script_error.txt', 'w') as f:
            f.write("Cannot call RPR_ShowConsoleMsg\n")
    except:
        pass

# --- Script state ------------------------------------------------------------
SCRIPT_NAME = "Sample Map Browser"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "SampleMapBrowser.json")

AUDIO_EXTS = {".wav", ".wave", ".aif", ".aiff", ".flac", ".mp3", ".ogg", ".m4a", ".wv"}

state = {
    "folders": [],
    "samples": [],
    "scan_queue": [],
    "scan_started": 0.0,
    "scan_total": 0,
    "selected": None,
    "filter": "",
    "map_seed": 1337,
}

ctx = None
font = None
running = True
preview_proc = None


# --- Helper functions ---------------------------------------------------------
def pick_number(ret, default=0.0):
    if isinstance(ret, (int, float)):
        return float(ret)
    if isinstance(ret, (list, tuple)):
        for v in ret:
            if isinstance(v, (int, float)):
                return float(v)
    return default


def pick_bool(ret, default=False):
    if isinstance(ret, bool):
        return ret
    if isinstance(ret, (list, tuple)):
        for v in ret:
            if isinstance(v, bool):
                return v
    return default


def ig_flag(name):
    try:
        fn_name = "RPR_ImGui_" + name
        if fn_name in globals():
            return globals()[fn_name]()
    except:
        pass
    return 0


def ig(name, *args):
    try:
        fn_name = "RPR_ImGui_" + name
        if fn_name in globals():
            return globals()[fn_name](*args)
    except Exception as e:
        log(f"ImGui call failed: {name} - {e}")
    return None


def api_exists(name):
    try:
        if "RPR_APIExists" in globals():
            return RPR_APIExists(name)
        # Fallback: check if function exists in globals
        if f"RPR_{name}" in globals():
            return True
    except:
        pass
    return False


# --- Persistence -------------------------------------------------------------
def load_config():
    if os.path.isfile(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
                cfg = json.load(fh)
                state["folders"] = cfg.get("folders", [])
                state["map_seed"] = cfg.get("map_seed", 1337)
                log(f"Loaded config: {len(state['folders'])} folders")
        except Exception as exc:
            log(f"Config load failed: {exc}")


def save_config():
    cfg = {
        "folders": state["folders"],
        "map_seed": state.get("map_seed", 1337),
    }
    try:
        with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
    except Exception as exc:
        log(f"Config save failed: {exc}")


# --- Scanning and analysis ---------------------------------------------------
def enqueue_scan():
    state["samples"] = []
    paths = []
    for folder in state["folders"]:
        if not os.path.isdir(folder):
            continue
        try:
            for root, _, files in os.walk(folder):
                for name in files:
                    ext = os.path.splitext(name)[1].lower()
                    if ext in AUDIO_EXTS:
                        paths.append(os.path.join(root, name))
        except Exception as e:
            log(f"Error scanning {folder}: {e}")
    state["scan_queue"] = paths
    state["scan_total"] = len(paths)
    state["scan_started"] = time.time()
    log(f"Enqueued {state['scan_total']} files for analysis")


def analyze_file(path):
    try:
        src = RPR_PCM_Source_CreateFromFile(path)
        if not src:
            return None
        
        length_ret = RPR_GetMediaSourceLength(src, None)
        duration = pick_number(length_ret, 0.0)
        
        sr_ret = RPR_GetMediaSourceSampleRate(src)
        sr = pick_number(sr_ret, 44100.0)
        
        ch_ret = RPR_GetMediaSourceNumChannels(src)
        ch = int(pick_number(ch_ret, 2))
        
        try:
            size = os.path.getsize(path)
        except OSError:
            size = 0
        
        RPR_PCM_Source_Destroy(src)
        
        avg_bps = size / max(duration, 0.01)
        sample = {
            "path": path,
            "name": os.path.basename(path),
            "folder": os.path.dirname(path),
            "duration": duration,
            "samplerate": sr,
            "channels": ch,
            "bps": avg_bps,
        }
        return sample
    except Exception as e:
        log(f"Analyze failed for {path}: {e}")
        return None


def process_scan_slice(max_ms=15.0):
    if not state["scan_queue"]:
        return
    deadline = time.time() + (max_ms / 1000.0)
    rng = random.Random(state.get("map_seed", 1337))
    while state["scan_queue"] and time.time() < deadline:
        path = state["scan_queue"].pop()
        sample = analyze_file(path)
        if sample:
            state["samples"].append(sample)
    if not state["scan_queue"]:
        layout_samples(rng)
        log(f"Analysis complete: {len(state['samples'])} samples")


def layout_samples(rng=None):
    if rng is None:
        rng = random.Random(state.get("map_seed", 1337))
    samples = state["samples"]
    if not samples:
        return
    
    len_scores = [math.log10(max(s["duration"], 0.01)) for s in samples]
    den_scores = [math.log10(max(s["bps"], 1.0)) for s in samples]
    sr_scores = [math.log10(max(s["samplerate"], 1.0)) for s in samples]

    def norm(values, val):
        lo = min(values)
        hi = max(values)
        if hi - lo < 1e-9:
            return 0.5
        return (val - lo) / (hi - lo)

    for s, lscore, dscore, rscore in zip(samples, len_scores, den_scores, sr_scores):
        x = norm(len_scores, lscore)
        y = norm(den_scores, dscore)
        jx = (rng.random() - 0.5) * 0.04
        jy = (rng.random() - 0.5) * 0.04
        s["x"] = min(max(x + jx, 0.0), 1.0)
        s["y"] = min(max(y + jy, 0.0), 1.0)
        color_base = 0xFF66CCFF if s["channels"] == 1 else 0xFF44AA55
        color_hot = 0xFFFFC84D
        s["color"] = color_base
        s["hot_color"] = color_hot


# --- Preview handling --------------------------------------------------------
def stop_preview():
    global preview_proc
    if preview_proc and preview_proc.poll() is None:
        try:
            preview_proc.terminate()
        except Exception:
            pass
    preview_proc = None


def preview_sample(sample):
    global preview_proc
    stop_preview()
    afplay = "/usr/bin/afplay"
    cmd = [afplay, sample["path"]]
    try:
        preview_proc = subprocess.Popen(cmd)
        log(f"Preview start: {sample['name']}")
    except Exception as exc:
        log(f"Preview failed: {exc}")
        preview_proc = None


# --- UI helpers --------------------------------------------------------------
def begin_window():
    try:
        ig("SetNextWindowSize", ctx, 1024, 720, ig_flag("Cond_FirstUseEver"))
        flags = ig_flag("WindowFlags_NoCollapse")
        ret = ig("Begin", ctx, SCRIPT_NAME, True, flags)
        if isinstance(ret, tuple):
            return pick_bool(ret[0], True), pick_bool(ret[1], True)
        return pick_bool(ret, True), True
    except Exception as e:
        log(f"begin_window error: {e}")
        return False, False


def render_header():
    try:
        if ig("Button", ctx, "Add Folder"):
            new_folder = browse_for_folder()
            if new_folder and new_folder not in state["folders"]:
                state["folders"].append(new_folder)
                save_config()
                log(f"Added folder: {new_folder}")
        ig("SameLine", ctx)
        if ig("Button", ctx, "Rescan"):
            enqueue_scan()
            log("Manual rescan triggered")
        ig("SameLine", ctx)
        if ig("Button", ctx, "Clear"):
            state["folders"] = []
            state["samples"] = []
            state["scan_queue"] = []
            save_config()
            log("Cleared folders and samples")
        ig("SameLine", ctx)
        text_ret = ig("InputText", ctx, "Filter", state["filter"], 256)
        if isinstance(text_ret, tuple) and len(text_ret) >= 2:
            changed, new_val = text_ret[0], text_ret[1]
            if changed:
                state["filter"] = new_val
        elif isinstance(text_ret, str):
            state["filter"] = text_ret

        ig("Separator", ctx)
        if state["folders"]:
            ig("Text", ctx, "Folders:")
            for idx, folder in enumerate(list(state["folders"])):
                ig("BulletText", ctx, folder)
                ig("SameLine", ctx)
                if ig("SmallButton", ctx, f"Remove##{idx}"):
                    state["folders"].pop(idx)
                    save_config()
                    break
        else:
            ig("TextColored", ctx, 0xFF888888, "No folders yet. Click Add Folder.")
        ig("Separator", ctx)
    except Exception as e:
        log(f"render_header error: {e}")


def render_map():
    try:
        avail = ig("GetContentRegionAvail", ctx)
        width = pick_number(avail[0], 640) if isinstance(avail, tuple) else 640
        height = pick_number(avail[1], 480) if isinstance(avail, tuple) else 480
        height = max(height, 320)
        
        map_id = "map_area"
        pos = ig("GetCursorScreenPos", ctx)
        x0 = pick_number(pos[0] if isinstance(pos, tuple) else pos, 0.0)
        y0 = pick_number(pos[1] if isinstance(pos, tuple) else pos, 0.0)
        
        ig("InvisibleButton", ctx, map_id, width, height)
        hovered = pick_bool(ig("IsItemHovered", ctx), False)
        dl = ig("GetWindowDrawList", ctx)
        
        bg = 0xFF1E1E1E
        grid = 0xFF2A2A2A
        ig("DrawList_AddRectFilled", dl, x0, y0, x0 + width, y0 + height, bg, 6)

        for i in range(11):
            gy = y0 + (height / 10.0) * i
            gx = x0 + (width / 10.0) * i
            ig("DrawList_AddLine", dl, x0, gy, x0 + width, gy, grid, 1.0)
            ig("DrawList_AddLine", dl, gx, y0, gx, y0 + height, grid, 1.0)

        mx = my = 0.0
        if hovered:
            mpos = ig("GetMousePos", ctx)
            mx = pick_number(mpos[0] if isinstance(mpos, tuple) else mpos, 0.0)
            my = pick_number(mpos[1] if isinstance(mpos, tuple) else mpos, 0.0)

        dot_radius = max(3.0, min(width, height) * 0.006)
        clicked_sample = None
        
        for s in state["samples"]:
            if state["filter"]:
                if state["filter"].lower() not in s["name"].lower():
                    continue
            px = x0 + s.get("x", 0.5) * width
            py = y0 + s.get("y", 0.5) * height
            color = s.get("color", 0xFF44AA55)
            ig("DrawList_AddCircleFilled", dl, px, py, dot_radius, color)
            
            if hovered:
                dx = mx - px
                dy = my - py
                if (dx * dx + dy * dy) <= (dot_radius * dot_radius * 1.6):
                    ig("DrawList_AddCircle", dl, px, py, dot_radius + 2.0, s.get("hot_color", 0xFFFFC84D), 16, 2.0)
                    ig("BeginTooltip", ctx)
                    ig("Text", ctx, s["name"])
                    ig("Text", ctx, f"{s['duration']:.2f}s | {int(s['samplerate'])} Hz | ch:{s['channels']}")
                    ig("EndTooltip", ctx)
                    if pick_bool(ig("IsMouseClicked", ctx, 0), False):
                        clicked_sample = s
                    state["selected"] = s

        if clicked_sample:
            preview_sample(clicked_sample)
        ig("Dummy", ctx, width, 0.0)

        if state["scan_queue"]:
            done = state["scan_total"] - len(state["scan_queue"])
            elapsed = time.time() - state["scan_started"]
            ig("Text", ctx, f"Scanning {done}/{state['scan_total']} ({elapsed:.1f}s)...")
        elif not state["samples"]:
            ig("Text", ctx, "Press Rescan to populate the map.")
        elif state["selected"]:
            s = state["selected"]
            ig("Text", ctx, f"Selected: {s['name']}")
    except Exception as e:
        log(f"render_map error: {e}")


def browse_for_folder():
    try:
        if api_exists("JS_Dialog_BrowseForFolder"):
            ret = RPR_JS_Dialog_BrowseForFolder("Choose folder to scan", "")
            if isinstance(ret, tuple):
                return ret[0]
            return ret
        ret = RPR_GetUserInputs("Add folder", 1, "Folder path,", "")
        if isinstance(ret, tuple) and len(ret) >= 2:
            ok, path = ret[0], ret[1]
            return path if ok else ""
    except Exception as e:
        log(f"browse_for_folder error: {e}")
    return ""


# --- Main loop ---------------------------------------------------------------
def loop():
    global running
    if not running:
        return
    
    try:
        if not api_exists("ImGui_ValidatePtr"):
            log("ImGui_ValidatePtr not available")
            running = False
            return
        
        if not pick_bool(ig("ValidatePtr", ctx, ctx, "ImGui_Context*"), True):
            log("ImGui context invalid; stopping loop")
            running = False
            return

        process_scan_slice()

        visible, open_state = begin_window()
        if visible:
            render_header()
            render_map()
        ig("End", ctx)

        if open_state and running:
            RPR_defer(loop)
        else:
            running = False
            stop_preview()
            ig("DestroyContext", ctx)
            save_config()
    except Exception as e:
        log(f"loop error: {e}")
        log(traceback.format_exc())
        running = False


def main():
    log("Starting Sample Map Browser...")
    
    # Show message box to confirm script is running
    try:
        RPR_ShowMessageBox("Sample Map Browser script is starting...", "Info", 0)
    except Exception as e:
        log(f"Cannot show message box: {e}")
    
    try:
        if not api_exists("ImGui_GetVersion"):
            RPR_ShowMessageBox("ReaImGui is required for this script.", "Missing dependency", 0)
            return
        
        load_config()
        
        global ctx, font
        ctx = ig("CreateContext", SCRIPT_NAME, ig_flag("ConfigFlags_DockingEnable"))
        if not ctx:
            log("Failed to create ImGui context")
            return
        
        font = ig("CreateFont", "sans-serif", 16)
        if font:
            ig("Attach", ctx, font)
        
        log("ImGui context created; beginning scan")
        enqueue_scan()
        loop()
    except Exception as e:
        log(f"Fatal error in main: {e}")
        log(traceback.format_exc())


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"Fatal error: {e}")
        log(traceback.format_exc())
