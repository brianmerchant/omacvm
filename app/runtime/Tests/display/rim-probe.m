/*
 * rim-probe: does WindowServer draw a light line along a borderless window's
 * edge? (omacvm-cocoa-borderless-no-rim.patch; test-borderless-rim-live.sh
 * builds and runs it.) A small black window, made titled and then borderless
 * as QEMU's is: "old" with setStyleMask alone (3.0.3), "fixed" through the
 * patch's omacvm_set_borderless (borderless-helper.inc). It captures its own
 * window with the shadow, as WindowServer draws it, and prints the brightest
 * value on the window's outer pixel ring and 8 pixels inside:
 *   mode=fixed edge=0 inner=0 rim=no
 * The window sits outside every display (nothing shows on screen; or at
 * RIM_PROBE_AT="x,y" in screen points), never becomes key or active and is
 * gone after about a second.
 *   rim-probe old|fixed OUT.png
 * When the probe cannot capture itself, it prints "wid=N" and waits up to
 * 10 s for OUT.png (the script then takes `screencapture -l N`).
 */
#import <AppKit/AppKit.h>
#include <dlfcn.h>

#include "borderless-helper.inc"

typedef CGImageRef (*CreateImageFn)(CGRect, uint32_t, uint32_t, uint32_t);

static CGImageRef capture_self(CGWindowID wid)
{
    /* Unavailable in the macOS 15+ SDK, still there at run time; an app may capture its own windows. */
    CreateImageFn f = (CreateImageFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (!f) {
        return NULL;
    }
    /* kCGWindowListOptionIncludingWindow, kCGWindowImageBestResolution: shadow included. */
    return f(CGRectNull, 1 << 3, wid, 1 << 3);
}

static int brightest(NSBitmapImageRep *rep, NSInteger x0, NSInteger y0, NSInteger x1, NSInteger y1, NSInteger inset)
{
    int best = 0;
    for (NSInteger y = y0 + inset; y <= y1 - inset; y++) {
        for (NSInteger x = x0 + inset; x <= x1 - inset; x++) {
            bool ring = x == x0 + inset || x == x1 - inset || y == y0 + inset || y == y1 - inset;
            if (!ring) {
                continue;
            }
            NSUInteger p[4] = {0, 0, 0, 0};
            [rep getPixel:p atX:x y:y];
            int v = (int)MAX(p[0], MAX(p[1], p[2]));
            best = MAX(best, v);
        }
    }
    return best;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 3 || (strcmp(argv[1], "old") && strcmp(argv[1], "fixed"))) {
            fprintf(stderr, "usage: rim-probe old|fixed OUT.png\n");
            return 2;
        }
        bool fixed = !strcmp(argv[1], "fixed");
        NSString *out = [NSString stringWithUTF8String:argv[2]];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        /* Outside every display (right of the rightmost one), or RIM_PROBE_AT="x,y". */
        CGFloat right = 0;
        for (NSScreen *s in [NSScreen screens]) {
            right = MAX(right, NSMaxX([s frame]));
        }
        NSRect r = NSMakeRect(right + 2000, 200, 240, 160);
        const char *at = getenv("RIM_PROBE_AT");
        double ax, ay;
        if (at && sscanf(at, "%lf,%lf", &ax, &ay) == 2) {
            r.origin = NSMakePoint(ax, ay);
        }
        NSWindow *w = [[NSWindow alloc] initWithContentRect:r
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        [w setReleasedWhenClosed:NO];
        [w setBackgroundColor:[NSColor blackColor]];
        [w setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorTransient |
                                 NSWindowCollectionBehaviorIgnoresCycle];
        if (fixed) {
            omacvm_set_borderless(w, NSWindowStyleMaskResizable);
        } else {
            [w setStyleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable];
        }
        [w setFrame:r display:YES];
        [w orderFront:nil];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
        CGWindowID wid = (CGWindowID)[w windowNumber];

        NSBitmapImageRep *rep = nil;
        CGImageRef img = capture_self(wid);
        const char *how = "self";
        if (img && CGImageGetWidth(img) > 2) {
            rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
        } else {
            how = "screencapture";
            printf("wid=%u\n", wid);
            fflush(stdout);
            for (int i = 0; i < 100 && !rep; i++) {
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                NSData *d = [NSData dataWithContentsOfFile:out];
                if (d.length) {
                    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
                    rep = [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:out]];
                }
            }
        }
        if (img) {
            CFRelease(img);
        }
        [w orderOut:nil];
        if (!rep) {
            printf("mode=%s capture=none\n", argv[1]);
            return 3;
        }
        /* The window: the opaque box (shadow pixels are see-through). */
        NSInteger W = [rep pixelsWide], H = [rep pixelsHigh];
        NSInteger x0 = W, y0 = H, x1 = -1, y1 = -1;
        for (NSInteger y = 0; y < H; y++) {
            for (NSInteger x = 0; x < W; x++) {
                if ([[rep colorAtX:x y:y] alphaComponent] > 0.99) {
                    x0 = MIN(x0, x); x1 = MAX(x1, x);
                    y0 = MIN(y0, y); y1 = MAX(y1, y);
                }
            }
        }
        if (x1 - x0 < 40 || y1 - y0 < 40) {
            printf("mode=%s capture=%s no window in the picture (%ldx%ld)\n", argv[1], how, (long)W, (long)H);
            return 3;
        }
        int edge = brightest(rep, x0, y0, x1, y1, 0);
        int inner = brightest(rep, x0, y0, x1, y1, 8);
        printf("mode=%s capture=%s picture=%ldx%ld window=%ldx%ld shadow=%s edge=%d inner=%d rim=%s\n",
               argv[1], how, (long)W, (long)H, (long)(x1 - x0 + 1), (long)(y1 - y0 + 1),
               [w hasShadow] ? "yes" : "no", edge, inner, edge > inner + 16 ? "yes" : "no");
    }
    return 0;
}
