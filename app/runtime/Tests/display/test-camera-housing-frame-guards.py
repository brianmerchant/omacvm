#!/usr/bin/env python3
"""Test generated geometry setters against a fake AppKit shrink, without a VM."""
import ast
import os
from pathlib import Path
import subprocess
import tempfile

transformer = Path(__file__).resolve().parents[2] / "patches/apply-camera-housing-fullscreen.py"
tree = ast.parse(transformer.read_text())

def literal_assignment(name):
    return next(ast.literal_eval(n.value) for n in tree.body
                if isinstance(n, ast.Assign) and any(
                    isinstance(t, ast.Name) and t.id == name for t in n.targets))

helper = literal_assignment("helper")
for removed in ("v2ParityNotification", "reassertV2Parity", "releaseV2ParityToolbar",
                "v2_parity_generation"):
    assert removed not in helper, removed
geometry = literal_assignment("geometry_diagnostics")
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
static unsigned v2_alpha_requests, v2_commits;
static CFTypeRef v2_transaction(int32_t cid)
{ return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); }
static void v2_alpha(CFTypeRef tx, uint64_t space, float alpha)
{ assert(space == 42 && alpha == 0.0f); v2_alpha_requests++; }
static int32_t v2_commit(CFTypeRef tx, int32_t synchronous)
{ assert(synchronous == 1); v2_commits++; return 0; }

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

@interface V2ReturnTestState : TestState
@end
@implementation V2ReturnTestState
/* Cleanup is otherwise real; the fake window has no toolbar or event monitor. */
- (void)showMenuBar {}
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
@interface ToolbarHandoffTestState : OmacVMCameraHousingState
@property(retain) FakeToolbarWindow *toolbar;
@end
@implementation ToolbarHandoffTestState
- (bool)usable { return test_usable && [[window screen] safeAreaInsets].top > 0; }
- (NSWindow *)fullScreenToolbarWindow { return (NSWindow *)_toolbar; }
@end
static unsigned handoff_hidden_requests, handoff_shown_requests;
static void handoff_alpha(CFTypeRef tx, uint64_t space, float alpha)
{
    assert(space == 42 || space == 43);
    assert(alpha == 0.0f || alpha == 1.0f);
    if (alpha == 0.0f) { handoff_hidden_requests++; }
    else { handoff_shown_requests++; }
}
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
windows = "\n".join(
    "@interface " + cls + " : FakeBaseWindow\n@end\n@implementation " + cls
    + "\n" + geometry + "\n@end\n"
    for cls in ("GuardedMainWindow", "GuardedHeadWindow"))
