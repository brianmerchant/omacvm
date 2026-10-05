/*
 * OmacVM's VA-API driver shim for OmacVM.app: Mesa's virtio_gpu driver with
 * one change. Mesa's virgl driver offers I420 and YV12 surfaces for decoding
 * next to NV12; FFmpeg then picks I420 (it matches yuv420p), and Firefox
 * cannot show I420 surfaces, so it falls back to decoding on the CPU. This
 * shim loads Mesa's driver unchanged and hides I420/YV12 from the surface
 * formats, as drivers for real hardware do.
 *
 * AV1: the Mac decodes whole AV1 frames with their headers, which Chromium
 * sends; FFmpeg (Firefox, mpv) sends only tile data, which cannot work. So
 * AV1 is listed for Chromium-based browsers only (OMACVM_VA_AV1=1 or 0
 * overrides).
 *
 * Limits: the Mac says in its video caps how many decoders and encoders a VM
 * should keep open at once. Past a somewhat higher limit of its own it gives
 * a new one nothing, and the guest cannot be told, so the video would stay
 * black. So the shim refuses vaCreateContext past the caps' number
 * (VA_STATUS_ERROR_MAX_NUM_EXCEEDED) and players and browsers decode (or
 * encode) that one on the CPU; an FFmpeg command that names a VA-API encoder
 * itself stops with that error. The Mac's extra room covers what the shim
 * cannot see: Mesa sends a closed context to the Mac only with the app's next
 * commands (the shim has freed its slot already), and apps that do not use
 * the shim.
 * Counting across processes: a context holds a slot, an OFD lock on one byte
 * of /dev/shm/omacvm-va-slots, so a process that quits or crashes frees its
 * slots. Firefox decodes in a sandbox that can neither open that file nor
 * lock; such a process counts only its own contexts, up to half the limit,
 * and the shared slots are the other half. The VM stays within the limit as
 * long as at most one such process decodes. OMACVM_VA_DEBUG=1 prints the
 * limits.
 *
 * Images in another YUV layout: vaGetImage and vaPutImage between an NV12
 * surface and an I420 or YV12 image (or back) are done here on the CPU, a
 * plain reshuffle of the planes, so the picture is bit for bit the decoded
 * one. Mesa does these on the GPU through its video compositor, which goes
 * through RGB and resamples the chroma; on OmacVM it gave empty pictures
 * (FFmpeg's -vf hwdownload,format=yuv420p). Everything else is Mesa's.
 *
 * Built in the VM by install.sh; used through LIBVA_DRIVER_NAME=omacvm.
 * MIT, part of OmacVM.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <drm/virtgpu_drm.h>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_drmcommon.h>

#ifndef MESA_DRIVER
#define MESA_DRIVER "/usr/lib/dri/virtio_gpu_drv_video.so"
#endif

static VAStatus (*mesa_query_surface_attributes)(VADriverContextP, VAConfigID,
                                                 VASurfaceAttrib *, unsigned int *);

static VAStatus query_surface_attributes(VADriverContextP ctx, VAConfigID config,
                                         VASurfaceAttrib *attribs, unsigned int *num)
{
    VAStatus st = mesa_query_surface_attributes(ctx, config, attribs, num);
    unsigned int i, n = 0;
    int has_nv12 = 0;

    if (st != VA_STATUS_SUCCESS || !attribs)
        return st;
    for (i = 0; i < *num; i++)
        if (attribs[i].type == VASurfaceAttribPixelFormat &&
            attribs[i].value.value.i == VA_FOURCC_NV12)
            has_nv12 = 1;
    if (!has_nv12)
        return st;
    for (i = 0; i < *num; i++) {
        if (attribs[i].type == VASurfaceAttribPixelFormat &&
            (attribs[i].value.value.i == VA_FOURCC_I420 ||
             attribs[i].value.value.i == VA_FOURCC_YV12))
            continue;
        attribs[n++] = attribs[i];
    }
    *num = n;
    return st;
}

static VAStatus (*mesa_query_config_profiles)(VADriverContextP, VAProfile *, int *);

static int av1_allowed(void)
{
    const char *env = getenv("OMACVM_VA_AV1");
    char exe[PATH_MAX];
    ssize_t n;

    if (env && *env)
        return *env == '1';
    n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0)
        return 0;
    exe[n] = 0;
    return strstr(exe, "chrom") || strstr(exe, "brave") || strstr(exe, "electron");
}

static VAStatus query_config_profiles(VADriverContextP ctx, VAProfile *list, int *num)
{
    VAStatus st = mesa_query_config_profiles(ctx, list, num);
    int i, n = 0;

    if (st != VA_STATUS_SUCCESS || av1_allowed())
        return st;
    for (i = 0; i < *num; i++) {
        if (list[i] == VAProfileAV1Profile0 || list[i] == VAProfileAV1Profile1)
            continue;
        list[n++] = list[i];
    }
    *num = n;
    return st;
}

/* ---- Images in another YUV layout (see the top) ---- */

