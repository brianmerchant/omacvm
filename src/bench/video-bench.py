#!/usr/bin/env python3
"""YouTube 4K in a Chrome-family browser: which decoder plays it (hardware or
software), at what resolution, and how many frames it drops.

  video-bench.py [--port 9222] [--video ID] [--seconds 60] [--quality hd2160]

Chrome must run with --remote-debugging-port. Opens the video's embed page
(no cookie banner), asks for 2160p (--quality: hd1080, hd1440, ...), plays it muted for --seconds and prints one
JSON line: {"test": "youtube-4k", "decoder", "hardware", "height", "fps",
"dropped_pct", "seconds"}. The decoder comes from Chrome's media events
(VaapiVideoDecoder, V4L2..., VideoToolbox... = hardware; Dav1d, Vpx, FFmpeg
= software).
"""
import http.server, importlib.util, json, os, sys, threading, time, urllib.request

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bb", os.path.join(here, "browser-bench.py"))
bb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bb)


class Tab(bb.DevTools):
    """DevTools that keeps the events it reads past (DevTools.call drops them)."""
    def __init__(self, url):
        super().__init__(url)
        self.events = []

    def call(self, method, **params):
        self.id += 1
        self._send(json.dumps({"id": self.id, "method": method, "params": params}))
        while True:
            m = self._recv()
            if m.get("id") == self.id:
                return m.get("result", {})
            if "method" in m:
                self.events.append(m)


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def main():
    port = int(arg("--port", 9222))
    # SDR on purpose: HDR video makes the Mac's display brighter (more power) than a VM's.
    video = arg("--video", "aqz-KE-bpKQ")   # "Big Buck Bunny 60fps 4K", Blender Foundation
    seconds = int(arg("--seconds", 60))
    quality = arg("--quality", "hd2160")
    # YouTube refuses embeds without a page around them (error 153): serve one.
    page = (f'<!doctype html><body style="margin:0;background:#000">'
            f'<iframe src="https://www.youtube-nocookie.com/embed/{video}?autoplay=1&mute=1&controls=0" '
            f'allow="autoplay; fullscreen" referrerpolicy="strict-origin-when-cross-origin" '
            f'style="border:0;width:100vw;height:100vh"></iframe>').encode()

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
            self.wfile.write(page)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/json/new?http://127.0.0.1:{srv.server_port}/", method="PUT")
    top = Tab(json.load(urllib.request.urlopen(req))["webSocketDebuggerUrl"])
    top.call("Page.enable"); top.call("Page.bringToFront")
    t = None
    for _ in range(30):   # the player runs in its own process: attach to that frame
        time.sleep(1)
        frames = [x for x in json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
                  if x.get("type") == "iframe" and "youtube" in x.get("url", "")]
        if frames:
            t = Tab(frames[0]["webSocketDebuggerUrl"]); t.call("Media.enable")
            break
    if t is None:
        raise SystemExit("video-bench: no YouTube frame")
    for _ in range(30):
        time.sleep(1)
        if t.js("!!document.querySelector('video') && !!document.getElementById('movie_player')"):
            break
    t.js("(() => { const p = document.getElementById('movie_player'); p.mute(); "
         f"p.setPlaybackQualityRange && p.setPlaybackQualityRange('{quality}', '{quality}'); p.playVideo(); }})()")
    time.sleep(10)   # quality switch and buffering
    q0 = t.js("(() => { const q = document.querySelector('video').getVideoPlaybackQuality(); return [q.totalVideoFrames, q.droppedVideoFrames] })()") or [0, 0]
    time.sleep(seconds)
    q1 = t.js("(() => { const q = document.querySelector('video').getVideoPlaybackQuality(); return [q.totalVideoFrames, q.droppedVideoFrames] })()") or [0, 0]
    height = t.js("document.querySelector('video').videoHeight")
    t.call("Runtime.evaluate", expression="1")   # collect pending events
    props = {}
    for e in t.events:
        if e["method"] == "Media.playerPropertiesChanged":
            for p in e["params"]["properties"]:
                props[p["name"]] = p["value"]
    try:
        track = json.loads(props.get("kVideoTracks", "[]"))[0]
        codec = f'{track["codec"]} {track["coded size"]}'
    except (ValueError, LookupError, TypeError):
        codec = ""
    frames, dropped = q1[0] - q0[0], q1[1] - q0[1]
    decoder = props.get("kVideoDecoderName", "")
    hw = props.get("kIsPlatformVideoDecoder")
    print(json.dumps({"test": "youtube-4k", "video": video, "decoder": decoder,
                      "hardware": hw in (True, "true"), "codec": codec,
                      "height": height, "fps": round(frames / seconds, 1) if seconds else None,
                      "dropped_pct": round(100 * dropped / frames, 1) if frames else None,
                      "seconds": seconds}))


if __name__ == "__main__":
    main()
