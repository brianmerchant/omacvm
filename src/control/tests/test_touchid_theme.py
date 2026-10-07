"""omacvm-touchid-theme (ADR 0041, addendum 3.0.2): the Omarchy theme's
colours as the VM sends them for the Mac's Touch ID panel, from the theme's
files and Hyprland as Omarchy's own password prompt draws them, signed with
the VM's key; sent once per change and boot, after a switch has settled."""
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from fakes import SRC, FakeMac, vm_env  # noqa: E402

SENDER = os.path.join(SRC, "bridge", "guest", "omacvm-touchid-theme")
FIX = os.path.join(SRC, "bridge", "mac", "tests", "fixtures")
TOKYO = {"accent": "#7aa2f7", "background": "#1a1b26", "border": ["#7aa2f7"], "error": "#f7768e",
         "foreground": "#a9b1d6", "radius": 0, "success": "#9ece6a", "muted": "#414868"}
FLEXOKI = 'mode = "light"\naccent = "#205EA6"\nmuted = "#B7B5AC"\nbackground = "#FFFCF0"\nforeground = "#100F0F"\n' \
          'red = "#D14D41"\ngreen = "#879A39"\n'


@pytest.fixture
def vm(tmp_path):
    theme = tmp_path / "current" / "theme"
    theme.mkdir(parents=True)
    shutil.copy(os.path.join(FIX, "tokyo-night-shell.toml"), theme / "shell.toml")
    shutil.copy(os.path.join(FIX, "tokyo-night-colors.toml"), theme / "colors.toml")
    hypr = tmp_path / "hyprctl"
    hypr.write_text('#!/bin/sh\ncase "$3" in\n'
                    '  decoration:rounding) cat "$(dirname "$0")/rounding" ;;\n'
                    '  general:col.active_border) cat "$(dirname "$0")/border" ;;\nesac\n')
    hypr.chmod(0o755)
    (tmp_path / "rounding").write_text('{"option": "decoration:rounding", "int": 0, "set": true }')
    (tmp_path / "border").write_text('{"option": "general:col.active_border", "gradient": "ff7aa2f7 0deg", "set": true }')
    (tmp_path / "boot_id").write_text("boot-1\n")
    env = dict(os.environ, OMACVM_TOUCHID_THEME_DIR=str(theme), OMACVM_TOUCHID_THEME_STATE=str(tmp_path / "sent"),
               OMACVM_TOUCHID_THEME_DELAY="0", OMACVM_HYPRCTL=str(hypr), HOME=str(tmp_path),
               OMACVM_TOUCHID_THEME_BOOT=str(tmp_path / "boot_id"))
    return tmp_path, env


def run(env, *args):
    return subprocess.run([sys.executable, "-I", SENDER, *args], env=env, capture_output=True, text=True, timeout=30)


def printed(env):
    r = run(env, "--print")
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def test_tokyo_night_from_the_shell_files_and_hyprland(vm):
    assert printed(vm[1]) == TOKYO


def test_a_gradient_border_and_rounding(vm):
    tmp, env = vm
    (tmp / "border").write_text('{"option": "general:col.active_border", "gradient": "ee798186 eecacccc 45deg", "set": true }')
    (tmp / "rounding").write_text('{"option": "decoration:rounding", "int": 6, "set": true }')
    t = printed(env)
    assert t["border"] == ["#798186", "#cacccc"] and t["border_angle"] == 45.0 and t["radius"] == 6


def test_without_hyprland_the_polkit_border(vm):
    tmp, env = vm
    env["OMACVM_HYPRCTL"] = str(tmp / "nothing-here")
    t = printed(env)
    assert t["border"] == ["#7aa2f7"] and "border_angle" not in t and t["radius"] == 0


def test_colors_toml_alone(vm):
    tmp, env = vm
    (tmp / "current" / "theme" / "shell.toml").unlink()
    (tmp / "current" / "theme" / "colors.toml").write_text('mode = "dark"\nbackground = "#282828"\nforeground = "#D4BE98"\n'
                                               'accent = "#7daea3"\nred = "#ea6962"\n')
    t = printed(env)
    assert (t["background"], t["foreground"], t["accent"], t["error"]) == ("#282828", "#d4be98", "#7daea3", "#ea6962")