static VAStatus (*mesa_get_image)(VADriverContextP, VASurfaceID, int, int,
                                  unsigned int, unsigned int, VAImageID);
static VAStatus (*mesa_put_image)(VADriverContextP, VASurfaceID, VAImageID, int, int,
                                  unsigned int, unsigned int, int, int,
                                  unsigned int, unsigned int);
static VAStatus (*mesa_destroy_surfaces)(VADriverContextP, VASurfaceID *, int);

static int is_420(uint32_t fourcc)
{
    return fourcc == VA_FOURCC_NV12 || fourcc == VA_FOURCC_I420 || fourcc == VA_FOURCC_YV12;
}

/* Each surface's layout, as Mesa made it (asked once, by an export). */
static pthread_mutex_t fmt_lock = PTHREAD_MUTEX_INITIALIZER;
static struct fmt {
    VADriverContextP drv;
    VASurfaceID id;
    uint32_t fourcc;
} fmts[256];
static unsigned nfmts, next_fmt;

static uint32_t surface_fourcc(VADriverContextP ctx, VASurfaceID surface)
{
    VADRMPRIMESurfaceDescriptor desc;
    uint32_t fourcc = 0;
    unsigned i;

    pthread_mutex_lock(&fmt_lock);
    for (i = 0; i < nfmts; i++)
        if (fmts[i].drv == ctx && fmts[i].id == surface)
            fourcc = fmts[i].fourcc;
    pthread_mutex_unlock(&fmt_lock);
    if (fourcc || !ctx->vtable->vaExportSurfaceHandle)
        return fourcc;
    memset(&desc, 0, sizeof(desc));
    if (ctx->vtable->vaExportSurfaceHandle(ctx, surface, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                           VA_EXPORT_SURFACE_READ_ONLY |
                                           VA_EXPORT_SURFACE_SEPARATE_LAYERS,
                                           &desc) != VA_STATUS_SUCCESS)
        return 0;
    for (i = 0; i < desc.num_objects && i < 4; i++)
        close(desc.objects[i].fd);
    fourcc = desc.fourcc;
    pthread_mutex_lock(&fmt_lock);
    if (nfmts < sizeof(fmts) / sizeof(fmts[0])) {
        fmts[nfmts++] = (struct fmt){ ctx, surface, fourcc };
    } else {
        fmts[next_fmt] = (struct fmt){ ctx, surface, fourcc };
        next_fmt = (next_fmt + 1) % nfmts;
    }
    pthread_mutex_unlock(&fmt_lock);
    return fourcc;
}

/* A surface ID may come back for a new surface: forget the old one's (or,
 * with n < 0, every surface of a display that closes). */
static void forget_surfaces(VADriverContextP ctx, const VASurfaceID *ids, int n)
{
    unsigned i = 0;
    int k;

    pthread_mutex_lock(&fmt_lock);
    while (i < nfmts) {
        int hit = n < 0;

        for (k = 0; k < n && !hit; k++)
            hit = fmts[i].id == ids[k];
        if (hit && fmts[i].drv == ctx) {
            fmts[i] = fmts[--nfmts];
            next_fmt = 0;
        } else {
            i++;
        }
    }
    pthread_mutex_unlock(&fmt_lock);
}

static VAStatus destroy_surfaces(VADriverContextP ctx, VASurfaceID *list, int n)
{
    forget_surfaces(ctx, list, n);
    return mesa_destroy_surfaces(ctx, list, n);
}

/* Where an image's planes are: Y, and U and V with their step (2 in NV12). */
struct planes {
    uint8_t *y, *u, *v;
    unsigned ypitch, cpitch, step;
};

