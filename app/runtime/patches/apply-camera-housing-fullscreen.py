#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-camera-housing-fullscreen.py PATH/TO/ui/cocoa.m")

path = Path(sys.argv[1])
s = path.read_text()
MARK = "OmacVM: UTM-style camera-housing fullscreen"
if MARK in s:
    print("camera-housing fullscreen already applied")
    raise SystemExit(0)

def replace_once(old, new, label):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {n}")
    s = s.replace(old, new, 1)

if "#include <objc/runtime.h>" not in s:
    replace_once('#include <Carbon/Carbon.h>\n',
                 '#include <Carbon/Carbon.h>\n#include <objc/runtime.h>\n',
                 "objc runtime include")

replace_once(
    'static CGFloat omacvm_main_full_top = -1;\n',
    r'''static CGFloat omacvm_main_full_top = -1;

/* OmacVM: UTM-style camera-housing fullscreen, defined below. */
static bool omacvm_camera_housing_requested(void);
static bool omacvm_camera_window_usable(NSWindow *window);
static bool omacvm_fullpanel_diagnostic_enabled(void);
static void omacvm_fullpanel_diagnostic(NSWindow *window, const char *event,
                                       NSString *detail, bool stack);
static void omacvm_fullpanel_flicker_trace(NSWindow *window, const char *event);
#define FP_DIAG(w, event, stack, ...) do { \
    if (omacvm_fullpanel_diagnostic_enabled()) { \
        omacvm_fullpanel_diagnostic(w, event, \
            [NSString stringWithFormat:__VA_ARGS__], stack); \
    } \
} while (0)
''',
    "camera-housing forward declaration"
)

replace_once(
    '''- (NSSize) screenSafeAreaSize
{
    NSSize size = [[[self window] screen] frame].size;
    NSEdgeInsets insets = [[[self window] screen] safeAreaInsets];
''',
    '''- (NSSize) screenSafeAreaSize
{
    NSSize size = [[[self window] screen] frame].size;
    if (omacvm_camera_window_usable([self window])) {
        return size;
    }
    NSEdgeInsets insets = [[[self window] screen] safeAreaInsets];
''',
    "screenSafeAreaSize"
)

replace_once(
    '''- (NSSize)window:(NSWindow *)window willUseFullScreenContentSize:(NSSize)proposedSize
{
    NSSize display = [[window screen] frame].size;
''',
    '''- (NSSize)window:(NSWindow *)window willUseFullScreenContentSize:(NSSize)proposedSize
{
    FP_DIAG(window, "CONTENT SIZE hook enter", true,
            @"proposed=%@", NSStringFromSize(proposedSize));
    if (omacvm_camera_window_usable(window) && [window screen] &&
        [[window screen] safeAreaInsets].top > 0) {
        proposedSize = [[window screen] frame].size;
    }
    FP_DIAG(window, "CONTENT SIZE hook result", false,
            @"result=%@", NSStringFromSize(proposedSize));
    NSSize display = [[window screen] frame].size;
''',
    "willUseFullScreenContentSize"
)

replace_once(
    '''    if (below_notch) {
        NSEdgeInsets in = [s safeAreaInsets];
''',
    '''    if (below_notch && !omacvm_camera_window_usable([cocoaView window])) {
        NSEdgeInsets in = [s safeAreaInsets];
''',
    "multi-display safe-area box"
)

