#!/usr/bin/env python3
"""A real QEMU's -netdev user (libslirp) while the Mac stalls a UDP send.

No guest and no CPU: -machine none, and a dgram netdev joined to the user
netdev by a hub stands in for the guest's network card. This script sends the
guest's Ethernet frames through it, so they take the VM's path: QEMU's main
loop (holding the BQL) -> net_slirp_receive -> udp_input -> sosendto. The
sendto() stall comes from udp-stall-inject.dylib (XNU's semantics: a blocking
socket waits, a non-blocking one gets EAGAIN); nothing leaves the Mac.

Cases (--case):
  fixed     burst of UDP datagrams to the stalled destination: QMP keeps
            answering, slirp keeps answering ARP and ping, the drops are counted
            ("info usernet") and logged once.
  hang      the same burst on a runtime without the fix: QMP must stop
            answering (the old freeze), detected with a timeout.
  watchdog  one send that stalls whatever the socket mode: the main loop stall
            watchdog must log the place (sosendto) and the end of the stall.
"""
import argparse
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

GUEST_MAC = bytes.fromhex("525400123456")
SLIRP_MAC_PREFIX = bytes.fromhex("5255")
GUEST_IP = socket.inet_aton("10.0.2.15")
GATEWAY_IP = socket.inet_aton("10.0.2.2")
STALL_IP = "192.0.2.1"  # TEST-NET-1, never reached: the injector answers
STALL_PORT = 9
BURST = 200


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def ether(dst, kind, payload):
    return dst + GUEST_MAC + struct.pack("!H", kind) + payload


def arp_request():
    body = struct.pack("!HHBBH", 1, 0x0800, 6, 4, 1) + GUEST_MAC + GUEST_IP + b"\0" * 6 + GATEWAY_IP
    return ether(b"\xff" * 6, 0x0806, body)


def ipv4(dst, proto, payload, ident):
    header = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(payload), ident, 0, 64, proto, 0, GUEST_IP, dst)
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    return header + payload


def udp_frame(gw_mac, ident):
    payload = b"x" * 512
    udp = struct.pack("!HHHH", 40000, STALL_PORT, 8 + len(payload), 0) + payload
    return ether(gw_mac, 0x0800, ipv4(socket.inet_aton(STALL_IP), 17, udp, ident))


def ping_frame(gw_mac, seq):
    icmp = struct.pack("!BBHHH", 8, 0, 0, 0x4f4d, seq) + b"omacvm-ping"
    icmp = icmp[:2] + struct.pack("!H", checksum(icmp)) + icmp[4:]
    return ether(gw_mac, 0x0800, ipv4(GATEWAY_IP, 1, icmp, 0x1000 + seq))


