#!/usr/bin/env python3
# cadence.py CAP.jsonl FPS [REFRESH_HZ]: how long each frame of a fixed-rate page (pacing.html?fps=N) stayed on
# screen, from sckpace's per-frame log. Ideal: every frame 1/FPS. Prints JSON: frames, hold histogram in
# refreshes, share of frames held exactly as long as they should (even cadence), skipped counter values.
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
fps = float(sys.argv[2]); hz = float(sys.argv[3]) if len(sys.argv) > 3 else 120.0
good = [r for r in rows if r["st"] == 0 and r["n"] >= 0]
holds, skips = {}, 0
for a, b in zip(good, good[1:]):
    if b["n"] == a["n"]:
        continue
    if (b["n"] - a["n"]) % 65536 > 1:
        skips += 1
    k = round((b["t"] - a["t"]) * hz / 1000)
    holds[k] = holds.get(k, 0) + 1
want = round(hz / fps)
n = sum(holds.values())
print(json.dumps({"frames": n, "refreshes_per_frame_ideal": want,
                  "hold_refreshes": dict(sorted(holds.items())),
                  "even": round(holds.get(want, 0) / n, 4) if n else 0, "skipped": skips}))