helper = r'''
/*
 * ---------------------------------------------------------------------------
 * OmacVM: UTM-style camera-housing fullscreen
 * ---------------------------------------------------------------------------
 *
 * Architecture and lifecycle are based on UTM's camera-housing fullscreen
 * work by Turing Software, LLC:
 *
 *   UTM PR #7885
 *   UTM PR #7910 ("fill the area beside the camera housing on macOS 12+")
 *   Platform/macOS/Display/VMDisplayWindow.swift
 *
 * UTM's implementation is Apache-2.0. This is an independent Objective-C
 * implementation for QEMU's MIT-licensed Cocoa driver; it follows the same
 * state machine and private-API safety model rather than copying the Swift
 * source.
 *
 * AppKit normally prevents a native-fullscreen window from using the strip
 * beside a MacBook camera housing in two independent ways:
 *
 *   1. it proposes a fullscreen frame below the camera housing;
 *   2. WindowServer covers that strip with the fullscreen Space's menu bar.
 *
 * When OMACVM_CAMERA_HOUSING=1, this code:
 *
 *   - keeps QEMU itself as the genuine native-fullscreen window/Space owner;
 *   - replaces AppKit's private fullscreen-frame answer with NSScreen.frame
 *     only when the window has the display to itself;
 *   - keeps that accepted frame for the lifetime of the fullscreen Space;
 *   - makes only that type-4 fullscreen Space's menu-bar layer transparent;
 *   - observes AppKit's fullscreen menu-bar companion so reveal at the true
 *     top edge still works;
 *   - hides AppKit's fullscreen toolbar window while the menu bar is hidden;
 *   - falls back to completely normal AppKit fullscreen if any private class,
 *     selector, function or expected Objective-C type encoding is missing.
 *
 * No window is moved between Spaces and no helper/token window owns the Space.
 * All private APIs are resolved at runtime.
 */

static bool omacvm_camera_housing_requested(void)
{
    const char *v = getenv("OMACVM_CAMERA_HOUSING");
    return v && !strcmp(v, "1");
}

static bool omacvm_camera_rect_equal(NSRect a, NSRect b)
{
    return fabs(a.origin.x - b.origin.x) < 0.5 &&
           fabs(a.origin.y - b.origin.y) < 0.5 &&
           fabs(a.size.width - b.size.width) < 0.5 &&
           fabs(a.size.height - b.size.height) < 0.5;
}

typedef NSRect (*OmacVMCameraFrameFn)(id, SEL);
static SEL omacvm_camera_frame_selector;
static SEL omacvm_camera_tile_selector;
static OmacVMCameraFrameFn omacvm_camera_appkit_frame;
static OmacVMCameraFrameFn omacvm_camera_tile_frame;
static const char *omacvm_camera_frame_types;
static Class omacvm_camera_hooked_classes[8];
static int omacvm_camera_hooked_count;

typedef int32_t (*OmacVMSLSMainConnectionIDFn)(void);
typedef CFArrayRef (*OmacVMSLSCopySpacesForWindowsFn)(int32_t, int32_t, CFArrayRef);
typedef int32_t (*OmacVMSLSSpaceGetTypeFn)(int32_t, uint64_t);
typedef CFTypeRef (*OmacVMSLSTransactionCreateFn)(int32_t);
typedef void (*OmacVMSLSTransactionSetMenuBarAlphaFn)(CFTypeRef, uint64_t, float);
/* UTM VMDisplayWindow.swift and yabai src/misc/extern.h agree on the ABI:
 * commit returns Int32/CGError; the second argument is synchronous, not flags.
 * These are private declarations, not an Apple-supported ABI guarantee.
 */
typedef int32_t (*OmacVMSLSTransactionCommitFn)(CFTypeRef, int32_t);

static void *omacvm_camera_skylight;
static int omacvm_camera_skylight_state;
static OmacVMSLSMainConnectionIDFn omacvm_camera_sls_main;
static OmacVMSLSCopySpacesForWindowsFn omacvm_camera_sls_spaces;
static OmacVMSLSSpaceGetTypeFn omacvm_camera_sls_space_type;
static OmacVMSLSTransactionCreateFn omacvm_camera_sls_transaction_create;
static OmacVMSLSTransactionSetMenuBarAlphaFn omacvm_camera_sls_menu_alpha;
static OmacVMSLSTransactionCommitFn omacvm_camera_sls_transaction_commit;

@class OmacVMCameraHousingState;
static char omacvm_camera_state_key;
static int omacvm_camera_reveal_state;

static OmacVMCameraHousingState *omacvm_camera_state(NSWindow *window)
{
    return window ? objc_getAssociatedObject(window, &omacvm_camera_state_key) : nil;
}

static bool omacvm_camera_load_skylight(void)
{
    if (omacvm_camera_skylight_state) {
        return omacvm_camera_skylight_state > 0;
    }
    omacvm_camera_skylight_state = -1;
    omacvm_camera_skylight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY | RTLD_LOCAL);
    if (!omacvm_camera_skylight) {
        fprintf(stderr, "omacvm: full panel: SkyLight is unavailable; using normal full screen\n");
        return false;
    }

#define OMACVM_CAMERA_SYM(dst, type, name) \
    dst = (type)dlsym(omacvm_camera_skylight, name)
    OMACVM_CAMERA_SYM(omacvm_camera_sls_main,
                      OmacVMSLSMainConnectionIDFn, "SLSMainConnectionID");
    OMACVM_CAMERA_SYM(omacvm_camera_sls_spaces,
                      OmacVMSLSCopySpacesForWindowsFn, "SLSCopySpacesForWindows");
    OMACVM_CAMERA_SYM(omacvm_camera_sls_space_type,
                      OmacVMSLSSpaceGetTypeFn, "SLSSpaceGetType");
    OMACVM_CAMERA_SYM(omacvm_camera_sls_transaction_create,
                      OmacVMSLSTransactionCreateFn, "SLSTransactionCreate");
    OMACVM_CAMERA_SYM(omacvm_camera_sls_menu_alpha,
                      OmacVMSLSTransactionSetMenuBarAlphaFn,
                      "SLSTransactionSetMenuBarSystemOverrideAlpha");
    OMACVM_CAMERA_SYM(omacvm_camera_sls_transaction_commit,
                      OmacVMSLSTransactionCommitFn, "SLSTransactionCommit");
#undef OMACVM_CAMERA_SYM

    if (!omacvm_camera_sls_main || !omacvm_camera_sls_spaces ||
        !omacvm_camera_sls_space_type || !omacvm_camera_sls_transaction_create ||
        !omacvm_camera_sls_menu_alpha || !omacvm_camera_sls_transaction_commit) {
        fprintf(stderr, "omacvm: full panel: SkyLight is missing a required symbol; using normal full screen\n");
        return false;
    }
    omacvm_camera_skylight_state = 1;
    return true;
}

static uint64_t omacvm_camera_space_id(NSWindow *window)
{
    if (!window || !omacvm_camera_load_skylight()) {
        return 0;
    }
    int32_t cid = omacvm_camera_sls_main();
    NSNumber *number = [NSNumber numberWithInteger:[window windowNumber]];
    CFArrayRef windows = (CFArrayRef)[NSArray arrayWithObject:number];
    CFArrayRef spaces = omacvm_camera_sls_spaces(cid, 7, windows);
    if (!spaces) {
        return 0;
    }

    uint64_t space = 0;
    if (CFArrayGetCount(spaces) == 1) {
        CFTypeRef value = CFArrayGetValueAtIndex(spaces, 0);
        if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &space);
        }
    }
    CFRelease(spaces);
    return space;
}

static uint64_t omacvm_camera_fullscreen_space_id(NSWindow *window)
{
    uint64_t space = omacvm_camera_space_id(window);
    if (!space) {
        return 0;
    }
    return omacvm_camera_sls_space_type(omacvm_camera_sls_main(), space) == 4 ?
           space : 0;
}

static void omacvm_camera_set_menu_alpha(NSWindow *window, uint64_t space,
                                         float alpha, const char *reason)
{
    FP_DIAG(window, "MENU ALPHA request", true,
            @"space=%llu alpha=%.3f reason=%s",
            (unsigned long long)space, alpha, reason);
    if (!space || !omacvm_camera_load_skylight()) {
        FP_DIAG(window, "MENU ALPHA skipped", false,
                @"space=%llu alpha=%.3f reason=%s failure=%@",
                (unsigned long long)space, alpha, reason,
                space ? @"SkyLight unavailable" : @"no target Space");
        return;
    }
    CFTypeRef transaction = omacvm_camera_sls_transaction_create(
        omacvm_camera_sls_main());
    if (!transaction) {
        FP_DIAG(window, "MENU ALPHA transaction creation failed", false,
                @"space=%llu alpha=%.3f reason=%s transaction=NULL",
                (unsigned long long)space, alpha, reason);
        return;
    }
    FP_DIAG(window, "MENU ALPHA transaction created", false,
            @"space=%llu alpha=%.3f reason=%s transaction=%p",
            (unsigned long long)space, alpha, reason, (void *)transaction);
    omacvm_camera_sls_menu_alpha(transaction, space, alpha);
    omacvm_fullpanel_flicker_trace(window, "menu alpha before commit");
    int32_t result = omacvm_camera_sls_transaction_commit(transaction, 1);
    omacvm_fullpanel_flicker_trace(window, "menu alpha after commit");
    FP_DIAG(window, "MENU ALPHA commit result", false,
            @"space=%llu alpha=%.3f reason=%s transaction=%p synchronous=1 returnCode=%d; observed result, not evidence of resize cause",
            (unsigned long long)space, alpha, reason, (void *)transaction,
            (int)result);
    CFRelease(transaction);
}

static Method omacvm_camera_private_method(const char *class_name,
                                           const char *selector_name,
                                           const char *expected_types)
{
    Class cls = NSClassFromString([NSString stringWithUTF8String:class_name]);
    if (!cls) {
        return NULL;
    }
    SEL selector = NSSelectorFromString(
        [NSString stringWithUTF8String:selector_name]);
    Method method = class_getInstanceMethod(cls, selector);
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    if (!method || !types || strcmp(types, expected_types)) {
        fprintf(stderr, "omacvm: full panel: cannot use -[%s %s]; using normal full screen\n",
                class_name, selector_name);
        return NULL;
    }
    return method;
}

typedef void (*OmacVMCameraSetRevealFn)(id, SEL, double);
typedef double (*OmacVMCameraGetRevealFn)(id, SEL);
typedef id (*OmacVMCameraGetObjectFn)(id, SEL);

@interface OmacVMCameraHousingState : NSObject
{
    NSWindow *window;
    bool full_screen_frame_kept;
    // Armed only after our frame hook has accepted the entire display.
    bool full_panel_frame_accepted;
    bool full_panel_safe_tile_requery_logged;
    bool full_panel_frame_reject_logged;
    bool in_full_screen_space;
    bool camera_housing_area_lost;
    uint64_t menu_bar_hidden_space;
    NSApplicationPresentationOptions revealable_presentation;
    bool revealable_presentation_valid;
    bool menu_bar_revealed;
    bool toolbar_revealed;
    bool menu_bar_reveal_allowed;
    bool presentation_forced;
    bool presentation_observing;
    id top_edge_monitor;
    bool toolbar_hidden;
    uint64_t v2_toolbar_handoff_space;
    bool v2_parity_established;
    bool workspace_observing;
    bool full_panel_refresh_pending;
    bool full_panel_compositor_wait_logged;
    bool full_panel_early_hide_sent;
    bool full_panel_presentation_ab_armed;
    bool full_panel_v2_return_armed;
    unsigned full_panel_v2_return_generation;
    unsigned full_panel_v2_return_batches;
    bool full_panel_handoff_departed;
    bool full_panel_handoff_sampling;
    unsigned full_panel_handoff_generation;
    NSString *full_panel_handoff_last_sample;
    double full_panel_handoff_last_uptime;
    double full_panel_handoff_max_gap;
    unsigned full_panel_handoff_samples;
    unsigned full_panel_handoff_restores;
}
- (id)initWithWindow:(NSWindow *)w;
- (bool)usable;
- (NSRect)fullScreenFrameForAppKitFrame:(NSRect)frame;
- (bool)keepSetFrame:(NSRect)proposed display:(bool)display;
- (void)menuRevealChanged:(bool)menu toolbar:(bool)toolbar;
- (NSString *)diagnosticSummary;
- (void)activeSpaceChanged:(NSNotification *)notification;
- (void)scheduleFullPanelRefresh:(NSString *)reason;
- (bool)refreshFullPanelForReason:(NSString *)reason;
- (void)finishFullPanelReturn:(NSString *)reason checksLeft:(unsigned)checks;
- (void)notePresentationSpaceDeparture;
- (bool)skipPresentationReassertForAB;
- (void)traceTransitionOverlayClose:(NSNotification *)notification;
- (void)noteV2ReturnDeparture;
- (bool)v2ReturnEligible;
- (void)v2ReturnNotification:(NSNotification *)notification;
- (void)reassertV2Return:(NSString *)reason;
- (void)noteV2ToolbarHandoffDeparture;
- (bool)v2ToolbarHandoffActive;
- (bool)v2ParityManaged;
- (void)noteHandoffDeparture;
- (void)cancelHandoffTrace:(const char *)reason;
- (void)startHandoffTrace:(NSString *)reason;
- (void)sampleHandoffTrace:(unsigned)generation checksLeft:(unsigned)checks;
@end

/* Read-only instrumentation: never query private frame/Space APIs for logging.
 * Callback stacks identify the observer, not necessarily the resize initiator.
 * A setter's requested frame and post-super result are evidence of a mutation
 * path, not proof that the preceding notification caused it.
 */
static bool omacvm_fullpanel_diagnostic_enabled(void)
{
    const char *value = getenv("OMACVM_FULLPANEL_DIAGNOSTIC");
    return value && !strcmp(value, "1");
}

/* Passive return alternate path. Previous policy experiments are disabled
 * when selected; no v2 event driver or deferred reassertion is installed.
 */
static bool omacvm_fullpanel_v2_parity_enabled(void)
{
    const char *value = getenv("OMACVM_FULLPANEL_V2_PARITY");
    return omacvm_camera_housing_requested() && value && !strcmp(value, "1");
}

static bool omacvm_fullpanel_early_hide_enabled(void)
{
    const char *value = getenv("OMACVM_FULLPANEL_EARLY_HIDE");
    return !omacvm_fullpanel_v2_parity_enabled() && value && !strcmp(value, "1");
}

/* One-variable A/B: after leaving an established Full Panel Space, let
 * AppKit own automatic presentation transitions. Initial entry, explicit
 * menu reveal/cleanup and Space-specific alpha restoration stay unchanged.
 */
static bool omacvm_fullpanel_passive_presentation_enabled(void)
{
    const char *value = getenv("OMACVM_FULLPANEL_PASSIVE_PRESENTATION");
    return !omacvm_fullpanel_v2_parity_enabled() &&
        omacvm_camera_housing_requested() && value && !strcmp(value, "1");
}

/* Requested v2 return A/B. Entry is untouched: arm only after leaving an
 * established Full Panel Space. The existing compositor-ready recovery stays
 * authoritative; these are v2's additional event/150ms/600ms reassertions.
 */
static bool omacvm_fullpanel_v2_return_enabled(void)
{
    const char *value = getenv("OMACVM_FULLPANEL_V2_RETURN");
    return !omacvm_fullpanel_v2_parity_enabled() &&
        omacvm_camera_housing_requested() && value && !strcmp(value, "1");
}

/* Isolate original v2's AppKit-owned toolbar coverage on return. Unlike the
 * earlier V2_RETURN experiment this adds no alpha/presentation reassertions
 * or timers. Initial entry retains our toolbar hiding; after an established
 * Space departure, leave this app's toolbar views to AppKit until cleanup.
 */
static bool omacvm_fullpanel_v2_toolbar_handoff_enabled(void)
{
    const char *value = getenv("OMACVM_FULLPANEL_V2_TOOLBAR_HANDOFF");
    return !omacvm_fullpanel_v2_parity_enabled() &&
        omacvm_camera_housing_requested() && value && !strcmp(value, "1");
}

/* Separate opt-in because additional WindowServer/layer observations can
 * perturb a very short transition. Never capture pixels or window titles.
 * No timers, redraws or changes to the fullscreen state machine. The only
 * additional observer is an opt-in, read-only transition-overlay close probe.
 */
static bool omacvm_fullpanel_flicker_trace_enabled(void)
{
    const char *value = getenv("OMACVM_FULLPANEL_FLICKER_TRACE");
    return omacvm_camera_housing_requested() && value && !strcmp(value, "1");
}

/* Bounded, read-only sampling beyond the existing geometry-ready callback.
 * Separate from the verbose layer trace; never use this to gate restoration.
 */
static bool omacvm_fullpanel_handoff_trace_enabled(void)
{
    const char *value = getenv("OMACVM_FULLPANEL_HANDOFF_TRACE");
    return omacvm_camera_housing_requested() && value && !strcmp(value, "1");
}

static NSString *omacvm_fullpanel_layer_trace(CALayer *layer)
{
    if (!layer) {
        return @"none";
    }
    CALayer *present = [layer presentationLayer];
    NSColor *background = [layer backgroundColor] ?
        [[NSColor colorWithCGColor:[layer backgroundColor]]
            colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]] : nil;
    CATransform3D transform = present ? [present transform] : [layer transform];
    return [NSString stringWithFormat:
        @"layer=%p class=%@ model={frame=%@ bounds=%@ hidden=%d opacity=%.3f opaque=%d contents=%d contentsPointer=%p masks=%d background=%@} present={available=%d frame=%@ bounds=%@ hidden=%d opacity=%.3f contents=%d contentsPointer=%p transform=(%.3f %.3f %.3f %.3f)} animations=%@",
        (void *)layer, NSStringFromClass([layer class]),
        NSStringFromRect(NSRectFromCGRect([layer frame])),
        NSStringFromRect(NSRectFromCGRect([layer bounds])),
        [layer isHidden], [layer opacity], [layer isOpaque],
        [layer contents] != nil, (void *)[layer contents], [layer masksToBounds], background,
        present != nil, NSStringFromRect(NSRectFromCGRect([present frame])),
        NSStringFromRect(NSRectFromCGRect([present bounds])),
        [present isHidden], [present opacity], [present contents] != nil,
        (void *)[present contents],
        transform.m11, transform.m22, transform.m41, transform.m42,
        [layer animationKeys]];
}

static NSString *omacvm_fullpanel_window_trace(NSWindow *w)
{
    NSView *content = [w contentView];
    NSMutableArray *layers = [NSMutableArray array];
    /* Include ancestor clipping/opacity, not just QEMU's content layer. */
    CALayer *layer = [content layer];
    for (unsigned depth = 0; layer && depth < 6; depth++, layer = [layer superlayer]) {
        [layers addObject:omacvm_fullpanel_layer_trace(layer)];
    }
    return [NSString stringWithFormat:
        @"window=%p number=%ld class=%@ frame=%@ level=%ld orderedIndex=%ld visible=%d key=%d activeSpace=%d occlusion=%llu alpha=%.3f opaque=%d background=%@ view=%p hidden=%d ancestorHidden=%d superviewHidden=%d viewFrame=%@ viewBounds=%@ layers=%@",
        (void *)w, (long)[w windowNumber], NSStringFromClass([w class]),
        NSStringFromRect([w frame]), (long)[w level], (long)[w orderedIndex],
        [w isVisible], [w isKeyWindow], [w isOnActiveSpace],
        (unsigned long long)[w occlusionState], [w alphaValue], [w isOpaque],
        [w backgroundColor], (void *)content, [content isHidden],
        [content isHiddenOrHasHiddenAncestor], [[content superview] isHidden],
        NSStringFromRect([content frame]), NSStringFromRect([content bounds]),
        [layers componentsJoinedByString:@" | "]];
}

static bool omacvm_fullpanel_is_transition_overlay(NSWindow *w)
{
    return [NSStringFromClass([w class])
        isEqualToString:@"_NSFullScreenTransitionOverlayWindow"];
}

/* Public metadata identifies ownership, not a foreign ObjC window class or
 * displayed pixel colour. Numbers let separate snapshots track one surface.
 * Keep titles and image contents out of the trace.
 */
static NSString *omacvm_fullpanel_surface_trace(NSDictionary *entry,
    NSUInteger rank, NSInteger targetNumber, NSDictionary *localClasses)
{
    NSNumber *number = [entry objectForKey:(id)kCGWindowNumber];
    NSNumber *pid = [entry objectForKey:(id)kCGWindowOwnerPID];
    bool own = pid && [pid intValue] == [[NSProcessInfo processInfo] processIdentifier];
    NSString *owner = [entry objectForKey:(id)kCGWindowOwnerName];
    owner = [[owner componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    NSString *localClass = own && number ? [localClasses objectForKey:number] : nil;
    CGRect bounds = CGRectZero;
    CFDictionaryRef value = (CFDictionaryRef)[entry objectForKey:(id)kCGWindowBounds];
    if (value) {
        CGRectMakeWithDictionaryRepresentation(value, &bounds);
    }
    return [NSString stringWithFormat:
        @"rank=%lu target=%d own=%d number=%@ ownerPID=%@ owner=%@ localClass=%@ bounds=%@ layer=%@ alpha=%@ onscreen=%@",
        (unsigned long)rank, number && [number integerValue] == targetNumber, own,
        number, pid, owner ?: @"unavailable",
        localClass ?: (own ? @"unavailable(local)" : @"unavailable(foreign)"),
        NSStringFromRect(NSRectFromCGRect(bounds)),
        [entry objectForKey:(id)kCGWindowLayer],
        [entry objectForKey:(id)kCGWindowAlpha],
        [entry objectForKey:(id)kCGWindowIsOnscreen]];
}

static NSString *omacvm_fullpanel_handoff_window(NSWindow *w)
{
    CALayer *layer = [[w contentView] layer];
    CALayer *present = [layer presentationLayer];
    return [NSString stringWithFormat:
        @"number=%ld class=%@ frame=%@ visible=%d key=%d activeSpace=%d occlusion=%llu alpha=%.3f opaque=%d layer={available=%d hidden=%d opacity=%.3f contents=%d} present={available=%d hidden=%d opacity=%.3f contents=%d}",
        (long)[w windowNumber], NSStringFromClass([w class]), NSStringFromRect([w frame]),
        [w isVisible], [w isKeyWindow], [w isOnActiveSpace],
        (unsigned long long)[w occlusionState], [w alphaValue], [w isOpaque],
        layer != nil, [layer isHidden], [layer opacity], [layer contents] != nil,
        present != nil, [present isHidden], [present opacity], [present contents] != nil];
}

/* Include all above-target surfaces intersecting the notch strip, not only
 * 39pt windows or a guessed owner/layer. A missing target/list is explicit;
 * it must not be interpreted as a clear handoff. No titles/pixels are read.
 */
static NSString *omacvm_fullpanel_handoff_snapshot(NSWindow *w)
{
    NSScreen *screen = [w screen];
    NSScreen *primary = [[NSScreen screens] firstObject];
    if (!screen || !primary || [screen safeAreaInsets].top <= 0) {
        return @"wsAvailable=0 targetRank=-1 reason=notched display unavailable";
    }
    NSRect physical = [screen frame];
    CGRect strip = CGRectMake(physical.origin.x,
        NSMaxY([primary frame]) - NSMaxY(physical), physical.size.width,
        [screen safeAreaInsets].top);
    NSMutableDictionary *classes = [NSMutableDictionary dictionary];
    NSMutableArray *overlays = [NSMutableArray array];
    for (NSWindow *candidate in [NSApp windows]) {
        if ([candidate windowNumber] > 0) {
            [classes setObject:NSStringFromClass([candidate class])
                       forKey:@([candidate windowNumber])];
        }
        if (omacvm_fullpanel_is_transition_overlay(candidate) &&
            NSIntersectsRect([candidate frame], physical)) {
            [overlays addObject:omacvm_fullpanel_handoff_window(candidate)];
        }
    }
    CFArrayRef info = primary && screen ? CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID) : NULL;
    NSMutableArray *above = [NSMutableArray array];
    NSInteger targetRank = -1;
    NSString *target = @"absent";
    NSUInteger rank = 0, matches = 0;
    for (NSDictionary *entry in (NSArray *)info) {
        if ([[entry objectForKey:(id)kCGWindowNumber] integerValue] == [w windowNumber]) {
            targetRank = rank;
            target = omacvm_fullpanel_surface_trace(entry, rank, [w windowNumber], classes);
            break; /* Front-to-back: subsequent windows are below QEMU. */
        }
        CGRect bounds;
        CFDictionaryRef value = (CFDictionaryRef)[entry objectForKey:(id)kCGWindowBounds];
        if (value && CGRectMakeWithDictionaryRepresentation(value, &bounds) &&
            CGRectIntersectsRect(bounds, strip)) {
            matches++;
            if ([above count] < 32) {
                [above addObject:omacvm_fullpanel_surface_trace(entry, rank,
                    [w windowNumber], classes)];
            }
        }
        rank++;
    }
    NSString *snapshot = [NSString stringWithFormat:
        @"presentation=%llu systemPresentation=%llu target={%@} wsAvailable=%d targetRank=%ld targetWS={%@} aboveStripCount=%lu truncated=%d aboveStrip={%@} transitionOverlays={%@}",
        (unsigned long long)[NSApp presentationOptions],
        (unsigned long long)[NSApp currentSystemPresentationOptions],
        omacvm_fullpanel_handoff_window(w), info != NULL, (long)targetRank, target,
        (unsigned long)matches, matches > 32, [above componentsJoinedByString:@" | "],
        [overlays componentsJoinedByString:@" | "]];
    if (info) {
        CFRelease(info);
    }
    return snapshot;
}

static void omacvm_fullpanel_flicker_trace(NSWindow *w, const char *event)
{
    if (!omacvm_fullpanel_flicker_trace_enabled() || !w ||
        ![NSThread isMainThread] || !omacvm_camera_state(w)) {
        return;
    }
    @autoreleasepool {
        NSMutableArray *toolbars = [NSMutableArray array];
        NSMutableArray *overlays = [NSMutableArray array];
        NSMutableDictionary *localClasses = [NSMutableDictionary dictionary];
        NSScreen *screen = [w screen];
        for (NSWindow *candidate in [NSApp windows]) {
            if ([candidate windowNumber] > 0) {
                [localClasses setObject:NSStringFromClass([candidate class])
                                 forKey:@([candidate windowNumber])];
            }
            if ([NSStringFromClass([candidate class])
                    isEqualToString:@"NSToolbarFullScreenWindow"] &&
                NSIntersectsRect([candidate frame], [screen frame])) {
                [toolbars addObject:omacvm_fullpanel_window_trace(candidate)];
            }
            if (omacvm_fullpanel_is_transition_overlay(candidate) &&
                NSIntersectsRect([candidate frame], [screen frame])) {
                /* Include ordered-out overlays: isVisible/orderedIndex and
                 * the public WS list distinguish presence from exposure.
                 */
                [overlays addObject:omacvm_fullpanel_window_trace(candidate)];
            }
        }
        /* Ownership metadata of surfaces intersecting this display's notch
         * strip. Rank follows the public front-to-back WindowServer list.
         * Do not log window titles or pixel contents.
         */
        NSMutableArray *top = [NSMutableArray array];
        NSScreen *primary = [[NSScreen screens] firstObject];
        NSRect physical = [screen frame];
        CGRect strip = CGRectMake(physical.origin.x,
            NSMaxY([primary frame]) - NSMaxY(physical),
            physical.size.width, [screen safeAreaInsets].top);
        CFArrayRef info = primary && screen ? CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly, kCGNullWindowID) : NULL;
        NSInteger targetRank = -1;
        NSUInteger rank = 0;
        for (NSDictionary *entry in (NSArray *)info) {
            NSInteger number = [[entry objectForKey:(id)kCGWindowNumber] integerValue];
            if (number == [w windowNumber]) {
                targetRank = (NSInteger)rank;
            }
            CGRect bounds;
            CFDictionaryRef value = (CFDictionaryRef)[entry objectForKey:(id)kCGWindowBounds];
            if (value && CGRectMakeWithDictionaryRepresentation(value, &bounds) &&
                CGRectIntersectsRect(bounds, strip) && [top count] < 12) {
                [top addObject:omacvm_fullpanel_surface_trace(entry, rank,
                    [w windowNumber], localClasses)];
            }
            rank++;
        }
        fprintf(stderr,
            "omacvm: FULLPANEL FLICKER t=%.6f uptime=%.6f event=%s presentation=%llu systemPresentation=%llu state={%s} target={%s} toolbars={%s} transitionOverlays={%s} wsAvailable=%d targetRank=%ld topSurfaces={%s}; metadata observations do not prove pixel colour or causality\n",
            [[NSDate date] timeIntervalSince1970], [[NSProcessInfo processInfo] systemUptime],
            event, (unsigned long long)[NSApp presentationOptions],
            (unsigned long long)[NSApp currentSystemPresentationOptions],
            [[omacvm_camera_state(w) diagnosticSummary] UTF8String],
            [omacvm_fullpanel_window_trace(w) UTF8String], [[toolbars componentsJoinedByString:@" | "] UTF8String],
            [[overlays componentsJoinedByString:@" | "] UTF8String],
            info != NULL, (long)targetRank, [[top componentsJoinedByString:@" | "] UTF8String]);
        if (info) {
            CFRelease(info);
        }
    }
}

static void omacvm_fullpanel_overlay_observed(NSWindow *w, NSWindow *overlay,
                                             const char *event)
{
    if (!omacvm_fullpanel_flicker_trace_enabled() || !w ||
        ![NSThread isMainThread] || !omacvm_camera_state(w) ||
        !omacvm_fullpanel_is_transition_overlay(overlay) ||
        !NSIntersectsRect([overlay frame], [[w screen] frame])) {
        return;
    }
    fprintf(stderr,
        "omacvm: FULLPANEL OVERLAY t=%.6f uptime=%.6f event=%s targetNumber=%ld ownerPID=%d overlay={%s}; observed callback, not evidence of pixel exposure\n",
        [[NSDate date] timeIntervalSince1970], [[NSProcessInfo processInfo] systemUptime],
        event, (long)[w windowNumber], [[NSProcessInfo processInfo] processIdentifier],
        [omacvm_fullpanel_window_trace(overlay) UTF8String]);
    omacvm_fullpanel_flicker_trace(w, event);
}

/* 1 = at the physical frame, 0 = still transformed/offscreen, -1 = unknown.
 * Mission Control can leave AppKit's geometry unchanged while WindowServer
 * animates the real window. Never use these observations to force a frame.
 */
static int omacvm_fullpanel_compositor_ready(NSWindow *w)
{
    NSScreen *primary = [[NSScreen screens] firstObject];
    if (!w || !primary || [w windowNumber] <= 0) {
        return -1;
    }
    CFArrayRef info = CGWindowListCopyWindowInfo(
        kCGWindowListOptionIncludingWindow, (CGWindowID)[w windowNumber]);
    if (!info) {
        return -1;
    }
    int ready = -1;
    NSRect frame = [w frame];
    NSRect expected = NSMakeRect(frame.origin.x,
        NSMaxY([primary frame]) - NSMaxY(frame), frame.size.width, frame.size.height);
    for (NSDictionary *entry in (NSArray *)info) {
        if ([[entry objectForKey:(id)kCGWindowNumber] integerValue] != [w windowNumber]) {
            continue;
        }
        CGRect bounds;
        CFDictionaryRef value = (CFDictionaryRef)[entry objectForKey:(id)kCGWindowBounds];
        if (value && CGRectMakeWithDictionaryRepresentation(value, &bounds)) {
            ready = omacvm_camera_rect_equal(NSRectFromCGRect(bounds), expected) ? 1 : 0;
        }
        break;
    }
    CFRelease(info);
    return ready;
}

/* Query only this window, never other apps' titles or contents. CG coordinates
 * have their origin at the primary display's top left, unlike AppKit's.
 * These observations can expose clipping/bounds differences, but a matching
 * rectangle does not prove that the compositor displayed the notch strip.
 */
static void omacvm_fullpanel_compositor_diagnostic(NSWindow *w,
                                                   const char *event)
{
    if (!omacvm_fullpanel_diagnostic_enabled() || !w ||
        ![NSThread isMainThread] || [w windowNumber] <= 0) {
        return;
    }
    @autoreleasepool {
        CFArrayRef info = CGWindowListCopyWindowInfo(
            kCGWindowListOptionIncludingWindow, (CGWindowID)[w windowNumber]);
        CGRect server = CGRectZero;
        bool found = false;
        if (info) {
            for (NSDictionary *entry in (NSArray *)info) {
                if ([[entry objectForKey:(id)kCGWindowNumber] integerValue] ==
                    [w windowNumber]) {
                    CFDictionaryRef bounds = (CFDictionaryRef)
                        [entry objectForKey:(id)kCGWindowBounds];
                    found = bounds && CGRectMakeWithDictionaryRepresentation(bounds, &server);
                    break;
                }
            }
        }
        NSRect appkit = [w frame];
        NSScreen *primary = [[NSScreen screens] firstObject];
        NSRect expected = NSMakeRect(appkit.origin.x,
            NSMaxY([primary frame]) - NSMaxY(appkit),
            appkit.size.width, appkit.size.height);
        NSView *view = [w contentView];
        CALayer *layer = [view layer];
        CALayer *parent = [layer superlayer];
        NSEdgeInsets insets = [view safeAreaInsets];
        bool different = found && primary &&
            !omacvm_camera_rect_equal(NSRectFromCGRect(server), expected);
        fprintf(stderr,
            "omacvm: FULLPANEL COMPOSITOR t=%.6f event=%s window=%p number=%ld key=%d activeSpace=%d visible=%d occlusion=%llu wsAvailable=%d wsBounds=%s expectedWSBounds=%s WS_FRAME_DIFFERS=%d layoutRect=%s viewVisibleRect=%s viewBounds=%s viewSafeInsets=(%.2f %.2f %.2f %.2f) layerFrame=%s layerBounds=%s layerHidden=%d layerOpacity=%.3f layerMasksToBounds=%d parentFrame=%s parentBounds=%s parentMasksToBounds=%d; observations do not prove notch pixels are visible\n",
            [[NSDate date] timeIntervalSince1970], event, (void *)w,
            (long)[w windowNumber], (int)[w isKeyWindow],
            (int)[w isOnActiveSpace], (int)[w isVisible],
            (unsigned long long)[w occlusionState], found,
            [NSStringFromRect(NSRectFromCGRect(server)) UTF8String],
            [NSStringFromRect(expected) UTF8String], different,
            [NSStringFromRect([w contentLayoutRect]) UTF8String],
            [NSStringFromRect([view visibleRect]) UTF8String],
            [NSStringFromRect([view bounds]) UTF8String],
            insets.top, insets.left, insets.bottom, insets.right,
            [NSStringFromRect(NSRectFromCGRect([layer frame])) UTF8String],
            [NSStringFromRect(NSRectFromCGRect([layer bounds])) UTF8String],
            (int)[layer isHidden], (double)[layer opacity],
            (int)[layer masksToBounds],
            [NSStringFromRect(NSRectFromCGRect([parent frame])) UTF8String],
            [NSStringFromRect(NSRectFromCGRect([parent bounds])) UTF8String],
            (int)[parent masksToBounds]);
        if (info) {
            CFRelease(info);
        }
    }
}

static void omacvm_fullpanel_diagnostic(NSWindow *w, const char *event,
                                       NSString *detail, bool stack)
{
    if (!omacvm_fullpanel_diagnostic_enabled()) {
        return;
    }
    @autoreleasepool {
        NSScreen *screen = [w screen];
        NSView *content = [w contentView];
        NSString *trace = @"";
        if (stack) {
            NSArray *symbols = [NSThread callStackSymbols];
            NSUInteger count = MIN((NSUInteger)7, [symbols count]);
            trace = [[symbols subarrayWithRange:NSMakeRange(0, count)]
                     componentsJoinedByString:@" | "];
        }
        fprintf(stderr,
                "omacvm: FULLPANEL DIAG t=%.6f event=%s window=%p number=%ld class=%s thread=%p main=%d frame=%s contentRect=%s viewFrame=%s viewBounds=%s screen=%p screenFrame=%s visibleFrame=%s safeTop=%.2f scale=%.2f style=%llu collection=%llu occlusion=%llu key=%d visible=%d presentation=%llu systemPresentation=%llu state={%s} detail={%s} stack={%s}\n",
                [[NSDate date] timeIntervalSince1970], event, (void *)w,
                (long)[w windowNumber], [NSStringFromClass([w class]) UTF8String],
                (void *)[NSThread currentThread], (int)[NSThread isMainThread],
                [NSStringFromRect([w frame]) UTF8String],
                [NSStringFromRect([w contentRectForFrameRect:[w frame]]) UTF8String],
                [NSStringFromRect([content frame]) UTF8String],
                [NSStringFromRect([content bounds]) UTF8String], (void *)screen,
                [NSStringFromRect([screen frame]) UTF8String],
                [NSStringFromRect([screen visibleFrame]) UTF8String],
                [screen safeAreaInsets].top, [w backingScaleFactor],
                (unsigned long long)[w styleMask],
                (unsigned long long)[w collectionBehavior],
                (unsigned long long)[w occlusionState],
                (int)[w isKeyWindow], (int)[w isVisible],
                (unsigned long long)[NSApp presentationOptions],
                (unsigned long long)[NSApp currentSystemPresentationOptions],
                [[omacvm_camera_state(w) diagnosticSummary] UTF8String] ?: "none",
                [detail UTF8String], [trace UTF8String]);
        /* Limit WindowServer queries to return/lifecycle events. */
        if (!strcmp(event, "SPACE notification") ||
            !strcmp(event, "CALLBACK windowDidBecomeKey") ||
            !strcmp(event, "OCCLUSION notification") ||
            !strncmp(event, "FULLPANEL refresh", 17)) {
            omacvm_fullpanel_compositor_diagnostic(w, event);
        }
    }
}

static bool omacvm_camera_window_usable(NSWindow *window)
{
    OmacVMCameraHousingState *state = omacvm_camera_state(window);
    return state && [state usable];
}

static bool omacvm_camera_install_reveal_observer(void)
{
    if (omacvm_camera_reveal_state) {
        return omacvm_camera_reveal_state > 0;
    }
    omacvm_camera_reveal_state = -1;

    Method set_menu = omacvm_camera_private_method(
        "_NSFullScreenMenuBarCompanionController", "setMenuBarReveal:",
        "v24@0:8d16");
    Method set_toolbar = omacvm_camera_private_method(
        "_NSFullScreenMenuBarCompanionController", "setToolbarWindowReveal:",
        "v24@0:8d16");
    Method get_menu = omacvm_camera_private_method(
        "_NSFullScreenMenuBarCompanionController", "menuBarReveal",
        "d16@0:8");
    Method get_toolbar = omacvm_camera_private_method(
        "_NSFullScreenMenuBarCompanionController", "toolbarWindowReveal",
        "d16@0:8");
    Method get_content = omacvm_camera_private_method(
        "_NSFullScreenMenuBarCompanionController", "contentController",
        "@16@0:8");
    Method get_window = omacvm_camera_private_method(
        "_NSFullScreenContentController", "window", "@16@0:8");

    if (!set_menu || !set_toolbar || !get_menu || !get_toolbar ||
        !get_content || !get_window) {
        return false;
    }

    SEL menu_get_sel = method_getName(get_menu);
    SEL toolbar_get_sel = method_getName(get_toolbar);
    SEL content_sel = method_getName(get_content);
    SEL window_sel = method_getName(get_window);
    OmacVMCameraGetRevealFn menu_get =
        (OmacVMCameraGetRevealFn)method_getImplementation(get_menu);
    OmacVMCameraGetRevealFn toolbar_get =
        (OmacVMCameraGetRevealFn)method_getImplementation(get_toolbar);
    OmacVMCameraGetObjectFn content_get =
        (OmacVMCameraGetObjectFn)method_getImplementation(get_content);
    OmacVMCameraGetObjectFn window_get =
        (OmacVMCameraGetObjectFn)method_getImplementation(get_window);

    Method setters[2] = { set_menu, set_toolbar };
    for (int i = 0; i < 2; i++) {
        Method setter = setters[i];
        SEL setter_sel = method_getName(setter);
        OmacVMCameraSetRevealFn original =
            (OmacVMCameraSetRevealFn)method_getImplementation(setter);

        id block = ^(id companion, double value) {
            if (omacvm_fullpanel_flicker_trace_enabled() && [NSThread isMainThread]) {
                id beforeContent = content_get(companion, content_sel);
                NSWindow *beforeWindow = beforeContent ? window_get(beforeContent, window_sel) : nil;
                omacvm_fullpanel_flicker_trace(beforeWindow,
                    i == 0 ? "menu reveal setter before AppKit" : "toolbar reveal setter before AppKit");
            }
            original(companion, setter_sel, value);

            bool menu = menu_get(companion, menu_get_sel) > 0;
            bool toolbar = toolbar_get(companion, toolbar_get_sel) > 0;
            id content = content_get(companion, content_sel);
            NSWindow *w = content ? window_get(content, window_sel) : nil;
            OmacVMCameraHousingState *state = omacvm_camera_state(w);
            if (!state) {
                return;
            }
            void (^update)(void) = ^{
                omacvm_fullpanel_flicker_trace(w,
                    i == 0 ? "menu reveal setter after AppKit" : "toolbar reveal setter after AppKit");
                [state menuRevealChanged:menu toolbar:toolbar];
                omacvm_fullpanel_flicker_trace(w, "reveal state applied");
            };
            if ([NSThread isMainThread]) {
                update();
            } else {
                dispatch_async(dispatch_get_main_queue(), update);
            }
        };
        method_setImplementation(setter, imp_implementationWithBlock(block));
    }

    omacvm_camera_reveal_state = 1;
    return true;
}

static NSRect omacvm_camera_fullscreen_frame_hook(id object, SEL selector)
{
    FP_DIAG((NSWindow *)object, "FRAME HOOK enter", true,
            @"selector=%@", NSStringFromSelector(selector));
    NSRect frame = omacvm_camera_appkit_frame ?
        omacvm_camera_appkit_frame(object, selector) : [(NSWindow *)object frame];
    OmacVMCameraHousingState *state =
        omacvm_camera_state((NSWindow *)object);
    NSRect result = state ? [state fullScreenFrameForAppKitFrame:frame] : frame;
    FP_DIAG((NSWindow *)object, "FRAME HOOK result", false,
            @"selector=%@ appkit=%@ result=%@", NSStringFromSelector(selector),
            NSStringFromRect(frame), NSStringFromRect(result));
    return result;
}

static bool omacvm_camera_class_already_hooked(Class cls)
{
    for (int i = 0; i < omacvm_camera_hooked_count; i++) {
        if (omacvm_camera_hooked_classes[i] == cls) {
            return true;
        }
    }
    return false;
}

static bool omacvm_camera_install_frame_hook(Class cls)
{
    if (omacvm_camera_class_already_hooked(cls)) {
        return true;
    }
    if (!omacvm_camera_appkit_frame) {
        const char *expected = "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8";
        omacvm_camera_frame_selector =
            NSSelectorFromString(@"_frameForFullScreenMode");
        omacvm_camera_tile_selector =
            NSSelectorFromString(@"_tileFrameForFullScreen");

        Method frame = class_getInstanceMethod([NSWindow class],
                                               omacvm_camera_frame_selector);
        Method tile = class_getInstanceMethod([NSWindow class],
                                              omacvm_camera_tile_selector);
        const char *frame_types = frame ? method_getTypeEncoding(frame) : NULL;
        const char *tile_types = tile ? method_getTypeEncoding(tile) : NULL;
        if (!frame || !tile || !frame_types || !tile_types ||
            strcmp(frame_types, expected) || strcmp(tile_types, expected)) {
            fprintf(stderr, "omacvm: full panel: AppKit fullscreen-frame methods changed; using normal full screen\n");
            return false;
        }
        omacvm_camera_frame_types = frame_types;
        omacvm_camera_appkit_frame =
            (OmacVMCameraFrameFn)method_getImplementation(frame);
        omacvm_camera_tile_frame =
            (OmacVMCameraFrameFn)method_getImplementation(tile);
    }

    if (!class_addMethod(cls, omacvm_camera_frame_selector,
                         (IMP)omacvm_camera_fullscreen_frame_hook,
                         omacvm_camera_frame_types)) {
        fprintf(stderr, "omacvm: full panel: cannot install fullscreen-frame hook on %s\n",
                class_getName(cls));
        return false;
    }
    if (omacvm_camera_hooked_count <
        (int)(sizeof(omacvm_camera_hooked_classes) /
              sizeof(omacvm_camera_hooked_classes[0]))) {
        omacvm_camera_hooked_classes[omacvm_camera_hooked_count++] = cls;
    }
    return true;
}

@implementation OmacVMCameraHousingState

- (NSString *)diagnosticSummary
{
    return [NSString stringWithFormat:
        @"kept=%d accepted=%d inSpace=%d areaLost=%d hiddenSpace=%llu menu=%d toolbar=%d revealAllowed=%d forced=%d presentationValid=%d savedPresentation=%llu presentationAB=%d v2ToolbarHandoff=%llu",
        full_screen_frame_kept, full_panel_frame_accepted, in_full_screen_space,
        camera_housing_area_lost, (unsigned long long)menu_bar_hidden_space,
        menu_bar_revealed, toolbar_revealed, menu_bar_reveal_allowed,
        presentation_forced, revealable_presentation_valid,
        (unsigned long long)revealable_presentation, full_panel_presentation_ab_armed,
        (unsigned long long)v2_toolbar_handoff_space];
}

- (id)initWithWindow:(NSWindow *)w
{
    self = [super init];
    if (!self) {
        return nil;
    }
    window = w;
    if (omacvm_fullpanel_flicker_trace_enabled()) {
        fprintf(stderr, "omacvm: FULLPANEL FLICKER enabled; observation only, no timing or policy change\n");
    }
    if (omacvm_fullpanel_handoff_trace_enabled()) {
        fprintf(stderr, "omacvm: FULLPANEL HANDOFF enabled; read-only return sampling, no restoration gate\n");
    }
    if (omacvm_fullpanel_v2_toolbar_handoff_enabled()) {
        fprintf(stderr, "omacvm: FULLPANEL V2 TOOLBAR HANDOFF enabled; AppKit owns toolbar after established Space departure, restoration unchanged\n");
    }

    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self selector:@selector(activeSpaceChanged:)
        name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    workspace_observing = true;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(willEnterFullScreen:)
                   name:NSWindowWillEnterFullScreenNotification object:w];
    [center addObserver:self selector:@selector(didEnterFullScreen:)
                   name:NSWindowDidEnterFullScreenNotification object:w];
    [center addObserver:self selector:@selector(windowDidResize:)
                   name:NSWindowDidResizeNotification object:w];
    [center addObserver:self selector:@selector(willLeaveFullScreen:)
                   name:NSWindowWillExitFullScreenNotification object:w];
    [center addObserver:self selector:@selector(willLeaveFullScreen:)
                   name:NSWindowWillCloseNotification object:w];
    [center addObserver:self selector:@selector(didExitFullScreen:)
                   name:NSWindowDidExitFullScreenNotification object:w];
    [center addObserver:self selector:@selector(otherWindowDidChangeOcclusionState:)
                   name:NSWindowDidChangeOcclusionStateNotification object:nil];
    [center addObserver:self selector:@selector(windowDidBecomeKey:)
                   name:NSWindowDidBecomeKeyNotification object:w];
    if (omacvm_fullpanel_flicker_trace_enabled()) {
        [center addObserver:self selector:@selector(traceTransitionOverlayClose:)
                       name:NSWindowWillCloseNotification object:nil];
    }
    if (omacvm_fullpanel_v2_return_enabled()) {
        [center addObserver:self selector:@selector(v2ReturnNotification:)
                       name:NSWindowDidBecomeKeyNotification object:nil];
        [center addObserver:self selector:@selector(v2ReturnNotification:)
                       name:NSApplicationDidBecomeActiveNotification object:NSApp];
        [center addObserver:self selector:@selector(v2ReturnNotification:)
                       name:NSApplicationDidChangeScreenParametersNotification object:NSApp];
        fprintf(stderr, "omacvm: FULLPANEL V2 RETURN enabled; entry unchanged, arms on established Space departure\n");
    }
    if (omacvm_fullpanel_v2_parity_enabled()) {
        fprintf(stderr, "omacvm: FULLPANEL V2 PARITY enabled; passive automatic-return bypass, no restoration driver\n");
    }
    return self;
}

- (void)dealloc
{
    [full_panel_handoff_last_sample release];
    if (workspace_observing) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    }
    [self showMenuBar];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (bool)usable
{
    if (!omacvm_camera_housing_requested() || !window || ![window screen] ||
        [[window screen] safeAreaInsets].top <= 0) {
        return false;
    }
    if ([[NSUserDefaults standardUserDefaults]
            boolForKey:@"AppleMenuBarVisibleInFullscreen"]) {
        return false;
    }
    return omacvm_camera_class_already_hooked([window class]) &&
           omacvm_camera_load_skylight() &&
           omacvm_camera_install_reveal_observer();
}

- (NSRect)fullScreenFrameForAppKitFrame:(NSRect)frame
{
    if (![self usable] || camera_housing_area_lost || ![window screen]) {
        return frame;
    }
    NSRect screen_frame = [[window screen] frame];
    NSRect tile = omacvm_camera_tile_frame ?
        omacvm_camera_tile_frame(window, omacvm_camera_tile_selector) : frame;
    bool full_tile = omacvm_camera_rect_equal(tile, screen_frame);
    FP_DIAG(window, "TILE QUERY observed", true,
            @"selector=%@ result=%@ appkit=%@",
            NSStringFromSelector(omacvm_camera_tile_selector),
            NSStringFromRect(tile), NSStringFromRect(frame));

    /*
     * Once WindowServer has accepted the actual display frame, AppKit can
     * re-query this private selector while the *proposed tile* is temporarily
     * limited by the camera housing. Returning AppKit's safe-area frame here
     * bypasses our setFrame:display: guards and abandons the notch strip.
     *
     * Preserve only the EXACT camera-housing-safe tile of the same display:
     * same x/y/width and height reduced by safeAreaInsets.top. A genuinely
     * smaller/tiled fullscreen region must still use AppKit's original frame.
     * Never authorize the safe tile until a full tile was accepted first.
     */
    CGFloat notch = [[window screen] safeAreaInsets].top;
    bool exact_safe_tile = full_panel_frame_accepted &&
        full_screen_frame_kept &&
        ([window styleMask] & NSWindowStyleMaskFullScreen) &&
        notch > 0 &&
        fabs(tile.origin.x - screen_frame.origin.x) < 0.5 &&
        fabs(tile.origin.y - screen_frame.origin.y) < 0.5 &&
        fabs(tile.size.width - screen_frame.size.width) < 0.5 &&
        fabs(tile.size.height - (screen_frame.size.height - notch)) < 0.5;

    if (!full_tile && !exact_safe_tile) {
        if (full_panel_frame_accepted && !full_panel_frame_reject_logged) {
            full_panel_frame_reject_logged = true;
            fprintf(stderr,
                    "omacvm: full panel: FRAME HOOK rejected tile=(%.0f %.0f %.0fx%.0f) display=(%.0f %.0f %.0fx%.0f) notch=%.0f\n",
                    tile.origin.x, tile.origin.y, tile.size.width, tile.size.height,
                    screen_frame.origin.x, screen_frame.origin.y,
                    screen_frame.size.width, screen_frame.size.height, notch);
        }
        return frame;
    }
    if (exact_safe_tile && !full_panel_safe_tile_requery_logged) {
        full_panel_safe_tile_requery_logged = true;
        fprintf(stderr,
                "omacvm: full panel: FRAME HOOK kept physical frame over safe tile %.0fx%.0f (notch %.0f)\n",
                tile.size.width, tile.size.height, notch);
    }
    full_panel_frame_accepted = true;
    FP_DIAG(window, "FRAME ACCEPTED", false, @"result=%@", NSStringFromRect(screen_frame));
    return screen_frame;
}

- (bool)keepSetFrame:(NSRect)proposed display:(bool)display
{
    if (!full_screen_frame_kept || !full_panel_frame_accepted ||
        !([window styleMask] & NSWindowStyleMaskFullScreen) ||
        ![self usable] || camera_housing_area_lost || ![window screen]) {
        FP_DIAG(window, "SET FRAME guard bypass", false,
                @"reason=state/style/usable/screen gate; see state and geometry");
        return false;
    }
    NSRect screen_frame = [[window screen] frame];
    if (!omacvm_camera_rect_equal([window frame], screen_frame)) {
        FP_DIAG(window, "SET FRAME guard bypass", false, @"reason=current frame already differs from physical screen");
        return false;
    }

    /*
     * AppKit can temporarily return the 39pt-safe-area tile while relayout
     * is in progress.  Re-querying _tileFrameForFullScreen here was disabling
     * our existing frame protection just as the unsafe resize arrived.
     * We already verified a full-width/full-height tile when the private
     * fullscreen-frame hook accepted this Space.  Only allow a genuine
     * horizontally tiled/Split View transition to change the frame now.
     */
    NSRect tile = omacvm_camera_tile_frame ?
        omacvm_camera_tile_frame(window, omacvm_camera_tile_selector) :
        screen_frame;
    FP_DIAG(window, "SET FRAME tile observed", false,
            @"tile=%@ proposed=%@", NSStringFromRect(tile), NSStringFromRect(proposed));
    if (fabs(tile.origin.x - screen_frame.origin.x) > 1 ||
        fabs(tile.size.width - screen_frame.size.width) > 1) {
        FP_DIAG(window, "SET FRAME guard bypass", false, @"reason=horizontal tile");
        return false;
    }

    if (!omacvm_camera_rect_equal(proposed, screen_frame)) {
        fprintf(stderr,
                "omacvm: full panel: protected accepted frame %.0fx%.0f from requested %.0fx%.0f\n",
                screen_frame.size.width, screen_frame.size.height,
                proposed.size.width, proposed.size.height);
    }
    if (display) {
        [window display];
    }
    return true;
}

- (NSWindow *)fullScreenToolbarWindow
{
    if (!menu_bar_hidden_space) {
        return nil;
    }
    for (NSWindow *candidate in [NSApp windows]) {
        if (candidate == window) {
            continue;
        }
        if (![NSStringFromClass([candidate class])
                isEqualToString:@"NSToolbarFullScreenWindow"]) {
            continue;
        }
        if (omacvm_camera_space_id(candidate) == menu_bar_hidden_space) {
            return candidate;
        }
    }
    return nil;
}

- (void)setToolbarHidden:(bool)hidden
{
    FP_DIAG(window, "TOOLBAR request", true, @"hidden=%d", hidden);
    toolbar_hidden = hidden;
    NSWindow *toolbar = [self fullScreenToolbarWindow];
    NSView *content = [toolbar contentView];
    if (!content) {
        return;
    }
    NSView *view = [content superview] ?: content;
    omacvm_fullpanel_flicker_trace(window, "toolbar hide before");
    [view setHidden:hidden];
    [toolbar setIgnoresMouseEvents:hidden];
    omacvm_fullpanel_flicker_trace(window, "toolbar hide after");
}

- (bool)v2ToolbarHandoffActive
{
    return v2_toolbar_handoff_space &&
        omacvm_fullpanel_v2_toolbar_handoff_enabled() &&
        v2_toolbar_handoff_space == menu_bar_hidden_space &&
        in_full_screen_space && full_screen_frame_kept &&
        full_panel_frame_accepted && !camera_housing_area_lost &&
        ([window styleMask] & NSWindowStyleMaskFullScreen) &&
        [self usable] && [window screen] &&
        omacvm_camera_rect_equal([window frame], [[window screen] frame]) &&
        omacvm_camera_fullscreen_space_id(window) == menu_bar_hidden_space;
}

/* Suppress only automatic return work after our existing initial entry.
 * Keep the accepted physical frame and initial alpha override as they are.
 * This does not hide notch pixels or detect Mission Control completion.
 * Transient Space-query absence must not enable the early driver again.
 */
- (bool)v2ParityManaged
{
    return v2_parity_established && omacvm_fullpanel_v2_parity_enabled() &&
        in_full_screen_space && full_screen_frame_kept &&
        full_panel_frame_accepted && !camera_housing_area_lost &&
        menu_bar_hidden_space &&
        ([window styleMask] & NSWindowStyleMaskFullScreen) &&
        [self usable] && [window screen] &&
        omacvm_camera_rect_equal([window frame], [[window screen] frame]);
}

- (void)noteV2ToolbarHandoffDeparture
{
    if (v2_toolbar_handoff_space ||
        !omacvm_fullpanel_v2_toolbar_handoff_enabled() ||
        !in_full_screen_space || !full_screen_frame_kept ||
        !full_panel_frame_accepted || camera_housing_area_lost ||
        !menu_bar_hidden_space || [window isOnActiveSpace] ||
        !([window styleMask] & NSWindowStyleMaskFullScreen) ||
        ![self usable] || ![window screen] ||
        !omacvm_camera_rect_equal([window frame], [[window screen] frame]) ||
        omacvm_camera_fullscreen_space_id(window) != menu_bar_hidden_space) {
        return;
    }
    /* Undo only our toolbar-view suppression. This is the app's own
     * NSToolbarFullScreenWindow in the tracked Space, never a system window.
     * AppKit then controls coverage; no claim that departure is MC completion.
     */
    if (toolbar_hidden) {
        [self setToolbarHidden:false];
    }
    v2_toolbar_handoff_space = menu_bar_hidden_space;
    FP_DIAG(window, "V2 TOOLBAR HANDOFF armed", false,
            @"space=%llu; released our toolbar hiding; alpha/presentation/compositor restoration unchanged",
            (unsigned long long)v2_toolbar_handoff_space);
}

- (void)notePresentationSpaceDeparture
{
    if (!full_panel_presentation_ab_armed &&
        omacvm_fullpanel_passive_presentation_enabled() &&
        in_full_screen_space && full_screen_frame_kept &&
        full_panel_frame_accepted && !camera_housing_area_lost &&
        menu_bar_hidden_space && ![window isOnActiveSpace]) {
        full_panel_presentation_ab_armed = true;
        FP_DIAG(window, "PRESENTATION AB armed", false,
                @"established fullscreen Space departed; suppress automatic reassertion until exit; alpha recovery unchanged");
    }
}

- (bool)skipPresentationReassertForAB
{
    return full_panel_presentation_ab_armed &&
        omacvm_fullpanel_passive_presentation_enabled() &&
        in_full_screen_space && full_screen_frame_kept &&
        full_panel_frame_accepted && !camera_housing_area_lost &&
        menu_bar_hidden_space &&
        ([window styleMask] & NSWindowStyleMaskFullScreen) &&
        !menu_bar_reveal_allowed && !menu_bar_revealed && !toolbar_revealed;
}

- (void)updatePresentationOptions
{
    if (!revealable_presentation_valid) {
        return;
    }
    if ([self skipPresentationReassertForAB]) {
        FP_DIAG(window, "PRESENTATION AB skipped", false,
                @"current=%llu saved=%llu key=%d active=%d; let AppKit own presentation, alpha recovery unchanged",
                (unsigned long long)[NSApp presentationOptions],
                (unsigned long long)revealable_presentation,
                [window isKeyWindow], [window isOnActiveSpace]);
        return; /* Do not change presentation_forced while skipping. */
    }

    NSApplicationPresentationOptions options = 0;
    bool have_options = false;
    const char *branch = "none";
    if (!menu_bar_reveal_allowed && [window isKeyWindow]) {
        options = NSApplicationPresentationFullScreen |
                  NSApplicationPresentationHideMenuBar |
                  NSApplicationPresentationHideDock;
        presentation_forced = true;
        have_options = true;
        branch = "force hidden presentation";
    } else if (presentation_forced) {
        options = revealable_presentation;
        presentation_forced = false;
        have_options = true;
        branch = "restore saved presentation";
    }

    FP_DIAG(window, "PRESENTATION decision", false,
            @"branch=%s haveOptions=%d requested=%llu current=%llu saved=%llu key=%d active=%d",
            branch, have_options, (unsigned long long)options,
            (unsigned long long)[NSApp presentationOptions],
            (unsigned long long)revealable_presentation,
            [window isKeyWindow], [window isOnActiveSpace]);
    if (have_options && [NSApp presentationOptions] != options) {
        omacvm_fullpanel_flicker_trace(window, "presentation setter before");
        FP_DIAG(window, "PRESENTATION request", true, @"options=%llu",
                (unsigned long long)options);
        [NSApp setPresentationOptions:options];
        omacvm_fullpanel_flicker_trace(window, "presentation setter after");
        FP_DIAG(window, "PRESENTATION result", false, @"requested=%llu",
                (unsigned long long)options);
    }
}

- (void)applyMenuBarReveal
{
    FP_DIAG(window, "MENU ALPHA caller", false,
            @"reason=applyMenuBarReveal space=%llu alpha=%.3f menuRevealed=%d",
            (unsigned long long)menu_bar_hidden_space,
            menu_bar_revealed ? 1.0 : 0.0, menu_bar_revealed);
    if (!menu_bar_hidden_space) {
        return;
    }
    omacvm_camera_set_menu_alpha(window, menu_bar_hidden_space,
                                 menu_bar_revealed ? 1.0f : 0.0f,
                                 "applyMenuBarReveal");
    if ([self v2ToolbarHandoffActive]) {
        FP_DIAG(window, "V2 TOOLBAR HANDOFF AppKit owns toolbar", false,
                @"space=%llu menu=%d toolbar=%d; skipped manual toolbar-view write only",
                (unsigned long long)menu_bar_hidden_space,
                menu_bar_revealed, toolbar_revealed);
    } else {
        [self setToolbarHidden:!toolbar_revealed];
    }
}

- (void)pointerDidMove
{
    if (![window isKeyWindow] || !menu_bar_hidden_space || ![window screen]) {
        return;
    }
    NSScreen *screen = [window screen];
    NSPoint point = [NSEvent mouseLocation];

    if (!menu_bar_reveal_allowed &&
        point.y >= NSMaxY([screen frame]) - 1) {
        menu_bar_reveal_allowed = true;
        [self updatePresentationOptions];
    } else if (menu_bar_reveal_allowed &&
               point.y < NSMaxY([screen frame]) -
                         [screen safeAreaInsets].top &&
               !menu_bar_revealed) {
        menu_bar_reveal_allowed = false;
        [self updatePresentationOptions];
    }
}

- (void)showMenuBar
{
    v2_toolbar_handoff_space = 0;
    FP_DIAG(window, "MENU ALPHA caller", false,
            @"reason=showMenuBar space=%llu alpha=1.000 restore ordinary menu bar",
            (unsigned long long)menu_bar_hidden_space);
    if (top_edge_monitor) {
        [NSEvent removeMonitor:top_edge_monitor];
        top_edge_monitor = nil;
    }
    if (presentation_observing) {
        @try {
            [NSApp removeObserver:self
                       forKeyPath:@"currentSystemPresentationOptions"];
        } @catch (NSException *exception) {
            (void)exception;
        }
        presentation_observing = false;
    }

    menu_bar_reveal_allowed = true;
    [self updatePresentationOptions];
    revealable_presentation_valid = false;
    [self setToolbarHidden:false];

    if (menu_bar_hidden_space) {
        omacvm_camera_set_menu_alpha(window, menu_bar_hidden_space, 1.0f,
                                     "showMenuBar");
    }
    menu_bar_hidden_space = 0;
}

- (void)updateMenuBarHidden
{
    NSScreen *screen = [window screen];
    if (in_full_screen_space && screen &&
        !omacvm_camera_rect_equal([window frame], [screen frame])) {
        if (!camera_housing_area_lost) {
            NSRect actual = [window frame];
            NSRect physical = [screen frame];
            fprintf(stderr,
                    "omacvm: full panel: AREA LOST, frame=(%.0f %.0f %.0fx%.0f) display=(%.0f %.0f %.0fx%.0f) accepted=%d style=%llu\n",
                    actual.origin.x, actual.origin.y,
                    actual.size.width, actual.size.height,
                    physical.origin.x, physical.origin.y,
                    physical.size.width, physical.size.height,
                    (int)full_panel_frame_accepted,
                    (unsigned long long)[window styleMask]);
        }
        if (!camera_housing_area_lost) {
            FP_DIAG(window, "AREA LOST transition", true,
                    @"old=0 new=1 observed geometry mismatch; initiating cause unknown");
        }
        camera_housing_area_lost = true;
        FP_DIAG(window, "AREA LOST state", false, @"latched=1");
    }

    if (!in_full_screen_space || ![self usable] ||
        camera_housing_area_lost || !screen ||
        [screen safeAreaInsets].top <= 0 ||
        !omacvm_camera_rect_equal([window frame], [screen frame])) {
        [self showMenuBar];
        return;
    }

    uint64_t space = omacvm_camera_fullscreen_space_id(window);
    if (!space) {
        [self showMenuBar];
        return;
    }
    if (menu_bar_hidden_space == space) {
        return;
    }

    [self showMenuBar];
    menu_bar_hidden_space = space;
    revealable_presentation = [NSApp presentationOptions];
    revealable_presentation_valid = true;

    [NSApp addObserver:self forKeyPath:@"currentSystemPresentationOptions"
               options:NSKeyValueObservingOptionNew context:NULL];
    presentation_observing = true;

    OmacVMCameraHousingState *state = self;
    top_edge_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        (NSEventMaskMouseMoved |
         NSEventMaskLeftMouseDragged |
         NSEventMaskRightMouseDragged |
         NSEventMaskOtherMouseDragged)
        handler:^NSEvent *(NSEvent *event) {
            [state pointerDidMove];
            return event;
        }];

    menu_bar_reveal_allowed = false;
    menu_bar_revealed = false;
    toolbar_revealed = false;
    [self updatePresentationOptions];
    [self applyMenuBarReveal];

    fprintf(stderr,
            "omacvm: full panel: native fullscreen Space %llu uses camera-housing area %.0fx%.0f\n",
            (unsigned long long)space,
            [screen frame].size.width, [screen frame].size.height);
}

- (void)menuRevealChanged:(bool)menu toolbar:(bool)toolbar
{
    FP_DIAG(window, "REVEAL observed", true, @"menu=%d toolbar=%d", menu, toolbar);
    if (menu_bar_revealed == menu && toolbar_revealed == toolbar) {
        return;
    }
    menu_bar_revealed = menu;
    toolbar_revealed = toolbar;
    if (!menu_bar_hidden_space) {
        return;
    }
    if ([self v2ParityManaged] && !menu_bar_reveal_allowed) {
        return; /* Passive AppKit observation; explicit user reveal is unchanged. */
    }
    [self applyMenuBarReveal];
    if (!menu_bar_revealed) {
        menu_bar_reveal_allowed = false;
        [self updatePresentationOptions];
    }
}

- (void)willEnterFullScreen:(NSNotification *)notification
{
    [self cancelHandoffTrace:"fullscreen entry"];
    FP_DIAG(window, "CALLBACK willEnterFullScreen", true, @"observed name=%@", [notification name]);
    full_screen_frame_kept = true;
    v2_parity_established = false;
    v2_toolbar_handoff_space = 0;
    full_panel_presentation_ab_armed = false;
    full_panel_v2_return_armed = false;
    full_panel_v2_return_batches = 0;
    full_panel_v2_return_generation++;
    FP_DIAG(window, "AREA LOST reset", false, @"old=%d new=0 reason=willEnter", camera_housing_area_lost);
    camera_housing_area_lost = false;
    (void)[self usable];
    FP_DIAG(window, "CALLBACK willEnterFullScreen result", false, @"observed");
}

- (void)didEnterFullScreen:(NSNotification *)notification
{
    FP_DIAG(window, "CALLBACK didEnterFullScreen", true, @"observed name=%@", [notification name]);
    in_full_screen_space = true;
    NSRect actual = [window frame];
    NSRect physical = [[window screen] frame];
    fprintf(stderr,
            "omacvm: full panel: DID ENTER frame=(%.0f %.0f %.0fx%.0f) display=(%.0f %.0f %.0fx%.0f) accepted=%d\n",
            actual.origin.x, actual.origin.y,
            actual.size.width, actual.size.height,
            physical.origin.x, physical.origin.y,
            physical.size.width, physical.size.height,
            (int)full_panel_frame_accepted);
    [self updateMenuBarHidden];
    /* NSWindowDidEnterFullScreen marks completed initial entry. All entry
     * geometry, alpha and presentation above use the existing implementation.
     */
    v2_parity_established = omacvm_fullpanel_v2_parity_enabled();
    FP_DIAG(window, "CALLBACK didEnterFullScreen result", false, @"observed");
}

- (void)windowDidResize:(NSNotification *)notification
{
    FP_DIAG(window, "CALLBACK windowDidResize", true, @"observed name=%@", [notification name]);
    if (in_full_screen_space) {
        [self updateMenuBarHidden];
    }
    FP_DIAG(window, "CALLBACK windowDidResize result", false, @"observed; callback alone does not identify resize cause");
}

- (void)willLeaveFullScreen:(NSNotification *)notification
{
    [self cancelHandoffTrace:"fullscreen exit/close"];
    FP_DIAG(window, "CALLBACK willLeaveFullScreen", true, @"observed name=%@", [notification name]);
    full_screen_frame_kept = false;
    v2_parity_established = false;
    v2_toolbar_handoff_space = 0;
    full_panel_frame_accepted = false;
    full_panel_safe_tile_requery_logged = false;
    full_panel_frame_reject_logged = false;
    in_full_screen_space = false;
    full_panel_presentation_ab_armed = false;
    full_panel_v2_return_armed = false;
    full_panel_v2_return_batches = 0;
    full_panel_v2_return_generation++;
    FP_DIAG(window, "AREA LOST reset", false, @"old=%d new=0 reason=willLeave", camera_housing_area_lost);
    camera_housing_area_lost = false;
    menu_bar_revealed = false;
    toolbar_revealed = false;
    [self showMenuBar];
    FP_DIAG(window, "CALLBACK willLeaveFullScreen result", false, @"observed");
}

- (void)didExitFullScreen:(NSNotification *)notification
{
    FP_DIAG(window, "CALLBACK didExitFullScreen", true, @"observed name=%@", [notification name]);
}

- (void)activeSpaceChanged:(NSNotification *)notification
{
    [self noteV2ToolbarHandoffDeparture];
    [self noteHandoffDeparture];
    [self noteV2ReturnDeparture];
    [self notePresentationSpaceDeparture];
    omacvm_fullpanel_flicker_trace(window, "active Space changed");
    FP_DIAG(window, "SPACE notification", true,
            @"observed name=%@; notification is not evidence of resize cause", [notification name]);
    [self scheduleFullPanelRefresh:@"active Space changed"];
}

/* Observe only returns from an established Full Panel Space, including the
 * clean Control+Arrow comparison. No new Mission Control notification is
 * invented: these are the existing Space/key/occlusion event entry points.
 */
- (void)noteHandoffDeparture
{
    if (omacvm_fullpanel_handoff_trace_enabled() && in_full_screen_space &&
        full_panel_frame_accepted && full_screen_frame_kept &&
        !camera_housing_area_lost && ![window isOnActiveSpace]) {
        [self cancelHandoffTrace:"Space departed"];
        full_panel_handoff_departed = true;
        @autoreleasepool {
            double epoch = [[NSDate date] timeIntervalSince1970];
            double uptime = [[NSProcessInfo processInfo] systemUptime];
            NSString *sample = omacvm_fullpanel_handoff_snapshot(window);
            fprintf(stderr, "omacvm: FULLPANEL HANDOFF departure t=%.6f uptime=%.6f targetNumber=%ld queryMs=%.3f state={%s}\n",
                    epoch, uptime, (long)[window windowNumber],
                    ([[NSProcessInfo processInfo] systemUptime] - uptime) * 1000,
                    [sample UTF8String]);
        }
    }
}

- (void)cancelHandoffTrace:(const char *)reason
{
    if (full_panel_handoff_sampling) {
        fprintf(stderr, "omacvm: FULLPANEL HANDOFF end t=%.6f uptime=%.6f targetNumber=%ld generation=%u samples=%u maxGapMs=%.3f reason=%s\n",
                [[NSDate date] timeIntervalSince1970], [[NSProcessInfo processInfo] systemUptime],
                (long)[window windowNumber], full_panel_handoff_generation,
                full_panel_handoff_samples, full_panel_handoff_max_gap * 1000, reason);
    }
    full_panel_handoff_generation++;
    full_panel_handoff_sampling = false;
    full_panel_handoff_departed = false;
    [full_panel_handoff_last_sample release];
    full_panel_handoff_last_sample = nil;
}

- (void)startHandoffTrace:(NSString *)reason
{
    if (!omacvm_fullpanel_handoff_trace_enabled() || !full_panel_handoff_departed ||
        full_panel_handoff_sampling || !in_full_screen_space ||
        !full_panel_frame_accepted || !full_screen_frame_kept ||
        camera_housing_area_lost || ![window isOnActiveSpace] ||
        ![window screen] || [[window screen] safeAreaInsets].top <= 0 ||
        !([window styleMask] & NSWindowStyleMaskFullScreen)) {
        return;
    }
    full_panel_handoff_departed = false;
    full_panel_handoff_sampling = true;
    unsigned generation = ++full_panel_handoff_generation;
    full_panel_handoff_samples = 0;
    full_panel_handoff_max_gap = 0;
    full_panel_handoff_last_uptime = [[NSProcessInfo processInfo] systemUptime];
    [full_panel_handoff_last_sample release];
    full_panel_handoff_last_sample = nil;
    fprintf(stderr, "omacvm: FULLPANEL HANDOFF begin t=%.6f uptime=%.6f targetNumber=%ld generation=%u reason=%s\n",
            [[NSDate date] timeIntervalSince1970], full_panel_handoff_last_uptime,
            (long)[window windowNumber], generation, [reason UTF8String]);
    /* Queue after the original immediate restoration and settled callback.
     * Diagnostic queries never become a prerequisite for notch restoration.
     */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self sampleHandoffTrace:generation checksLeft:240];
    });
}

- (void)sampleHandoffTrace:(unsigned)generation checksLeft:(unsigned)checks
{
    if (generation != full_panel_handoff_generation) {
        return;
    }
    double epoch = [[NSDate date] timeIntervalSince1970];
    double uptime = [[NSProcessInfo processInfo] systemUptime];
    bool eligible = omacvm_fullpanel_handoff_trace_enabled() &&
        in_full_screen_space && full_panel_frame_accepted && full_screen_frame_kept &&
        !camera_housing_area_lost && [window isOnActiveSpace] &&
        [window screen] && [[window screen] safeAreaInsets].top > 0 &&
        ([window styleMask] & NSWindowStyleMaskFullScreen);
    if (!eligible || !checks) {
        full_panel_handoff_sampling = false;
        fprintf(stderr, "omacvm: FULLPANEL HANDOFF end t=%.6f uptime=%.6f targetNumber=%ld generation=%u samples=%u maxGapMs=%.3f reason=%s; sampling ended, not an animation-complete event\n",
                epoch, uptime, (long)[window windowNumber],
                generation, full_panel_handoff_samples, full_panel_handoff_max_gap * 1000,
                eligible ? "budget exhausted" : "Space/exit/state changed");
        [full_panel_handoff_last_sample release];
        full_panel_handoff_last_sample = nil;
        return;
    }
    @autoreleasepool {
        double gap = uptime - full_panel_handoff_last_uptime;
        full_panel_handoff_max_gap = MAX(full_panel_handoff_max_gap, gap);
        full_panel_handoff_last_uptime = uptime;
        full_panel_handoff_samples++;
        NSString *sample = [NSString stringWithFormat:@"restoreCount=%u %@",
            full_panel_handoff_restores, omacvm_fullpanel_handoff_snapshot(window)];
        double queryMs = ([[NSProcessInfo processInfo] systemUptime] - uptime) * 1000;
        if (![sample isEqualToString:full_panel_handoff_last_sample] || checks == 1) {
            fprintf(stderr, "omacvm: FULLPANEL HANDOFF sample t=%.6f uptime=%.6f targetNumber=%ld generation=%u sample=%u queryMs=%.3f gapMs=%.3f state={%s}; metadata cannot identify displayed text or snapshot/live IOSurface handoff\n",
                    epoch, uptime, (long)[window windowNumber],
                    generation, full_panel_handoff_samples, queryMs, gap * 1000,
                    [sample UTF8String]);
            [full_panel_handoff_last_sample release];
            full_panel_handoff_last_sample = [sample copy];
        }
    }
    /* Reuse the existing return probe's cadence/budget, for observation only.
     * No transparency transaction, redraw, frame, alpha or ordering change.
     */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 120),
                   dispatch_get_main_queue(), ^{
        [self sampleHandoffTrace:generation checksLeft:checks - 1];
    });
}

/* V2 has no Mission Control-specific callback. Match its key/app/display
 * events only during an established Space departure/return, including normal
 * Space switching. Never arm from initial fullscreen entry or windowed mode.
 */
- (void)noteV2ReturnDeparture
{
    if (omacvm_fullpanel_v2_return_enabled() && !full_panel_v2_return_armed &&
        in_full_screen_space && full_screen_frame_kept && full_panel_frame_accepted &&
        !camera_housing_area_lost && menu_bar_hidden_space &&
        ([window styleMask] & NSWindowStyleMaskFullScreen) && ![window isOnActiveSpace]) {
        full_panel_v2_return_armed = true;
        full_panel_v2_return_generation++;
        FP_DIAG(window, "V2 RETURN armed", false, @"established Space departed");
    }
}

- (bool)v2ReturnEligible
{
    return omacvm_fullpanel_v2_return_enabled() && full_panel_v2_return_armed &&
        in_full_screen_space && full_screen_frame_kept && full_panel_frame_accepted &&
        !camera_housing_area_lost && menu_bar_hidden_space &&
        ([window styleMask] & NSWindowStyleMaskFullScreen) &&
        !menu_bar_revealed && !toolbar_revealed && !menu_bar_reveal_allowed &&
        [self usable] && [window screen] &&
        omacvm_camera_rect_equal([window frame], [[window screen] frame]) &&
        omacvm_camera_fullscreen_space_id(window) == menu_bar_hidden_space;
}

- (void)reassertV2Return:(NSString *)reason
{
    if (![self v2ReturnEligible]) {
        return;
    }
    /* V2 sends alpha first, even when the target is not key. Keep the current
     * reveal/geometry gates and exact owned Space, and do not touch toolbar
     * views or the VM surface. Its presentation condition is key OR app-active.
     */
    FP_DIAG(window, "V2 RETURN reassert", false, @"reason=%@ space=%llu", reason,
            (unsigned long long)menu_bar_hidden_space);
    omacvm_camera_set_menu_alpha(window, menu_bar_hidden_space, 0.0f, "v2 return experiment");
    if ([window isKeyWindow] || [NSApp isActive]) {
        NSApplicationPresentationOptions options = NSApplicationPresentationFullScreen |
            NSApplicationPresentationHideMenuBar | NSApplicationPresentationHideDock;
        presentation_forced = true;
        if ([NSApp presentationOptions] != options) {
            FP_DIAG(window, "V2 RETURN presentation request", true, @"reason=%@ options=%llu",
                    reason, (unsigned long long)options);
            [NSApp setPresentationOptions:options];
        }
    }
}

- (void)v2ReturnNotification:(NSNotification *)notification
{
    if (![NSThread isMainThread] || ![self v2ReturnEligible]) {
        return;
    }
    NSString *reason = [notification name];
    if ([reason isEqualToString:NSWindowDidBecomeKeyNotification]) {
        reason = [notification object] == window ? @"main-key" : @"other-key";
    }
    unsigned generation = full_panel_v2_return_generation;
    full_panel_v2_return_batches++;
    [self reassertV2Return:[reason stringByAppendingString:@" immediate"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (generation == full_panel_v2_return_generation) {
            [self reassertV2Return:[reason stringByAppendingString:@" +150ms"]];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (generation != full_panel_v2_return_generation) {
            return; /* Exit/re-entry invalidates old callbacks. */
        }
        [self reassertV2Return:[reason stringByAppendingString:@" +600ms"]];
        full_panel_v2_return_batches--;
        if (!full_panel_v2_return_batches && [window isOnActiveSpace] && [window isKeyWindow]) {
            full_panel_v2_return_armed = false;
            FP_DIAG(window, "V2 RETURN finished", false, @"event burst completed");
        }
    });
}

/* Mission Control may rebuild its menu-bar/compositor state while retaining
 * our physical window frame and Space ID. Refresh immediately when eligible,
 * then observe WindowServer until its transition is complete, including when
 * that Space ID has not changed. Coalesce recursive/overlapping return events.
 * This never reacquires geometry or changes reveal policy.
 */
- (void)scheduleFullPanelRefresh:(NSString *)reason
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scheduleFullPanelRefresh:reason];
        });
        return;
    }
    if ([self v2ParityManaged]) {
        FP_DIAG(window, "V2 PARITY bypass automatic refresh", false, @"reason=%@", reason);
        return;
    }
    if (full_panel_refresh_pending) {
        return;
    }
    full_panel_refresh_pending = true;
    full_panel_compositor_wait_logged = false;
    full_panel_early_hide_sent = false;
    [self refreshFullPanelForReason:
        [NSString stringWithFormat:@"return immediate: %@", reason]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishFullPanelReturn:reason checksLeft:240];
    });
    [self startHandoffTrace:reason];
}

/* Bounded observation of this return only, not a repeating repair loop.
 * Re-check exit/eligibility on each turn; apply alpha only after the real
 * window reaches its full frame. Two seconds without that evidence expires.
 */
- (void)finishFullPanelReturn:(NSString *)reason checksLeft:(unsigned)checks
{
    if ([self refreshFullPanelForReason:
            [NSString stringWithFormat:@"return compositor settled: %@", reason]]) {
        full_panel_refresh_pending = false;
        return;
    }
    if (!checks) {
        full_panel_refresh_pending = false;
        FP_DIAG(window, "FULLPANEL return timeout", false, @"reason=%@; no frame forced", reason);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 120),
                   dispatch_get_main_queue(), ^{
        [self finishFullPanelReturn:reason checksLeft:checks - 1];
    });
}

/* True means finished or ineligible; false means wait for the compositor. */
- (bool)refreshFullPanelForReason:(NSString *)reason
{
    if ([self v2ParityManaged]) {
        return true; /* Also cancel a queued pre-entry compositor refresh. */
    }
    if (!in_full_screen_space || !full_screen_frame_kept ||
        !full_panel_frame_accepted || camera_housing_area_lost ||
        !menu_bar_hidden_space ||
        !([window styleMask] & NSWindowStyleMaskFullScreen) ||
        ![window isKeyWindow] || ![window isVisible] ||
        ![window isOnActiveSpace] ||
        !([window occlusionState] & NSWindowOcclusionStateVisible) ||
        ![self usable] || ![window screen] ||
        !omacvm_camera_rect_equal([window frame], [[window screen] frame]) ||
        omacvm_camera_fullscreen_space_id(window) != menu_bar_hidden_space) {
        FP_DIAG(window, "FULLPANEL refresh skipped", false, @"reason=%@", reason);
        return true;
    }
    int compositor = omacvm_fullpanel_compositor_ready(window);
    if (compositor != 1) {
        /* One opt-in alpha reassertion before the compositor settles, only
         * for an eligible full-screen window in its own active type-4 Space.
         * The original compositor-ready refresh below remains authoritative.
         * Do not interfere with an already-revealed menu or toolbar.
         */
        if (compositor == 0 && !full_panel_early_hide_sent &&
            omacvm_fullpanel_early_hide_enabled() &&
            !menu_bar_revealed && !toolbar_revealed) {
            full_panel_early_hide_sent = true;
            FP_DIAG(window, "FULLPANEL early menu-alpha reassert", false,
                    @"reason=%@ space=%llu; compositor still transformed",
                    reason, (unsigned long long)menu_bar_hidden_space);
            omacvm_camera_set_menu_alpha(window, menu_bar_hidden_space,
                                         0.0f, "experimental early hide");
        }
        if (!full_panel_compositor_wait_logged || compositor < 0) {
            full_panel_compositor_wait_logged = true;
            omacvm_fullpanel_flicker_trace(window, "compositor pending");
            FP_DIAG(window, "FULLPANEL compositor pending", false,
                    @"reason=%@ status=%d; no alpha request before WindowServer settles; repeated wait logs suppressed",
                    reason, compositor);
        }
        return compositor < 0; /* missing evidence: stop, do not force */
    }
    /* Apply before the diagnostic's additional WindowServer/layer queries. */
    omacvm_fullpanel_flicker_trace(window, "compositor ready before restore");
    [self updatePresentationOptions];
    [self applyMenuBarReveal];
    if (omacvm_fullpanel_handoff_trace_enabled()) {
        full_panel_handoff_restores++;
    }
    omacvm_fullpanel_flicker_trace(window, "compositor ready after restore");
    FP_DIAG(window, "FULLPANEL refresh", false,
            @"reason=%@ space=%llu; reapplied existing reveal state, no geometry change",
            reason, (unsigned long long)menu_bar_hidden_space);
    if (omacvm_fullpanel_diagnostic_enabled()) {
        omacvm_fullpanel_compositor_diagnostic(window, "refresh completed");
    }
    return true;
}

- (void)otherWindowDidChangeOcclusionState:(NSNotification *)notification
{
    omacvm_fullpanel_overlay_observed(window, [notification object],
                                     "transition overlay occlusion observed");
    FP_DIAG(window, "OCCLUSION notification", true,
            @"observed name=%@ changedWindow=%p number=%ld class=%@ occlusion=%llu frame=%@",
            [notification name], (void *)[notification object],
            (long)[[notification object] windowNumber],
            NSStringFromClass([[notification object] class]),
            (unsigned long long)[[notification object] occlusionState],
            NSStringFromRect([[notification object] frame]));
    if (!menu_bar_hidden_space) {
        return;
    }
    NSWindow *changed = [notification object];
    if (changed == window) {
        [self noteV2ToolbarHandoffDeparture];
    }
    if (changed == window ||
        [NSStringFromClass([changed class]) isEqualToString:@"NSToolbarFullScreenWindow"]) {
        omacvm_fullpanel_flicker_trace(window, "window or toolbar occlusion changed");
    }
    if (changed == window &&
        ([window occlusionState] & NSWindowOcclusionStateVisible)) {
        [self scheduleFullPanelRefresh:@"window became visible"];
    }
    if (changed && changed == [self fullScreenToolbarWindow] &&
        (![self v2ParityManaged] || menu_bar_reveal_allowed)) {
        [self applyMenuBarReveal];
    }
}

- (void)traceTransitionOverlayClose:(NSNotification *)notification
{
    omacvm_fullpanel_overlay_observed(window, [notification object],
                                     "transition overlay will close observed");
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    omacvm_fullpanel_flicker_trace(window, "window became key");
    FP_DIAG(window, "CALLBACK windowDidBecomeKey", true, @"observed name=%@", [notification name]);
    if (![self v2ParityManaged] || menu_bar_reveal_allowed) {
        [self updatePresentationOptions];
    }
    [self scheduleFullPanelRefresh:@"window became key"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    if ([keyPath isEqualToString:@"currentSystemPresentationOptions"]) {
        FP_DIAG(window, "PRESENTATION observed", true,
                @"keyPath=%@ object=%p change=%@; KVO is observation, not proof of resize cause",
                keyPath, (void *)object, change);
        omacvm_fullpanel_flicker_trace(window, "system presentation observed");
        dispatch_async(dispatch_get_main_queue(), ^{
            FP_DIAG(window, "PRESENTATION queued update", false, @"from KVO");
            if (![self v2ParityManaged] || menu_bar_reveal_allowed) {
                [self updatePresentationOptions];
            }
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object
                           change:change context:context];
}

@end

static void omacvm_camera_prepare_window(NSWindow *window)
{
    if (!omacvm_camera_housing_requested() || !window) {
        return;
    }
    if (omacvm_camera_state(window)) {
        return;
    }

    bool frame = omacvm_camera_install_frame_hook([window class]);
    bool sky = omacvm_camera_load_skylight();
    bool reveal = omacvm_camera_install_reveal_observer();

    OmacVMCameraHousingState *state =
        [[OmacVMCameraHousingState alloc] initWithWindow:window];
    objc_setAssociatedObject(window, &omacvm_camera_state_key, state,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [state release];

    if (!frame || !sky || !reveal) {
        fprintf(stderr,
                "omacvm: full panel: a private dependency is unavailable; this window will use normal full screen\n");
    }
}

static bool omacvm_camera_keep_set_frame(NSWindow *window,
                                         NSRect proposed, bool display)
{
    OmacVMCameraHousingState *state = omacvm_camera_state(window);
    return state && [state keepSetFrame:proposed display:display];
}

'''

