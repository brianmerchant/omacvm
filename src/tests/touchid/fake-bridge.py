#!/usr/bin/env python3
"""A fake OmacVM Bridge for src/tests/touchid-client.sh: /proof and
POST /omacvm/touchid as touchid.swift answers them, with the answer chosen
by the test (DIR/mode). Checks the request's signature like the Bridge.
  fake-bridge.py DIR   (DIR/token, DIR/key; writes DIR/port, logs DIR/requests)"""
import hashlib, hmac, http.server, json, os, sys, time

D = sys.argv[1]
token = open(f"{D}/token", "rb").read().strip()
key = open(f"{D}/key", "rb").read().strip()


def mac(k, text):
    return hmac.new(k, text.encode(), hashlib.sha256).hexdigest()


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj, sign=None):
        data = (json.dumps(obj, separators=(",", ":"), sort_keys=True) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if sign:
            k, nonce = sign
            self.send_header("X-OmacVM-Answer", mac(k, "\n".join(["omacvm-touchid-answer 1", nonce, str(code), hashlib.sha256(data).hexdigest()])))
        self.end_headers()
        self.wfile.write(data)

    def mode(self):
        try:
            return open(f"{D}/mode").read().strip()
        except OSError:
            return "yes"

    def do_GET(self):
        n = self.path.partition("nonce=")[2]
        knows = token if self.mode() != "wrong-proof" else b"x" * 64
        self.send(200, {"proof": mac(knows, f"omacvm-bridge mac 127.0.0.1 {n}")})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(f"{D}/requests", "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization", ""), "body": body.decode()}) + "\n")
        if self.headers.get("Authorization") != "Bearer " + token.decode():
            return self.send(401, {"error": "token"})
        f = (self.headers.get("X-OmacVM-Auth") or "").split(" ")
        want = mac(key, "\n".join(["omacvm-touchid-request 1", "POST", self.path, f[1] if len(f) > 1 else "",
                                   f[2] if len(f) > 2 else "", self.headers.get("X-OmacVM-Proto", ""), hashlib.sha256(body).hexdigest()]))
        if len(f) != 4 or not hmac.compare_digest(want, f[3]) or abs(time.time() - int(f[1])) > 300:
            return self.send(403, {"error": "key", "code": "vm-key"})
        nonce, m = f[2], self.mode()
        if m == "yes":
            self.send(200, {"result": "yes"}, (key, nonce))
        elif m.startswith("no-"):
            self.send(200, {"result": "no", "reason": m[3:]}, (key, nonce))
        elif m == "unsigned":
            self.send(200, {"result": "yes"})
        elif m == "other-key":
            self.send(200, {"result": "yes"}, (b"o" * 64, nonce))
        elif m == "other-nonce":
            self.send(200, {"result": "yes"}, (key, "0" * 32))
        elif m == "off":
            self.send(403, {"error": "off", "code": "off"}, (key, nonce))


s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(f"{D}/port.tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.replace(f"{D}/port.tmp", f"{D}/port")
s.serve_forever()