static int planes_of(const VAImage *img, uint8_t *base, struct planes *p)
{
    p->y = base + img->offsets[0];
    p->ypitch = img->pitches[0];
    p->cpitch = img->pitches[1];
    switch (img->format.fourcc) {
    case VA_FOURCC_NV12:
        p->u = base + img->offsets[1];
        p->v = p->u + 1;
        p->step = 2;
        return 1;
    case VA_FOURCC_I420:
        p->u = base + img->offsets[1];
        p->v = base + img->offsets[2];
        break;
    case VA_FOURCC_YV12:
        p->v = base + img->offsets[1];
        p->u = base + img->offsets[2];
        break;
    default:
        return 0;
    }
    p->step = 1;
    /* Both chroma planes share a pitch in Mesa's images; refuse otherwise. */
    return img->pitches[2] == img->pitches[1];
}

static void copy_420(const struct planes *s, const struct planes *d, unsigned w, unsigned h)
{
    unsigned x, r, cw = (w + 1) / 2, ch = (h + 1) / 2;

    for (r = 0; r < h; r++)
        memcpy(d->y + r * d->ypitch, s->y + r * s->ypitch, w);
    for (r = 0; r < ch; r++) {
        const uint8_t *su = s->u + r * s->cpitch, *sv = s->v + r * s->cpitch;
        uint8_t *du = d->u + r * d->cpitch, *dv = d->v + r * d->cpitch;

        for (x = 0; x < cw; x++) {
            du[x * d->step] = su[x * s->step];
            dv[x * d->step] = sv[x * s->step];
        }
    }
}

/* Copies w x h from image `from` to image `to` (other 4:2:0 layout) at 0,0. */
static VAStatus convert_image(VADriverContextP ctx, const VAImage *from, const VAImage *to,
                              unsigned w, unsigned h)
{
    void *src = NULL, *dst = NULL;
    struct planes sp, dp;
    VAStatus st;

    if (w > from->width || h > from->height || w > to->width || h > to->height)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    st = ctx->vtable->vaMapBuffer(ctx, from->buf, &src);
    if (st != VA_STATUS_SUCCESS)
        return st;
    st = ctx->vtable->vaMapBuffer(ctx, to->buf, &dst);
    if (st == VA_STATUS_SUCCESS) {
        if (planes_of(from, src, &sp) && planes_of(to, dst, &dp))
            copy_420(&sp, &dp, w, h);
        else
            st = VA_STATUS_ERROR_OPERATION_FAILED;
        ctx->vtable->vaUnmapBuffer(ctx, to->buf);
    }
    ctx->vtable->vaUnmapBuffer(ctx, from->buf);
    return st;
}

/* The app's 4:2:0 images by ID (vaGetImage and vaPutImage name only the ID):
 * recorded at vaCreateImage, dropped at vaDestroyImage. */
static VAStatus (*mesa_create_image)(VADriverContextP, VAImageFormat *, int, int, VAImage *);
static VAStatus (*mesa_destroy_image)(VADriverContextP, VAImageID);
static struct img {
    VADriverContextP drv;
    VAImage image;
} imgs[256];
static unsigned nimgs;

static VAStatus create_image(VADriverContextP ctx, VAImageFormat *format, int width,
                             int height, VAImage *image)
{
    VAStatus st = mesa_create_image(ctx, format, width, height, image);

    if (st == VA_STATUS_SUCCESS && is_420(image->format.fourcc)) {
        pthread_mutex_lock(&fmt_lock);
        if (nimgs < sizeof(imgs) / sizeof(imgs[0]))
            imgs[nimgs++] = (struct img){ ctx, *image };
        pthread_mutex_unlock(&fmt_lock);
    }
    return st;
}

static void forget_image(VADriverContextP ctx, VAImageID id, int all)
{
    unsigned i = 0;

    pthread_mutex_lock(&fmt_lock);
    while (i < nimgs) {
        if (imgs[i].drv == ctx && (all || imgs[i].image.image_id == id))
            imgs[i] = imgs[--nimgs];
        else
            i++;
    }
    pthread_mutex_unlock(&fmt_lock);
}

static VAStatus destroy_image(VADriverContextP ctx, VAImageID id)
{
    forget_image(ctx, id, 0);
    return mesa_destroy_image(ctx, id);
}

