#!/usr/bin/env python3
"""omacvm-camera's frames and their times (no VM, no camera needed).

    python3 src/camera/guest/tests/test_frames.py

A new reader gets v4l2loopback's last frame first. Its time must sit right
before the next frame, or ffmpeg fills the gap with copies of it (all black).
"""
import ctypes
import errno
import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[4]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


camera = load("omacvm_camera", "src/camera/guest/omacvm-camera")


class FrameTimes(unittest.TestCase):
    def test_runs_with_the_monotonic_clock(self):
        clock = camera.FrameClock()
        self.assertEqual(clock.time(100.0), 100.0)
        self.assertEqual(clock.time(101.5), 101.5)

    def test_stopped_while_nobody_reads(self):
        clock = camera.FrameClock()
        clock.stop(100.0)
        self.assertEqual(clock.time(100.0), 100.0)
        self.assertEqual(clock.time(3700.0), 100.0)   # an hour later

    def test_next_frame_comes_right_after_the_old_one(self):
        clock = camera.FrameClock()
        clock.stop(100.0)            # last frame of the last use: 100.0
        clock.go(3700.0)             # an app reads an hour later
        self.assertAlmostEqual(clock.time(3700.0), 100.0 + camera.FRAME_TIME)
        self.assertAlmostEqual(clock.time(3701.0), 101.0 + camera.FRAME_TIME)   # runs at real speed

    def test_many_uses_never_go_back(self):
        clock = camera.FrameClock()
        last, now = clock.time(10.0), 10.0
        for gap in (0.01, 5.0, 600.0, 0.0):
            now += 2.0
            self.assertGreater(clock.time(now), last)
            last = clock.time(now)
            clock.stop(now)
            now += gap
            clock.go(now)
            self.assertGreater(clock.time(now), last)
            self.assertLess(clock.time(now) - last, 0.05)
            last = clock.time(now)

    def test_stop_and_go_twice_change_nothing(self):
        clock = camera.FrameClock()
        clock.stop(100.0)
        clock.stop(200.0)
        self.assertEqual(clock.time(300.0), 100.0)
        clock.go(300.0)
        before = clock.time(301.0)
        clock.go(301.0)
        self.assertEqual(clock.time(301.0), before)

    def test_timeval(self):
        t = camera.timeval(12.25)
        self.assertEqual((t.seconds, t.microseconds), (12, 250000))
        t = camera.timeval(1.9999999)
        self.assertEqual((t.seconds, t.microseconds), (2, 0))
        t = camera.timeval(0.0)   # 0.0 would be "the kernel's time"
        self.assertEqual((t.seconds, t.microseconds), (0, 1))


class Ioctls(unittest.TestCase):
    """The numbers are the kernel's (64-bit: the guest is aarch64)."""

    def test_numbers(self):
        if ctypes.sizeof(ctypes.c_long) != 8:
            self.skipTest("not a 64-bit Python")
        self.assertEqual(ctypes.sizeof(camera.V4L2Buffer), 88)
        self.assertEqual(ctypes.sizeof(camera.V4L2RequestBuffers), 20)
        self.assertEqual(camera.VIDIOC_REQBUFS, 0xC0145608)
        self.assertEqual(camera.VIDIOC_QUERYBUF, 0xC0585609)
        self.assertEqual(camera.VIDIOC_QBUF, 0xC058560F)
        self.assertEqual(camera.VIDIOC_DQBUF_BUFFER, 0xC0585611)
        self.assertEqual(camera.VIDIOC_STREAMON, 0x40045612)
        self.assertEqual(camera.V4L2Buffer.timestamp.offset, 24)
        self.assertEqual(camera.V4L2Buffer.m.offset, 64)


class Fallback(unittest.TestCase):
    def test_without_buffers_frames_are_written(self):
        with tempfile.TemporaryFile() as f:
            frames = camera.Frames(f.fileno(), buffers=False)
            frames.put(camera.BLACK)
            self.assertEqual(os.fstat(f.fileno()).st_size, camera.FRAME_BYTES)

    def test_no_v4l2_device_means_no_buffers(self):
        with tempfile.TemporaryFile() as f:
            with self.assertRaises(camera.NoBuffers):
                camera.Frames(f.fileno(), buffers=True)

    def test_setup_tries_again_with_write(self):
        fds = [os.open(os.devnull, os.O_RDONLY), os.open(os.devnull, os.O_RDONLY)]
        calls = []

        def configure(fd, buffers=True):
            calls.append((fd, buffers))
            if buffers:
                raise camera.NoBuffers("no QBUF")
            return "frames"

        with mock.patch.object(camera, "open_camera", side_effect=list(fds)), \
                mock.patch.object(camera, "configure_camera", side_effect=configure), \
                mock.patch.object(camera, "log"):
            fd, frames = camera.setup_camera()
        try:
            self.assertEqual((fd, frames), (fds[1], "frames"))
            self.assertEqual(calls, [(fds[0], True), (fds[1], False)])
            with self.assertRaises(OSError):
                os.fstat(fds[0])   # the first descriptor was closed
        finally:
            os.close(fds[1])

    def test_gone_device_is_not_a_fallback(self):
        def configure(fd, buffers=True):
            raise OSError(errno.ENODEV, "gone")

        fd = os.open(os.devnull, os.O_RDONLY)
        try:
            with mock.patch.object(camera, "open_camera", return_value=fd), \
                    mock.patch.object(camera, "configure_camera", side_effect=configure):
                with self.assertRaises(OSError) as caught:
                    camera.setup_camera()
            self.assertEqual(caught.exception.errno, errno.ENODEV)
        finally:
            os.close(fd)


if __name__ == "__main__":
    unittest.main()
