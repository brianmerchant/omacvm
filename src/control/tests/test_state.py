"""State rules: every step of the status order, dependencies, updates."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402

from omacvm_cc import state as S  # noqa: E402

TSV = os.path.join(os.path.dirname(__file__), "..", "..", "features.tsv")


@pytest.fixture(scope="module")
def features():
    return S.parse_features_tsv(open(TSV, encoding="utf-8").read())


def by(features, name):
    return next(f for f in features if f.name == name)


def chk(status, feature, human=False, side="vm", name="x", detail="d"):
    return S.Check(side=side, status=status, name=name, detail=detail, human=human, feature=feature)


def test_features_tsv_parses(features):
    names = [f.name for f in features]
    assert "bridge" in names and "gestures" in names
    assert by(features, "scroll-momentum").needs == "gestures"
    assert by(features, "wallpaper").needs == "bridge"
    assert "experimental" in by(features, "scroll-momentum").tags
    assert all(S.NAME_RE.match(n) for n in names)


def test_parse_env_last_wins():
    env = S.parse_env("OMACVM_FEATURE_bridge=on\nOMACVM_FEATURE_bridge=off\nnoise\n# c=1\n")
    assert env == {"OMACVM_FEATURE_bridge": "off"}


def test_desired_defaults_for_unnamed(features):
    on = S.desired(features, {"OMACVM_FEATURE_bridge": "off"})
    assert on["bridge"] is False
    assert on["gestures"] is True            # default on
    assert on["scroll-momentum"] is False    # older VMs: off
    assert on["omanotch"] is False           # notch: the Mac decides; unnamed = off


def test_parse_check_tsv():
    text = "section\tBridge\nok\tWi-Fi\tHome, -50 dBm\t\tbridge\nfail\tLocation\tnot granted\t1\tbridge\nskip\tx\ty\t\t\nweird line\n"
    c = S.parse_check_tsv(text)
    assert [x.status for x in c] == ["ok", "fail", "skip"]
    assert c[1].human and c[1].feature == "bridge"
    assert c[2].feature == ""


def test_parse_check_tsv_old_four_columns():
    c = S.parse_check_tsv("ok\tWi-Fi\tfine\t\n")
    assert c[0].feature == "" and not c[0].human


def test_parse_mac_checks_ignores_junk():
    c = S.parse_mac_checks([{"status": "fail", "name": "a", "detail": "b", "needs_human": True, "feature": "gestures"},
                            {"status": "boom"}, "x"])
    assert len(c) == 1 and c[0].side == "mac" and c[0].human


# ---- the status order, one step at a time ----

def test_busy_wins_over_everything(features):
    f = by(features, "gestures")
    job = S.Job(id="1", action="enable", features=("gestures",), state="running", step=2, of=4, text="Mac side")
    st, note = S.status_of(f, True, S.Avail(False, "no"), [chk("fail", "gestures", True)], job)
    assert st is S.Status.BUSY and note == "Mac side (2/4)"


def test_finished_job_is_not_busy(features):
    f = by(features, "gestures")
    job = S.Job(id="1", action="enable", features=("gestures",), state="done")
    assert S.status_of(f, True, None, [], job)[0] is S.Status.WORKS


def test_unavailable_before_off(features):
    st, note = S.status_of(by(features, "omanotch"), False, S.Avail(False, "needs a MacBook with a notch"), None, None)
    assert st is S.Status.UNAVAILABLE and "notch" in note


def test_off_before_unknown(features):
    assert S.status_of(by(features, "autologin"), False, None, None, None)[0] is S.Status.OFF


def test_unknown_without_checks(features):
    assert S.status_of(by(features, "bridge"), True, None, None, None)[0] is S.Status.UNKNOWN


def test_needs_person_before_failing(features):
    checks = [chk("fail", "gestures", name="gestures", detail="not connected"),
              chk("fail", "gestures", True, side="mac", detail="System Settings > Accessibility")]
    st, note = S.status_of(by(features, "gestures"), True, None, checks, None)
    assert st is S.Status.NEEDS_PERSON and note == "Mac: System Settings > Accessibility"


def test_human_skip_is_a_hint_not_a_problem(features):
    st, _ = S.status_of(by(features, "camera"), True, None, [chk("skip", "camera", True)], None)
    assert st is S.Status.WORKS


def test_failing(features):
    st, note = S.status_of(by(features, "bridge"), True, None, [chk("fail", "bridge", name="audio", detail="no answer")], None)
    assert st is S.Status.FAILING and note == "audio: no answer"


def test_works_when_checked_and_nothing_failed(features):
    assert S.status_of(by(features, "mac-clock"), True, None, [], None)[0] is S.Status.WORKS


# ---- rows ----

def test_rows_map_checks_and_local_avail(features):
    on = S.desired(features, {})
    rows = S.build_rows(features, on, vm_type="parallels",
                        checks=[chk("fail", "bridge", name="audio"), chk("fail", "", name="zram")])
    r = {x.feature.name: x for x in rows}
    assert r["bridge"].status is S.Status.FAILING
    assert r["gestures"].status is S.Status.WORKS
    assert r["battery"].status is S.Status.UNAVAILABLE and "Parallels" in r["battery"].note
    assert r["fast-network"].status is S.Status.UNAVAILABLE and "OmacVM.app" in r["fast-network"].note


def test_app_only_feature_on_the_app(features):
    on = S.desired(features, {"OMACVM_FEATURE_fast_network": "on"})
    rows = S.build_rows(features, on, vm_type="app", checks=[])
    r = {x.feature.name: x for x in rows}
    assert r["fast-network"].status is S.Status.WORKS


def test_rows_mac_avail_and_older_mac(features):
    on = S.desired(features, {"OMACVM_FEATURE_control_centre": "on"})
    rows = S.build_rows(features, on, avail={"omanotch": S.Avail(False, "needs a MacBook with a notch")},
                        checks=[], mac_features={f.name for f in features} - {"control-centre"})
    r = {x.feature.name: x for x in rows}
    assert r["omanotch"].status is S.Status.UNAVAILABLE
    assert r["control-centre"].status is S.Status.UNAVAILABLE and "older" in r["control-centre"].note


def test_update_flags_and_update_job(features):
    on = S.desired(features, {})
    installed = {"gestures": {"digest": "sha256:a"}, "bridge": {"digest": "sha256:b"}}
    offer = {"gestures": {"digest": "sha256:c", "release": "2.9.1"}, "bridge": {"digest": "sha256:b"}, "camera": {}}
    job = S.Job(id="9", action="update", features=(), state="running")
    rows = S.build_rows(features, on, checks=[], installed=installed, offer=offer, jobs=[job])
    r = {x.feature.name: x for x in rows}
    assert r["gestures"].update and r["gestures"].status is S.Status.BUSY
    assert not r["bridge"].update and r["bridge"].status is S.Status.WORKS
    assert not r["camera"].update                  # no digest offered: nothing to say
    assert S.counts(rows)["updates"] == 1


def test_part_never_installed_counts_as_changed():
    assert S.part_changed("gestures", {}, {"gestures": {"digest": "sha256:x"}})


# ---- toggles with dependencies ----

def test_toggle_on_brings_what_it_needs(features):
    on = S.desired(features, {"OMACVM_FEATURE_gestures": "off"})
    assert S.toggle_plan(features, on, "scroll-momentum") == {"scroll-momentum": True, "gestures": True}


def test_toggle_off_takes_dependents(features):
    on = S.desired(features, {"OMACVM_FEATURE_bridge": "on", "OMACVM_FEATURE_wallpaper": "on"})
    # external-brightness (on by default) needs the Bridge too.
    assert S.toggle_plan(features, on, "bridge") == {"bridge": False, "wallpaper": False, "external-brightness": False}


def test_toggle_plain(features):
    on = S.desired(features, {})
    assert S.toggle_plan(features, on, "autologin") == {"autologin": True}


def test_toggle_unknown_feature(features):
    with pytest.raises(KeyError):
        S.toggle_plan(features, {}, "rm -rf")


def test_checks_off_hides_marks_but_not_a_running_update():
    fs = S.parse_features_tsv(open(os.path.join(os.path.dirname(__file__), "..", "..", "features.tsv"), encoding="utf-8").read())
    on = {f.name: True for f in fs}
    offer = {"gestures": {"digest": "sha256:" + "c" * 64, "release": "2.9.1"}}
    installed = {"gestures": {"digest": "sha256:" + "a" * 64}}
    rows = {r.feature.name: r for r in S.build_rows(fs, on, checks=[], offer=offer, installed=installed, show_updates=False)}
    assert not rows["gestures"].update
    job = S.Job(id="1", action="update", features=(), state="running", step=5, of=6, text="the VM side")
    rows = {r.feature.name: r for r in S.build_rows(fs, on, checks=[], offer=offer, installed=installed,
                                                    jobs=[job], show_updates=False)}
    assert rows["gestures"].status is S.Status.BUSY and rows["gestures"].note == "the VM side (5/6)"
    assert not rows["gestures"].update and rows["bridge"].status is not S.Status.BUSY


def test_graphics_row_only_for_app_vms():
    st = {"graphics": {"graphics": "auto", "next_start": "vulkan", "this_start": "auto -> vulkan (macOS 27, KosmicKrisp)"}}
    assert S.graphics_row(st, "parallels") is None
    r = S.graphics_row(st, "app")
    assert r.feature.name == "graphics" and r.status is S.Status.WORKS
    assert r.note == "Automatic: OpenGL and Vulkan"


def test_graphics_row_says_next_start():
    st = {"graphics": {"graphics": "opengl", "next_start": "opengl", "this_start": "auto -> vulkan (macOS 27, KosmicKrisp)"}}
    assert S.graphics_row(st, "app").note == "OpenGL: OpenGL from the next start"


def test_graphics_row_unknown_and_busy():
    assert S.graphics_row({}, "app").status is S.Status.UNKNOWN
    assert S.graphics_row({"graphics": {"graphics": "metal"}}, "app").status is S.Status.UNKNOWN
    j = S.Job(id="1", action="graphics", features=("vulkan",), state="running")
    r = S.graphics_row({"graphics": {"graphics": "auto"}}, "app", [j])
    assert r.status is S.Status.BUSY and "Vulkan" in r.note


def test_graphics_row_failing_check():
    st = {"graphics": {"graphics": "vulkan", "next_start": "vulkan", "this_start": "vulkan -> vulkan (chosen, MoltenVK)"}}
    c = chk("fail", "graphics", name="Vulkan (Venus)", detail="needed: omacvm apply")
    r = S.graphics_row(st, "app", [], [c, chk("fail", "bridge")])
    assert r.status is S.Status.FAILING and "omacvm apply" in r.note and len(r.checks) == 1


def test_next_graphics_cycles():
    assert [S.next_graphics(x) for x in ("auto", "opengl", "vulkan", "")] == ["opengl", "vulkan", "auto", "auto"]
