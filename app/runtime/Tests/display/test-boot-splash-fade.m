/*
 * test-boot-splash-fade: the boot logo fades into the desktop once.
 *
 * -fade in ui/cocoa.m (omacvm-cocoa-boot-splash.patch) adds its own 0.4 s
 * "fade" animation and sets the layer's opacity to 0. If the layer's actions
 * do not turn off "opacity", Core Animation adds its implicit 0.25 s opacity
 * animation on top: it ends first, and the logo comes back at ~25 % and fades
 * a second time (seen in the start-sequence v2 recording).
 *
 * intro-actions.inc is the layer's actions dictionary, taken from the patch
 * (check-boot-splash.sh) or the patched ui/cocoa.m (build-qemu-gpu-runtime.sh).
 * The layer is put in an offscreen CARenderer's tree on Apple's software GL
 * renderer, so CA gives it implicit actions as in a window; nothing is drawn
 * and no window opens.
 */
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/OpenGL.h>
#include <stdio.h>

static NSDictionary *intro_actions(void)
{
    return
#include "intro-actions.inc"
    ;
}

/* -fade's steps: the explicit animation, then the model value. */
static NSArray *fade_keys(CALayer *l)
{
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    NSArray *keys;

    [a setFromValue:@1.0];
    [a setToValue:@0.0];
    [a setDuration:0.4];
    [CATransaction begin];
    [l addAnimation:a forKey:@"fade"];
    [l setOpacity:0];
    keys = [l animationKeys];
    [CATransaction commit];
    return keys;
}

int main(void)
{
    @autoreleasepool {
        CGLPixelFormatAttribute attrs[] = {
            kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID, 0
        };
        CGLPixelFormatObj pf;
        CGLContextObj ctx;
        GLint n;
        CARenderer *r;
        CALayer *root = [CALayer layer], *bare = [CALayer layer], *logo = [CALayer layer];
        NSArray *keys;
        int failures = 0;

        if (CGLChoosePixelFormat(attrs, &pf, &n) != kCGLNoError || !pf ||
            CGLCreateContext(pf, NULL, &ctx) != kCGLNoError) {
            fprintf(stderr, "test-boot-splash-fade: no software GL context\n");
            return 1;
        }
        CGLDestroyPixelFormat(pf);
        r = [CARenderer rendererWithCGLContext:ctx options:nil];
        [root setFrame:CGRectMake(0, 0, 16, 16)];
        [r setLayer:root];
        [r setBounds:[root frame]];
        [root addSublayer:bare];
        [root addSublayer:logo];
        [logo setActions:intro_actions()];
        [CATransaction flush];

        /* The harness itself: without the actions, CA does add its own. */
        keys = fade_keys(bare);
        if (![keys containsObject:@"opacity"]) {
            fprintf(stderr, "test-boot-splash-fade: CA added no implicit opacity animation "
                    "here (%s); the check below would prove nothing\n",
                    [[keys componentsJoinedByString:@","] UTF8String]);
            failures++;
        }
        keys = fade_keys(logo);
        if (![keys isEqualToArray:@[ @"fade" ]]) {
            fprintf(stderr, "test-boot-splash-fade: the logo's fade runs [%s], not only "
                    "\"fade\": add \"opacity\" to its no-action list\n",
                    [[keys componentsJoinedByString:@","] UTF8String]);
            failures++;
        }
        [r setLayer:nil];
        CGLDestroyContext(ctx);
        if (failures) {
            return 1;
        }
        printf("test-boot-splash-fade: the logo fades once (only its own 0.4 s fade)\n");
    }
    return 0;
}
