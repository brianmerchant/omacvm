/*
 * test-boot-splash-link: the boot logo replaces and drops its display link
 * without aborting QEMU.
 *
 * The logo layer (ui/cocoa.m, omacvm-cocoa-boot-splash.patch) runs its
 * animation from an NSView display link. A link that only the run loop held
 * was freed inside its own -invalidate, which then unlocked freed memory:
 * QEMU aborted ("Unlock of an os_unfair_lock not owned by current thread",
 * in -[OmacVMIntroLayer watchLink]) when it replaced a link that never gave
 * a frame, in a window that was not visible (screen locked, app hidden).
 *
 * link.inc is the layer's -makeLink and -dropLink, taken from the patch
 * (check-boot-splash.sh) or the patched ui/cocoa.m (build-qemu-gpu-runtime.sh).
 * The window is never shown, so the links get no frames, as in the crash:
 * the test replaces the link twice as -watchLink does, then drops it as
 * -fade does. Old code: the process aborts. Without a window server (no GUI
 * session) it says so and passes.
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>

static NSView *cocoaView;

@interface IntroLink : NSObject {
    CADisplayLink *link;
    int step;
}
- (void)makeLink;
- (void)dropLink;
@end

@implementation IntroLink
#include "link.inc"

- (void)tick:(CADisplayLink *)l
{
    (void)l;
}

- (void)next
{
    if (step++ < 2) {
        [self dropLink];   /* -watchLink: a new display link */
        [self makeLink];
    } else {
        [self dropLink];   /* -fade */
        printf("test-boot-splash-link: a link without frames replaced twice and dropped\n");
        exit(0);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ [self next]; });
}
@end

int main(void)
{
    @autoreleasepool {
        CFDictionaryRef session = CGSessionCopyCurrentDictionary();

        if (!session) {
            printf("test-boot-splash-link: skipped, no window server\n");
            return 0;
        }
        CFRelease(session);
        [NSApplication sharedApplication];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 200)
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        cocoaView = [w contentView];
        IntroLink *t = [[IntroLink alloc] init];
        [t makeLink];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ [t next]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            fprintf(stderr, "FAIL: test-boot-splash-link timed out\n");
            exit(1);
        });
        [NSApp run];
    }
    return 1;
}
