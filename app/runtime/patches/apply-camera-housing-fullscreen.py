#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-camera-housing-fullscreen.py PATH/TO/ui/cocoa.m")

path = Path(sys.argv[1])
s = path.read_text()
MARK = "OmacVM: UTM-style camera-housing fullscreen"
if MARK in s:
    # A lone marker is not a complete patch. Refuse partial/changed injection
    # instead of reporting success after an interrupted or foreign edit.
    applied_anchors = {
        MARK: 2,
        "@implementation OmacVMCameraHousingState": 1,
        "static int omacvm_fullpanel_compositor_ready(NSWindow *w)": 1,
        "- (void)activeSpaceChanged:(NSNotification *)notification\n{": 1,
        "- (void)setFrame:(NSRect)frameRect display:(BOOL)flag animate:(BOOL)animate": 2,
        "- (void)setFrameOrigin:(NSPoint)point": 2,
        "- (void)setFrameTopLeftPoint:(NSPoint)point": 2,
        "- (void)setContentSize:(NSSize)size": 2,
    }
    for anchor, count in applied_anchors.items():
        if s.count(anchor) != count:
            raise SystemExit(f"camera-housing fullscreen: incomplete patch at {anchor!r}")
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
    if (omacvm_camera_window_usable(window) && [window screen] &&
        [[window screen] safeAreaInsets].top > 0) {
        proposedSize = [[window screen] frame].size;
    }

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

static void omacvm_camera_set_menu_alpha(uint64_t space,
                                         float alpha, const char *reason)
{
    if (!space || !omacvm_camera_load_skylight()) {
        return;
    }
    CFTypeRef transaction = omacvm_camera_sls_transaction_create(
        omacvm_camera_sls_main());
    if (!transaction) {
        fprintf(stderr, "omacvm: full panel: menu transaction unavailable (%s)\n", reason);
        return;
    }

    omacvm_camera_sls_menu_alpha(transaction, space, alpha);

    int32_t result = omacvm_camera_sls_transaction_commit(transaction, 1);
    if (result) {
        fprintf(stderr, "omacvm: full panel: menu transaction failed (%s): %d\n",
                reason, (int)result);
    }

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
    bool workspace_observing;
    bool full_panel_refresh_pending;
}
- (id)initWithWindow:(NSWindow *)w;
- (bool)usable;
- (NSRect)fullScreenFrameForAppKitFrame:(NSRect)frame;
- (bool)keepSetFrame:(NSRect)proposed display:(bool)display;
- (void)menuRevealChanged:(bool)menu toolbar:(bool)toolbar;
- (void)activeSpaceChanged:(NSNotification *)notification;
- (void)scheduleFullPanelRefresh:(NSString *)reason;
- (bool)refreshFullPanelForReason:(NSString *)reason;
- (void)finishFullPanelReturn:(NSString *)reason checksLeft:(unsigned)checks;
@end

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
                [state menuRevealChanged:menu toolbar:toolbar];

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
    NSRect frame = omacvm_camera_appkit_frame ?
        omacvm_camera_appkit_frame(object, selector) : [(NSWindow *)object frame];
    OmacVMCameraHousingState *state =
        omacvm_camera_state((NSWindow *)object);
    NSRect result = state ? [state fullScreenFrameForAppKitFrame:frame] : frame;

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

- (id)initWithWindow:(NSWindow *)w
{
    self = [super init];
    if (!self) {
        return nil;
    }
    window = w;

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
    [center addObserver:self selector:@selector(otherWindowDidChangeOcclusionState:)
                   name:NSWindowDidChangeOcclusionStateNotification object:nil];
    [center addObserver:self selector:@selector(windowDidBecomeKey:)
                   name:NSWindowDidBecomeKeyNotification object:w];

    return self;
}

- (void)dealloc
{
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

    return screen_frame;
}

