/*
 * The start animation's core (ui/omacvm-splash.h of
 * omacvm-cocoa-boot-splash.patch), built on its own:
 *
 * - it starts as the word OMACVM, every cell still, and ends as exactly the
 *   logo's cells (the firmware's), still, with no glow;
 * - the timeline: OMACVM holds INTRO_HOLD s, the cells fly for 2.5 to 3 s
 *   after that, nothing moves after INTRO_END;
 * - still cells end on the pixels where GL's nearest sampling of the logo
 *   texture ends them (omacvm_splash_draw), at several window sizes, so the
 *   animation's last frame is the GL splash's logo; the cells are square;
 * - no cell jumps from one frame to the next (120 Hz);
 * - the glow comes and goes: none at the start and the end, some mid-flight;
 *   the background is plain navy without it;
 * - the desktop is told apart from the firmware's logo and text on black.
 *
 * build-qemu-gpu-runtime.sh builds it with -I the patched ui/;
 * check-boot-splash.sh with the header taken from the patch.
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define g_new0(T, n) ((T *)calloc((n), sizeof(T)))

#include "omacvm-splash.h"

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "test-boot-splash-morph: " __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

static IntroCell cells[INTRO_MAX];

/* The cells at t as a grid of whole/half cells: grid[y][2x] = on. */
static bool word[SPLASH_ROWS][2 * SPLASH_COLS + 2];

static int still_grid(double t, double *glow)
{
    int n = omacvm_intro_cells(t, cells, glow);

    memset(word, 0, sizeof(word));
    for (int i = 0; i < n; i++) {
        double x2 = cells[i].x * 2, y = cells[i].y;
        if (!cells[i].rest || cells[i].size != 1 || x2 != floor(x2) || y != floor(y) ||
            x2 < 0 || x2 > 2 * SPLASH_COLS || y < 0 || y >= SPLASH_ROWS) {
            return -1;
        }
        word[(int)y][(int)x2] = true;
    }
    return n;
}

static void test_ends(void)
{
    double glow;

    /* The end, and long after it: the logo, cell for cell. */
    for (double t = INTRO_END; t < INTRO_END + 5; t += 0.5) {
        CHECK(still_grid(t, &glow) > 0, "t=%.1f: a cell still moves after the end", t);
        CHECK(glow == 0, "t=%.1f: glow %.3f after the end", t, glow);
        for (int r = 0; r < SPLASH_ROWS; r++) {
            for (int c = 0; c < SPLASH_COLS; c++) {
                bool logo = omacvm_splash_cells[r][c] == '#';
                CHECK(word[r][2 * c] == logo, "t=%.1f: cell %d,%d is %s the logo's", t,
                      c, r, logo ? "missing from" : "not in");
                CHECK(!word[r][2 * c + 1], "t=%.1f: a cell between columns", t);
            }
        }
    }

    /* The start: OMACVM, 76 cells wide, 2.5 cells right of the logo. */
    CHECK(still_grid(0, &glow) > 0, "t=0: not every cell is still");
    CHECK(glow == 0, "t=0: glow %.3f", glow);
    int left = 2 * SPLASH_COLS, right = 0, on = 0;
    for (int r = 0; r < SPLASH_ROWS; r++) {
        for (int x2 = 0; x2 < 2 * SPLASH_COLS + 2; x2++) {
            if (word[r][x2]) {
                left = MIN(left, x2);
                right = MAX(right, x2);
                on++;
                /* O, M and A where the logo has them, 2.5 cells on. */
                if (x2 < 2 * MORPH_KEEP_COLS) {
                    CHECK(x2 % 2 == 1 && omacvm_splash_cells[r][(x2 - 5) / 2] == '#',
                          "t=0: %g,%d is not O, M or A", x2 / 2.0, r);
                }
            }
        }
    }
    CHECK(left == 5 && right == 5 + 2 * 75, "t=0: OMACVM spans %g..%g, not 2.5..77.5",
          left / 2.0, right / 2.0);
    CHECK(on > 300, "t=0: only %d cells", on);
}

