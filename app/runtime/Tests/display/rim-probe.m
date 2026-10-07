/*
 * rim-probe: does WindowServer draw a light line along a borderless window's
 * edge? (omacvm-cocoa-borderless-no-rim.patch; test-borderless-rim-live.sh
 * builds and runs it.) A small black window, made titled and then borderless
 * as QEMU's is: "old" with setStyleMask alone (3.0.3), "fixed" through the
 * patch's omacvm_set_borderless (borderless-helper.inc). It captures its own
 * window with the shadow, as WindowServer draws it, and prints the brightest
 * value on the window's outer two pixel rings and 8 pixels inside (the
 * window is black). MacBook Air, macOS 26.6.2:
 *   mode=old ... shadow=yes edge=25,5 inner=0 rim=yes
 *   mode=fixed ... shadow=no edge=0,0 inner=0 rim=no
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

/* RGBA, 8 bits each, premultiplied: the same layout whatever the capture's. */
typedef struct Pixels { size_t w, h; uint8_t *rgba; } Pixels;

static bool pixels_from(CGImageRef img, Pixels *px)
{
    px->w = CGImageGetWidth(img);
    px->h = CGImageGetHeight(img);
    px->rgba = calloc(px->w * px->h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(px->rgba, px->w, px->h, 8, px->w * 4, cs,
                                           (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) {
        return false;
    }
    CGContextDrawImage(c, CGRectMake(0, 0, px->w, px->h), img);
    CGContextRelease(c);
    return true;
}

static const uint8_t *pixel(const Pixels *px, size_t x, size_t y)
{
    return px->rgba + (y * px->w + x) * 4;
}

/* The brightest colour value on the ring INSET pixels inside the box. */
static int brightest(const Pixels *px, size_t x0, size_t y0, size_t x1, size_t y1, size_t inset)
{
    int best = 0;
    for (size_t y = y0 + inset; y <= y1 - inset; y++) {
        for (size_t x = x0 + inset; x <= x1 - inset; x++) {
            if (x != x0 + inset && x != x1 - inset && y != y0 + inset && y != y1 - inset) {
                continue;
            }
            const uint8_t *p = pixel(px, x, y);
            best = MAX(best, (int)MAX(p[0], MAX(p[1], p[2])));
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

        CGImageRef img = capture_self(wid);
        const char *how = "self";
        if (img && CGImageGetWidth(img) > 2) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
        } else {
            if (img) {
                CGImageRelease(img);
                img = NULL;
            }
            how = "screencapture";
            printf("wid=%u\n", wid);
            fflush(stdout);
            for (int i = 0; i < 100 && !img; i++) {
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:out]];
                if (rep) {
                    img = CGImageRetain([rep CGImage]);
                }
            }
        }
        [w orderOut:nil];
        Pixels px = {0, 0, NULL};
        if (!img || !pixels_from(img, &px)) {
            printf("mode=%s capture=none\n", argv[1]);
            return 3;
        }
        CGImageRelease(img);
        /* The window: the opaque box (shadow pixels are see-through). */
        size_t x0 = px.w, y0 = px.h, x1 = 0, y1 = 0;
        for (size_t y = 0; y < px.h; y++) {
            for (size_t x = 0; x < px.w; x++) {
                if (pixel(&px, x, y)[3] == 255) {
                    x0 = MIN(x0, x); x1 = MAX(x1, x);
                    y0 = MIN(y0, y); y1 = MAX(y1, y);
                }
            }
        }
        if (x0 > x1 || x1 - x0 < 40 || y1 - y0 < 40) {
            printf("mode=%s capture=%s no window in the picture (%zux%zu)\n", argv[1], how, px.w, px.h);
            return 3;
        }
        int edge = brightest(&px, x0, y0, x1, y1, 0);
        int next = brightest(&px, x0, y0, x1, y1, 1);
        int inner = brightest(&px, x0, y0, x1, y1, 8);
        printf("mode=%s capture=%s picture=%zux%zu window=%zux%zu shadow=%s edge=%d,%d inner=%d rim=%s\n",
               argv[1], how, px.w, px.h, x1 - x0 + 1, y1 - y0 + 1,
               [w hasShadow] ? "yes" : "no", edge, next, inner, edge > inner + 8 ? "yes" : "no");
        free(px.rgba);
    }
    return 0;
}