- (bool)keepSetFrame:(NSRect)proposed display:(bool)display
{
    if (!full_screen_frame_kept || !full_panel_frame_accepted ||
        !([window styleMask] & NSWindowStyleMaskFullScreen) ||
        ![self usable] || camera_housing_area_lost || ![window screen]) {
        return false;
    }
    NSRect screen_frame = [[window screen] frame];
    if (!omacvm_camera_rect_equal([window frame], screen_frame)) {
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

    if (fabs(tile.origin.x - screen_frame.origin.x) > 1 ||
        fabs(tile.size.width - screen_frame.size.width) > 1) {
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
    NSWindow *toolbar = [self fullScreenToolbarWindow];
    NSView *content = [toolbar contentView];
    if (!content) {
        return;
    }
    NSView *view = [content superview] ?: content;

    [view setHidden:hidden];
    [toolbar setIgnoresMouseEvents:hidden];
}

- (void)updatePresentationOptions
{
    if (!revealable_presentation_valid) {
        return;
    }

    NSApplicationPresentationOptions options = 0;
    bool have_options = false;
    if (!menu_bar_reveal_allowed && [window isKeyWindow]) {
        options = NSApplicationPresentationFullScreen |
                  NSApplicationPresentationHideMenuBar |
                  NSApplicationPresentationHideDock;
        presentation_forced = true;
        have_options = true;
    } else if (presentation_forced) {
        options = revealable_presentation;
        presentation_forced = false;
        have_options = true;
    }

    if (have_options && [NSApp presentationOptions] != options) {
        [NSApp setPresentationOptions:options];
    }
}

- (void)applyMenuBarReveal
{
    if (!menu_bar_hidden_space) {
        return;
    }
    omacvm_camera_set_menu_alpha(menu_bar_hidden_space,
                                 menu_bar_revealed ? 1.0f : 0.0f,
                                 "applyMenuBarReveal");

    [self setToolbarHidden:!toolbar_revealed];
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
        omacvm_camera_set_menu_alpha(menu_bar_hidden_space, 1.0f,
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
        camera_housing_area_lost = true;
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
    if (menu_bar_revealed == menu && toolbar_revealed == toolbar) {
        return;
    }
    menu_bar_revealed = menu;
    toolbar_revealed = toolbar;
    if (!menu_bar_hidden_space) {
        return;
    }

    [self applyMenuBarReveal];
    if (!menu_bar_revealed) {
        menu_bar_reveal_allowed = false;
        [self updatePresentationOptions];
    }
}

- (void)willEnterFullScreen:(NSNotification *)notification
{
    full_screen_frame_kept = true;

    camera_housing_area_lost = false;
    (void)[self usable];
}

- (void)didEnterFullScreen:(NSNotification *)notification
{
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
}

- (void)windowDidResize:(NSNotification *)notification
{
    if (in_full_screen_space) {
        [self updateMenuBarHidden];
    }
}

- (void)willLeaveFullScreen:(NSNotification *)notification
{
    full_screen_frame_kept = false;
    full_panel_frame_accepted = false;
    full_panel_safe_tile_requery_logged = false;
    full_panel_frame_reject_logged = false;
    in_full_screen_space = false;

    camera_housing_area_lost = false;
    menu_bar_revealed = false;
    toolbar_revealed = false;
    [self showMenuBar];
}

- (void)activeSpaceChanged:(NSNotification *)notification
{
    [self scheduleFullPanelRefresh:@"active Space changed"];
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

    if (full_panel_refresh_pending) {
        return;
    }
    full_panel_refresh_pending = true;
    [self refreshFullPanelForReason:
        [NSString stringWithFormat:@"return immediate: %@", reason]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishFullPanelReturn:reason checksLeft:240];
    });
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
        fprintf(stderr, "omacvm: full panel: return timed out (%s); no frame forced\n",
                [reason UTF8String]);
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
        return true;
    }
    int compositor = omacvm_fullpanel_compositor_ready(window);
    if (compositor != 1) {
        return compositor < 0; /* missing evidence: stop, do not force */
    }

    [self updatePresentationOptions];
    [self applyMenuBarReveal];

    return true;
}

- (void)otherWindowDidChangeOcclusionState:(NSNotification *)notification
{
    if (!menu_bar_hidden_space) {
        return;
    }
    NSWindow *changed = [notification object];

    if (changed == window &&
        ([window occlusionState] & NSWindowOcclusionStateVisible)) {
        [self scheduleFullPanelRefresh:@"window became visible"];
    }
    if (changed && changed == [self fullScreenToolbarWindow]) {
        [self applyMenuBarReveal];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    [self updatePresentationOptions];

    [self scheduleFullPanelRefresh:@"window became key"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    if ([keyPath isEqualToString:@"currentSystemPresentationOptions"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updatePresentationOptions];
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
    bool kept = omacvm_camera_keep_set_frame(self, frameRect, flag);

    if (kept) {
        return;
    }
    [super setFrame:frameRect display:flag];
}
- (void)setFrame:(NSRect)frameRect display:(BOOL)flag animate:(BOOL)animate
{
    bool kept = omacvm_camera_keep_set_frame(self, frameRect, flag);

    if (kept) {
        return;
    }
    [super setFrame:frameRect display:flag animate:animate];
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
    bool kept = omacvm_camera_keep_set_frame(self, frameRect, flag);

    if (kept) {
        return;
    }
    [super setFrame:frameRect display:flag];
}
- (void)setFrame:(NSRect)frameRect display:(BOOL)flag animate:(BOOL)animate
{
    bool kept = omacvm_camera_keep_set_frame(self, frameRect, flag);

    if (kept) {
        return;
    }
    [super setFrame:frameRect display:flag animate:animate];
}
@end
''',
    "OmacVMHeadWindow methods"
)

# These alternate public geometry paths may bypass the existing two frame
# guards. AppKit can constrain even a no-op origin change internally. Apply
# the same retention gate before entering these setters; never repair a frame.
geometry_guards = r'''
- (void)setFrameOrigin:(NSPoint)point
{
    NSRect proposed = [self frame];
    proposed.origin = point;
    if (omacvm_camera_keep_set_frame(self, proposed, false)) {
        return;
    }
    [super setFrameOrigin:point];
}
- (void)setFrameTopLeftPoint:(NSPoint)point
{
    NSRect proposed = [self frame];
    proposed.origin = NSMakePoint(point.x, point.y - proposed.size.height);
    if (omacvm_camera_keep_set_frame(self, proposed, false)) {
        return;
    }
    [super setFrameTopLeftPoint:point];
}
- (void)setContentSize:(NSSize)size
{
    NSRect proposed = [self frame];
    proposed.size = size;
    if (omacvm_camera_keep_set_frame(self, proposed, false)) {
        return;
    }
    [super setContentSize:size];
}

'''
for cls in ("QemuWindow", "OmacVMHeadWindow"):
    anchor = f"@implementation {cls}\n"
    if s.count(anchor) != 1:
        raise SystemExit(f"geometry guards: missing unique {cls}")
    s = s.replace(anchor, anchor + geometry_guards, 1)

path.write_text(s)
print(f"camera-housing fullscreen applied to {path}")
