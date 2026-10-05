#!/usr/bin/env python3
"""Which video decoder does a Chromium-family browser pick for local files?

  chromium-probe.py [--port 9222] [--seconds 8] file.mp4 file.webm ...

Chromium must run with --remote-debugging-port. Prints the GPU process's
video decode status and profiles (what chrome://gpu shows), then plays each
file from a local HTTP server and prints one JSON line per file with the
decoder name, whether it is a platform (hardware) decoder, frames decoded
and the media log messages (chrome://media-internals).
"""
import functools, http.server, importlib.util, json, os, sys, threading, time, urllib.request

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bb", os.path.join(here, "..", "browser-bench.py"))
if not os.path.exists(spec.origin):
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
                return m.get("result", m.get("error", {}))
            if "method" in m:
                self.events.append(m)


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def main():
    port = int(arg("--port", 9222))
    seconds = int(arg("--seconds", 8))
    skip = {"--port", "--seconds"}
    files, i = [], 1
    while i < len(sys.argv):
        if sys.argv[i] in skip:
            i += 2
            continue
        files.append(os.path.abspath(sys.argv[i])); i += 1

    base = f"http://127.0.0.1:{port}"
    browser = Tab(json.load(urllib.request.urlopen(f"{base}/json/version"))["webSocketDebuggerUrl"])
    info = browser.call("SystemInfo.getInfo")
    gpu = info.get("gpu", {})
    print(json.dumps({"gpu_feature_video_decode": gpu.get("featureStatus", {}).get("video_decode"),
                      "video_decoding": gpu.get("videoDecoding", []),
                      "gl_renderer": next((d.get("deviceString") for d in gpu.get("devices", [])), None)}))

    for path in files:
        d, name = os.path.split(path)
        page = (f'<!doctype html><body style="margin:0;background:#000">'
                f'<video src="{name}" autoplay muted loop playsinline style="width:100vw;height:100vh"></video>')

        class H(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.path in ("/", "/index.html"):
                    self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
                    self.wfile.write(page.encode())
                else:
                    super().do_GET()

            def log_message(self, *a):
                pass

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=d))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        req = urllib.request.Request(f"{base}/json/new?http://127.0.0.1:{srv.server_port}/", method="PUT")
        target = json.load(urllib.request.urlopen(req))
        t = Tab(target["webSocketDebuggerUrl"])
        t.call("Media.enable"); t.call("Page.enable"); t.call("Page.bringToFront")
        time.sleep(seconds)
        q = t.js("(() => { const v = document.querySelector('video'); const q = v.getVideoPlaybackQuality(); "
                 "return [q.totalVideoFrames, q.droppedVideoFrames, v.currentTime, v.videoWidth, v.videoHeight, "
                 "v.error ? v.error.message : null] })()") or []
        t.call("Runtime.evaluate", expression="1")   # collect pending events
        props, msgs, errors = {}, [], []
        for e in t.events:
            if e["method"] == "Media.playerPropertiesChanged":
                for p in e["params"]["properties"]:
                    props[p["name"]] = p["value"]
            elif e["method"] == "Media.playerMessagesLogged":
                msgs += [f'{m["level"]}: {m["message"]}' for m in e["params"]["messages"]]
            elif e["method"] == "Media.playerErrorsRaised":
                errors += [json.dumps(x) for x in e["params"]["errors"]]
        print(json.dumps({"file": name, "decoder": props.get("kVideoDecoderName"),
                          "platform_decoder": props.get("kIsPlatformVideoDecoder"),
                          "frames_dropped_time_w_h_err": q,
                          "video_tracks": props.get("kVideoTracks"),
                          "messages": msgs[-25:], "errors": errors}, indent=1))
        urllib.request.urlopen(urllib.request.Request(f"{base}/json/close/{target['id']}", method="PUT"))
        srv.shutdown()


if __name__ == "__main__":
    main()