replace_once('@implementation QemuWindow\n',
             helper + '\n@implementation QemuWindow\n',
             "QemuWindow implementation")

replace_once(
    '''@implementation QemuWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end
''',
    '''@implementation QemuWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)toggleFullScreen:(id)sender
{
    if (!([self styleMask] & NSWindowStyleMaskFullScreen)) {
        omacvm_camera_prepare_window(self);
    }
    [super toggleFullScreen:sender];
}
- (void)setFrame:(NSRect)frameRect display:(BOOL)flag
{
    FP_DIAG(self, "SET FRAME enter", true, @"selector=%@ requested=%@ display=%d",
            NSStringFromSelector(_cmd), NSStringFromRect(frameRect), (int)flag);
    bool kept = omacvm_camera_keep_set_frame(self, frameRect, flag);
    FP_DIAG(self, "SET FRAME decision", false, @"kept=%d requested=%@", kept, NSStringFromRect(frameRect));
    if (kept) {
        FP_DIAG(self, "SET FRAME result", false, @"superCalled=0 kept=1");
        return;
    }
    [super setFrame:frameRect display:flag];
    FP_DIAG(self, "SET FRAME result", false, @"superCalled=1 requested=%@", NSStringFromRect(frameRect));
}
- (void)setFrame:(NSRect)frameRect display:(BOOL)flag animate:(BOOL)animate
{
    FP_DIAG(self, "SET FRAME enter", true, @"selector=%@ requested=%@ display=%d animate=%d",
            NSStringFromSelector(_cmd), NSStringFromRect(frameRect), (int)flag, (int)animate);
    bool kept = omacvm_camera_keep_set_frame(self, frameRect, flag);
    FP_DIAG(self, "SET FRAME decision", false, @"kept=%d requested=%@", kept, NSStringFromRect(frameRect));
    if (kept) {
        FP_DIAG(self, "SET FRAME result", false, @"superCalled=0 kept=1");
        return;
    }
    [super setFrame:frameRect display:flag animate:animate];
    FP_DIAG(self, "SET FRAME result", false, @"superCalled=1 requested=%@", NSStringFromRect(frameRect));
}
@end
''',
    "QemuWindow methods"
)

