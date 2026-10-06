"""The VM's key never leaves the VM: requests are signed with it, answers
must be signed with it, and a VM that answers for the Mac's address (it has
the Bridge token like every VM) learns nothing it can use."""
import http.client
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from fakes import TOKEN, VM_KEY, FakeMac, vm_env  # noqa: E402
from omacvm_cc.bridge import Bridge, BridgeError, answer_mac, request_mac  # noqa: E402


def test_same_signatures_as_the_bridge():
    # The vector in src/bridge/mac/tests/control_tests.swift.
    body = b'{"action": "disable", "features": ["gestures"]}'
    n = "0123456789abcdef0123456789abcdef"
    assert request_mac(VM_KEY, "POST", "/omacvm/jobs", 1760000000, n, "1", body) == \
        "e939f8224895cf8b312f3eb4af84fd179551fc9920e39ebba4b94905138a2b56"
    assert answer_mac(VM_KEY, n, 202, b'{"ok": true}\n') == \
        "10be1a4a1ddefe1ec4fe0f09d079c9cb4ad19225688a1ad00af15da382883718"


@pytest.fixture
def env(tmp_path, monkeypatch):
    def at(mac):
        for k, v in vm_env(str(tmp_path), mac.port, "/nonexistent").items():
            monkeypatch.setenv(k, v)
        return Bridge({"OMACVM_HOST": "127.0.0.1"}, "2.7.0")
    return at


def leaked(mac) -> bool:
    return any(VM_KEY in " ".join(h.values()) or VM_KEY.encode() in b for h, b in mac.headers_seen)


def test_requests_are_signed_hello_carries_nothing(env):
    mac = FakeMac()
    try:
        b = env(mac)
        b.hello()
        b.status()
        b.start_job("disable", ["gestures"])
        hello = [h for h, _ in mac.headers_seen if "X-OmacVM-Auth" not in h]
        assert len(hello) == 1   # hello only
        assert mac.signed == [("/omacvm/status", True), ("/omacvm/jobs", True)]
        assert not leaked(mac)
    finally:
        mac.stop()


def test_an_impostor_learns_nothing_and_is_not_believed(env):
    """A VM answering for 10.211.55.2: it has the token (passes /proof), not the key."""
    impostor, real = FakeMac(), FakeMac()
    impostor.sign_answers = False
    impostor.manifest = {"version": "9.9.9", "parts": {}}
    try:
        b = env(impostor)
        b.hello()                                     # open to any VM: nothing at stake
        with pytest.raises(BridgeError) as e:
            b.updates()
        assert e.value.kind == "unproven"             # an unsigned answer is not used
        with pytest.raises(BridgeError) as e:
            b.start_job("disable", ["gestures"])
        assert e.value.kind == "unproven"
        assert not leaked(impostor)
        # What it caught, sent on to the Mac: once at most, and not changed.
        h, body = next((h, b) for h, b in impostor.headers_seen if h.get("X-OmacVM-Auth") and b)

        def replay(data: bytes) -> int:
            c = http.client.HTTPConnection("127.0.0.1", real.port, timeout=5)
            c.request("POST", "/omacvm/jobs", body=data, headers={
                "Authorization": "Bearer " + TOKEN.decode(), "X-OmacVM-Proto": h["X-OmacVM-Proto"],
                "X-OmacVM-Auth": h["X-OmacVM-Auth"], "Content-Type": "application/json"})
            r = c.getresponse()
            st = r.status, json.loads(r.read()).get("code")
            c.close()
            return st
        assert replay(body.replace(b"disable", b"enable")) == (403, "vm-key")   # changed: refused
        assert replay(body)[0] == 202                                         # as the VM sent it
        assert replay(body) == (403, "replay")                                # never twice
    finally:
        impostor.stop()
        real.stop()


def test_unsigned_refusals_steer_nothing(env):
    impostor = FakeMac()
    impostor.sign_answers = False
    impostor.refuse_jobs = (409, "update-first", "the Mac has a newer OmacVM: update first")
    try:
        b = env(impostor)
        with pytest.raises(BridgeError) as e:
            b.start_job("enable", ["gestures"])
        assert e.value.kind == "refused" and e.value.code == ""   # shown, but no "u updates" offer
    finally:
        impostor.stop()


def test_clock_off_signs_again_with_the_macs_time(env):
    mac = FakeMac()
    mac.clock_skew = 3600
    try:
        b = env(mac)
        assert b.status()["omacvm"] == "2.7.0"
        assert 3590 < b.clock_offset < 3610
        assert [ok for _, ok in mac.signed] == [True, True]
    finally:
        mac.stop()


def test_no_key_in_the_vm_sends_nothing(env, monkeypatch, tmp_path):
    mac = FakeMac()
    try:
        b = env(mac)
        b.vm_key_file = str(tmp_path / "missing")
        with pytest.raises(BridgeError) as e:
            b.status()
        assert e.value.code == "no-vm-key" and not mac.signed
    finally:
        mac.stop()
