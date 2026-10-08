#!/bin/bash
# omacvm features' checklist (src/lib/checklist.sh) in a pseudo-terminal, read
# back through a small terminal emulator: ↑/↓ keep every row on its own line
# once, with long rows, a list taller than the window and a window that
# changes size; q leaves the screen as it was (#292). No VM needed.
#   src/tests/features-checklist.sh [DRIVER]   (DRIVER: a script drawing a
#   checklist the same way, for trying an older one; default: the one below)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
DRIVER=${1:-$T/driver.sh}
cat > "$T/driver.sh" <<EOF
#!/bin/bash
set -euo pipefail
echo "BEFORE THE LIST"
source "$R/src/lib/checklist.sh"
ON=()
for ((i = 0; i < 19; i++)); do ON[\$i]=0; done
cl_item() {
  CL_MARK="[ ]"; (( ON[\$1] )) && CL_MARK=\$'[\\033[32m✓\\033[0m]'
  CL_TEXT=\$(printf 'F%02d row' \$((\$1 + 1)))
  # Long rows, with colours: wider than the window.
  (( \$1 % 3 == 1 )) && CL_TEXT+=\$' \\033[2m(a long reason why this one cannot be switched on this Mac, longer than any window here)\\033[0m'
  return 0
}
cl_detail() { printf 'Detail of F%02d: %s' \$((\$1 + 1)) "a summary that is also longer than the window is wide, by quite a bit"; }
cl_switch() { ON[\$1]=\$(( ON[\$1] ? 0 : 1 )); }
CL_HEAD=("Omarchy (app, OmacVM 3.0.9)" "  VM is off: these are the defaults; start it to see its own. Nothing was started.")
rc=0; cl_run 19 || rc=\$?
echo "rc=\$rc cur=\$CL_CUR on=\${ON[*]}"
EOF
chmod +x "$T/driver.sh"

python3 -I - "$DRIVER" <<'EOF'
import os, pty, sys, time, fcntl, termios, struct, select, re

class Screen:
    """Enough of a VT100 for the checklist: wraps (and counts them), scrolls,
    cursor moves, erase, the alternate screen."""
    def __init__(s, rows, cols):
        s.rows, s.cols = rows, cols
        s.main = s.blank(); s.alt = None; s.buf = s.main
        s.y = s.x = 0; s.wrap_next = False; s.wraps = 0; s.saved = (0, 0)
        s.esc = b""; s.utf = b""
    def blank(s): return [[" "] * s.cols for _ in range(s.rows)]
    def resize(s, rows, cols):
        for name in ("main", "alt"):
            b = getattr(s, name)
            if b is None: continue
            nb = [[" "] * cols for _ in range(rows)]
            for y in range(min(rows, len(b))):
                for x in range(min(cols, len(b[y]))): nb[y][x] = b[y][x]
            setattr(s, name, nb)
        s.buf = s.alt if s.alt is not None and s.buf is not s.main else s.main
        s.rows, s.cols = rows, cols
        s.y = min(s.y, rows - 1); s.x = min(s.x, cols - 1)
    def lf(s):
        s.y += 1
        if s.y >= s.rows:
            s.buf.pop(0); s.buf.append([" "] * s.cols); s.y = s.rows - 1
    def put(s, ch):
        if s.wrap_next:
            s.wraps += 1; s.x = 0; s.lf(); s.wrap_next = False
        s.buf[s.y][s.x] = ch
        if s.x == s.cols - 1: s.wrap_next = True
        else: s.x += 1
    def csi(s, params, final):
        priv = params.startswith("?")
        nums = [int(p) if p.isdigit() else 0 for p in params.lstrip("?").split(";")] if params.lstrip("?") else []
        n = nums[0] if nums and nums[0] else 1
        s.wrap_next = False
        if final == "A": s.y = max(0, s.y - n)
        elif final == "B": s.y = min(s.rows - 1, s.y + n)
        elif final == "C": s.x = min(s.cols - 1, s.x + n)
        elif final == "D": s.x = max(0, s.x - n)
        elif final == "H":
            r = nums[0] if len(nums) > 0 and nums[0] else 1
            c = nums[1] if len(nums) > 1 and nums[1] else 1
            s.y, s.x = min(r, s.rows) - 1, min(c, s.cols) - 1
        elif final == "J":
            m = nums[0] if nums else 0
            if m == 2: s.buf[:] = s.blank()
            elif m == 0:
                s.buf[s.y][s.x:] = [" "] * (s.cols - s.x)
                for y in range(s.y + 1, s.rows): s.buf[y] = [" "] * s.cols
        elif final == "K":
            m = nums[0] if nums else 0
            if m == 0: s.buf[s.y][s.x:] = [" "] * (s.cols - s.x)
            elif m == 2: s.buf[s.y] = [" "] * s.cols
        elif final in "hl" and priv and 1049 in nums:
            if final == "h":
                s.saved = (s.y, s.x); s.alt = s.blank(); s.buf = s.alt
            else:
                s.alt = None; s.buf = s.main; s.y, s.x = s.saved
    def feed(s, data):
        for b in data:
            c = bytes([b])
            if s.esc:
                s.esc += c
                if s.esc == b"\x1b[" : continue
                if s.esc.startswith(b"\x1b["):
                    if 0x40 <= b <= 0x7e:
                        s.csi(s.esc[2:-1].decode(), chr(b)); s.esc = b""
                    continue
                s.esc = b""   # ESC 7, ESC 8 ...: nothing here needs them
                continue
            if b == 0x1b: s.esc = c; continue
            if s.utf or b >= 0x80:
                s.utf += c
                try: ch = s.utf.decode()
                except UnicodeDecodeError:
                    if len(s.utf) < 4: continue
                    ch = "?"
                s.utf = b""; s.put(ch); continue
            if b == 0x0d: s.x = 0; s.wrap_next = False
            elif b == 0x0a: s.lf(); s.wrap_next = False
            elif b == 0x08: s.x = max(0, s.x - 1)
            elif b >= 0x20: s.put(chr(b))
    def lines(s): return ["".join(r).rstrip() for r in s.buf]

