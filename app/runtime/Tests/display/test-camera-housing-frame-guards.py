#!/usr/bin/env python3
"""Test generated geometry setters against a fake AppKit shrink, without a VM."""
import ast
from pathlib import Path
import subprocess
import sys
import tempfile

transformer = Path(__file__).resolve().parents[2] / "patches/apply-camera-housing-fullscreen.py"
tree = ast.parse(transformer.read_text())

def literal_assignment(name):
    return next(ast.literal_eval(n.value) for n in tree.body
                if isinstance(n, ast.Assign) and any(
                    isinstance(t, ast.Name) and t.id == name for t in n.targets))

helper = literal_assignment("helper")
ABANDONED_FLAGS = (
    "DIAGNOSTIC", "FLICKER_TRACE", "HANDOFF_TRACE", "V2_PARITY", "EARLY_HIDE",
    "PASSIVE_PRESENTATION", "V2_RETURN", "V2_TOOLBAR_HANDOFF",
)
for flag_name in ABANDONED_FLAGS:
    assert "OMACVM_FULLPANEL_" + flag_name not in transformer.read_text(), flag_name
for removed in ("v2ParityManaged", "v2ToolbarHandoffActive", "noteV2ReturnDeparture",
                "noteHandoffDeparture", "sampleHandoffTrace", "FP_DIAG"):
    assert removed not in helper, removed
geometry = literal_assignment("geometry_guards")
# Execute the existing clean-size patch's predicate. The rejected Full Panel
# trim bypass is gone; both Full Panel and Native retain their scale presets.
size_patch = (transformer.parent / "omacvm-cocoa-clean-size.patch").read_text().splitlines()
size_index = next(i for i, line in enumerate(size_patch)
                  if line.startswith("+        full = isFullscreen"))
size_condition = "\n".join(line[1:] for line in size_patch[size_index:size_index + 2]) + "\n"
assert "Full Panel bypasses scale-preset height trim" not in transformer.read_text()
forward = next(ast.literal_eval(n.args[1]) for n in ast.walk(tree)
               if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
               and n.func.id == "replace_once"
               and ast.literal_eval(n.args[0]) == "static CGFloat omacvm_main_full_top = -1;\n")
# Replay the real transformer on its verified anchor fixture. The fixture is
# deliberately not a complete QEMU translation unit; compile its generated
# helper and window methods below against fake AppKit instead.
original_anchors = []
for node in ast.walk(tree):
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
            and node.func.id == "replace_once" and isinstance(node.args[0], ast.Constant)):
        original_anchors.append(ast.literal_eval(node.args[0]))
fixture_anchors = [a for a in original_anchors if not any(a != b and a in b for b in original_anchors)]
fixture = "\n".join(fixture_anchors) + size_condition
with tempfile.TemporaryDirectory(prefix="fullpanel-transform-") as directory:
    cocoa = Path(directory) / "cocoa.m"
    cocoa.write_text(fixture)
    subprocess.run([sys.executable, str(transformer), str(cocoa)], check=True, capture_output=True)
    generated = cocoa.read_text()
    subprocess.run(["bash", str(transformer.parents[1] / "Tests/display/test-camera-housing-fullscreen.sh"),
                    str(cocoa)], check=True)
    subprocess.run([sys.executable, str(transformer), str(cocoa)], check=True, capture_output=True)
    assert cocoa.read_text() == generated
    for anchor in fixture_anchors:
        for broken in (fixture.replace(anchor, "", 1), fixture + "\n" + anchor):
            cocoa.write_text(broken)
            result = subprocess.run([sys.executable, str(transformer), str(cocoa)], capture_output=True)
            assert result.returncode != 0, anchor
            assert cocoa.read_text() == broken, anchor
    cocoa.write_text(literal_assignment("MARK"))
    result = subprocess.run([sys.executable, str(transformer), str(cocoa)], capture_output=True)
    assert result.returncode != 0
    assert cocoa.read_text() == literal_assignment("MARK")
    print("camera-housing transformation: PASS (source checks, idempotence, missing/duplicate anchors, partial marker)")