def test_success_and_muted_from_colors_toml(vm):
    tmp, env = vm
    text = (tmp / "current" / "theme" / "colors.toml").read_text()
    (tmp / "current" / "theme" / "colors.toml").write_text(text.replace('green = "#9ece6a"', 'green = "nope"'))
    t = printed(env)
    assert "success" not in t and t["muted"] == "#414868", "a colour it cannot read is left out (the Mac uses the text colour)"


def test_odd_values_are_left_out(vm):
    tmp, env = vm
    (tmp / "current" / "theme" / "shell.toml").unlink()
    (tmp / "current" / "theme" / "colors.toml").write_text('background = "#282828"\nforeground = "#ebdbb2"\naccent = "blue"\nred = 5\n')
    (tmp / "rounding").write_text('{"int": true}')
    t = printed(env)
    assert t["accent"] == "#ebdbb2" and t["error"] == "#ebdbb2" and t["radius"] == 0


def test_a_light_theme_without_shell_toml(vm):
    tmp, env = vm
    (tmp / "current" / "theme" / "shell.toml").unlink()
    (tmp / "current" / "theme" / "colors.toml").write_text(FLEXOKI)
    t = printed(env)
    assert (t["background"], t["foreground"], t["accent"], t["error"], t["success"]) == \
        ("#fffcf0", "#100f0f", "#205ea6", "#d14d41", "#879a39"), "flexoki-light, as the user's VM has it"


def test_the_prompts_own_accent_and_border(vm):
    tmp, env = vm
    shell = (tmp / "current" / "theme" / "shell.toml")
    text = shell.read_text()
    # Omarchy's prompt: its lock glyph in [polkit] accent, its border the theme's own gradient.
    text = text.replace('accent           = "#7aa2f7"', 'accent           = "#bb9af7"')
    text = text.replace('border           = "hyprland.active-border"\nborder-error',
                        'border           = "rgba(33ccffee) rgba(00ff99ee) 45deg"\nborder-error')
    shell.write_text(text)
    t = printed(env)
    assert t["accent"] == "#bb9af7" and t["border"] == ["#33ccff", "#00ff99"] and t["border_angle"] == 45.0


def test_the_hyprland_token_when_hyprland_does_not_answer(vm):
    tmp, env = vm
    env["OMACVM_HYPRCTL"] = str(tmp / "nothing-here")
    shell = (tmp / "current" / "theme" / "shell.toml")
    shell.write_text(shell.read_text().replace('active-border            = "#7aa2f7"', 'active-border            = "rgb(dcd7ba)"'))
    assert printed(env)["border"] == ["#dcd7ba"]


def test_hyprland_colour_forms(vm):
    tmp, env = vm
    env["OMACVM_HYPRCTL"] = str(tmp / "nothing-here")
    shell = (tmp / "current" / "theme" / "shell.toml")
    text = shell.read_text()
    for value, want, angle in [('0xee33ccff 0xee00ff99 45deg', ["#33ccff", "#00ff99"], 45.0),
                               ('rgba(51, 204, 255, 0.9) rgb(0,255,153) 90deg', ["#33ccff", "#00ff99"], 90.0),
                               ('rgba(33ccffee) rgba(ff0000ee) rgba(00ff99ee) 30deg', ["#33ccff", "#00ff99"], 30.0)]:
        shell.write_text(text.replace('border           = "hyprland.active-border"\nborder-error',
                                      f'border           = "{value}"\nborder-error'))
        t = printed(env)
        assert (t["border"], t["border_angle"]) == (want, angle), value
    shell.write_text(text.replace('border           = "hyprland.active-border"\nborder-error',
                                  'border           = "$myborder"\nborder-error'))
    assert printed(env)["border"] == ["#7aa2f7"], "a variable it cannot read: Hyprland's token"


