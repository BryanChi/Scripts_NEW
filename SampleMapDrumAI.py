#!/usr/bin/env python3
"""Small local drum-pattern variation model for the Sample Map Browser sequencer.

This is intentionally dependency-free (only the Python standard library) so it
starts in a few milliseconds under REAPER's bundled /usr/bin/python3 and returns
a varied pattern almost instantly. The "model" is a per-genre groove prior
(hand-encoded probabilities over the 16 sixteenth-note positions per rhythmic
family) combined with the user's current pattern and a stochastic sampler whose
temperature is driven by the requested variation amount.

I/O contract
------------
argv[1] = path to a JSON file containing:
    {
      "genre":         "house",
      "steps_per_bar": 16,
      "bars":          4,
      "roles":         ["kick", "snare", "hat", ...],
      "pattern":       { "kick": [0,4,8,12], "snare": [4,12], ... },
      "variation":     0.5,        # 0..1
      "seed":          123456
    }

stdout = JSON:
    {
      "pattern": { "kick": [...], "snare": [...], ... },
      "engine":  "groove-prior-v1"
    }

The returned step lists are 16th-note positions (0..15) within one bar; the Lua
side repeats them across every bar of the region, exactly like the built-in
templates.
"""

import sys
import json
import math
import random


# --- role -> rhythmic family -------------------------------------------------
def family_of(role):
    if role in ("kick", "808", "bass"):
        return "kick"
    if role in ("snare", "clap", "rim"):
        return "backbeat"
    if role in ("hat", "ride"):
        return "hat"
    return "perc"


# --- groove priors -----------------------------------------------------------
# Each entry is a probability (0..1) that a given family wants a hit at each of
# the 16 sixteenth positions in a bar. These are the "learned" weights of the
# model: distilled from common drum programming for each genre.
def _p(steps, value=1.0, base=0.04):
    arr = [base] * 16
    for s in steps:
        arr[s] = value
    return arr


FOUR_FLOOR = _p([0, 4, 8, 12], 0.97)
BACKBEAT = _p([4, 12], 0.97)
EIGHTS = _p([0, 2, 4, 6, 8, 10, 12, 14], 0.8)
SIXTEENTHS = [0.85 if i % 2 == 0 else 0.6 for i in range(16)]
OFFBEATS = _p([2, 6, 10, 14], 0.85)

GENRE_PRIORS = {
    "house": {
        "kick": FOUR_FLOOR,
        "backbeat": _p([4, 12], 0.9),
        "hat": OFFBEATS,
        "perc": _p([3, 7, 11, 15], 0.45, 0.08),
    },
    "techno": {
        "kick": FOUR_FLOOR,
        "backbeat": _p([12], 0.7),
        "hat": OFFBEATS,
        "perc": _p([3, 11], 0.5, 0.1),
    },
    "disco": {
        "kick": FOUR_FLOOR,
        "backbeat": BACKBEAT,
        "hat": EIGHTS,
        "perc": OFFBEATS,
    },
    "basic": {
        "kick": _p([0, 8], 0.95),
        "backbeat": BACKBEAT,
        "hat": EIGHTS,
        "perc": _p([2, 6, 10, 14], 0.4, 0.06),
    },
    "rock": {
        "kick": _p([0, 8, 10], 0.9),
        "backbeat": BACKBEAT,
        "hat": EIGHTS,
        "perc": _p([0], 0.3, 0.04),
    },
    "hiphop": {
        "kick": _p([0, 6, 10], 0.92),
        "backbeat": BACKBEAT,
        "hat": SIXTEENTHS,
        "perc": _p([7, 15], 0.35, 0.08),
    },
    "trap": {
        "kick": _p([0, 7, 10], 0.9),
        "backbeat": _p([4, 12], 0.95),
        "hat": [0.9 if i % 2 == 0 else 0.55 for i in range(16)],
        "perc": _p([3, 11], 0.4, 0.08),
    },
    "funk": {
        "kick": _p([0, 3, 10], 0.88),
        "backbeat": BACKBEAT,
        "hat": SIXTEENTHS,
        "perc": _p([2, 7, 9, 14], 0.5, 0.1),
    },
    "dnb": {
        "kick": _p([0, 10], 0.9),
        "backbeat": _p([4, 12], 0.95),
        "hat": EIGHTS,
        "perc": _p([3, 7, 11, 15], 0.45, 0.1),
    },
    "breakbeat": {
        "kick": _p([0, 6, 10], 0.88),
        "backbeat": _p([4, 12], 0.92),
        "hat": SIXTEENTHS,
        "perc": _p([2, 7, 14], 0.5, 0.1),
    },
    "reggaeton": {
        "kick": _p([0, 8], 0.95),
        "backbeat": _p([3, 7, 11, 15], 0.9),
        "hat": EIGHTS,
        "perc": _p([2, 10], 0.4, 0.08),
    },
    "afrobeat": {
        "kick": _p([0, 6, 8, 14], 0.85),
        "backbeat": _p([4, 12], 0.85),
        "hat": SIXTEENTHS,
        "perc": _p([1, 3, 7, 9, 13], 0.55, 0.12),
    },
}


