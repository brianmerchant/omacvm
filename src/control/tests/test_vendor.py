"""OmacVM's own Textual (src/control/vendor, omacvm_cc/vendor.py): the wheels
as shipped, unpacked once into the user's cache, loaded without anything
from pacman or pip, and refused when they are not as shipped."""
import os
import shutil
import subprocess
import sys
import time
import zipfile

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omacvm_cc import vendor  # noqa: E402

VENDOR = os.path.join(os.path.dirname(__file__), "..", "vendor")
CI = os.path.join(os.path.dirname(__file__), "..", "..", "..", ".github", "workflows", "check.yml")


@pytest.fixture
def cache(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
    monkeypatch.delenv("OMACVM_VENDOR_DIR", raising=False)
    return tmp_path / "cache" / "omacvm" / "python"


def copy_vendor(tmp_path, monkeypatch):
    d = tmp_path / "vendor"
    shutil.copytree(VENDOR, d)
    monkeypatch.setenv("OMACVM_VENDOR_DIR", str(d))
    return d


def test_shipped_set_is_pure_python_and_complete():
    listed, _ = vendor.wheels(VENDOR)
    names = [n for n, _ in listed]
    assert sorted(names) == sorted(n for n in os.listdir(VENDOR) if n.endswith(".whl"))
    assert all(n.endswith("-py3-none-any.whl") for n in names), names   # no compiled code: any Python 3, any CPU
    assert any(n.startswith("textual-8.2.8-") for n in names)
    for dep in ("rich", "pygments", "markdown_it_py", "mdurl", "platformdirs", "typing_extensions"):
        assert any(n.startswith(dep + "-") for n in names), dep
    assert len(vendor.verify(VENDOR)) == len(names)


def test_ci_tests_the_shipped_set():
    """The control centre's tests run with these wheels, not another Textual."""
    with open(CI, encoding="utf-8") as f:
        ci = f.read()
    assert "src/control/vendor/*.whl" in ci and 'textual==' not in ci


def test_unpacked_once_and_loads_without_site_packages(cache):
    path = vendor.ensure()
    assert os.path.dirname(path) == str(cache) and os.path.exists(os.path.join(path, vendor.DONE))
    mtime = os.stat(os.path.join(path, "textual", "__init__.py")).st_mtime
    assert vendor.ensure() == path
    assert os.stat(os.path.join(path, "textual", "__init__.py")).st_mtime == mtime   # not unpacked again
    # -I -S: no user or system site-packages, so nothing but this copy can answer.
    code = "import sys; sys.path.insert(0, sys.argv[1]); import textual.app, textual.widgets; print(textual.__version__)"
    r = subprocess.run([sys.executable, "-I", "-S", "-c", code, path], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.strip() == "8.2.8", r.stderr


def test_use_puts_it_first(cache, monkeypatch):
    monkeypatch.setattr(sys, "path", list(sys.path))
    assert vendor.use() == ""
    assert sys.path[0] == vendor.ensure()


def test_a_changed_wheel_is_refused(tmp_path, cache, monkeypatch):
    d = copy_vendor(tmp_path, monkeypatch)
    w = next(p for p in d.iterdir() if p.name.startswith("rich-"))
    w.write_bytes(w.read_bytes()[:-10])
    with pytest.raises(vendor.Missing, match="rich-.* is not as shipped"):
        vendor.ensure()
    assert "not as shipped" in vendor.use()
    ok, text = vendor.check()
    assert not ok and "not as shipped" in text
    assert not cache.exists() or not list(cache.glob("*/" + vendor.DONE))


def test_missing_copy_says_so(tmp_path, cache, monkeypatch):
    monkeypatch.setenv("OMACVM_VENDOR_DIR", str(tmp_path / "nothing"))
    assert "OmacVM's copy of Textual is missing" in vendor.use()
    d = copy_vendor(tmp_path, monkeypatch)
    next(p for p in d.iterdir() if p.name.startswith("pygments-")).unlink()
    with pytest.raises(vendor.Missing, match="pygments-.* is missing"):
        vendor.ensure()


def test_a_path_outside_the_folder_is_refused(tmp_path, cache, monkeypatch):
    d = tmp_path / "evil"
    d.mkdir()
    w = d / "evil-1.0-py3-none-any.whl"
    with zipfile.ZipFile(w, "w") as z:
        z.writestr("../../escaped.py", "x = 1\n")
    import hashlib
    (d / "SHA256SUMS").write_text(f"{hashlib.sha256(w.read_bytes()).hexdigest()}  {w.name}\n")
    monkeypatch.setenv("OMACVM_VENDOR_DIR", str(d))
    with pytest.raises(vendor.Missing, match="bad path"):
        vendor.ensure()
    assert not (tmp_path / "escaped.py").exists() and not (tmp_path / "cache" / "escaped.py").exists()


def test_bad_sums_file(tmp_path, cache, monkeypatch):
    d = tmp_path / "v"
    d.mkdir()
    monkeypatch.setenv("OMACVM_VENDOR_DIR", str(d))
    for text in ("", "abc  x.whl\n", "0" * 64 + "  ../x.whl\n", "0" * 64 + "  x.tar.gz\n"):
        (d / "SHA256SUMS").write_text(text)
        with pytest.raises(vendor.Missing):
            vendor.wheels()


def test_older_sets_go_after_a_week(cache):
    path = vendor.ensure()
    old, fresh = cache / "0123456789abcdef", cache / "fedcba9876543210"
    for d in (old, fresh):
        d.mkdir()
        (d / vendor.DONE).write_text("")
    week = time.time() - vendor.KEEP_OLD - 60
    os.utime(old / vendor.DONE, (week, week))
    (cache / ".new-x").mkdir()   # another start unpacking right now
    shutil.rmtree(path)          # unpacked again: the clean-up runs
    vendor.ensure()
    assert not old.exists() and fresh.exists() and (cache / ".new-x").exists()


def test_check_for_the_guest_check(cache):
    ok, text = vendor.check()
    assert ok and text == "8.2.8 (OmacVM's own)", text
    assert not cache.exists()   # check writes nothing


def test_runs_alone_as_a_script(tmp_path, cache):
    """guest/install.sh and check.sh run vendor.py by itself (python3 -I)."""
    script = os.path.join(os.path.dirname(__file__), "..", "omacvm_cc", "vendor.py")
    env = dict(os.environ, XDG_CACHE_HOME=str(tmp_path / "cache"))
    env.pop("OMACVM_VENDOR_DIR", None)
    r = subprocess.run([sys.executable, "-I", script], capture_output=True, text=True, env=env, cwd=tmp_path)
    assert r.returncode == 0 and r.stdout.strip().startswith(str(cache)), r.stderr
    r = subprocess.run([sys.executable, "-I", script, "--check"], capture_output=True, text=True, env=env, cwd=tmp_path)
    assert r.returncode == 0 and "OmacVM's own" in r.stdout, r.stderr