static int find_image(VADriverContextP ctx, VAImageID id, VAImage *out)
{
    unsigned i;
    int found = 0;

    pthread_mutex_lock(&fmt_lock);
    for (i = 0; i < nimgs && !found; i++)
        if (imgs[i].drv == ctx && imgs[i].image.image_id == id) {
            *out = imgs[i].image;
            found = 1;
        }
    pthread_mutex_unlock(&fmt_lock);
    return found;
}

/* A temporary image in the surface's own layout. Not recorded: the shim's
 * own wrappers never see it. */
static VAStatus temp_image(VADriverContextP ctx, uint32_t fourcc, int w, int h, VAImage *img)
{
    VAImageFormat f = { .fourcc = fourcc, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12 };

    return mesa_create_image(ctx, &f, w, h, img);
}

/* The surface's layout when it and the image are different 4:2:0 layouts
 * (the case done here), else 0 (Mesa's own path). */
static uint32_t other_layout(VADriverContextP ctx, VASurfaceID surface, VAImageID id,
                             VAImage *image)
{
    uint32_t s;

    if (!find_image(ctx, id, image))
        return 0;
    s = surface_fourcc(ctx, surface);
    return is_420(s) && s != image->format.fourcc ? s : 0;
}

static VAStatus get_image(VADriverContextP ctx, VASurfaceID surface, int x, int y,
                          unsigned int width, unsigned int height, VAImageID id)
{
    VAImage image, tmp;
    uint32_t s = other_layout(ctx, surface, id, &image);
    VAStatus st;

    if (!s)
        return mesa_get_image(ctx, surface, x, y, width, height, id);
    st = temp_image(ctx, s, image.width, image.height, &tmp);
    if (st != VA_STATUS_SUCCESS)
        return st;
    st = mesa_get_image(ctx, surface, x, y, width, height, tmp.image_id);
    if (st == VA_STATUS_SUCCESS)
        st = convert_image(ctx, &tmp, &image, width, height);
    mesa_destroy_image(ctx, tmp.image_id);
    return st;
}

/* Only a 1:1 copy is done here; a scaled put stays Mesa's. */
static VAStatus put_image(VADriverContextP ctx, VASurfaceID surface, VAImageID id,
                          int src_x, int src_y, unsigned int src_w, unsigned int src_h,
                          int dst_x, int dst_y, unsigned int dst_w, unsigned int dst_h)
{
    VAImage image, tmp;
    uint32_t s = src_x == 0 && src_y == 0 && src_w == dst_w && src_h == dst_h ?
                 other_layout(ctx, surface, id, &image) : 0;
    VAStatus st;

    if (!s)
        return mesa_put_image(ctx, surface, id, src_x, src_y, src_w, src_h,
                              dst_x, dst_y, dst_w, dst_h);
    st = temp_image(ctx, s, image.width, image.height, &tmp);
    if (st != VA_STATUS_SUCCESS)
        return st;
    st = convert_image(ctx, &image, &tmp, src_w, src_h);
    if (st == VA_STATUS_SUCCESS)
        st = mesa_put_image(ctx, surface, tmp.image_id, 0, 0, src_w, src_h,
                            dst_x, dst_y, dst_w, dst_h);
    mesa_destroy_image(ctx, tmp.image_id);
    return st;
}

/* ---- Limits (see the top) ---- */

enum { DEC, ENC, KINDS };
static const char *const kind_name[KINDS] = { "decoders", "encoders" };

/* The virgl caps (capset 2) as the host sends them. The struct only grows at
 * its end (virgl protocol), so these offsets stay. Per video cap, OmacVM's
 * host puts the limit for that entrypoint into the top 8 of the 20 reserved
 * bits of the 4th word; 0 (any other host) means no limit is said. */
#define CAPS_SIZE 1408          /* sizeof(union virgl_caps) */
#define CAPS_NUM_VIDEO 856      /* offsetof(struct virgl_caps_v2, num_video_caps) */
#define CAPS_VIDEO 860          /* offsetof(struct virgl_caps_v2, video_caps), 16 bytes each */
#define PIPE_ENTRYPOINT_BITSTREAM 1
#define PIPE_ENTRYPOINT_ENCODE 4

#define SLOTS_FILE "/dev/shm/omacvm-va-slots"
#define SLOTS_KIND_STRIDE 256   /* encoders' bytes start here */