def prior_from_input(positions):
    """Fallback prior for genres without a built-in table (e.g. abstract
    presets): stay close to the user's pattern but allow nearby motion."""
    arr = [0.12] * 16
    for s in positions:
        if 0 <= s < 16:
            arr[s] = 0.85
            for nb in (s - 1, s + 1):
                if 0 <= nb < 16:
                    arr[nb] = max(arr[nb], 0.3)
    # Gentle pull toward downbeats so it doesn't drift into mush.
    for s in (0, 4, 8, 12):
        arr[s] = max(arr[s], 0.2)
    return arr


def get_prior(genre, role, input_positions):
    fam = family_of(role)
    table = GENRE_PRIORS.get(genre)
    if table and fam in table:
        return list(table[fam])
    return prior_from_input(input_positions)


def softmax_sample(candidates, scores, n, tau, rng):
    """Sample n distinct candidates weighted by softmax(scores / tau)."""
    chosen = []
    pool = list(candidates)
    sc = dict(zip(candidates, scores))
    tau = max(0.05, tau)
    while pool and len(chosen) < n:
        weights = []
        mx = max(sc[c] for c in pool)
        for c in pool:
            weights.append(math.exp((sc[c] - mx) / tau))
        total = sum(weights) or 1.0
        roll = rng.random() * total
        acc = 0.0
        pick = pool[-1]
        for c, w in zip(pool, weights):
            acc += w
            if roll <= acc:
                pick = c
                break
        chosen.append(pick)
        pool.remove(pick)
    return chosen


def vary_role(genre, role, input_positions, variation, rng):
    prior = get_prior(genre, role, input_positions)
    input_set = set(p for p in input_positions if 0 <= p < 16)

    # Blend prior with the user's pattern; more variation -> trust prior/noise.
    w_input = (1.0 - variation) * 0.9 + 0.1
    w_prior = 0.4 + variation * 0.7
    scores = []
    for s in range(16):
        in_mask = 1.0 if s in input_set else 0.0
        noise = rng.random() * variation * 0.35
        scores.append(w_prior * prior[s] + w_input * in_mask + noise)

    # Steps the genre considers structurally important.
    strong = [s for s in range(16) if prior[s] >= 0.8]

    if input_set:
        # Density anchors on the user's note count; preserve the groove skeleton
        # by keeping their hits that land on strong prior positions.
        base_count = len(input_set)
        forced = sorted(s for s in input_set if prior[s] >= 0.8)
        if not forced:
            # No strong-prior overlap (e.g. abstract preset): keep the first hit.
            forced = [min(input_set)]
    else:
        # Empty role: lean entirely on the genre prior so it still grooves.
        base_count = sum(1 for v in prior if v >= 0.6) or 2
        forced = list(strong)

    # Density stays near the source; variation only adds mild symmetric jitter,
    # so low variation keeps the same number of notes.
    jitter = round((rng.random() * 2.0 - 1.0) * variation * 2.5)
    target = base_count + jitter
    target = max(1, min(12, target))
    if target < len(forced):
        target = len(forced)

    chosen = set(forced[:target]) if forced else set()
    remaining = target - len(chosen)
    if remaining > 0:
        candidates = [s for s in range(16) if s not in chosen]
        cand_scores = [scores[s] for s in candidates]
        tau = 0.25 + variation * 0.9
        for s in softmax_sample(candidates, cand_scores, remaining, tau, rng):
            chosen.add(s)

    return sorted(chosen)


def main():
    try:
        in_path = sys.argv[1]
        with open(in_path, "r") as fh:
            req = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"error": "bad input: %s" % exc}))
        return

    genre = str(req.get("genre", "basic"))
    roles = req.get("roles") or list((req.get("pattern") or {}).keys())
    pattern_in = req.get("pattern") or {}
    variation = float(req.get("variation", 0.5))
    variation = max(0.0, min(1.0, variation))
    seed = int(req.get("seed", 0)) or random.randint(1, 2_000_000_000)
    rng = random.Random(seed)

    out = {}
    for role in roles:
        positions = pattern_in.get(role) or []
        try:
            positions = [int(p) for p in positions]
        except Exception:  # noqa: BLE001
            positions = []
        out[role] = vary_role(genre, role, positions, variation, rng)

    print(json.dumps({"pattern": out, "engine": "groove-prior-v1", "seed": seed}))


if __name__ == "__main__":
    main()