replace_once(
    '''@implementation OmacVMHeadWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
''',
    '''@implementation OmacVMHeadWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)toggleFullScreen:(id)sender
{
    if (!([self styleMask] & NSWindowStyleMaskFullScreen)) {
        omacvm_camera_prepare_window(self);
    }
    [super toggleFullScreen:sender];
}
- (void)setFrame:(NSRect)frameRect display:(BOOL)flag
{
    FP_DIAG(self, "SET FRAME enter", true, @"selector=%@ requested=%@ display=%d",
            NSStringFromSelector(_cmd), NSStringFromRect(frameRect), (int)flag);
    bool kept = omacvm_camera_keep_set_frame(self, frameRect, flag);
    FP_DIAG(self, "SET FRAME decision", false, @"kept=%d requested=%@", kept, NSStringFromRect(frameRect));
    if (kept) {
        FP_DIAG(self, "SET FRAME result", false, @"superCalled=0 kept=1");
        return;
    }
    [super setFrame:frameRect display:flag];
    FP_DIAG(self, "SET FRAME result", false, @"superCalled=1 requested=%@", NSStringFromRect(frameRect));
}
- (void)setFrame:(NSRect)frameRect display:(BOOL)flag animate:(BOOL)animate
{
    FP_DIAG(self, "SET FRAME enter", true, @"selector=%@ requested=%@ display=%d animate=%d",
            NSStringFromSelector(_cmd), NSStringFromRect(frameRect), (int)flag, (int)animate);
    bool kept = omacvm_camera_keep_set_frame(self, frameRect, flag);
    FP_DIAG(self, "SET FRAME decision", false, @"kept=%d requested=%@", kept, NSStringFromRect(frameRect));
    if (kept) {
        FP_DIAG(self, "SET FRAME result", false, @"superCalled=0 kept=1");
        return;
    }
    [super setFrame:frameRect display:flag animate:animate];
    FP_DIAG(self, "SET FRAME result", false, @"superCalled=1 requested=%@", NSStringFromRect(frameRect));
}
@end
''',
    "OmacVMHeadWindow methods"
)

