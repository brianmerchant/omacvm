/*
 * scanout-read: copy the buffer an output of virtio-gpu shows right now into a
 * raw file, without asking the compositor for a frame.
 *
 * grim (wlr-screencopy) and every other Wayland capture make Hyprland damage
 * the whole output and draw it again, so they always show a clean frame and
 * hide stale pixels. This reads the plane's framebuffer itself: the host
 * texture of the virgl resource is copied into the buffer's guest pages
 * (TRANSFER_FROM_HOST) and mapped. Root only (GETFB2 handles).
 *
 * usage: scanout-read OUTPUT OUT.raw   (OUTPUT: Virtual-1, ...)
 * prints "WIDTH HEIGHT PITCH FOURCC"; OUT.raw is PITCH * HEIGHT bytes.
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <libdrm/drm_fourcc.h>
#include <libdrm/virtgpu_drm.h>

static uint32_t crtc_of(int fd, const char *output)
{
    drmModeRes *res = drmModeGetResources(fd);
    uint32_t crtc = 0;

    for (int i = 0; res && i < res->count_connectors && !crtc; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        char name[64];

        if (!c) {
            continue;
        }
        snprintf(name, sizeof name, "%s-%u",
                 c->connector_type == DRM_MODE_CONNECTOR_VIRTUAL ? "Virtual" : "Other",
                 c->connector_type_id);
        if (!strcmp(name, output) && c->encoder_id) {
            drmModeEncoder *e = drmModeGetEncoder(fd, c->encoder_id);
            if (e) {
                crtc = e->crtc_id;
                drmModeFreeEncoder(e);
            }
        }
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(res);
    return crtc;
}

/* The primary plane's framebuffer on CRTC (atomic: the CRTC's own fb id may be stale). */
static uint32_t primary_fb(int fd, uint32_t crtc)
{
    drmModePlaneRes *pr = drmModeGetPlaneResources(fd);
    uint32_t fb = 0;

    for (uint32_t i = 0; pr && i < pr->count_planes && !fb; i++) {
        drmModePlane *p = drmModeGetPlane(fd, pr->planes[i]);
        if (!p) {
            continue;
        }
        if (p->crtc_id == crtc && p->fb_id) {
            drmModeObjectProperties *pp =
                drmModeObjectGetProperties(fd, p->plane_id, DRM_MODE_OBJECT_PLANE);
            for (uint32_t k = 0; pp && k < pp->count_props; k++) {
                drmModePropertyRes *prop = drmModeGetProperty(fd, pp->props[k]);
                if (prop && !strcmp(prop->name, "type") &&
                    pp->prop_values[k] == DRM_PLANE_TYPE_PRIMARY) {
                    fb = p->fb_id;
                }
                drmModeFreeProperty(prop);
            }
            drmModeFreeObjectProperties(pp);
        }
        drmModeFreePlane(p);
    }
    drmModeFreePlaneResources(pr);
    return fb;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: scanout-read OUTPUT OUT.raw\n");
        return 64;
    }
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        perror("/dev/dri/card0");
        return 1;
    }
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    uint32_t crtc = crtc_of(fd, argv[1]);
    uint32_t fb_id = crtc ? primary_fb(fd, crtc) : 0;
    if (!fb_id) {
        fprintf(stderr, "scanout-read: %s shows no framebuffer\n", argv[1]);
        return 1;
    }
    /*
     * The kernel makes this file's 3D context on first use and attaches a
     * resource to it only when its handle is opened after that: make the
     * context first, then open the handle (else the host refuses the
     * transfer as an illegal resource and drops the context).
     */
    struct drm_virtgpu_context_init ci = { 0 };
    if (ioctl(fd, DRM_IOCTL_VIRTGPU_CONTEXT_INIT, &ci)) {
        perror("VIRTGPU_CONTEXT_INIT");
        return 1;
    }
    drmModeFB2 *fb = drmModeGetFB2(fd, fb_id);
    if (!fb || !fb->handles[0]) {
        fprintf(stderr, "scanout-read: no handle for fb %u (root?)\n", fb_id);
        return 1;
    }
    uint32_t w = fb->width, h = fb->height, pitch = fb->pitches[0];
    struct drm_virtgpu_3d_transfer_from_host t = {
        .bo_handle = fb->handles[0],
        .box = { .w = w, .h = h, .d = 1 },
    };
    if (ioctl(fd, DRM_IOCTL_VIRTGPU_TRANSFER_FROM_HOST, &t)) {
        perror("VIRTGPU_TRANSFER_FROM_HOST");
        return 1;
    }
    struct drm_virtgpu_3d_wait wt = { .handle = fb->handles[0] };
    while (ioctl(fd, DRM_IOCTL_VIRTGPU_WAIT, &wt)) {
        /* busy: the transfer is not done yet */
    }
    struct drm_virtgpu_map m = { .handle = fb->handles[0] };
    if (ioctl(fd, DRM_IOCTL_VIRTGPU_MAP, &m)) {
        perror("VIRTGPU_MAP");
        return 1;
    }
    size_t size = (size_t)pitch * h;
    void *px = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, m.offset);
    if (px == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    FILE *o = fopen(argv[2], "wb");
    if (!o || fwrite(px, 1, size, o) != size || fclose(o)) {
        perror(argv[2]);
        return 1;
    }
    printf("%u %u %u %.4s\n", w, h, pitch, (const char *)&fb->pixel_format);
    return 0;
}
