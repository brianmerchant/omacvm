# stats.py FILE: rAF interval statistics from pacing-stats.json
import json, sys, statistics as st
d = json.load(open(sys.argv[1])); iv = d['iv'][30:]
iv.sort(); n = len(iv); p = lambda q: iv[min(n - 1, int(q * n))]
period = float(sys.argv[2]) if len(sys.argv) > 2 else 1000 / 120
late = sum(1 for x in iv if x > period * 1.5)
print(json.dumps({'frames': d['frames'], 'fps': round(1000 / st.mean(iv), 2), 'median_ms': round(p(.5), 3),
  'p1': round(p(.01), 3), 'p99': round(p(.99), 3), 'max': round(iv[-1], 3), 'stdev_ms': round(st.pstdev(iv), 3),
  'over_1.5_periods': late, 'over_pct': round(100 * late / n, 2)}))