prefix = """#import <Cocoa/Cocoa.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <math.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "omacvm-clean-size.h"
static int test_compositor = 1;
static unsigned test_window_queries;
/* Mock WindowServer bounds, without creating a real window. */
CFArrayRef CGWindowListCopyWindowInfo(CGWindowListOption option, CGWindowID wid)
{
    test_window_queries++;
    if (test_compositor < 0) { return NULL; }
    CGRect rect = test_compositor ? CGRectMake(0, 0, 1800, 1169) :
                                   CGRectMake(322, 280, 1157, 751);
    CFDictionaryRef bounds = CGRectCreateDictionaryRepresentation(rect);
    NSArray *result = [[NSArray alloc] initWithObjects:
        @{(id)kCGWindowNumber: @(wid), (id)kCGWindowBounds: (NSDictionary *)bounds}, nil];
    CFRelease(bounds);
    return (CFArrayRef)result;
}
"""
fake = r'''
static NSRect test_tile;
static bool test_usable = true;
static uint64_t test_space = 42;
static int32_t test_space_type = 4;
static NSRect tile(id object, SEL selector) { return test_tile; }
static int32_t connection(void) { return 1; }
static CFArrayRef spaces(int32_t cid, int32_t mask, CFArrayRef windows)
{ return (CFArrayRef)[[NSArray alloc] initWithObjects:@(test_space), nil]; }
static int32_t space_type(int32_t cid, uint64_t space) { return test_space_type; }
@interface FakeScreen : NSObject
@property NSRect frame;
@property CGFloat notch;
@end
@implementation FakeScreen
- (NSEdgeInsets)safeAreaInsets { return (NSEdgeInsets){_notch, 0, 0, 0}; }
@end

@interface TestState : OmacVMCameraHousingState
@property int presentationUpdates;
@property int revealUpdates;
@end
@implementation TestState
- (bool)usable { return test_usable && [[window screen] safeAreaInsets].top > 0; }
- (void)updatePresentationOptions { _presentationUpdates++; }
- (void)applyMenuBarReveal { _revealUpdates++; }
@end

/* Exercise the actual presentation method without creating NSApplication. */
@interface FakePresentationApp : NSObject
@property NSApplicationPresentationOptions current;
@property unsigned writes;
@property(getter=isActive) bool active;
@end
@implementation FakePresentationApp
- (NSApplicationPresentationOptions)presentationOptions { return _current; }
- (void)setPresentationOptions:(NSApplicationPresentationOptions)options
{ _current = options; _writes++; }
@end

@interface PresentationTestState : OmacVMCameraHousingState
@end
@implementation PresentationTestState
- (bool)usable { return true; }
@end

@interface FakeBaseWindow : NSObject
@property NSRect frame;
@property NSWindowStyleMask styleMask;
@property(retain) FakeScreen *screen;
@property int writes;
@property(getter=isKeyWindow) bool keyWindow;
@property(getter=isVisible) bool visible;
@property(getter=isOnActiveSpace) bool onActiveSpace;
@property NSWindowOcclusionState occlusionState;
@end
@implementation FakeBaseWindow
- (void)toggleFullScreen:(id)sender {}
- (void)display {}
- (void)setFrame:(NSRect)rect display:(BOOL)flag
{ _writes++; _frame = rect; _frame.size.height = 1130; }
- (void)setFrame:(NSRect)rect display:(BOOL)flag animate:(BOOL)animate
{ _writes++; _frame = rect; _frame.size.height = 1130; }
- (NSInteger)windowNumber { return 7; }
- (NSView *)contentView { return nil; }
- (CGFloat)alphaValue { return 1; }
- (BOOL)isOpaque { return YES; }
/* Reproduce an internal AppKit constraint which bypasses setFrame overrides.
 * In particular a no-op origin setter drops 39pt despite safeTop reporting 38.
 */
- (void)setFrameOrigin:(NSPoint)point
{ _writes++; _frame.origin = point; _frame.size.height = 1130; }
- (void)setFrameTopLeftPoint:(NSPoint)point
{ _writes++; _frame.origin = NSMakePoint(point.x, point.y - _frame.size.height); _frame.size.height = 1130; }
- (void)setContentSize:(NSSize)size
{ _writes++; _frame.size = size; _frame.size.height = 1130; }
- (NSRect)constrainFrameRect:(NSRect)rect toScreen:(NSScreen *)screen { return rect; }
@end

/* Exercise the real toolbar-view writes without an NSWindow/NSApplication. */
@interface FakeToolbarView : NSObject
@property(nonatomic, getter=isHidden) bool hidden;
@property unsigned writes;
@end
@implementation FakeToolbarView
- (NSView *)superview { return nil; }
- (void)setHidden:(bool)hidden { _hidden = hidden; _writes++; }
@end
@interface FakeToolbarWindow : NSObject
@property(retain) FakeToolbarView *contentView;
@property bool ignoresMouseEvents;
@end
@implementation FakeToolbarWindow
@end
@interface ToolbarTestState : OmacVMCameraHousingState
@property(retain) FakeToolbarWindow *toolbar;
@end
@implementation ToolbarTestState
- (bool)usable { return test_usable && [[window screen] safeAreaInsets].top > 0; }
- (NSWindow *)fullScreenToolbarWindow { return (NSWindow *)_toolbar; }
@end
'''
fake += r'''
static bool test_present_layer = true;
static bool omacvm_present_layer(void) { return test_present_layer; }
@interface SizeTestView : NSObject
@property(retain) FakeBaseWindow *window;
@end
@implementation SizeTestView
- (OmacVMSize)preferredSize:(bool)isFullscreen
{
    bool full = false;
''' + size_condition + r'''
    return omacvm_clean_size(3600, 2338, 2, full);
}
@end
'''
window_methods = {}
for node in ast.walk(tree):
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
            and node.func.id == "replace_once" and len(node.args) == 3
            and isinstance(node.args[2], ast.Constant)
            and node.args[2].value in ("QemuWindow methods", "OmacVMHeadWindow methods")):
        name = "GuardedMainWindow" if node.args[2].value == "QemuWindow methods" else "GuardedHeadWindow"
        implementation = ast.literal_eval(node.args[1])
        body = implementation[implementation.index("\n") + 1:implementation.rindex("@end")]
        window_methods[name] = body