/* GL_NEAREST over the 81 x 19 texture in the viewport omacvm_splash_draw()
 * sets: the first pixel (from the top left) of each cell. The logo: as in a
 * 1920 x 1080 frame with 10-pixel cells (810 x 190, the firmware's) stretched
 * to w x h, square cells. */
static void gl_edges(int w, int h, int *xs, int *ys)
{
    double cell = MIN(w * 10.0 / 1920, h * 10.0 / 1080);
    int lw = MAX(1, (int)lround(81 * cell)), lh = MAX(1, (int)lround(19 * cell));
    int vx = (w - lw) / 2, vy = (h - lh) / 2;   /* GL: from the bottom */

    for (int c = 0; c <= SPLASH_COLS; c++) {
        xs[c] = -1;
    }
    for (int p = vx; p < vx + lw; p++) {
        int c = (int)floor((p + 0.5 - vx) / lw * SPLASH_COLS);
        if (xs[c] < 0) {
            xs[c] = p;
        }
    }
    xs[SPLASH_COLS] = vx + lw;
    for (int r = 0; r <= SPLASH_ROWS; r++) {
        ys[r] = -1;
    }
    /* Rows from the top: texture row 0 is the logo's top row. */
    for (int j = vy + lh - 1; j >= vy; j--) {
        int r = (int)floor((vy + lh - (j + 0.5)) / lh * SPLASH_ROWS);
        if (ys[r] < 0) {
            ys[r] = h - 1 - j;
        }
    }
    ys[SPLASH_ROWS] = h - vy;
}

static void test_geometry(void)
{
    static const int sizes[][2] = {
        { 1280, 720 }, { 1920, 1080 }, { 2880, 1800 }, { 3456, 2234 }, { 1366, 768 },
        { 2000, 1333 }, { 1600, 1000 }, { 1217, 777 }, { 800, 1200 }, { 5120, 1440 },
        { 640, 480 },
    };
    double glow;
    int n = omacvm_intro_cells(INTRO_END, cells, &glow);

    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
        int w = sizes[s][0], h = sizes[s][1], xs[SPLASH_COLS + 1], ys[SPLASH_ROWS + 1];
        IntroGeom g = omacvm_intro_geom(w, h);
        int bad = 0;

        gl_edges(w, h, xs, ys);
        /* Square cells, up to the rounding of the logo's size. */
        CHECK(fabs(g.sx - g.sy) < 1.0 / SPLASH_ROWS + 1e-9, "%dx%d: cells %.3f x %.3f", w, h,
              g.sx, g.sy);
        for (int i = 0; i < n; i++) {
            int c = (int)cells[i].x, r = (int)cells[i].y;
            double e[4];
            omacvm_intro_rect(&g, &cells[i], e);
            if (e[0] != xs[c] || e[2] != xs[c + 1] || e[1] != ys[r] || e[3] != ys[r + 1]) {
                if (!bad++) {
                    fprintf(stderr, "  %dx%d cell %d,%d: %g..%g x %g..%g, GL %d..%d x %d..%d\n",
                            w, h, c, r, e[0], e[2], e[1], e[3], xs[c], xs[c + 1],
                            ys[r], ys[r + 1]);
                }
            }
        }
        CHECK(!bad, "%dx%d: %d cells off GL's pixels", w, h, bad);
    }
}

