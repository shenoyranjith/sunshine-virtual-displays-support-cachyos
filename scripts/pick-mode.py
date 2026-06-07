#!/usr/bin/env python3
"""Pick the best kscreen mode id for a target W/H/FPS on a given output.
Prints the chosen mode id to stdout (empty if output not found).
Also prints a second line: EXACT|FALLBACK so the caller knows if the
requested mode existed verbatim (used by the EDID-regen feature).

Usage: pick-mode.py <output-name> <width> <height> <fps>
"""
import json
import subprocess
import sys


def main():
    name, W, H, FPS = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
    try:
        out = subprocess.run(["kscreen-doctor", "--json"],
                             capture_output=True, text=True, check=True).stdout
        data = json.loads(out)
    except Exception as e:
        sys.stderr.write(f"kscreen-doctor failed: {e}\n")
        return 2

    output = next((o for o in data.get("outputs", []) if o.get("name") == name), None)
    if not output:
        sys.stderr.write(f"output {name} not found\n")
        return 1

    modes = output.get("modes", [])
    best, best_score, exact = None, None, False
    for m in modes:
        sz = m.get("size", {})
        w, h = sz.get("width"), sz.get("height")
        r = m.get("refreshRate", 0)
        if w is None or h is None:
            continue
        # score: prefer exact resolution, then closest fps, then closest area
        res_pen = 0 if (w == W and h == H) else abs(w*h - W*H) + 10_000_000
        fps_pen = abs(r - FPS)
        score = (res_pen, fps_pen)
        if w == W and h == H and round(r) == round(FPS):
            best, exact = m, True
            break
        if best_score is None or score < best_score:
            best, best_score = m, score
    if not best:
        return 1
    print(best.get("id", ""))
    print("EXACT" if exact else "FALLBACK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
