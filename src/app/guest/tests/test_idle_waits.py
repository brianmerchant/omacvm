#!/usr/bin/env python3
"""How long the guest agents sleep while nothing happens (no VM needed).

    python3 src/app/guest/tests/test_idle_waits.py
"""
import importlib.machinery
import importlib.util
import os
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


camera = load("omacvm_camera", "src/camera/guest/omacvm-camera")
clipboard = load("omacvm_clipboard", "src/app/guest/omacvm-clipboard")


class Camera(unittest.TestCase):
    def test_unused_camera_sleeps(self):
        self.assertEqual(camera.wait_ms(False, 100.0, 0.0), -1)
        self.assertEqual(camera.wait_ms(False, 100.0, 99.0), -1)   # quiet time over

    def test_quiet_port_is_looked_at_again(self):
        self.assertEqual(camera.wait_ms(False, 100.0, 100.5), 501)
        self.assertGreaterEqual(camera.wait_ms(False, 100.0, 100.0001), 1)

    def test_reading_app_keeps_the_fast_loop(self):
        self.assertEqual(camera.wait_ms(True, 100.0, 0.0), 200)


class Clipboard(unittest.TestCase):
    def test_watcher_exit_wakes_the_loop(self):
        import select
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.2)"])
        fd = clipboard.exit_fd(child.pid)
        if fd is None:
            child.wait()
            self.assertNotEqual(sys.platform, "linux", "no pidfd on Linux")   # the guest has one
            self.skipTest("no pidfd here (the agent looks once a second)")
        try:
            self.assertEqual(select.select([fd], [], [], 5)[0], [fd])
            self.assertIsNotNone(child.poll())
        finally:
            os.close(fd)


if __name__ == "__main__":
    unittest.main()
