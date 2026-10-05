#!/usr/bin/env python3
"""Count the glitches in a recorded test tone (the sound-crackle measurements).

  glitches.py FILE.wav                   a WAV (QEMU's HMP `wavcapture`)
  glitches.py FILE.raw [--rate 44100]    raw S16 stereo (sdlprobe.c's stream)
  glitches.py --selftest                 finds made-up glitches in a made-up tone

A pure sine obeys x[n] = 2 cos(w) x[n-1] - x[n-2]. A dropout, a repeated or a
skipped block breaks that: a "break" is a residual above 40 LSB (breaks
within 20 ms count once). Digital silence of 1 ms or more is counted apart
(a gap that starts at a zero crossing leaves no break). Prints one JSON line.
Use a low tone (30 Hz, -12 dBFS): a laptop's speakers barely play it.
"""
import json
import math
import struct
import sys
import wave

THRESH = 40


def analyse(x, rate):
    n = len(x)
    zc = [i for i in range(1, n) if x[i - 1] < 0 <= x[i]]
    freq = (len(zc) - 1) / ((zc[-1] - zc[0]) / rate) if len(zc) > 2 else 31.0
    c = 2 * math.cos(2 * math.pi * freq / rate)
    breaks, last, silence, run = [], -10**9, [], 0
    for i in range(2, n):
        if abs(x[i] - c * x[i - 1] + x[i - 2]) > THRESH:
            if i - last > rate // 50:
                breaks.append(i)
            last = i
        if x[i] == 0 and x[i - 1] == 0:
            run += 1
        else:
            if run >= rate // 1000:
                silence.append(run)
            run = 0
    seconds = n / rate if rate else 0
    return {
        "seconds": round(seconds, 1), "rate": rate, "tone_hz": round(freq, 2),
        "breaks": len(breaks),
        "breaks_per_10min": round(len(breaks) * 600 / seconds, 1) if seconds else 0,
        "silences_ge_1ms": len(silence),
        "silence_ms_total": round(sum(silence) * 1000 / rate, 1) if rate else 0,
        "first_breaks_s": [round(b / rate, 2) for b in breaks[:12]],
    }


def load(path, rate):
    if path.endswith('.raw'):
        raw = open(path, 'rb').read()
        ch = 2
    else:
        w = wave.open(path, 'rb')
        rate, ch = w.getframerate(), w.getnchannels()
        if w.getsampwidth() != 2:
            sys.exit("glitches.py: 16-bit samples only")
        raw = w.readframes(w.getnframes())
    n = len(raw) // (2 * ch)
    return struct.unpack('<%dh' % (n * ch), raw[: n * ch * 2])[0::ch], rate


def selftest():
    r, a = 44100, 8191
    x = [int(round(a * math.sin(2 * math.pi * 31 * i / r))) for i in range(r * 10)]
    # a 10 ms gap at a zero crossing, a 5-sample skip, a 200-sample repeat
    x = x[: r * 2] + [0] * 441 + x[r * 2: r * 4] + x[r * 4 + 5: r * 6] + x[r * 6 - 200:]
    got = analyse(x, r)
    want = (2, 1, 10.0)
    have = (got["breaks"], got["silences_ge_1ms"], got["silence_ms_total"])
    clean = analyse([int(round(a * math.sin(2 * math.pi * 31 * i / r))) for i in range(r * 5)], r)
    ok = have == want and clean["breaks"] == 0 and clean["silences_ge_1ms"] == 0
    print("glitches.py selftest:", "ok" if ok else "FAIL %s (want %s), clean %s" % (have, want, clean))
    return 0 if ok else 1


def main(argv):
    if argv[1:2] == ['--selftest']:
        return selftest()
    if len(argv) < 2:
        sys.exit(__doc__)
    rate = int(argv[argv.index('--rate') + 1]) if '--rate' in argv else 44100
    x, rate = load(argv[1], rate)
    print(json.dumps(analyse(x, rate)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