static pthread_mutex_t lim_lock = PTHREAD_MUTEX_INITIALIZER;
static int lim_read;            /* the host's caps were read */
static unsigned limit[KINDS];   /* per VM; 0 = none said */
static int slots_fd = -1;       /* the shared slots */
static int slots_ok;            /* ... usable: else this process counts on its own */
static unsigned own[KINDS];     /* contexts counted in this process only */
static struct held {
    VADriverContextP drv;
    VAContextID id;
    int kind;
    int slot;                   /* byte in SLOTS_FILE, or -1 (counted in own[]) */
} held[2 * 256];                /* limits are 8 bits: at most 255 each */
static unsigned nheld;

static VAStatus (*mesa_create_context)(VADriverContextP, VAConfigID, int, int, int,
                                       VASurfaceID *, int, VAContextID *);
static VAStatus (*mesa_destroy_context)(VADriverContextP, VAContextID);
static VAStatus (*mesa_terminate)(VADriverContextP);

static void read_limits(VADriverContextP ctx)
{
    struct drm_state *drm = ctx->drm_state;
    uint32_t caps[CAPS_SIZE / 4] = { 0 };
    struct drm_virtgpu_get_caps args = { .cap_set_id = 2, .cap_set_ver = 0,
                                         .addr = (uintptr_t)caps, .size = sizeof(caps) };
    uint32_t i, n;

    if (!drm || drm->fd < 0 || ioctl(drm->fd, DRM_IOCTL_VIRTGPU_GET_CAPS, &args))
        return;
    lim_read = 1;
    n = caps[CAPS_NUM_VIDEO / 4];
    for (i = 0; i < n && i < 32; i++) {
        const uint32_t *v = &caps[(CAPS_VIDEO + 16 * i) / 4];
        unsigned entrypoint = (v[0] >> 8) & 0xff, max = v[3] >> 24;
        int k = entrypoint == PIPE_ENTRYPOINT_BITSTREAM ? DEC :
                entrypoint == PIPE_ENTRYPOINT_ENCODE ? ENC : -1;
        if (k >= 0 && max && (!limit[k] || max < limit[k]))
            limit[k] = max;
    }
    if (!limit[DEC] && !limit[ENC]) {
        if (getenv("OMACVM_VA_DEBUG"))
            fprintf(stderr, "omacvm_drv_video: the Mac says no limit (an older OmacVM)\n");
        return;
    }
    /* Opened before a sandbox closes in where it can (Chrome); Firefox's
     * decoding process cannot, and then counts on its own. Not O_CREAT on an
     * existing file: another user's file in /dev/shm would be refused. */
    slots_fd = open(SLOTS_FILE, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (slots_fd < 0 && errno == ENOENT) {
        slots_fd = open(SLOTS_FILE, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0666);
        if (slots_fd >= 0)
            fchmod(slots_fd, 0666);
        else if (errno == EEXIST)
            slots_fd = open(SLOTS_FILE, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    }
    slots_ok = slots_fd >= 0;
    if (getenv("OMACVM_VA_DEBUG"))
        fprintf(stderr, "omacvm_drv_video: the Mac keeps at most %u decoders and %u encoders "
                "open per VM (0: none said); this process %s\n", limit[DEC], limit[ENC],
                slots_ok ? "shares the count through " SLOTS_FILE : "counts on its own");
}

/* Shared slots are half the limit (rounded up), a process counting on its
 * own gets the other half. */
static unsigned shared_slots(int k) { return limit[k] - limit[k] / 2; }
static unsigned own_budget(int k) { return limit[k] / 2; }

/* A free shared slot (locked for this context), -1 if all are taken, -2 if
 * locks do not work here. Called with lim_lock held, like everything that
 * touches the state above. */
static int take_slot(int k)
{
    unsigned s, i;

    for (s = 0; s < shared_slots(k); s++) {
        struct flock fl = { .l_type = F_WRLCK, .l_whence = SEEK_SET,
                            .l_start = k * SLOTS_KIND_STRIDE + s, .l_len = 1 };
        /* OFD locks belong to the open file, so this process's own slots do
         * not conflict: skip them by hand. */
        for (i = 0; i < nheld; i++)
            if (held[i].kind == k && held[i].slot == (int)s)
                break;
        if (i < nheld)
            continue;
        if (fcntl(slots_fd, F_OFD_SETLK, &fl) == 0)
            return s;
        if (errno != EAGAIN && errno != EACCES)
            return -2;
    }
    return -1;
}

static void give_back(int k, int slot)
{
    if (slot >= 0) {
        struct flock fl = { .l_type = F_UNLCK, .l_whence = SEEK_SET,
                            .l_start = k * SLOTS_KIND_STRIDE + slot, .l_len = 1 };
        fcntl(slots_fd, F_OFD_SETLK, &fl);
    } else if (own[k]) {
        own[k]--;
    }
}

/* Decoder, encoder, or neither (video processing makes no codec on the Mac). */
static int config_kind(VADriverContextP ctx, VAConfigID config)
{
    VAProfile profile;
    VAEntrypoint entrypoint;
    VAConfigAttrib *attribs;
    int n = 0, k = -1;

    if (!ctx->vtable->vaQueryConfigAttributes)
        return -1;
    attribs = calloc(ctx->max_attributes > 0 ? ctx->max_attributes : 1, sizeof(*attribs));
    if (attribs && ctx->vtable->vaQueryConfigAttributes(ctx, config, &profile, &entrypoint,
                                                        attribs, &n) == VA_STATUS_SUCCESS)
        k = entrypoint == VAEntrypointVLD ? DEC :
            entrypoint == VAEntrypointEncSlice || entrypoint == VAEntrypointEncSliceLP ||
            entrypoint == VAEntrypointEncPicture ? ENC : -1;
    free(attribs);
    return k;
}

/* A refusal goes to stderr: the first at once, then at most every 10 s with
 * how many there were since. */
static void say_refused(int k, int shared)
{
    static struct timespec last[KINDS];
    static unsigned since[KINDS];
    struct timespec now;

    clock_gettime(CLOCK_MONOTONIC, &now);
    if (last[k].tv_sec && now.tv_sec - last[k].tv_sec < 10) {
        since[k]++;
        return;
    }
    if (shared)
        fprintf(stderr, "omacvm_drv_video: the VM's %u hardware video %s are in use (the Mac "
                "keeps %u open per VM); refused this one (players and browsers use the CPU "
                "then)", shared_slots(k), kind_name[k], limit[k]);
    else
        fprintf(stderr, "omacvm_drv_video: this process has its %u hardware video %s open "
                "(half the Mac's %u per VM); refused this one (players and browsers use the "
                "CPU then)", own_budget(k), kind_name[k], limit[k]);
    if (since[k])
        fprintf(stderr, " (%u more refused in the last %ld s)", since[k],
                (long)(now.tv_sec - last[k].tv_sec));
    fputc('\n', stderr);
    last[k] = now;
    since[k] = 0;
}

static VAStatus create_context(VADriverContextP ctx, VAConfigID config, int width, int height,
                               int flag, VASurfaceID *targets, int num_targets,
                               VAContextID *context)
{
    int k = config_kind(ctx, config), slot = -1;
    VAStatus st;

    pthread_mutex_lock(&lim_lock);
    if (!lim_read)
        read_limits(ctx);
    if (k < 0 || !limit[k]) {
        pthread_mutex_unlock(&lim_lock);
        return mesa_create_context(ctx, config, width, height, flag, targets, num_targets, context);
    }
    if (slots_ok) {
        slot = take_slot(k);
        if (slot == -2) {
            /* Locks refused (a sandbox): count on our own from now on. Slots
             * this process holds stay held (closing the file would drop them). */
            fprintf(stderr, "omacvm_drv_video: cannot lock %s here, counting this process's "
                    "video contexts on its own\n", SLOTS_FILE);
            slots_ok = 0;
        } else if (slot == -1) {
            say_refused(k, 1);
            pthread_mutex_unlock(&lim_lock);
            return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
        }
    }
    if (slot < 0) {
        if (own[k] >= own_budget(k)) {
            say_refused(k, 0);
            pthread_mutex_unlock(&lim_lock);
            return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
        }
        own[k]++;
        slot = -1;
    }
    pthread_mutex_unlock(&lim_lock);

    st = mesa_create_context(ctx, config, width, height, flag, targets, num_targets, context);

    pthread_mutex_lock(&lim_lock);
    if (st == VA_STATUS_SUCCESS && nheld < sizeof(held) / sizeof(held[0]))
        held[nheld++] = (struct held){ ctx, *context, k, slot };
    else
        give_back(k, slot);
    pthread_mutex_unlock(&lim_lock);
    return st;
}

static void release(VADriverContextP ctx, VAContextID id, int all)
{
    unsigned i = 0;

    pthread_mutex_lock(&lim_lock);
    while (i < nheld) {
        if (held[i].drv == ctx && (all || held[i].id == id)) {
            give_back(held[i].kind, held[i].slot);
            held[i] = held[--nheld];
            if (!all)
                break;
        } else {
            i++;
        }
    }
    pthread_mutex_unlock(&lim_lock);
}

/* The slot is given back first: once Mesa frees the context, another thread
 * may get the same ID for a new one. */
static VAStatus destroy_context(VADriverContextP ctx, VAContextID context)
{
    release(ctx, context, 0);
    return mesa_destroy_context(ctx, context);
}

/* A display closed with contexts still open frees their slots too. */
static VAStatus terminate(VADriverContextP ctx)
{
    release(ctx, 0, 1);
    forget_surfaces(ctx, NULL, -1);
    forget_image(ctx, 0, 1);
    return mesa_terminate(ctx);
}

typedef VAStatus (*init_fn)(VADriverContextP);

static VAStatus shim_init(VADriverContextP ctx)
{
    static void *mesa;
    char name[32];
    init_fn init = NULL;
    VAStatus st;
    int minor;

    if (!mesa)
        mesa = dlopen(MESA_DRIVER, RTLD_NOW | RTLD_GLOBAL);
    if (!mesa)
        return VA_STATUS_ERROR_UNKNOWN;
    for (minor = 99; minor >= 0 && !init; minor--) {
        snprintf(name, sizeof(name), "__vaDriverInit_1_%d", minor);
        init = (init_fn)dlsym(mesa, name);
    }
    if (!init)
        return VA_STATUS_ERROR_UNKNOWN;
    st = init(ctx);
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaQuerySurfaceAttributes) {
        mesa_query_surface_attributes = ctx->vtable->vaQuerySurfaceAttributes;
        ctx->vtable->vaQuerySurfaceAttributes = query_surface_attributes;
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaQueryConfigProfiles) {
        mesa_query_config_profiles = ctx->vtable->vaQueryConfigProfiles;
        ctx->vtable->vaQueryConfigProfiles = query_config_profiles;
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaCreateContext &&
        ctx->vtable->vaDestroyContext && ctx->vtable->vaTerminate) {
        mesa_create_context = ctx->vtable->vaCreateContext;
        mesa_destroy_context = ctx->vtable->vaDestroyContext;
        mesa_terminate = ctx->vtable->vaTerminate;
        ctx->vtable->vaCreateContext = create_context;
        ctx->vtable->vaDestroyContext = destroy_context;
        ctx->vtable->vaTerminate = terminate;
        pthread_mutex_lock(&lim_lock);
        if (!lim_read)
            read_limits(ctx);
        pthread_mutex_unlock(&lim_lock);
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaGetImage &&
        ctx->vtable->vaPutImage && ctx->vtable->vaCreateImage && ctx->vtable->vaDestroyImage &&
        ctx->vtable->vaDestroySurfaces && ctx->vtable->vaMapBuffer && ctx->vtable->vaUnmapBuffer) {
        mesa_get_image = ctx->vtable->vaGetImage;
        mesa_put_image = ctx->vtable->vaPutImage;
        mesa_create_image = ctx->vtable->vaCreateImage;
        mesa_destroy_image = ctx->vtable->vaDestroyImage;
        mesa_destroy_surfaces = ctx->vtable->vaDestroySurfaces;
        ctx->vtable->vaGetImage = get_image;
        ctx->vtable->vaPutImage = put_image;
        ctx->vtable->vaCreateImage = create_image;
        ctx->vtable->vaDestroyImage = destroy_image;
        ctx->vtable->vaDestroySurfaces = destroy_surfaces;
    }
    return st;
}

/* libva looks for its own minor version first, then older ones. */
#define INIT(m) VAStatus __vaDriverInit_1_##m(VADriverContextP ctx); \
    __attribute__((visibility("default"))) VAStatus __vaDriverInit_1_##m(VADriverContextP ctx) { return shim_init(ctx); }
INIT(20) INIT(21) INIT(22) INIT(23) INIT(24) INIT(25) INIT(26) INIT(27) INIT(28)
INIT(29) INIT(30) INIT(31) INIT(32)