static void test_motion(void)
{
    static IntroCell prev[INTRO_MAX];
    double glow, most = 0, glow_max = 0, step = 0;
    int n = omacvm_intro_cells(0, prev, &glow);

    for (int f = 1; f <= (int)(INTRO_END * 120) + 12; f++) {
        double t = f / 120.0;
        omacvm_intro_cells(t, cells, &glow);
        glow_max = fmax(glow_max, glow);
        for (int i = 0; i < n; i++) {
            step = fmax(fabs(cells[i].x - prev[i].x), fabs(cells[i].y - prev[i].y));
            most = fmax(most, step);
        }
        memcpy(prev, cells, sizeof(cells));
    }
    /* The fastest cell crosses ~30 cells in 0.8 s, eased: under 1 cell a frame. */
    CHECK(most < 1, "a cell moves %.2f cells in one frame", most);
    CHECK(glow_max > 0.3 && glow_max < 1, "glow peaks at %.3f", glow_max);
}

static void test_background(void)
{
    static uint8_t px[INTRO_BG_W * INTRO_BG_H * 4];
    double glow;
    int n = omacvm_intro_cells(INTRO_END, cells, &glow);
    int lit = 0, top = 0;

    omacvm_intro_background(cells, n, glow, px);
    for (int i = 0; i < INTRO_BG_W * INTRO_BG_H; i++) {
        lit += px[i * 4] != 0x1a || px[i * 4 + 1] != 0x1b || px[i * 4 + 2] != 0x26 ||
               px[i * 4 + 3] != 255;
    }
    CHECK(!lit, "the end's background is not plain navy (%d pixels)", lit);

    /* The glow's peak: 2.05 s into the preview. */
    n = omacvm_intro_cells(INTRO_HOLD + (2.05 - PREVIEW_START) * INTRO_SLOW, cells, &glow);
    omacvm_intro_background(cells, n, glow, px);
    int out = 0;
    for (int i = 0; i < INTRO_BG_W * INTRO_BG_H; i++) {
        top = MAX(top, px[i * 4 + 1]);
        /* Never past the green, never under the navy. */
        out += px[i * 4 + 1] < 0x1b || px[i * 4 + 1] > 0xcd;
    }
    CHECK(!out, "%d glow pixels out of range", out);
    CHECK(top > 0x1b + 20, "no glow at its peak (green %d)", top);
}

/* The timeline: OMACVM holds, then the cells fly for 2.5 to 3 s. */
static void test_timeline(void)
{
    static IntroCell first[INTRO_MAX];
    double glow, first_move = -1, last = -1;
    int n = omacvm_intro_cells(0, first, &glow);

    for (double t = 0; t <= INTRO_HOLD; t += 1 / 120.0) {
        omacvm_intro_cells(t, cells, &glow);
        CHECK(!memcmp(first, cells, n * sizeof(cells[0])), "t=%.3f: OMACVM moves before %.1f s",
              t, INTRO_HOLD);
    }
    for (int f = 0; f <= (int)((INTRO_END + 1) * 120); f++) {
        double t = f / 120.0;
        bool moving = false;

        omacvm_intro_cells(t, cells, &glow);
        for (int i = 0; i < n; i++) {
            moving |= !cells[i].rest;
        }
        if (moving) {
            first_move = first_move < 0 ? t : first_move;
            last = t;
        }
        if (fabs(t - (INTRO_HOLD + 0.1)) < 1 / 240.0) {
            CHECK(moving, "nothing moves 0.1 s after OMACVM's hold");
        }
    }
    /* The user's ask: OMACVM about 0.6 s, the morph 2.5 to 3 s. */
    CHECK(first_move >= 0.55 && first_move <= 0.7, "OMACVM holds %.2f s, not about 0.6",
          first_move);
    CHECK(last - INTRO_HOLD >= 2.5 && last - INTRO_HOLD <= 3.0,
          "the cells fly for %.2f s, not 2.5 to 3", last - INTRO_HOLD);
    CHECK(INTRO_END >= last && INTRO_END <= 4.0, "the animation ends at %.2f s", INTRO_END);
}

/* A w x h picture of 32-bit pixels, all of colour c. */
static uint32_t *picture(int w, int h, uint32_t c)
{
    uint32_t *f = malloc((size_t)w * h * 4);

    for (size_t i = 0; i < (size_t)w * h; i++) {
        f[i] = c;
    }
    return f;
}

