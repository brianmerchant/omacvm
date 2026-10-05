#!/usr/bin/env python3
"""Run the GPU throughput page in Google Chrome and print its result as one JSON line.

  run.py [--method timer|wall] [--headless] [--port 9222] [--chrome PATH] [--query runs=7] [--timeout 900]
  run.py --viewport-only      start Chrome full screen, print its page size, stop

--method: timer (GPU timer queries, the default) or wall (wall time of long
frames); see index.html. A browser without timer queries answers the timer
method with "noTimer" and no score.

Without --port it starts its own Chrome with a throwaway profile and stops it
after. With --port it uses a Chrome that already runs with
--remote-debugging-port (bench.sh, the final-round runners).
--headless starts Chrome without a window but with the GPU (macOS: ANGLE on
Metal). The page draws offscreen at a fixed size, so the window does not
change the score. The result says which renderer Chrome used: a software
renderer is reported as not available, not as a score.
"""
import argparse, json, os, platform, shutil, subprocess, sys, tempfile, time, urllib.parse, urllib.request
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "index.html")


def devtools_module():
    """browser-bench.py's DevTools client (src/bench, next to tests/ or in OMACVM_BENCH_SRC)."""
    for d in (os.environ.get("OMACVM_BENCH_SRC", ""), os.path.join(HERE, "..", "..", "..", "src", "bench"),
              "/usr/local/share/omacvm/bench"):
        p = os.path.join(d, "browser-bench.py")
        if d and os.path.isfile(p):
            spec = importlib.util.spec_from_file_location("bb", p)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            return m
    raise SystemExit("run.py: src/bench/browser-bench.py not found (set OMACVM_BENCH_SRC)")


def find_chrome():
    for c in ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/opt/google/chrome/google-chrome",
              shutil.which("google-chrome-stable") or "", shutil.which("google-chrome") or ""):
        if c and os.path.exists(c):
            return c
    raise SystemExit("run.py: Google Chrome not found")


def start_chrome(chrome, port, headless):
    profile = tempfile.mkdtemp(prefix="omacvm-gpu-throughput-")
    args = [chrome, f"--user-data-dir={profile}", f"--remote-debugging-port={port}", "--no-first-run",
            "--no-default-browser-check", "--disable-background-timer-throttling",
            "--disable-renderer-backgrounding", "--allow-file-access-from-files"]
    if headless:
        args += ["--headless=new", "--enable-gpu", "--ignore-gpu-blocklist", "--window-size=1280,800"]
        if platform.system() == "Darwin":
            args += ["--use-angle=metal"]
    else:
        args += ["--start-fullscreen"]
        if platform.system() == "Darwin":   # full screen without the toolbar, as bench.sh: the same page size
            os.makedirs(os.path.join(profile, "Default"))
            with open(os.path.join(profile, "Default", "Preferences"), "w") as f:
                json.dump({"browser": {"show_fullscreen_toolbar": False}}, f)
        if platform.system() == "Linux":   # Omarchy's Chrome flags, as bench.sh
            for f in ("/etc/chrome-flags.conf", os.path.expanduser("~/.config/chrome-flags.conf")):
                if os.path.isfile(f):
                    args += [l.strip() for l in open(f) if l.strip() and not l.startswith("#") and "--load-extension" not in l]
            args += ["--ozone-platform=wayland"]
    args.append("about:blank")
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(180):   # a VM just resumed or busy can take a while
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=2)
            return proc, profile, args[1:]
        except OSError:
            time.sleep(0.5)
    proc.kill()
    raise SystemExit("run.py: Chrome did not start")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int)
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--chrome")
    ap.add_argument("--method", choices=("timer", "wall"), default="timer")
    ap.add_argument("--query", default="", help="more page options, e.g. runs=7&only=throughput")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--viewport-only", action="store_true")
    a = ap.parse_args()
    bb = devtools_module()
    proc = profile = None
    flags = []
    port = a.port or 9341
    if not a.port:
        proc, profile, flags = start_chrome(a.chrome or find_chrome(), port, a.headless)
    base = f"http://127.0.0.1:{port}"
    version = json.load(urllib.request.urlopen(f"{base}/json/version"))
    tab = json.load(urllib.request.urlopen(urllib.request.Request(f"{base}/json/new?about:blank", method="PUT")))
    url = "file://" + urllib.parse.quote(PAGE) + "?json&method=" + a.method + ("&" + a.query if a.query else "")
    result = None
    try:
        d = bb.DevTools(tab["webSocketDebuggerUrl"])
        d.call("Page.enable")
        d.call("Page.bringToFront")
        if a.viewport_only:   # a full-screen window settles in a moment
            time.sleep(3)
            result = {"viewportOnly": True}
            a.timeout = 0
        else:
            d.call("Page.navigate", url=url)
        start = time.time()
        while time.time() - start < a.timeout:
            time.sleep(2)
            if d.js("document.title") in ("DONE", "FAILED"):
                result = d.js("window.gpuResult")
                break
        viewport = d.js("innerWidth + 'x' + innerHeight + ' at ' + devicePixelRatio + 'x'")
    finally:
        try:
            urllib.request.urlopen(f"{base}/json/close/{tab['id']}")
        except OSError:
            pass
        if proc:
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
            shutil.rmtree(profile, ignore_errors=True)
    if result is None:
        result = {"ok": False, "errors": [f"no result after {a.timeout} s"]}
    result["chrome"] = version.get("Browser")
    result["viewport"] = viewport
    result["headless"] = a.headless
    if flags:
        result["chromeFlags"] = [f for f in flags if not f.startswith("--user-data-dir")]
    result["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(json.dumps(result))
    return 0 if result.get("ok") or result.get("notAvailable") or a.viewport_only else 1


if __name__ == "__main__":
    sys.exit(main())