def test_a_switch_is_sent_once_its_files_settled(vm):
    tmp, env = vm
    env["OMACVM_TOUCHID_THEME_DELAY"] = "3"
    env["OMACVM_TOUCHID_THEME_RECHECK"] = "0"
    old = time.time() - 60
    for p in (tmp / "current" / "theme").iterdir():
        os.utime(p, (old, old))
    for d in (tmp / "current" / "theme", tmp / "current"):
        os.utime(d, (old, old))
    t0 = time.monotonic()
    run(env, "--force")   # nothing to send to (no Mac here): the wait is what counts
    assert time.monotonic() - t0 < 0.6, "settled files: no wait (a login sends at once)"
    (tmp / "current" / "theme" / "colors.toml").write_text((tmp / "current" / "theme" / "colors.toml").read_text())
    t0 = time.monotonic()
    run(env, "--force")
    took = time.monotonic() - t0
    assert 0.7 <= took < 2.5, f"files just written: waits until they are quiet ({took:.2f} s)"


def test_no_theme_sends_nothing(vm):
    tmp, env = vm
    env["OMACVM_TOUCHID_THEME_DIR"] = str(tmp / "none")
    r = run(env, "--print")
    assert r.returncode == 0 and r.stdout == "" and "no Omarchy theme" in r.stderr


@pytest.fixture
def mac(vm):
    tmp, env = vm
    m = FakeMac()
    env.update(vm_env(str(tmp), m.port, "/nonexistent"))
    os.symlink(os.path.join(SRC, "control"), os.path.join(env["OMACVM_SHARE"], "control"))
    yield m, env, tmp
    m.stop()


def test_sent_signed_once_per_change(mac):
    m, env, tmp = mac
    r = run(env)
    assert r.returncode == 0 and "-> the Mac" in r.stdout, r.stderr
    assert [q for q in m.requests if q[1] == "/omacvm/theme"] == [("POST", "/omacvm/theme", TOKYO)]
    assert ("/omacvm/theme", True) in m.signed
    run(env)
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 1, "unchanged: not sent again"
    run(env, "--force")
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 2
    (tmp / "rounding").write_text('{"int": 4}')
    run(env)
    assert m.requests[-1][2]["radius"] == 4, "a change goes out"
    (tmp / "boot_id").write_text("boot-2\n")
    run(env)
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 4, "a new boot (login) sends it again"
    run(env)
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 4
    (tmp / "sent").unlink()   # touchid.sh on/off clears the record
    run(env)
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 5, "Touch ID switched on again: sent again"


def test_a_second_look_after_hyprland_reloads(mac):
    m, env, tmp = mac
    env["OMACVM_TOUCHID_THEME_DELAY"] = "1"
    env["OMACVM_TOUCHID_THEME_RECHECK"] = "0.4"
    # Hyprland answers with the old rounding first, the new one once it reloaded.
    (tmp / "rounding").write_text('{"int": 0}')
    hypr = tmp / "hyprctl"
    hypr.write_text('#!/bin/sh\nd="$(dirname "$0")"\ncase "$3" in\n'
                    '  decoration:rounding) n=$(cat "$d/n" 2>/dev/null || echo 0); echo $((n + 1)) > "$d/n"\n'
                    '    if [ "$n" -ge 1 ]; then echo \'{"int": 8}\'; else cat "$d/rounding"; fi ;;\n'
                    '  general:col.active_border) cat "$d/border" ;;\nesac\n')
    r = run(env)
    assert r.returncode == 0, r.stderr
    sent = [q[2] for q in m.requests if q[1] == "/omacvm/theme"]
    assert [t["radius"] for t in sent] == [0, 8], "the reloaded rounding goes out on the second look"
    run(env)
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 2, "nothing changed: nothing sent"


def test_refused_is_tried_again_next_time(mac):
    m, env, tmp = mac
    m.refuse_theme = (403, "off", "Touch ID is off for this VM")
    r = run(env)
    assert r.returncode == 0 and "not sent" in r.stderr and not (tmp / "sent").exists()
    m.refuse_theme = None
    run(env)
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 2