windows = "\n".join(
    "@interface " + cls + " : FakeBaseWindow\n@end\n@implementation " + cls
    + "\n" + geometry + window_methods[cls] + "\n@end\n"
    for cls in ("GuardedMainWindow", "GuardedHeadWindow"))
test = r'''
static void flag(TestState *state, NSString *key, bool value)
{ [state setValue:@(value) forKey:key]; }

int main(void)
{
    @autoreleasepool {
        /* Reproduce the restored scaling trim with the original predicate
         * and real clean-size helper, for Full Panel as well as Native.
         */
        for (int fullscreen = 0; fullscreen < 2; fullscreen++) {
            for (int layer = 0; layer < 2; layer++) {
                for (int notch = 0; notch < 2; notch++) {
                    for (int mode = 0; mode < 3; mode++) {
                        FakeScreen *s = [FakeScreen new];
                        s.notch = notch ? 38 : 0;
                        FakeBaseWindow *w = [FakeBaseWindow new];
                        w.screen = s;
                        TestState *state = [TestState new];
                        [state setValue:w forKey:@"window"];
                        if (mode) {
                            objc_setAssociatedObject(w, &omacvm_camera_state_key,
                                state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        }
                        test_usable = mode != 2; /* private APIs unavailable */
                        test_present_layer = layer;
                        SizeTestView *view = [SizeTestView new];
                        view.window = w;
                        OmacVMSize size = [view preferredSize:fullscreen];
                        bool trim = fullscreen && layer && notch;
                        assert(size.w == 3600 && size.h == (trim ? 2328 : 2338));
                        assert(w.writes == 0);
                        view.window = nil;
                        objc_setAssociatedObject(w, &omacvm_camera_state_key,
                                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        [view release]; [state release]; [w release]; [s release];
                    }
                }
            }
        }
        test_usable = true;
        puts("camera-housing scaling: PASS (24 sizing cases; original Full Panel/Native trim restored)");
        omacvm_camera_tile_frame = tile;
        NSRect physical = NSMakeRect(0, 0, 1800, 1169);
        NSRect safe = NSMakeRect(0, 0, 1800, 1130);
        /* Primary-screen coordinates are fixed for these synthetic windows. */
        Method screensMethod = class_getClassMethod([NSScreen class], @selector(screens));
        IMP originalScreens = method_setImplementation(screensMethod,
            imp_implementationWithBlock(^NSArray *(id cls) {
                FakeScreen *screen = [[[FakeScreen alloc] init] autorelease];
                screen.frame = physical; screen.notch = 38;
                return @[screen];
            }));

        /* Initial safe tiles never authorize FullPanel; exact safe re-queries
         * are accepted only after the physical frame, never Split View. */
        for (int scenario = 0; scenario < 10; scenario++) {
            TestState *state = [TestState new];
            FakeScreen *screen = [FakeScreen new];
            screen.frame = physical; screen.notch = 39;
            FakeBaseWindow *w = [FakeBaseWindow new];
            w.frame = physical; w.screen = screen;
            w.styleMask = NSWindowStyleMaskFullScreen;
            [state setValue:w forKey:@"window"];
            test_usable = true; test_tile = physical;
            flag(state, @"full_screen_frame_kept", true);
            if (scenario) {
                flag(state, @"full_panel_frame_accepted", true);
                test_tile = safe;
            }
            switch (scenario) {
                case 2: flag(state, @"full_panel_frame_accepted", false); break;
                case 3: flag(state, @"full_screen_frame_kept", false); break;
                case 4: w.styleMask = 0; break;
                case 5: test_tile = NSMakeRect(0, 0, 900, 1130); break;
                case 6: test_tile = NSMakeRect(900, 0, 900, 1130); break;
                case 7: test_tile.origin.y += 1; break;
                case 8: flag(state, @"camera_housing_area_lost", true); break;
                case 9: test_usable = false; break;
            }
            NSRect result = [state fullScreenFrameForAppKitFrame:safe];
            assert(omacvm_camera_rect_equal(result, scenario < 2 ? physical : safe));
            assert(w.writes == 0);
            [state release]; [w release]; [screen release];
        }
        puts("camera-housing frame hook: PASS (10 initial/safe-tile/Split View/fallback cases)");
        Class classes[] = {[GuardedMainWindow class], [GuardedHeadWindow class]};
        for (int cls = 0; cls < 2; cls++) {
            for (int scenario = 0; scenario < 12; scenario++) {
                for (int setter = 0; setter < 5; setter++) {
                    TestState *state = [TestState new];
                    FakeScreen *screen = [FakeScreen new];
                    screen.frame = physical; screen.notch = 38;
                    FakeBaseWindow *w = [classes[cls] new];
                    w.frame = physical; w.screen = screen;
                    w.styleMask = NSWindowStyleMaskFullScreen;
                    [state setValue:w forKey:@"window"];
                    flag(state, @"in_full_screen_space", true);
                    flag(state, @"full_screen_frame_kept", true);
                    flag(state, @"full_panel_frame_accepted", true);
                    objc_setAssociatedObject(w, &omacvm_camera_state_key, state,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    test_usable = true; test_tile = safe;
                    switch (scenario) {
                        case 1: flag(state, @"full_screen_frame_kept", false); break;
                        case 2: flag(state, @"full_panel_frame_accepted", false); break;
                        case 3: w.styleMask = 0; break;
                        case 4: test_usable = false; break;
                        case 5: flag(state, @"camera_housing_area_lost", true); break;
                        case 6: w.frame = safe; break;
                        case 7: test_tile = NSMakeRect(0, 0, 900, 1130); break;
                        case 8: test_tile = NSMakeRect(900, 0, 900, 1130); break;
                        case 9: screen.frame = NSMakeRect(1800, 0, 1920, 1080); break;
                        case 10: screen.notch = 0; break;
                        case 11: objc_setAssociatedObject(w, &omacvm_camera_state_key,
                                                         nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); break;
                    }
                    if (setter == 0) { [w setFrameOrigin:NSMakePoint(0, 0)]; }
                    if (setter == 1) { [w setFrameTopLeftPoint:NSMakePoint(0, NSMaxY(w.frame))]; }
                    if (setter == 2) { [w setContentSize:w.frame.size]; }
                    if (setter == 3) { [w setFrame:safe display:YES]; }
                    if (setter == 4) { [w setFrame:safe display:YES animate:YES]; }
                    assert(w.writes == (scenario == 0 ? 0 : 1));
                    if (scenario == 0) {
                        assert(omacvm_camera_rect_equal(w.frame, physical));
                    }
                    objc_setAssociatedObject(w, &omacvm_camera_state_key,
                                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [state release]; [w release]; [screen release];
                }
            }
        }
        puts("camera-housing frame guards: PASS (120 fake-window scenarios, no VM/GUI)");
        omacvm_camera_skylight_state = 1;
        omacvm_camera_sls_main = connection;
        omacvm_camera_sls_spaces = spaces;
        omacvm_camera_sls_space_type = space_type;
        for (int scenario = 0; scenario < 23; scenario++) {
            TestState *state = [TestState new];
            FakeScreen *screen = [FakeScreen new];
            screen.frame = physical; screen.notch = 38;
            FakeBaseWindow *w = [FakeBaseWindow new];
            w.frame = physical; w.screen = screen;
            w.styleMask = NSWindowStyleMaskFullScreen;
            w.keyWindow = w.visible = w.onActiveSpace = true;
            w.occlusionState = NSWindowOcclusionStateVisible;
            [state setValue:w forKey:@"window"];
            flag(state, @"in_full_screen_space", true);
            flag(state, @"full_screen_frame_kept", true);
            flag(state, @"full_panel_frame_accepted", true);
            [state setValue:@42 forKey:@"menu_bar_hidden_space"];
            test_space = 42; test_space_type = 4; test_usable = true;
            test_compositor = 1;
            switch (scenario) {
                case 1: w.keyWindow = false; break;
                case 2: w.visible = false; break;
                case 3: w.onActiveSpace = false; break;
                case 4: w.occlusionState = 0; break;
                case 5: flag(state, @"full_screen_frame_kept", false); break;
                case 6: flag(state, @"full_panel_frame_accepted", false); break;
                case 7: flag(state, @"in_full_screen_space", false); break;
                case 8: flag(state, @"camera_housing_area_lost", true); break;
                case 9: [state setValue:@0 forKey:@"menu_bar_hidden_space"]; break;
                case 10: w.styleMask = 0; break;
                case 11: test_usable = false; break;
                case 12: w.frame = safe; break;
                case 13: test_space = 43; break;
                case 14: test_space_type = 0; break;
                case 15:
                    flag(state, @"menu_bar_revealed", true);
                    flag(state, @"toolbar_revealed", true);
                    break;
                case 18: w.keyWindow = false; break;
                case 19: test_compositor = 0; break;
                case 20: test_compositor = -1; break;
                case 21: test_compositor = 0; break;
                case 22: test_compositor = 0; break;
            }
            NSRect before = w.frame;
            if ((scenario >= 16 && scenario <= 18) || scenario == 21) {
                [state scheduleFullPanelRefresh:@"window became key"];
                assert(state.revealUpdates == (scenario == 18 || scenario == 21 ? 0 : 1));
                [state scheduleFullPanelRefresh:@"active Space changed"];
                assert(state.revealUpdates == (scenario == 18 || scenario == 21 ? 0 : 1));
                if (scenario == 17) {
                    /* A queued return event must not change exit state. */
                    flag(state, @"in_full_screen_space", false);
                    flag(state, @"full_screen_frame_kept", false);
                }
                if (scenario == 18) {
                    /* Return becomes eligible after the initial notification. */
                    w.keyWindow = true;
                }
                if (scenario == 21) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 30),
                                   dispatch_get_main_queue(), ^{ test_compositor = 1; });
                }
                for (int i = 0; i < 10 &&
                     [[state valueForKey:@"full_panel_refresh_pending"] boolValue]; i++) {
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
                }
                assert(![[state valueForKey:@"full_panel_refresh_pending"] boolValue]);
            } else if (scenario == 22) {
                flag(state, @"full_panel_refresh_pending", true);
                [state finishFullPanelReturn:@"timeout test" checksLeft:0];
                assert(![[state valueForKey:@"full_panel_refresh_pending"] boolValue]);
            } else {
                [state refreshFullPanelForReason:@"test return from Mission Control"];
            }
            int expected = scenario == 16 ? 2 :
                (scenario == 0 || scenario == 15 || scenario == 17 || scenario == 18 || scenario == 21 ? 1 : 0);
            assert(state.presentationUpdates == expected);
            assert(state.revealUpdates == expected);
            assert(w.writes == 0 && omacvm_camera_rect_equal(w.frame, before));
            if (scenario == 15) {
                assert([[state valueForKey:@"menu_bar_revealed"] boolValue]);
                assert([[state valueForKey:@"toolbar_revealed"] boolValue]);
            }
            [state setValue:@0 forKey:@"menu_bar_hidden_space"];
            [state release]; [w release]; [screen release];
        }
        puts("camera-housing return refresh: PASS (23 lifecycle/compositor scenarios, no geometry writes)");

        /* Real default presentation and toolbar restoration, without a GUI. */
        NSApplication *savedApp = NSApp;
        FakePresentationApp *app = [FakePresentationApp new];
        NSApp = (NSApplication *)app;
        PresentationTestState *presentation = [PresentationTestState new];
        FakeBaseWindow *w = [FakeBaseWindow new];
        w.keyWindow = true;
        [presentation setValue:w forKey:@"window"];
        [presentation setValue:@10 forKey:@"revealable_presentation"];
        [presentation setValue:@YES forKey:@"revealable_presentation_valid"];
        app.current = 10;
        [presentation updatePresentationOptions];
        NSApplicationPresentationOptions hidden = NSApplicationPresentationFullScreen |
            NSApplicationPresentationHideMenuBar | NSApplicationPresentationHideDock;
        assert(app.current == hidden && app.writes == 1);
        [presentation updatePresentationOptions];
        assert(app.writes == 1); /* no redundant presentation write */
        [presentation setValue:@YES forKey:@"menu_bar_reveal_allowed"];
        [presentation updatePresentationOptions];
        assert(app.current == 10 && app.writes == 2);
        [presentation setValue:@NO forKey:@"revealable_presentation_valid"];
        [presentation release]; [w release];

        ToolbarTestState *toolbarState = [ToolbarTestState new];
        FakeToolbarWindow *toolbar = [FakeToolbarWindow new];
        FakeToolbarView *view = [FakeToolbarView new];
        toolbarState.toolbar = toolbar;
        /* A late-created toolbar must receive the same requested hide state. */
        [toolbarState setToolbarHidden:true];
        toolbar.contentView = view;
        [toolbarState setToolbarHidden:true];
        assert(view.hidden && view.writes == 1 && toolbar.ignoresMouseEvents);
        [toolbarState setToolbarHidden:false];
        assert(!view.hidden && view.writes == 2 && !toolbar.ignoresMouseEvents);
        toolbarState.toolbar = nil;
        [toolbarState release]; [toolbar release]; [view release];
        NSApp = savedApp; [app release];
        puts("camera-housing default reveal/restore: PASS (presentation and late toolbar)");

    }
}
'''
with tempfile.TemporaryDirectory(prefix="fullpanel-frame-guards-") as tmp:
    subprocess.run(["patch", "-s", "-d", tmp, "-p1", "-f", "-i",
                    str(transformer.parent / "omacvm-cocoa-clean-size-logic.patch")],
                   check=True)
    source = Path(tmp) / "guards.m"
    binary = Path(tmp) / "guards"
    source.write_text(prefix + forward + "\n" + helper + fake + windows + test)
    # FakeBaseWindow deliberately derives from NSObject to avoid a GUI window.
    subprocess.run(["clang", "-fblocks", "-Werror", "-I" + str(Path(tmp) / "ui"), "-Wno-unused-function",
                    "-Wno-incompatible-pointer-types",
                    str(source), "-framework", "Cocoa", "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