class Qmp:
    def __init__(self, path, timeout):
        deadline = time.monotonic() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                self.sock.close()
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.05)
        self.buf = b""
        self.read(timeout)  # greeting
        self.call("qmp_capabilities", timeout=timeout)

    def read(self, timeout):
        self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("QMP closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, command, timeout=2.0, **arguments):
        message = {"execute": command}
        if arguments:
            message["arguments"] = arguments
        self.sock.sendall(json.dumps(message).encode() + b"\n")
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise socket.timeout(command)
            reply = self.read(left)
            if "return" in reply or "error" in reply:
                return reply


class Rig:
    def __init__(self, qemu, inject, mode, secs, work):
        self.work = work
        self.net = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.net.bind(("127.0.0.1", 0))
        here = self.net.getsockname()[1]
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.bind(("127.0.0.1", 0))
        there = probe.getsockname()[1]
        probe.close()
        self.qemu_addr = ("127.0.0.1", there)
        self.qmp_path = os.path.join(work, "qmp.sock")
        self.log_path = os.path.join(work, "qemu.log")
        self.stall_log = os.path.join(work, "stall.log")
        env = dict(os.environ)
        env.update({
            "DYLD_INSERT_LIBRARIES": inject,
            "UDP_STALL_DEST": "%s:%d" % (STALL_IP, STALL_PORT),
            "UDP_STALL_MODE": mode,
            "UDP_STALL_SECS": str(secs),
            "UDP_STALL_LOG": self.stall_log,
        })
        env.pop("OMACVM_STALL_WATCHDOG", None)
        cmd = [qemu, "-machine", "none", "-nodefaults", "-display", "none", "-msg", "timestamp=on",
               "-netdev", "user,id=u0",
               "-netdev", "dgram,id=d0,local.type=inet,local.host=127.0.0.1,local.port=%d,"
                          "remote.type=inet,remote.host=127.0.0.1,remote.port=%d" % (there, here),
               "-netdev", "hubport,id=h0,hubid=0,netdev=u0",
               "-netdev", "hubport,id=h1,hubid=0,netdev=d0",
               "-qmp", "unix:%s,server=on,wait=off" % self.qmp_path]
        self.log = open(self.log_path, "w")
        self.proc = subprocess.Popen(cmd, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        self.qmp = Qmp(self.qmp_path, 10.0)
        self.gw_mac = None

    def close(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGKILL)
        self.proc.wait()
        self.log.close()
        self.net.close()

    def send(self, frame):
        self.net.sendto(frame, self.qemu_addr)

    def expect(self, want, timeout):
        """Wait for a frame from slirp that want(frame) accepts."""
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            self.net.settimeout(left)
            try:
                frame, _ = self.net.recvfrom(65536)
            except socket.timeout:
                return None
            if want(frame):
                return frame

    def arp(self, timeout=2.0):
        self.send(arp_request())

        def reply(f):
            return (len(f) >= 42 and f[12:14] == b"\x08\x06" and f[20:22] == b"\x00\x02"
                    and f[28:32] == GATEWAY_IP)
        frame = self.expect(reply, timeout)
        if frame:
            self.gw_mac = frame[22:28]
        return frame is not None

    def ping(self, seq, timeout=2.0):
        self.send(ping_frame(self.gw_mac, seq))

        def reply(f):
            return (len(f) >= 42 and f[12:14] == b"\x08\x00" and f[23] == 1 and f[26:30] == GATEWAY_IP
                    and f[34] == 0 and struct.unpack("!H", f[40:42])[0] == seq)
        return self.expect(reply, timeout) is not None

    def responsive(self, timeout=2.0):
        try:
            return self.qmp.call("query-status", timeout=timeout).get("return") is not None
        except (socket.timeout, OSError, ValueError):
            return False

    def usernet(self):
        reply = self.qmp.call("human-monitor-command", timeout=2.0, **{"command-line": "info usernet"})
        return reply.get("return", "")

    def logged(self):
        with open(self.log_path, errors="replace") as f:
            return f.read()

    def stalls(self):
        try:
            with open(self.stall_log) as f:
                return f.read().split()
        except FileNotFoundError:
            return []


def fail(msg, rig=None):
    print("slirp-udp-stall: FAIL: " + msg)
    if rig:
        print("--- qemu.log ---")
        print(rig.logged()[-4000:])
    return 1


def ready(rig):
    """The rig works before the stall: QMP, ARP and ping answer."""
    if not rig.responsive():
        return "QMP did not answer before the test"
    if not rig.arp():
        return "slirp did not answer ARP before the test"
    if not rig.ping(1):
        return "slirp did not answer ping before the test"
    return None


def case_fixed(rig):
    problem = ready(rig)
    if problem:
        return fail(problem, rig)
    for i in range(BURST):
        rig.send(udp_frame(rig.gw_mac, i + 1))
    time.sleep(0.5)
    if not rig.responsive():
        return fail("QMP stopped answering after the burst: the main loop is stuck", rig)
    for seq in range(2, 7):
        if not rig.ping(seq):
            return fail("slirp stopped answering ping %d after the burst" % seq, rig)
    stalls = rig.stalls()
    if "wait" in stalls:
        return fail("libslirp sent on a blocking socket (%d waits)" % stalls.count("wait"), rig)
    if stalls.count("eagain") != BURST:
        return fail("expected %d EAGAIN sends, the injector saw %d" % (BURST, stalls.count("eagain")), rig)
    info = rig.usernet()
    want = "Datagrams dropped (host busy): %d" % BURST
    if want not in info:
        return fail("'info usernet' lacks %r:\n%s" % (want, info), rig)
    lines = [l for l in rig.logged().splitlines() if "dropped a datagram to %s port %d" % (STALL_IP, STALL_PORT) in l]
    if len(lines) != 1:
        return fail("expected the drop logged once (once a minute), got %d lines" % len(lines), rig)
    print("slirp-udp-stall: fixed ok: %d datagrams dropped and counted, logged once, QMP and ping answer" % BURST)
    print("  " + lines[0].strip())
    return 0


def case_hang(rig, wait):
    problem = ready(rig)
    if problem:
        return fail(problem, rig)
    for i in range(BURST):
        rig.send(udp_frame(rig.gw_mac, i + 1))
    started = time.monotonic()
    answered = rig.responsive(timeout=wait)
    if answered:
        return fail("QMP still answered: this runtime does not freeze (has it the fix?)", rig)
    if rig.stalls()[:1] != ["wait"]:
        return fail("QMP did not answer, but not because sendto() waited: %r" % rig.stalls()[:3], rig)
    print("slirp-udp-stall: hang reproduced: sendto() on a blocking libslirp socket, "
          "QMP silent for %.1f s (old freeze)" % (time.monotonic() - started))
    return 0


def case_watchdog(rig, secs):
    problem = ready(rig)
    if problem:
        return fail(problem, rig)
    rig.send(udp_frame(rig.gw_mac, 1))
    deadline = time.monotonic() + secs + 6
    log = ""
    while time.monotonic() < deadline:
        log = rig.logged()
        if "main loop stall over" in log:
            break
        time.sleep(0.2)
    stalled = [l for l in log.splitlines() if "main loop stalled for" in l]
    if len(stalled) != 1:
        return fail("expected one 'main loop stalled' line, got %d" % len(stalled), rig)
    if "sosendto" not in stalled[0] or "BQL held" not in stalled[0]:
        return fail("the stall line does not name sosendto with the BQL held:\n" + stalled[0], rig)
    if "main loop stall over" not in log:
        return fail("no 'main loop stall over' line after the stall ended", rig)
    if not rig.responsive():
        return fail("QMP did not answer after the stall", rig)
    print("slirp-udp-stall: watchdog ok")
    print("  " + stalled[0].strip()[:300])
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", required=True)
    ap.add_argument("--inject", required=True)
    ap.add_argument("--case", choices=["fixed", "hang", "watchdog"], required=True)
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="slirp-stall.")
    mode, secs = {"fixed": ("kernel", 20), "hang": ("kernel", 20), "watchdog": ("always", 4)}[args.case]
    rig = None
    try:
        rig = Rig(args.qemu, args.inject, mode, secs, work)
        if args.case == "fixed":
            return case_fixed(rig)
        if args.case == "hang":
            return case_hang(rig, 5.0)
        return case_watchdog(rig, secs)
    finally:
        if rig:
            rig.close()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
