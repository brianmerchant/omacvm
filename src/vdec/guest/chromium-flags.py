#!/usr/bin/env python3
"""Chromium's switches for its V4L2 decoder. Run AS THE USER (install.sh does):
chromium-flags.py on|off|check

  --enable-features=AcceleratedVideoDecoder   Chromium's V4L2 decoder, off by
      default in builds without VA-API (Arch Linux ARM's)
  --load-extension=/usr/local/share/omacvm/chromium-no-av1   YouTube sends
      VP9 instead of AV1, which this Chromium decodes only on the CPU

Chromium keeps only the LAST of each switch on its command line, and Arch's
launcher reads /etc/chromium-flags.conf, then ~/.config/chromium-flags.conf
(Omarchy's, which has both). So each value goes into the last such switch of
the user's file (several flags may share a line), or into a new line with
/etc's last list plus the value when the user's file has none. A marker in
~/.local/state/omacvm remembers what was added, so "off" never removes what
the user set. Files are replaced whole (a temporary file, then a rename), so
Chromium never reads half a file; a linked file stays a link (its target is
replaced). check: exit 0 when Chromium would get both."""
import json, os, pwd, re, sys, tempfile

ADD = {"--enable-features=": "AcceleratedVideoDecoder",
       "--load-extension=": "/usr/local/share/omacvm/chromium-no-av1"}
ETC = "/etc/chromium-flags.conf"
HOME = pwd.getpwuid(os.getuid()).pw_dir   # not $HOME: runuser keeps root's
USER_FILE = f"{HOME}/.config/chromium-flags.conf"
MARK = f"{HOME}/.local/state/omacvm/chromium-v4l2-flags.json"


def lines(path):
    try:
        with open(path) as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return []


def last_switch(ls, switch):
    """(line index, match) of the last SWITCH, comments skipped."""
    token = re.compile(r"(?<!\S)" + re.escape(switch) + r"(\S*)")
    found = None
    for i, l in enumerate(ls):
        if l.lstrip().startswith("#"):
            continue
        for m in token.finditer(l):
            found = (i, m)
    return found


def values(m):
    return [x for x in m.group(1).split(",") if x]


def effective(switch):
    for path in (USER_FILE, ETC):
        hit = last_switch(lines(path), switch)
        if hit:
            return values(hit[1])
    return []


def write(path, text):
    """Replaces PATH's content atomically. A link is followed: its target is
    replaced and the link kept. Keeps the file's mode (a new file: the umask's)."""
    path = os.path.realpath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        mode = os.stat(path).st_mode & 0o7777
    except FileNotFoundError:
        umask = os.umask(0o22)
        os.umask(umask)
        mode = 0o666 & ~umask
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".omacvm-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fchmod(f.fileno(), mode)
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def write_lines(path, ls):
    write(path, "".join(l + "\n" for l in ls))


def load_mark():
    try:
        with open(MARK) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def on():
    mark, ls, changed = load_mark(), lines(USER_FILE), False
    for switch, value in ADD.items():
        if value in effective(switch):
            continue
        hit = last_switch(ls, switch)
        if hit:
            i, m = hit
            ls[i] = ls[i][:m.start()] + switch + ",".join(values(m) + [value]) + ls[i][m.end():]
            mark[switch] = "added"
        else:
            etc = last_switch(lines(ETC), switch)
            ls.append(switch + ",".join((values(etc[1]) if etc else []) + [value]))
            mark[switch] = "line " + ls[-1]
        changed = True
    if changed:
        write_lines(USER_FILE, ls)
        write(MARK, json.dumps(mark))


def off():
    mark = load_mark()
    if not mark:
        return
    ls = lines(USER_FILE)
    for switch, how in mark.items():
        value = ADD.get(switch)
        if not value:
            continue
        if how.startswith("line "):
            ls = [l for l in ls if l != how[5:]]
            continue
        hit = last_switch(ls, switch)
        if hit:
            i, m = hit
            rest = [x for x in values(m) if x != value]
            ls[i] = (ls[i][:m.start()] + (switch + ",".join(rest) if rest else "") + ls[i][m.end():]).rstrip()
            if not ls[i].strip():
                del ls[i]
    write_lines(USER_FILE, ls)
    os.remove(MARK)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "on":
        on()
    elif cmd == "off":
        off()
    elif cmd == "check":
        sys.exit(0 if all(v in effective(s) for s, v in ADD.items()) else 1)
    else:
        sys.exit("usage: chromium-flags.py on|off|check")
