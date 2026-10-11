#!/bin/bash
# Local source/unit checks only; no app, settings, helper or VM is launched.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-menu-warning.XXXXXX")
trap 'rm -rf "$T"' EXIT
swiftc -warnings-as-errors -swift-version 5 -parse-as-library -module-cache-path "$T/modules" \
  "$R/app/app/Sources/OmacVMFeatures/NotchArea.swift" \
  "$R/app/app/Sources/OmacVM/FullPanelMenuWarning.swift" \
  "$R/src/tests/fullpanel-menu-warning/main.swift" -o "$T/test"
"$T/test"
# NSArgumentDomain belongs to this test process only. These string values
# exercise Foundation's real search order/conversion without writing defaults.
[[ $("$T/test" --preference-probe -AppleMenuBarVisibleInFullscreen YES) == true ]]
[[ $("$T/test" --preference-probe -AppleMenuBarVisibleInFullscreen NO) == false ]]
[[ $("$T/test" --preference-probe -AppleMenuBarVisibleInFullscreen 1) == true ]]
[[ $("$T/test" --preference-probe -AppleMenuBarVisibleInFullscreen 0) == false ]]
echo "fullpanel-menu-warning: 4 NSUserDefaults lookup/conversion probes passed"
python3 - "$R" <<'CHECK'
from pathlib import Path
import sys
r = Path(sys.argv[1])
main = (r/'app/app/Sources/OmacVM/main.swift').read_text()
runner = (r/'app/app/Sources/OmacVM/Runner.swift').read_text()
helper = (r/'app/app/Sources/OmacVM/FullPanelMenuWarning.swift').read_text()
start = main[main.index('    private func startVM('):main.index('    /// Before a start')]
# Existing safety checks run first; warning precedes network, disk changes and Runner.
markers = ['state.screen == .building', 'state.storage.moving != nil', 'state.config.filesProblem',
           'Paths.startProblem', 'VMOpen.qemuRuns', 'fullPanelMenuWarning.intercept(',
           'RunMarker.confirmStart', 'askFastNetwork {', 'VMDisk.cutIfDue', 'let r = Runner(', 'try r.start()']
indices = [start.index(m) for m in markers]
assert indices == sorted(indices), 'startup safety/prompt ordering changed'
assert 'VMConfig.load(from: folder)' in start and 'self.state.config = config' in start
assert 'self.state.screen != .building' in start and 'self.runner == nil' in start
assert 'applicationDidBecomeActive' in main and 'fullPanelMenuWarning.reactivated()' in main
assert 'r.withoutNotchOnce = withoutNotch' in start
assert sum('withoutNotch: withoutNotch' in line and 'startVM(' in line for line in start.splitlines()) == 4, 'network/graphics/disk retries lose override'
assert 'fullPanelMenuWarning.cancel()' in main[main.index('func applicationShouldTerminate'):main.index('func applicationShouldHandleReopen')]
assert 'if notchStart.fullPanel || withoutNotchOnce { links.omanotch = false }' in runner
assert '(Settings.startFullScreen || withoutNotchOnce) ? "on" : "off"' in runner
assert 'let notchPlan = Self.notchPlan(folder: c.folder, withoutNotch: withoutNotchOnce)' in runner
assert 'wantsFullPanel: Runner.notchPlan(folder: folder, withoutNotch: withoutNotch).start.fullPanel' in start
plan = runner[runner.index('    static func notchPlan('):runner.index('    /// What of the Mac this start')]
assert 'NotchArea.start(mode: NotchArea.read(folder: folder)' in plan
assert 'NotchArea.guestReady(folder: folder' in plan and 'withoutNotch: withoutNotch)' in plan
assert 'TestHooks.value("OMACVM_TEST_NOTCH_GEOMETRY"' in plan
assert '?? Mac.notchGeometry' in plan and 'fullScreen: Settings.startFullScreen' in plan
assert runner.count('NotchArea.start(') == 1 and 'NotchArea.start(' not in start
assert 'if !withoutNotchOnce {\n            a += ["-smbios", "type=11,value=omacvm.notchpointer=1"]' in runner
assert 'if notchStart.fullPanel, let g = notchGeometry' in runner
assert 'else { env.removeValue(forKey: "OMACVM_FULLPANEL") }' in runner
for forbidden in ('NotchArea.write', 'setVolatileDomain', 'CFPreferencesSet', 'Timer(', 'asyncAfter', 'defaults write'):
    assert forbidden not in helper + start, forbidden
assert 'defaults.bool(forKey: preference)' in helper
assert 'UserDefaults = .standard' in helper
assert 'CFPreferences' not in helper and 'synchronize(' not in helper
qemu = (r/'app/runtime/patches/omacvm-cocoa-fullpanel.patch').read_text()
assert '[[NSUserDefaults standardUserDefaults]' in qemu
assert 'boolForKey:@"AppleMenuBarVisibleInFullscreen"' in qemu
assert 'static let preference = "AppleMenuBarVisibleInFullscreen"' in helper
failure = helper[helper.index('            if !settings() {'):helper.index('        default:')]
assert failure.index('cancel()') < failure.index('settingsFailed()')
print('fullpanel-menu-warning: startup and Runner wiring checks passed')
CHECK
