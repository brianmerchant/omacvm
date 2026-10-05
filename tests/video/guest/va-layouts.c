/*
 * va-layouts: VA-API images in another 4:2:0 layout than their surface, bit for bit.
 * Run in the VM (any user):
 *   cc -O2 -o va-layouts va-layouts.c -lva -lva-drm && \
 *   LIBVA_DRIVER_NAME=omacvm LIBVA_DRIVERS_PATH=/usr/local/lib/dri:/usr/lib/dri ./va-layouts
 * For each surface layout (NV12, I420) and image layout (NV12, I420, YV12): a random
 * picture goes in with vaPutImage from one image and comes out with vaGetImage into
 * another, whole and as an odd-sized part at an offset; every Y, U and V sample must be
 * the one put in. Exit 0 when all match. OmacVM's driver shim does the layouts other
 * than the surface's on the CPU (src/app/guest/omacvm_drv_video.c).
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>

#define W 322
#define H 182

static VADisplay dpy;
static uint8_t ref_y[H][W], ref_u[H / 2][W / 2], ref_v[H / 2][W / 2];

static const char *name(uint32_t f)
{
    return f == VA_FOURCC_NV12 ? "NV12" : f == VA_FOURCC_I420 ? "I420" : "YV12";
}

/* Pointers to sample (x, y) of each plane of a mapped image. */
static uint8_t *at(const VAImage *img, uint8_t *base, int plane, int x, int y)
{
    if (plane == 0)
        return base + img->offsets[0] + y * img->pitches[0] + x;
    if (img->format.fourcc == VA_FOURCC_NV12)
        return base + img->offsets[1] + y * img->pitches[1] + 2 * x + (plane == 2);
    if (img->format.fourcc == VA_FOURCC_YV12)
        plane = 3 - plane;   /* V first */
    return base + img->offsets[plane] + y * img->pitches[plane] + x;
}

static int make_image(uint32_t fourcc, VAImage *img)
{
    VAImageFormat f = { .fourcc = fourcc, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12 };

    return vaCreateImage(dpy, &f, W, H, img) == VA_STATUS_SUCCESS;
}

static int put(VASurfaceID s, uint32_t fourcc)
{
    VAImage img;
    uint8_t *p;
    int x, y, ok;

    if (!make_image(fourcc, &img) || vaMapBuffer(dpy, img.buf, (void **)&p))
        return 0;
    for (y = 0; y < H; y++)
        for (x = 0; x < W; x++)
            *at(&img, p, 0, x, y) = ref_y[y][x];
    for (y = 0; y < H / 2; y++)
        for (x = 0; x < W / 2; x++) {
            *at(&img, p, 1, x, y) = ref_u[y][x];
            *at(&img, p, 2, x, y) = ref_v[y][x];
        }
    vaUnmapBuffer(dpy, img.buf);
    ok = vaPutImage(dpy, s, img.image_id, 0, 0, W, H, 0, 0, W, H) == VA_STATUS_SUCCESS;
    vaDestroyImage(dpy, img.image_id);
    return ok;
}

/* Reads w x h at (x0, y0) (even) into a FOURCC image; counts samples that differ. */
static long get(VASurfaceID s, uint32_t fourcc, int x0, int y0, int w, int h)
{
    VAImage img;
    uint8_t *p;
    long bad = 0;
    int x, y;

    if (!make_image(fourcc, &img))
        return -1;
    if (vaGetImage(dpy, s, x0, y0, w, h, img.image_id) || vaMapBuffer(dpy, img.buf, (void **)&p)) {
        vaDestroyImage(dpy, img.image_id);
        return -1;
    }
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++)
            bad += *at(&img, p, 0, x, y) != ref_y[y0 + y][x0 + x];
    for (y = 0; y < h / 2; y++)
        for (x = 0; x < w / 2; x++) {
            bad += *at(&img, p, 1, x, y) != ref_u[y0 / 2 + y][x0 / 2 + x];
            bad += *at(&img, p, 2, x, y) != ref_v[y0 / 2 + y][x0 / 2 + x];
        }
    vaUnmapBuffer(dpy, img.buf);
    vaDestroyImage(dpy, img.image_id);
    return bad;
}

int main(void)
{
    static const uint32_t surf[] = { VA_FOURCC_NV12, VA_FOURCC_I420 };
    static const uint32_t imgs[] = { VA_FOURCC_NV12, VA_FOURCC_I420, VA_FOURCC_YV12 };
    int fd = open("/dev/dri/renderD128", O_RDWR), major, minor, failed = 0;
    unsigned i, a, b;

    dpy = vaGetDisplayDRM(fd);
    if (fd < 0 || vaInitialize(dpy, &major, &minor)) {
        puts("FAIL: no VA-API display");
        return 1;
    }
    srand(1);
    for (i = 0; i < sizeof(ref_y); i++)
        ((uint8_t *)ref_y)[i] = rand();
    for (i = 0; i < sizeof(ref_u); i++) {
        ((uint8_t *)ref_u)[i] = rand();
        ((uint8_t *)ref_v)[i] = rand();
    }
    for (i = 0; i < 2; i++) {
        VASurfaceAttrib attr = { .type = VASurfaceAttribPixelFormat,
                                 .flags = VA_SURFACE_ATTRIB_SETTABLE,
                                 .value = { .type = VAGenericValueTypeInteger,
                                            .value.i = (int)surf[i] } };
        VASurfaceID s;

        if (vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, W, H, &s, 1, &attr, 1)) {
            printf("SKIP: no %s surfaces\n", name(surf[i]));
            continue;
        }
        for (a = 0; a < 3; a++) {
            if (!put(s, imgs[a])) {
                printf("FAIL: %s surface: vaPutImage from %s\n", name(surf[i]), name(imgs[a]));
                failed = 1;
                continue;
            }
            for (b = 0; b < 3; b++) {
                long whole = get(s, imgs[b], 0, 0, W, H);
                long part = get(s, imgs[b], 64, 32, 101, 75);

                printf("%s: %s surface, %s in, %s out: %ld + %ld samples differ\n",
                       whole || part ? "FAIL" : "PASS", name(surf[i]), name(imgs[a]),
                       name(imgs[b]), whole, part);
                failed |= whole != 0 || part != 0;
            }
        }
        vaDestroySurfaces(dpy, &s, 1);
    }
    vaTerminate(dpy);
    close(fd);
    return failed;
}
