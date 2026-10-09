#!/bin/bash
set -euo pipefail
f=${1:?usage: test-camera-housing-fullscreen.sh ui/cocoa.m}

need() {
  grep -qF "$1" "$f" || { echo "camera-housing test: missing: $1" >&2; exit 1; }
}

need 'OmacVM: UTM-style camera-housing fullscreen'
need 'OMACVM_CAMERA_HOUSING'
need 'omacvm_camera_window_usable'
need '_frameForFullScreenMode'
need '_tileFrameForFullScreen'
need 'SLSCopySpacesForWindows'
need 'SLSSpaceGetType'
need 'SLSTransactionSetMenuBarSystemOverrideAlpha'
need '_NSFullScreenMenuBarCompanionController'
need 'setMenuBarReveal:'
need 'setToolbarWindowReveal:'
need 'NSToolbarFullScreenWindow'
need 'AppleMenuBarVisibleInFullscreen'
need 'NSWindowDidChangeOcclusionStateNotification'
need 'omacvm_camera_prepare_window(self)'
need 'below_notch && !omacvm_camera_window_usable([cocoaView window])'
need '        full = isFullscreen && omacvm_present_layer() &&'
need '               [[[self window] screen] safeAreaInsets].top > 0;'


# Full-panel retention regression: protect both AppKit frame mutation paths.
need 'full_panel_frame_accepted = true'
need 'full_panel_frame_accepted = false'
need 'omacvm: full panel: AREA LOST'
need 'omacvm: full panel: protected accepted frame'
count=$(grep -Fc -- '- (void)setFrame:(NSRect)frameRect display:(BOOL)flag animate:(BOOL)animate' "$f")
if [[ $count -ne 2 ]]; then
  echo "camera-housing test: missing animated setFrame guards: $count" >&2
  exit 1
fi

# Verify safe-tile re-query handling is deliberately narrow and gated.
need 'bool exact_safe_tile = full_panel_frame_accepted'
need 'fabs(tile.size.height - (screen_frame.size.height - notch)) < 0.5'
need 'if (!full_tile && !exact_safe_tile)'
need 'FRAME HOOK kept physical frame over safe tile'
need 'FRAME HOOK rejected tile='

# Default restoration remains active and bounded; no experiment switches.
need 'NSWorkspaceActiveSpaceDidChangeNotification'
need 'omacvm_fullpanel_compositor_ready'
need 'return compositor < 0; /* missing evidence: stop, do not force */'
need 'scheduleFullPanelRefresh:@"window became key"'
need 'scheduleFullPanelRefresh:@"window became visible"'
need 'scheduleFullPanelRefresh:@"active Space changed"'
need 'checksLeft:240'
need 'omacvm_camera_fullscreen_space_id(window) != menu_bar_hidden_space'
for removed in OMACVM_FULLPANEL_DIAGNOSTIC OMACVM_FULLPANEL_FLICKER_TRACE \
  OMACVM_FULLPANEL_HANDOFF_TRACE OMACVM_FULLPANEL_V2_PARITY \
  OMACVM_FULLPANEL_EARLY_HIDE OMACVM_FULLPANEL_PASSIVE_PRESENTATION \
  OMACVM_FULLPANEL_V2_RETURN OMACVM_FULLPANEL_V2_TOOLBAR_HANDOFF \
  v2ParityManaged v2ToolbarHandoffActive noteV2ReturnDeparture \
  noteHandoffDeparture sampleHandoffTrace FP_DIAG; do
  if grep -qF "$removed" "$f"; then
    echo "camera-housing test: abandoned experiment remains: $removed" >&2
    exit 1
  fi
done

echo "camera-housing fullscreen source checks: PASS"

# UTM toolbar late-window check
# UTM reapplies the toolbar view state when AppKit creates/reveals the
# NSToolbarFullScreenWindow later; an equality early-return would miss it.
if grep -A5 -F -- '- (void)setToolbarHidden:(bool)hidden' "$f" |
   grep -q 'toolbar_hidden == hidden'; then
  echo "camera-housing test: toolbar late-window behavior was short-circuited" >&2
  exit 1
fi