ROWS, COLS = 12, 60
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/bash", ["/bin/bash", sys.argv[1]])
def winsize(r, c): fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", r, c, 0, 0))
winsize(ROWS, COLS)
scr = Screen(ROWS, COLS)
def pump(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: return False
            if not d: return False
            scr.feed(d)
    return True
def wait_for(pred, t=5):
    end = time.time() + t
    while time.time() < end:
        pump(0.1)
        if pred(): return True
    return False
def key(k):
    os.write(fd, k); pump(0.08)

fails = 0
def check(what, ok, show=True):
    global fails
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        fails += 1
        if show: print("\n".join("     |" + l for l in scr.lines()))
def rows_of(lines): return [l for l in lines if re.search(r"F\d\d row", l)]
def screen_ok(want, label):
    L = scr.lines(); rows = rows_of(L)
    names = [re.search(r"F(\d\d) row", l).group(1) for l in rows]
    ptr = [l for l in L if "❯" in l]
    check(f"{label}: one cursor, on F{want:02d}", len(ptr) == 1 and f"F{want:02d} row" in ptr[0])
    check(f"{label}: every row once, in order", len(names) == len(set(names)) and names == sorted(names)
          and all(int(b) - int(a) == 1 for a, b in zip(names, names[1:])), show=False)
    check(f"{label}: the rows fill the window", len(names) == min(19, scr.rows - 5), show=False)
    check(f"{label}: nothing wrapped", scr.wraps == 0, show=False)
    check(f"{label}: the detail is the cursor's row", any(f"Detail of F{want:02d}" in l for l in L), show=False)

check("the list is drawn", wait_for(lambda: any("F01 row" in l for l in scr.lines())))
for _ in range(13): key(b"\x1b[B")
for _ in range(4): key(b"\x1b[A")
key(b"j"); key(b"k")
wait_for(lambda: any("❯" in l and "F10 row" in l for l in scr.lines()), 3)
screen_ok(10, f"{ROWS}x{COLS}, 13 down, 4 up")
for _ in range(30): key(b"\x1b[B")
wait_for(lambda: any("❯" in l and "F19 row" in l for l in scr.lines()), 3)
screen_ok(19, "to the end")
for _ in range(9): key(b"\x1b[A")
key(b" ")
wait_for(lambda: any("❯" in l and "F10 row" in l for l in scr.lines()), 3)
screen_ok(10, "back up")
check("space switches the cursor's row", any("❯" in l and "[✓]" in l for l in scr.lines()))
# A narrower, shorter window: drawn again within about a second, still one
# line per row.
ROWS, COLS = 9, 34
winsize(ROWS, COLS); scr.resize(ROWS, COLS)
wait_for(lambda: any("❯" in l and "F10 row" in l for l in scr.lines()) and
         any(l.startswith("  10/19") for l in scr.lines()), 4)
screen_ok(10, f"resized to {ROWS}x{COLS}")
check("no line is wider than the window", all(len(l) <= COLS for l in scr.lines()))
key(b"q")
alive = wait_for(lambda: any(l.startswith("rc=") for l in scr.lines()), 4)
L = scr.lines()
check("q: back to the screen as it was", alive and any("BEFORE THE LIST" in l for l in L) and not rows_of(L))
check("q: returns 1, the switch kept", any(l.startswith("rc=1 cur=9 on=0 0 0 0 0 0 0 0 0 1") for l in L))
try: os.kill(pid, 9)
except OSError: pass
sys.exit(1 if fails else 0)
EOF