/* The probe's pixels of it, as cocoa.m takes them from a 2D surface. */
static bool desktop(const uint32_t *f, int w, int h)
{
    uint32_t px[SPLASH_PROBE_ROWS * SPLASH_PROBE_COLS];

    for (int r = 0; r < SPLASH_PROBE_ROWS; r++) {
        int y = omacvm_splash_probe_at(r, SPLASH_PROBE_ROWS, h);
        for (int c = 0; c < SPLASH_PROBE_COLS; c++) {
            int x = omacvm_splash_probe_at(c, SPLASH_PROBE_COLS, w);
            CHECK(x >= 0 && x < w && y >= 0 && y < h, "probe %d,%d outside %dx%d", x, y, w, h);
            px[r * SPLASH_PROBE_COLS + c] = f[(size_t)y * w + x];
        }
    }
    return omacvm_splash_desktop(px);
}

static void test_desktop(void)
{
    const int w = 1920, h = 1080;
    uint32_t *f = picture(w, h, 0xff000000);
    unsigned seed = 1;

    CHECK(!desktop(f, w, h), "black is the desktop");
    /* The firmware's logo, SPLASH_CELL-pixel cells in the middle, a progress
     * bar under it. */
    const int lx = (w - SPLASH_COLS * SPLASH_CELL) / 2, ly = (h - SPLASH_ROWS * SPLASH_CELL) / 2;
    for (int y = 0; y < SPLASH_ROWS * SPLASH_CELL; y++) {
        for (int x = 0; x < SPLASH_COLS * SPLASH_CELL; x++) {
            if (omacvm_splash_cells[y / SPLASH_CELL][x / SPLASH_CELL] == '#') {
                f[(size_t)(ly + y) * w + lx + x] = 0xff000000 | SPLASH_GREEN;
            }
        }
    }
    for (int y = 900; y < 920; y++) {
        for (int x = 200; x < 1720; x++) {
            f[(size_t)y * w + x] = 0xffffffff;
        }
    }
    CHECK(!desktop(f, w, h), "the firmware's logo is the desktop");
    free(f);
    /* Linux's console, full of text: a third of each 8 x 16 cell lit. */
    f = picture(w, h, 0xff000000);
    for (size_t i = 0; i < (size_t)w * h; i++) {
        seed = seed * 1103515245 + 12345;
        if ((seed >> 16) % 3 == 0) {
            f[i] = 0xffaaaaaa;
        }
    }
    CHECK(!desktop(f, w, h), "a console full of text is the desktop");
    free(f);
    /* Omarchy's background (Tokyo Night), a wallpaper half black. */
    f = picture(w, h, 0xff000000 | SPLASH_NAVY);
    CHECK(desktop(f, w, h), "Omarchy's background is not the desktop");
    for (int y = 0; y < h; y++) {
        memset(f + (size_t)y * w, 0, w / 2 * 4);
    }
    CHECK(desktop(f, w, h), "a wallpaper half black is not the desktop");
    free(f);
    /* Hyprland's grey before the wallpaper: not yet. */
    f = picture(w, h, 0xff111111);
    CHECK(!desktop(f, w, h), "Hyprland's grey alone is the desktop");
    free(f);
    /* Tiny and odd pictures: the probe stays inside. */
    f = picture(1, 1, 0xff808080);
    CHECK(desktop(f, 1, 1), "a 1 x 1 grey picture is not the desktop");
    free(f);
}

int main(void)
{
    test_ends();
    test_geometry();
    test_motion();
    test_background();
    test_timeline();
    test_desktop();
    if (failures) {
        fprintf(stderr, "test-boot-splash-morph: %d failures\n", failures);
        return 1;
    }
    printf("test-boot-splash-morph: OMACVM to the logo on the slowed timeline, still ends on "
           "GL's pixels, no jumps, the desktop told apart\n");
    return 0;
}