# Instrument the existing delegate callbacks too: the state observer is only
# one recipient of a resize notification. No callback is treated as a cause.
import re
s, resize_count = re.subn(
    r'(- \(void\)windowDidResize:\(NSNotification \*\)(\w+)\n\{\n)',
    lambda m: m[1] +
        '    FP_DIAG([' + m[2] + ' object], "RESIZE delegate observed", true, '
        '@"notification=%@; observer stack does not establish cause", [' + m[2] + ' name]);\n',
    s)
if resize_count < 3:
    raise SystemExit(f"resize diagnostics: expected state and two delegates, found {resize_count}")

# These alternate public geometry paths may bypass the existing two frame
# guards. AppKit can constrain even a no-op origin change internally. Apply
# the same retention gate before entering these setters; never repair a frame.
geometry_diagnostics = r'''
- (void)setFrameOrigin:(NSPoint)point
{
    FP_DIAG(self, "GEOMETRY enter", true, @"selector=%@ origin=%@", NSStringFromSelector(_cmd), NSStringFromPoint(point));
    NSRect proposed = [self frame];
    proposed.origin = point;
    if (omacvm_camera_keep_set_frame(self, proposed, false)) {
        FP_DIAG(self, "GEOMETRY protected", false, @"selector=%@ superCalled=0", NSStringFromSelector(_cmd));
        return;
    }
    [super setFrameOrigin:point];
    FP_DIAG(self, "GEOMETRY result", false, @"selector=%@", NSStringFromSelector(_cmd));
}
- (void)setFrameTopLeftPoint:(NSPoint)point
{
    FP_DIAG(self, "GEOMETRY enter", true, @"selector=%@ topLeft=%@", NSStringFromSelector(_cmd), NSStringFromPoint(point));
    NSRect proposed = [self frame];
    proposed.origin = NSMakePoint(point.x, point.y - proposed.size.height);
    if (omacvm_camera_keep_set_frame(self, proposed, false)) {
        FP_DIAG(self, "GEOMETRY protected", false, @"selector=%@ superCalled=0", NSStringFromSelector(_cmd));
        return;
    }
    [super setFrameTopLeftPoint:point];
    FP_DIAG(self, "GEOMETRY result", false, @"selector=%@", NSStringFromSelector(_cmd));
}
- (void)setContentSize:(NSSize)size
{
    FP_DIAG(self, "GEOMETRY enter", true, @"selector=%@ contentSize=%@", NSStringFromSelector(_cmd), NSStringFromSize(size));
    NSRect proposed = [self frame];
    proposed.size = size;
    if (omacvm_camera_keep_set_frame(self, proposed, false)) {
        FP_DIAG(self, "GEOMETRY protected", false, @"selector=%@ superCalled=0", NSStringFromSelector(_cmd));
        return;
    }
    [super setContentSize:size];
    FP_DIAG(self, "GEOMETRY result", false, @"selector=%@", NSStringFromSelector(_cmd));
}
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen
{
    FP_DIAG(self, "CONSTRAIN enter", true, @"requested=%@ targetScreen=%p", NSStringFromRect(frameRect), (void *)screen);
    NSRect result = [super constrainFrameRect:frameRect toScreen:screen];
    FP_DIAG(self, "CONSTRAIN result", false, @"requested=%@ result=%@", NSStringFromRect(frameRect), NSStringFromRect(result));
    return result;
}
'''
for cls in ("QemuWindow", "OmacVMHeadWindow"):
    anchor = f"@implementation {cls}\n"
    if s.count(anchor) != 1:
        raise SystemExit(f"geometry diagnostics: missing unique {cls}")
    s = s.replace(anchor, anchor + geometry_diagnostics, 1)

path.write_text(s)
print(f"camera-housing fullscreen applied to {path}")
