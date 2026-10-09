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

# Opt-in, read-only tracing of the accepted-frame/shrink sequence.
need 'OMACVM_FULLPANEL_DIAGNOSTIC'
need 'omacvm: FULLPANEL DIAG t='
need 'NSWorkspaceActiveSpaceDidChangeNotification'
need 'SET FRAME guard bypass'
need 'SET FRAME result'
need 'CONSTRAIN result'
need 'GEOMETRY protected'
need 'FULLPANEL refresh'
need 'FULLPANEL compositor pending'
need 'FULLPANEL return timeout'
need 'FULLPANEL COMPOSITOR t='
need 'WS_FRAME_DIFFERS='
need 'viewVisibleRect='
need 'refresh completed'
need 'scheduleFullPanelRefresh:@"window became key"'
need 'scheduleFullPanelRefresh:@"window became visible"'
need 'scheduleFullPanelRefresh:@"active Space changed"'
need 'RESIZE delegate observed'
need 'PRESENTATION observed'
need 'MENU ALPHA request'
need 'MENU ALPHA transaction creation failed'
need 'MENU ALPHA commit result'
need 'reason=applyMenuBarReveal'
need 'reason=showMenuBar'
need 'AREA LOST transition'
need 'observer stack does not establish cause'

# Separate read-only trace for Mission Control top-strip flicker.
need 'OMACVM_FULLPANEL_FLICKER_TRACE'
need 'FULLPANEL FLICKER t='
need 'compositor ready before restore'
need 'compositor ready after restore'
need 'toolbar reveal setter before AppKit'
need 'toolbar reveal setter after AppKit'
need 'toolbar hide before'
need 'toolbar hide after'
need 'presentation setter before'
need 'presentation setter after'
need 'menu alpha before commit'
need 'menu alpha after commit'
need 'presentationLayer'
need 'targetRank='
need 'topSurfaces='
need 'transitionOverlays='
need 'FULLPANEL OVERLAY t='
need '_NSFullScreenTransitionOverlayWindow'
need 'ownerPID='
need 'localClass='
need 'unavailable(foreign)'
need 'contentsPointer='
need 'transition overlay will close observed'
need 'metadata observations do not prove pixel colour or causality'
need 'OMACVM_FULLPANEL_HANDOFF_TRACE'
need 'FULLPANEL HANDOFF departure'
need 'FULLPANEL HANDOFF begin'
need 'FULLPANEL HANDOFF sample'
need 'FULLPANEL HANDOFF end'
need 'aboveStripCount='
need 'queryMs='
need 'maxGapMs='
need 'restoreCount='
need 'sampling ended, not an animation-complete event'

# Reversible presentation-only A/B; menu-alpha recovery remains independent.
need 'OMACVM_FULLPANEL_PASSIVE_PRESENTATION'
need 'PRESENTATION AB armed'
need 'PRESENTATION AB skipped'
need 'PRESENTATION decision'
need 'restore saved presentation'
need 'savedPresentation='
need '[self notePresentationSpaceDeparture]'
need 'OMACVM_FULLPANEL_V2_RETURN'
need 'FULLPANEL V2 RETURN enabled'
need 'V2 RETURN armed'
need 'V2 RETURN reassert'
need 'V2 RETURN finished'
need '150 * NSEC_PER_MSEC'
need '600 * NSEC_PER_MSEC'
need 'NSApplicationDidBecomeActiveNotification'
need 'NSApplicationDidChangeScreenParametersNotification'
need 'OMACVM_FULLPANEL_V2_TOOLBAR_HANDOFF'
need 'FULLPANEL V2 TOOLBAR HANDOFF enabled'
need 'V2 TOOLBAR HANDOFF armed'
need 'V2 TOOLBAR HANDOFF AppKit owns toolbar'
need 'v2_toolbar_handoff_space == menu_bar_hidden_space'
need '[self noteV2ToolbarHandoffDeparture]'
need 'OMACVM_FULLPANEL_V2_PARITY'
need 'FULLPANEL V2 PARITY enabled'
need 'V2 PARITY bypass automatic refresh'
need 'passive automatic-return bypass, no restoration driver'
need 'return true; /* Also cancel a queued pre-entry compositor refresh. */'
for removed in v2ParityNotification reassertV2Parity releaseV2ParityToolbar v2_parity_generation; do
  if grep -qF "$removed" "$f"; then
    echo "camera-housing test: active parity logic remains: $removed" >&2
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