test = r'''
static void flag(TestState *state, NSString *key, bool value)
{ [state setValue:@(value) forKey:key]; }

int main(void)
{
    @autoreleasepool {
        /* Disabled tracing and Native mode must not query WindowServer or
         * inspect fake-window views (which intentionally do not exist).
         */
        FakeBaseWindow *traceWindow = [FakeBaseWindow new];
        unsetenv("OMACVM_CAMERA_HOUSING");
        unsetenv("OMACVM_FULLPANEL_FLICKER_TRACE");
        omacvm_fullpanel_flicker_trace((NSWindow *)traceWindow, "disabled test");
        omacvm_fullpanel_overlay_observed((NSWindow *)traceWindow,
            (NSWindow *)traceWindow, "disabled overlay test");
        setenv("OMACVM_FULLPANEL_FLICKER_TRACE", "1", 1);
        omacvm_fullpanel_flicker_trace((NSWindow *)traceWindow, "Native test");
        omacvm_fullpanel_overlay_observed((NSWindow *)traceWindow,
            (NSWindow *)traceWindow, "Native overlay test");
        assert(test_window_queries == 0);
        assert(!omacvm_fullpanel_flicker_trace_enabled());
        setenv("OMACVM_CAMERA_HOUSING", "1", 1);
        assert(omacvm_fullpanel_flicker_trace_enabled());
        unsetenv("OMACVM_FULLPANEL_FLICKER_TRACE");
        unsetenv("OMACVM_CAMERA_HOUSING");
        [traceWindow release];
        puts("camera-housing flicker trace: PASS (opt-in and Native isolation)");
        /* Ownership is public metadata; only our own window numbers can be
         * mapped to a local AppKit class. Never label a foreign 39pt surface
         * as an AppKit transition overlay based on its dimensions.
         */
        NSMutableDictionary *entry = [@{
            (id)kCGWindowNumber: @88,
            (id)kCGWindowOwnerPID: @([[NSProcessInfo processInfo] processIdentifier] + 1),
            (id)kCGWindowOwnerName: @"Dock\n",
            (id)kCGWindowName: @"title must not be logged",
            (id)kCGWindowLayer: @24,
            (id)kCGWindowAlpha: @1,
            (id)kCGWindowIsOnscreen: @YES
        } mutableCopy];
        NSDictionary *surfaceClasses = @{@88: @"_NSFullScreenTransitionOverlayWindow"};
        NSString *metadata = omacvm_fullpanel_surface_trace(entry, 0, 7, surfaceClasses);
        assert([metadata containsString:@"own=0 number=88 ownerPID="]);
        assert([metadata containsString:@"owner=Dock "]);
        assert([metadata containsString:@"localClass=unavailable(foreign)"]);
        assert(![metadata containsString:@"_NSFullScreenTransitionOverlayWindow"]);
        assert(![metadata containsString:@"title must not be logged"]);
        assert(![metadata containsString:@"\n"]);
        [entry setObject:@([[NSProcessInfo processInfo] processIdentifier])
                  forKey:(id)kCGWindowOwnerPID];
        metadata = omacvm_fullpanel_surface_trace(entry, 2, 88, surfaceClasses);
        assert([metadata containsString:@"rank=2 target=1 own=1 number=88"]);
        assert([metadata containsString:@"localClass=_NSFullScreenTransitionOverlayWindow"]);
        metadata = omacvm_fullpanel_surface_trace(@{}, 0, 0, @{});
        assert([metadata containsString:@"target=0 own=0"]);
        assert([metadata containsString:@"owner=unavailable localClass=unavailable(foreign)"]);
        [entry release];
        puts("camera-housing surface trace: PASS (foreign/own/missing metadata, no GUI)");
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
        Class classes[] = {[GuardedMainWindow class], [GuardedHeadWindow class]};
        for (int cls = 0; cls < 2; cls++) {
            for (int scenario = 0; scenario < 12; scenario++) {
                for (int setter = 0; setter < 3; setter++) {
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
        puts("camera-housing frame guards: PASS (72 fake-window scenarios, no VM/GUI)");
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

        {
            NSApplication *savedApp = NSApp;
            FakePresentationApp *app = [FakePresentationApp new];
            NSApp = (NSApplication *)app;
            V2ReturnTestState *state = [V2ReturnTestState new];
            FakeScreen *screen = [FakeScreen new];
            screen.frame = physical; screen.notch = 38;
            FakeBaseWindow *w = [FakeBaseWindow new];
            w.screen = screen; w.frame = physical; w.styleMask = NSWindowStyleMaskFullScreen;
            w.keyWindow = w.onActiveSpace = true;
            [state setValue:w forKey:@"window"];
            setenv("OMACVM_CAMERA_HOUSING", "1", 1);
            setenv("OMACVM_FULLPANEL_V2_RETURN", "1", 1);
            test_usable = true; test_space = 42; test_space_type = 4;
            omacvm_camera_skylight_state = 1;
            omacvm_camera_sls_transaction_create = v2_transaction;
            omacvm_camera_sls_menu_alpha = v2_alpha;
            omacvm_camera_sls_transaction_commit = v2_commit;
            for (NSString *key in @[@"in_full_screen_space", @"full_screen_frame_kept",
                                   @"full_panel_frame_accepted"]) { flag(state, key, true); }
            [state setValue:@42 forKey:@"menu_bar_hidden_space"];
            NSNotification *keyEvent = [NSNotification notificationWithName:
                NSWindowDidBecomeKeyNotification object:w];
            [state noteV2ReturnDeparture];
            [state v2ReturnNotification:keyEvent];
            assert(![state v2ReturnEligible] && v2_alpha_requests == 0); /* entry */
            w.onActiveSpace = w.keyWindow = false;
            [state noteV2ReturnDeparture];
            assert([state v2ReturnEligible]);
            [state reassertV2Return:@"inactive target"];
            assert(v2_alpha_requests == 1 && app.writes == 0);
            app.active = true;
            [state reassertV2Return:@"app-active, target not key"];
            assert(v2_alpha_requests == 2 && app.current == 1034 && app.writes == 1);
            flag(state, @"menu_bar_revealed", true);
            [state reassertV2Return:@"revealed menu"];
            assert(v2_alpha_requests == 2);
            flag(state, @"menu_bar_revealed", false);
            for (NSString *gate in @[@"camera_housing_area_lost", @"toolbar_revealed",
                                    @"menu_bar_reveal_allowed"]) {
                flag(state, gate, true); assert(![state v2ReturnEligible]);
                flag(state, gate, false);
            }
            test_space = 43; assert(![state v2ReturnEligible]); test_space = 42;
            test_usable = false; assert(![state v2ReturnEligible]); test_usable = true;
            w.frame = safe; assert(![state v2ReturnEligible]); w.frame = physical;
            unsetenv("OMACVM_CAMERA_HOUSING"); assert(![state v2ReturnEligible]);
            setenv("OMACVM_CAMERA_HOUSING", "1", 1);
            unsetenv("OMACVM_FULLPANEL_V2_RETURN"); assert(![state v2ReturnEligible]);
            setenv("OMACVM_FULLPANEL_V2_RETURN", "1", 1);
            w.keyWindow = w.onActiveSpace = true;
            v2_alpha_requests = v2_commits = 0;
            [state v2ReturnNotification:keyEvent];
            [state v2ReturnNotification:[NSNotification notificationWithName:
                NSApplicationDidBecomeActiveNotification object:app]];
            [state v2ReturnNotification:[NSNotification notificationWithName:
                NSApplicationDidChangeScreenParametersNotification object:app]];
            assert(v2_alpha_requests == 3);
            for (unsigned i = 0; i < 90 &&
                 [[state valueForKey:@"full_panel_v2_return_batches"] unsignedIntValue]; i++) {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
            }
            assert(v2_alpha_requests == 9 && v2_commits == 9);
            assert(![[state valueForKey:@"full_panel_v2_return_armed"] boolValue]);
            w.onActiveSpace = false;
            [state noteV2ReturnDeparture];
            [state v2ReturnNotification:keyEvent];
            assert(v2_alpha_requests == 10);
            [state willLeaveFullScreen:nil];
            for (unsigned i = 0; i < 70; i++) {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
            }
            assert(v2_alpha_requests == 10 && w.writes == 0 && NSEqualRects(w.frame, physical));
            unsetenv("OMACVM_FULLPANEL_V2_RETURN"); unsetenv("OMACVM_CAMERA_HOUSING");
            NSApp = savedApp;
            [state release]; [w release]; [screen release]; [app release];
            puts("camera-housing v2 return: PASS (entry/Native isolation, owned Space/reveal guards, event bursts, exit cancellation)");
        }

        /* V2 toolbar ownership is one coverage variable: alpha and compositor
         * restoration still execute, and geometry never changes. */
        for (unsigned scenario = 0; scenario < 15; scenario++) {
            ToolbarHandoffTestState *state = [ToolbarHandoffTestState new];
            FakeScreen *screen = [FakeScreen new];
            screen.frame = physical; screen.notch = 38;
            FakeBaseWindow *w = [FakeBaseWindow new];
            w.screen = screen; w.frame = physical; w.styleMask = NSWindowStyleMaskFullScreen;
            w.keyWindow = w.visible = true; w.onActiveSpace = false;
            w.occlusionState = NSWindowOcclusionStateVisible;
            FakeToolbarWindow *toolbar = [FakeToolbarWindow new];
            FakeToolbarView *view = [FakeToolbarView new];
            toolbar.contentView = view; state.toolbar = toolbar;
            [state setValue:w forKey:@"window"];
            for (NSString *key in @[@"in_full_screen_space", @"full_screen_frame_kept",
                                   @"full_panel_frame_accepted"]) { flag(state, key, true); }
            [state setValue:@42 forKey:@"menu_bar_hidden_space"];
            test_usable = true; test_space = 42; test_space_type = 4; test_compositor = 1;
            omacvm_camera_skylight_state = 1;
            omacvm_camera_sls_transaction_create = v2_transaction;
            omacvm_camera_sls_menu_alpha = handoff_alpha;
            omacvm_camera_sls_transaction_commit = v2_commit;
            handoff_hidden_requests = handoff_shown_requests = 0;
            setenv("OMACVM_CAMERA_HOUSING", "1", 1);
            setenv("OMACVM_FULLPANEL_V2_TOOLBAR_HANDOFF", "1", 1);
            if (scenario == 0) { unsetenv("OMACVM_FULLPANEL_V2_TOOLBAR_HANDOFF"); }
            if (scenario == 1) { unsetenv("OMACVM_CAMERA_HOUSING"); }
            if (scenario == 2) { flag(state, @"in_full_screen_space", false); }
            if (scenario == 3) { flag(state, @"full_panel_frame_accepted", false); }
            if (scenario == 4) { flag(state, @"camera_housing_area_lost", true); }
            if (scenario == 5) { flag(state, @"full_screen_frame_kept", false); }
            if (scenario == 6) { [state setValue:@0 forKey:@"menu_bar_hidden_space"]; }
            if (scenario == 7) { w.onActiveSpace = true; }
            if (scenario == 8) { w.styleMask = 0; }
            if (scenario == 9) { screen.notch = 0; }
            if (scenario == 10) { test_usable = false; }
            if (scenario == 11) { test_space = 43; }
            if (scenario == 12) { test_space_type = 0; }
            if (scenario == 13) { w.frame = NSMakeRect(0, 0, 1800, 1130); }
            [state setToolbarHidden:true]; /* Initial entry's current behavior. */
            assert(view.hidden && toolbar.ignoresMouseEvents);
            [state noteV2ToolbarHandoffDeparture];
            bool armed = scenario == 14;
            assert([state v2ToolbarHandoffActive] == armed);
            assert(view.hidden == !armed && toolbar.ignoresMouseEvents == !armed);
            unsigned writes = view.writes;
            [state noteV2ToolbarHandoffDeparture]; /* Coalesce departure callbacks. */
            assert(view.writes == writes);
            w.onActiveSpace = true;
            [state applyMenuBarReveal];
            assert(handoff_hidden_requests == (scenario == 6 ? 0 : 1));
            assert(view.writes == writes + (armed || scenario == 6 ? 0 : 1));
            if (armed) {
                writes = view.writes;
                assert([state refreshFullPanelForReason:@"v2 toolbar test"]);
                assert(handoff_hidden_requests == 2 && view.writes == writes);
                flag(state, @"menu_bar_revealed", true);
                flag(state, @"toolbar_revealed", true);
                [state applyMenuBarReveal];
                assert(handoff_shown_requests == 1 && view.writes == writes);
                /* A replacement Space cannot inherit this ownership latch. */
                test_space = 43; [state setValue:@43 forKey:@"menu_bar_hidden_space"];
                assert(![state v2ToolbarHandoffActive]);
                [state applyMenuBarReveal]; assert(view.writes == writes + 1);
                test_space = 42; [state setValue:@42 forKey:@"menu_bar_hidden_space"];
                [state willLeaveFullScreen:nil];
                assert(![state v2ToolbarHandoffActive]);
                assert([[state valueForKey:@"v2_toolbar_handoff_space"] unsignedLongLongValue] == 0);
                assert(!view.hidden && !toolbar.ignoresMouseEvents);
                [state willEnterFullScreen:nil];
                assert([[state valueForKey:@"v2_toolbar_handoff_space"] unsignedLongLongValue] == 0);
            }
            assert(w.writes == 0);
            [state setValue:@0 forKey:@"menu_bar_hidden_space"];
            [state showMenuBar];
            assert([[state valueForKey:@"v2_toolbar_handoff_space"] unsignedLongLongValue] == 0);
            state.toolbar = nil; toolbar.contentView = nil;
            [state release]; [toolbar release]; [view release]; [w release]; [screen release];
        }
        unsetenv("OMACVM_FULLPANEL_V2_TOOLBAR_HANDOFF"); unsetenv("OMACVM_CAMERA_HOUSING");
        test_space = 42; test_space_type = 4; test_usable = true;
        method_setImplementation(screensMethod, originalScreens);
        puts("camera-housing v2 toolbar handoff: PASS (15 eligibility cases, entry/exit, alpha/reveal/readiness preserved)");

        /* Passive parity leaves initial entry/existing surface state intact.
         * Automatic Space/key/occlusion/reveal/KVO callbacks must do no return
         * writes. Explicit menu handling and exit still use the original code.
         */
        {
            NSApplication *savedApp = NSApp;
            FakePresentationApp *app = [FakePresentationApp new];
            NSApp = (NSApplication *)app;
            ToolbarHandoffTestState *state = [ToolbarHandoffTestState new];
            FakeScreen *screen = [FakeScreen new];
            screen.frame = physical; screen.notch = 38;
            FakeBaseWindow *w = [FakeBaseWindow new];
            w.screen = screen; w.frame = physical; w.styleMask = NSWindowStyleMaskFullScreen;
            w.keyWindow = w.onActiveSpace = w.visible = true;
            w.occlusionState = NSWindowOcclusionStateVisible;
            FakeToolbarWindow *toolbar = [FakeToolbarWindow new];
            FakeToolbarView *view = [FakeToolbarView new];
            toolbar.contentView = view; state.toolbar = toolbar;
            [state setValue:w forKey:@"window"];
            for (NSString *key in @[@"in_full_screen_space", @"full_screen_frame_kept",
                                   @"full_panel_frame_accepted"]) { flag(state, key, true); }
            [state setValue:@42 forKey:@"menu_bar_hidden_space"];
            test_usable = true; test_space = 42; test_space_type = 4;
            omacvm_camera_sls_menu_alpha = handoff_alpha;
            setenv("OMACVM_CAMERA_HOUSING", "1", 1);
            setenv("OMACVM_FULLPANEL_V2_PARITY", "1", 1);
            for (NSString *name in @[@"OMACVM_FULLPANEL_EARLY_HIDE",
                    @"OMACVM_FULLPANEL_PASSIVE_PRESENTATION", @"OMACVM_FULLPANEL_V2_RETURN",
                    @"OMACVM_FULLPANEL_V2_TOOLBAR_HANDOFF"]) { setenv([name UTF8String], "1", 1); }
            assert(!omacvm_fullpanel_early_hide_enabled());
            assert(!omacvm_fullpanel_passive_presentation_enabled());
            assert(!omacvm_fullpanel_v2_return_enabled());
            assert(!omacvm_fullpanel_v2_toolbar_handoff_enabled());
            assert(![state v2ParityManaged]); /* Entry not completed. */
            handoff_hidden_requests = handoff_shown_requests = 0;
            [state applyMenuBarReveal];
            assert(handoff_hidden_requests == 1 && view.hidden);
            flag(state, @"v2_parity_established", true);
            handoff_hidden_requests = handoff_shown_requests = 0;
            app.current = 10; app.writes = 0;
            for (NSString *key in @[@"in_full_screen_space", @"full_screen_frame_kept",
                                   @"full_panel_frame_accepted"]) {
                flag(state, key, false); assert(![state v2ParityManaged]); flag(state, key, true);
            }
            flag(state, @"camera_housing_area_lost", true);
            assert(![state v2ParityManaged]); flag(state, @"camera_housing_area_lost", false);
            test_usable = false; assert(![state v2ParityManaged]); test_usable = true;
            screen.notch = 0; assert(![state v2ParityManaged]); screen.notch = 38;
            /* Transient Space queries do not re-enable the early driver. */
            for (NSNumber *space in @[@43, @0]) {
                test_space = [space unsignedLongLongValue];
                assert([state v2ParityManaged]);
                assert([state refreshFullPanelForReason:@"passive while Space query changes"]);
            }
            test_space = 42;
            w.frame = safe; assert(![state v2ParityManaged]); w.frame = physical;
            w.styleMask = 0; assert(![state v2ParityManaged]); w.styleMask = NSWindowStyleMaskFullScreen;
            unsetenv("OMACVM_CAMERA_HOUSING"); assert(![state v2ParityManaged]);
            setenv("OMACVM_CAMERA_HOUSING", "1", 1);
            unsetenv("OMACVM_FULLPANEL_V2_PARITY"); assert(![state v2ParityManaged]);
            setenv("OMACVM_FULLPANEL_V2_PARITY", "1", 1);
            NSNotification *keyEvent = [NSNotification notificationWithName:
                NSWindowDidBecomeKeyNotification object:w];
            test_window_queries = 0;
            unsigned toolbarWrites = view.writes;
            w.onActiveSpace = false;
            [state activeSpaceChanged:[NSNotification notificationWithName:
                NSWorkspaceActiveSpaceDidChangeNotification object:nil]];
            w.onActiveSpace = true;
            [state windowDidBecomeKey:keyEvent];
            for (id changed in @[w, toolbar]) {
                [state otherWindowDidChangeOcclusionState:[NSNotification notificationWithName:
                    NSWindowDidChangeOcclusionStateNotification object:changed]];
            }
            [state observeValueForKeyPath:@"currentSystemPresentationOptions" ofObject:app
                change:@{} context:NULL];
            [state menuRevealChanged:true toolbar:true];
            [state menuRevealChanged:false toolbar:false];
            [state scheduleFullPanelRefresh:@"correct bounds during MC animation"];
            assert([state refreshFullPanelForReason:@"still animating"]);
            flag(state, @"full_panel_refresh_pending", true);
            [state finishFullPanelReturn:@"old queued compositor probe" checksLeft:240];
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
            assert(![[state valueForKey:@"full_panel_refresh_pending"] boolValue]);
            assert(handoff_hidden_requests == 0 && handoff_shown_requests == 0);
            assert(app.writes == 0 && app.current == 10 && test_window_queries == 0);
            assert(view.writes == toolbarWrites && view.hidden && toolbar.ignoresMouseEvents);
            assert(w.writes == 0 && NSEqualRects(w.frame, physical));
            /* Explicit user reveal, close and cleanup retain original writes. */
            flag(state, @"revealable_presentation_valid", true);
            flag(state, @"presentation_forced", true);
            [state setValue:@10 forKey:@"revealable_presentation"];
            app.current = 1034;
            flag(state, @"menu_bar_reveal_allowed", true);
            [state updatePresentationOptions];
            assert(app.current == 10 && app.writes == 1);
            [state menuRevealChanged:true toolbar:true];
            assert(handoff_shown_requests == 1 && !view.hidden);
            [state menuRevealChanged:false toolbar:false];
            assert(handoff_hidden_requests == 1 && view.hidden);
            assert(app.current == 1034 && app.writes == 2);
            [state willLeaveFullScreen:nil];
            assert(![state v2ParityManaged]);
            assert(handoff_shown_requests == 2 && app.current == 10 && app.writes == 3);
            assert(!view.hidden && !toolbar.ignoresMouseEvents && w.writes == 0);
            [state setValue:@0 forKey:@"menu_bar_hidden_space"];
            state.toolbar = nil; toolbar.contentView = nil;
            [state release]; [toolbar release]; [view release]; [w release]; [screen release]; [app release];
            NSApp = savedApp;
            for (NSString *name in @[@"OMACVM_FULLPANEL_V2_PARITY", @"OMACVM_CAMERA_HOUSING",
                    @"OMACVM_FULLPANEL_EARLY_HIDE", @"OMACVM_FULLPANEL_PASSIVE_PRESENTATION",
                    @"OMACVM_FULLPANEL_V2_RETURN", @"OMACVM_FULLPANEL_V2_TOOLBAR_HANDOFF"]) { unsetenv([name UTF8String]); }
            puts("camera-housing passive parity: PASS (no automatic return writes/queries, unchanged entry surface/menu/exit, no driver)");
        }

        /* The diagnostic must not sample initial/Native entry or let a stale
         * queued observer survive exit/re-entry. No real window/GUI is made.
         */
        {
            TestState *state = [TestState new];
            FakeBaseWindow *w = [FakeBaseWindow new];
            FakeScreen *screen = [FakeScreen new];
            screen.notch = 39;
            w.screen = screen;
            [state setValue:w forKey:@"window"];
            w.styleMask = NSWindowStyleMaskFullScreen;
            for (NSString *key in @[@"in_full_screen_space", @"full_screen_frame_kept",
                                   @"full_panel_frame_accepted"]) {
                [state setValue:@YES forKey:key];
            }
            unsigned queries = test_window_queries;
            setenv("OMACVM_FULLPANEL_HANDOFF_TRACE", "1", 1);
            unsetenv("OMACVM_CAMERA_HOUSING");
            [state noteHandoffDeparture];
            assert(![[state valueForKey:@"full_panel_handoff_departed"] boolValue]);
            setenv("OMACVM_CAMERA_HOUSING", "1", 1);
            w.onActiveSpace = true;
            [state startHandoffTrace:@"initial entry"];
            assert(![[state valueForKey:@"full_panel_handoff_sampling"] boolValue]);
            assert(test_window_queries == queries);
            w.onActiveSpace = false;
            [state noteHandoffDeparture];
            queries = test_window_queries; /* one departure snapshot if a screen exists */
            [state startHandoffTrace:@"still departed"];
            assert(![[state valueForKey:@"full_panel_handoff_sampling"] boolValue]);
            w.onActiveSpace = true;
            [state startHandoffTrace:@"returned"];
            assert([[state valueForKey:@"full_panel_handoff_sampling"] boolValue]);
            unsigned generation = [[state valueForKey:@"full_panel_handoff_generation"] unsignedIntValue];
            [state startHandoffTrace:@"duplicate return"];
            assert([[state valueForKey:@"full_panel_handoff_generation"] unsignedIntValue] == generation);
            [state cancelHandoffTrace:"test exit"];
            [state sampleHandoffTrace:generation checksLeft:240]; /* stale: no WS query */
            [state startHandoffTrace:@"new initial entry"];
            assert(![[state valueForKey:@"full_panel_handoff_sampling"] boolValue]);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false); /* queued stale callback */
            assert(test_window_queries == queries && w.writes == 0);
            unsetenv("OMACVM_FULLPANEL_HANDOFF_TRACE"); unsetenv("OMACVM_CAMERA_HOUSING");
            [state release]; [w release]; [screen release];
            puts("camera-housing handoff trace: PASS (Native/initial isolation, coalescing, stale callback cancellation, no GUI)");
        }

        /* One-variable experiment: only automatic presentation writes are
         * skipped after an established Space departure. No visual/VM app.
         */
        NSApplication *savedApp = NSApp;
        FakePresentationApp *app = [FakePresentationApp new];
        NSApp = (NSApplication *)app;
        setenv("OMACVM_CAMERA_HOUSING", "1", 1);
        for (unsigned scenario = 0; scenario < 12; scenario++) {
            setenv("OMACVM_FULLPANEL_PASSIVE_PRESENTATION", "1", 1);
            PresentationTestState *state = [PresentationTestState new];
            FakeBaseWindow *w = [FakeBaseWindow new];
            w.styleMask = NSWindowStyleMaskFullScreen;
            w.keyWindow = true; w.onActiveSpace = false;
            [state setValue:w forKey:@"window"];
            [state setValue:@42 forKey:@"menu_bar_hidden_space"];
            [state setValue:@1034 forKey:@"revealable_presentation"];
            for (NSString *key in @[@"in_full_screen_space", @"full_screen_frame_kept",
                                   @"full_panel_frame_accepted", @"revealable_presentation_valid",
                                   @"presentation_forced"]) {
                [state setValue:@YES forKey:key];
            }
            switch (scenario) {
                case 1: unsetenv("OMACVM_FULLPANEL_PASSIVE_PRESENTATION"); break;
                case 2: w.onActiveSpace = true; break; /* no departure: initial entry */
                case 3: [state setValue:@NO forKey:@"full_panel_frame_accepted"]; break;
            }
            [state notePresentationSpaceDeparture];
            bool armed = [[state valueForKey:@"full_panel_presentation_ab_armed"] boolValue];
            assert(armed == (scenario != 1 && scenario != 2 && scenario != 3));
            /* Return is active again; the skip also covers the non-key KVO
             * restore branch observed in the physical diagnostic run.
             */
            w.onActiveSpace = true;
            switch (scenario) {
                case 4: w.keyWindow = false; break;
                case 5: [state setValue:@YES forKey:@"menu_bar_reveal_allowed"]; break;
                case 6: [state setValue:@YES forKey:@"menu_bar_revealed"]; break;
                case 7: [state setValue:@YES forKey:@"toolbar_revealed"]; break;
                case 8: [state setValue:@YES forKey:@"camera_housing_area_lost"]; break;
                case 9: w.styleMask = 0; break;
                case 10: [state setValue:@NO forKey:@"in_full_screen_space"]; break;
                case 11: unsetenv("OMACVM_CAMERA_HOUSING"); break;
            }
            app.current = 10; app.writes = 0;
            bool skip = scenario == 0 || scenario == 4;
            assert([state skipPresentationReassertForAB] == skip);
            [state updatePresentationOptions];
            assert(app.writes == (skip ? 0 : 1));
            assert(app.current == (skip ? 10 : 1034));
            if (skip) {
                assert([[state valueForKey:@"presentation_forced"] boolValue]);
            }
            assert(w.writes == 0);
            [state setValue:@0 forKey:@"menu_bar_hidden_space"];
            [state setValue:@NO forKey:@"revealable_presentation_valid"];
            [state release]; [w release];
            setenv("OMACVM_CAMERA_HOUSING", "1", 1);
        }
        unsetenv("OMACVM_FULLPANEL_PASSIVE_PRESENTATION");
        unsetenv("OMACVM_CAMERA_HOUSING");
        NSApp = savedApp;
        [app release];
        puts("camera-housing presentation A/B: PASS (12 mocked-app scenarios, no GUI)");
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
    env = dict(os.environ)
    env.pop("OMACVM_FULLPANEL_DIAGNOSTIC", None)
    env.pop("OMACVM_FULLPANEL_FLICKER_TRACE", None)
    env.pop("OMACVM_FULLPANEL_HANDOFF_TRACE", None)
    env.pop("OMACVM_FULLPANEL_EARLY_HIDE", None)
    env.pop("OMACVM_FULLPANEL_PASSIVE_PRESENTATION", None)
    env.pop("OMACVM_FULLPANEL_V2_RETURN", None)
    env.pop("OMACVM_FULLPANEL_V2_TOOLBAR_HANDOFF", None)
    env.pop("OMACVM_FULLPANEL_V2_PARITY", None)
    subprocess.run([str(binary)], check=True, env=env)
