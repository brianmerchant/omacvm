/* Shader constants (CONST[0], the guest's plain uniforms) through uniform buffers
 * (virgl-const-uniform-buffer.patch), through the public renderer API on Apple's software
 * renderer (soft-gl.h; never on the GPU). Linked with gl-oracle.c: a draw whose active
 * uniform blocks have no buffer, or a range shorter than the block, aborts.
 *
 * Each case runs in a fresh context and draws up to four times into four stripes of one
 * 16x16 colour buffer, then checks the middle pixel of every stripe:
 *  1 vertex shader constants changed before each draw, all in one submit (the colour sits
 *    in the third vec4, so the range offset counts);
 *  2 fragment shader constants changed before each draw;
 *  3 both stages per draw: the fragment colour is the vertex colour times its constant;
 *  4 fragment constants set once, then six submits with vertex constants only: the ring
 *    buffers the fragment constants came in take later submits, the draws still see them;
 *  5 fewer constants than the shader declares: the rest reads as zero (uniforms: not
 *    checked, the old path read past the guest's data);
 *  6 an index computed in the shader (ADDR) picks one of four colours, and one far out
 *    of range is clamped (drawn, no fault);
 *  7 two programs with 4 and 8 constants alternating in one submit;
 *  8 two sub contexts in one submit, each with its own constants; one destroyed after the
 *    submit's constants went to it;
 *  9 constants and a guest uniform buffer in one shader;
 * 10 a constants command with no data (zeros), and a submit whose last constants command
 *    runs past the buffer's end: the draws before it are drawn;
 * 11 white-box (OMACVM_VIRGL_CACHE_STATS=1, set here): 4 constants commands and 4 draws in
 *    one submit are one upload, then one window bind and 4 index values for the vertex
 *    shader (OMACVM_VIRGL_CONST_UBO=1: 4 range binds; =0: none, a plain uniform), nothing
 *    one by one; the program has the block "vsconstblk";
 * 12 800 draws with 8 vec4s each in one submit: more constants than one window holds, so
 *    the window moves on; every draw still reads its own;
 * 13 a vertex shader with 16 inputs (no location left for the index) keeps a range per
 *    draw;
 * 14 a vertex shader reading CONST[0][3000] with 4 constants declared, then 800 draws with
 *    red constants in the same submit: the shader is refused as before (uniforms and a
 *    block of 4 do not compile); a window must not let it read the other draws' constants;
 * 15 separable shaders linked early (LINK_SHADER): the vertex window still works (the index
 *    attribute is bound before that link), not only a fallback to uniforms; skipped where
 *    the host refuses the separable link in every mode (Apple's GL, gl_PerVertex);
 * 16 a submit of a pattern, then small vertex and fragment constants: the buffer the GPU
 *    reads holds those constants and zeros, nothing of the earlier submit (the gaps between
 *    entries and the window pad are zeroed).
 * Run as is, with OMACVM_VIRGL_CONST_UBO=1 and with OMACVM_VIRGL_CONST_UBO=0.
 * Usage: test-const-ubo [case] */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2, TEST_SHADER_VERTEX = 0,
       TEST_SHADER_FRAGMENT = 1, TEST_PRIM_TRIANGLES = 4, TEST_CLEAR_COLOR0 = 1 << 2 };

/* RGBA8 pixels as read back (little endian: 0xAABBGGRR) */
enum { RED = 0xff0000ff, GREEN = 0xff00ff00, BLUE = 0xffff0000, YELLOW = 0xff00ffff,
       WHITE = 0xffffffff, ZERO = 0x00000000 };

/* resources of a context: handle = 1000 * ctx + R_* */
enum { R_RT = 1, R_POS, R_UBO, R_COUNT };
/* objects */
enum { VS_CONST = 10, VS_CONST8, VS_INDEX, VS_UBO, VS_PLAIN, VS_IN16, FS_VARYING, FS_CONST, FS_MUL,
       VE = 20, VS_FAR = 30, VS_SEP, FS_SEP, SURFACE = 40, BLEND, RS };

static CGLContextObj main_ctx;
static int failures;
/* 0: uniforms, 1: a range per draw, 2: vertex shaders index a window */
static int const_ubo = 2;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

/* The renderer's constant buffer totals, from its log line when a context ends. */
static struct totals {
   unsigned long long uploads, bytes, binds, own, index, windows;
} last;
/* the host refused a separable link (Apple's GL: a separable vertex shader must redeclare
 * gl_PerVertex, which vrend does not: separable vertex programs never draw on macOS) */
static int separable_refused;

static void log_cb(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)data;
   struct totals t;
   const char *p = strstr(message, "constant buffers (");
   if (p && (p = strstr(p, "totals uploads")) &&
       sscanf(p, "totals uploads %llu upload-bytes %llu binds %llu own-uploads %llu "
              "index-draws %llu window-binds %llu",
              &t.uploads, &t.bytes, &t.binds, &t.own, &t.index, &t.windows) == 6)
      last = t;
   else if (strstr(message, "(separable link)"))
      separable_refused = 1;
   if (p)
      return;
   if (level >= VIRGL_LOG_LEVEL_WARNING || strstr(message, "shader constants:"))
      fprintf(stderr, "virgl: %s", message);
}

static void write_fence(void *cookie, uint32_t fence)
{
   (void)cookie;
   (void)fence;
}

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie;
   (void)scanout;
   (void)param;
   return soft_gl_context(main_ctx);
}

static void destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   CGLDestroyContext(ctx);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   (void)scanout;
   return CGLSetCurrentContext(ctx) ? -1 : 0;
}

static struct virgl_renderer_callbacks callbacks = {
   .version = 1,
   .write_fence = write_fence,
   .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context,
   .make_current = make_current,
};

struct cmds {
   uint32_t dw[65536];
   unsigned n;
};

static void emit(struct cmds *c, uint32_t v)
{
   c->dw[c->n++] = v;
}

static void emit_float(struct cmds *c, float f)
{
   uint32_t u;
   memcpy(&u, &f, 4);
   emit(c, u);
}

static int submit(int ctx, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx, c->n);
   c->n = 0;
   return r;
}

static uint32_t res_id(int ctx, int r)
{
   return 1000 * ctx + r;
}

static void emit_shader(struct cmds *c, uint32_t handle, uint32_t type, const char *text)
{
   uint32_t bytes = strlen(text) + 1, words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER, 5 + words));
   emit(c, handle);
   emit(c, type);
   emit(c, VIRGL_OBJ_SHADER_OFFSET_VAL(bytes));
   emit(c, 300);
   emit(c, 0);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], text, bytes);
   c->n += words;
}

static void emit_bind_shader(struct cmds *c, uint32_t handle, uint32_t type)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_SHADER, 0, 2));
   emit(c, handle);
   emit(c, type);
}

static void emit_bind_shaders(struct cmds *c, uint32_t vs, uint32_t fs)
{
   emit_bind_shader(c, vs, TEST_SHADER_VERTEX);
   emit_bind_shader(c, fs, TEST_SHADER_FRAGMENT);
}

/* n vec4s of constants for a stage; vec4 k is val[k] (RGBA floats) */
static void emit_consts(struct cmds *c, uint32_t stage, unsigned n, const float (*val)[4])
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_CONSTANT_BUFFER, 0, 2 + 4 * n));
   emit(c, stage);
   emit(c, 0);
   for (unsigned k = 0; k < n; k++)
      for (int i = 0; i < 4; i++)
         emit_float(c, val[k][i]);
}

/* n vec4s, all zero except vec4 at = colour */
static void emit_colour_consts(struct cmds *c, uint32_t stage, unsigned n, unsigned at,
                               uint32_t colour)
{
   float val[8][4];
   memset(val, 0, sizeof(val));
   for (int i = 0; i < 4; i++)
      val[at][i] = ((colour >> (8 * i)) & 0xff) / 255.0f;
   emit_consts(c, stage, n, (const float (*)[4])val);
}

static void emit_draw(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(c, 0);                      /* start */
   emit(c, 3);                      /* count */
   emit(c, TEST_PRIM_TRIANGLES);
   emit(c, 0);                      /* not indexed */
   emit(c, 0);                      /* instances */
   emit(c, 0);                      /* index bias */
   emit(c, 0);                      /* start instance */
   emit(c, 0);                      /* primitive restart */
   emit(c, 0);                      /* restart index */
   emit(c, 0);                      /* min index */
   emit(c, 0xffffffff);             /* max index */
   emit(c, 0);                      /* count from stream output */
}

/* stripe 0-3: x 4 * stripe .. 4 * stripe + 3 of the 16x16 buffer, all rows */
static void emit_stripe(struct cmds *c, int stripe)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VIEWPORT_STATE, 0, VIRGL_SET_VIEWPORT_STATE_SIZE(1)));
   emit(c, 0);
   emit_float(c, 2);
   emit_float(c, 8);
   emit_float(c, 0.5f);
   emit_float(c, 4 * stripe + 2);
   emit_float(c, 8);
   emit_float(c, 0.5f);
}

static void emit_clear(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(c, TEST_CLEAR_COLOR0);
   emit_float(c, 0.5f);             /* grey: no case expects it */
   emit_float(c, 0.5f);
   emit_float(c, 0.5f);
   emit_float(c, 1);
   emit(c, 0);                      /* depth (double) */
   emit(c, 0);
   emit(c, 0);                      /* stencil */
}

static void emit_sub_ctx(struct cmds *c, uint32_t cmd, uint32_t id)
{
   emit(c, VIRGL_CMD0(cmd, 0, 1));
   emit(c, id);
}

/* colour from vec4 2 of 4 */
static const char *vs_const =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..3]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][2]\n"
   "  2: END\n";

/* colour from vec4 6 of 8 */
static const char *vs_const8 =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..7]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][6]\n"
   "  2: END\n";

/* colour from vec4 1 + CONST[0][0].x */
static const char *vs_index =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..4]\n"
   "DCL ADDR[0]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: ARL ADDR[0].x, CONST[0][0].xxxx\n"
   "  2: MOV OUT[1], CONST[0][ADDR[0].x+1]\n"
   "  3: END\n";

/* colour = CONST[0][0] * the guest's uniform buffer 1, vec4 0 */
static const char *vs_ubo =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0]\n"
   "DCL CONST[1][0]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MUL OUT[1], CONST[0][0], CONST[1][0]\n"
   "  2: END\n";

/* white */
static const char *vs_plain =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "IMM[0] FLT32 { 1.0, 1.0, 1.0, 1.0 }\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], IMM[0]\n"
   "  2: END\n";

/* 16 inputs, the colour from vec4 2 of 4 */
static const char *vs_inputs16 =
   "VERT\n"
   "DCL IN[0]\n" "DCL IN[1]\n" "DCL IN[2]\n" "DCL IN[3]\n" "DCL IN[4]\n" "DCL IN[5]\n"
   "DCL IN[6]\n" "DCL IN[7]\n" "DCL IN[8]\n" "DCL IN[9]\n" "DCL IN[10]\n" "DCL IN[11]\n"
   "DCL IN[12]\n" "DCL IN[13]\n" "DCL IN[14]\n" "DCL IN[15]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..3]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][2]\n"
   "  2: END\n";

/* reads vec4 3000 of 4 */
static const char *vs_far =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..3]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][3000]\n"
   "  2: END\n";

/* vs_const and fs_varying as separable programs */
static const char *vs_sep =
   "VERT\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..3]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][2]\n"
   "  2: END\n";

static const char *fs_sep =
   "FRAG\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

static const char *fs_varying =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

/* colour from vec4 1 of 2 */
static const char *fs_const =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "DCL CONST[0][0..1]\n"
   "  0: MOV OUT[0], CONST[0][1]\n"
   "  1: END\n";

/* colour = the vertex colour * CONST[0][0] */
static const char *fs_mul =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "DCL CONST[0][0]\n"
   "  0: MUL OUT[0], IN[0], CONST[0][0]\n"
   "  1: END\n";

static void make_buffer(int ctx, int r, uint32_t bind, uint32_t width)
{
   struct virgl_renderer_resource_create_args a = {
      .handle = res_id(ctx, r), .target = TEST_PIPE_BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = bind, .width = width, .height = 1, .depth = 1, .array_size = 1,
   };
   if (virgl_renderer_resource_create(&a, NULL, 0))
      printf("note: buffer %d not created\n", r);
   virgl_renderer_ctx_attach_resource(ctx, res_id(ctx, r));
}

static void emit_write(struct cmds *c, uint32_t handle, const void *data, uint32_t bytes)
{
   uint32_t words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, 11 + words));
   emit(c, handle);
   emit(c, 0);                      /* level */
   emit(c, 0);                      /* usage */
   emit(c, 0);                      /* stride */
   emit(c, 0);                      /* layer stride */
   emit(c, 0);                      /* x */
   emit(c, 0);
   emit(c, 0);
   emit(c, bytes);                  /* w */
   emit(c, 1);
   emit(c, 1);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], data, bytes);
   c->n += words;
}

/* the objects of a sub context (each has its own): surface, blend, rasterizer, shaders,
 * vertex elements and buffer, cleared colour buffer */
static void emit_state(struct cmds *c, int ctx)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(c, SURFACE);
   emit(c, res_id(ctx, R_RT));
   emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(c, 1);
   emit(c, 0);
   emit(c, SURFACE);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_BLEND, VIRGL_OBJ_BLEND_SIZE));
   emit(c, BLEND);
   emit(c, 0);
   emit(c, 0);
   for (int i = 0; i < VIRGL_MAX_COLOR_BUFS; i++)
      emit(c, VIRGL_OBJ_BLEND_S2_RT_COLORMASK(0xf));
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_BLEND, 1));
   emit(c, BLEND);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_RASTERIZER, VIRGL_OBJ_RS_SIZE));
   emit(c, RS);
   emit(c, VIRGL_OBJ_RS_S0_DEPTH_CLIP(1));
   emit_float(c, 1.0f);
   for (int i = 0; i < VIRGL_OBJ_RS_SIZE - 3; i++)
      emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(c, RS);

   emit_shader(c, VS_CONST, TEST_SHADER_VERTEX, vs_const);
   emit_shader(c, VS_CONST8, TEST_SHADER_VERTEX, vs_const8);
   emit_shader(c, VS_INDEX, TEST_SHADER_VERTEX, vs_index);
   emit_shader(c, VS_UBO, TEST_SHADER_VERTEX, vs_ubo);
   emit_shader(c, VS_PLAIN, TEST_SHADER_VERTEX, vs_plain);
   emit_shader(c, VS_IN16, TEST_SHADER_VERTEX, vs_inputs16);
   emit_shader(c, FS_VARYING, TEST_SHADER_FRAGMENT, fs_varying);
   emit_shader(c, FS_CONST, TEST_SHADER_FRAGMENT, fs_const);
   emit_shader(c, FS_MUL, TEST_SHADER_FRAGMENT, fs_mul);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);

   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS,
                      VIRGL_OBJ_VERTEX_ELEMENTS_SIZE(1)));
   emit(c, VE);
   emit(c, 0);                      /* src offset */
   emit(c, 0);                      /* instance divisor */
   emit(c, 0);                      /* vertex buffer */
   emit(c, VIRGL_FORMAT_R32G32B32A32_FLOAT);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS, 1));
   emit(c, VE);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VERTEX_BUFFERS, 0, VIRGL_SET_VERTEX_BUFFERS_SIZE(1)));
   emit(c, 16);
   emit(c, 0);
   emit(c, res_id(ctx, R_POS));
   emit_clear(c);
}

/* A context with a 16x16 colour buffer, one triangle over the whole viewport (POS) and a
 * guest uniform buffer of one vec4 (UBO: white). */
static void setup(struct cmds *c, int ctx)
{
   char name[16];
   snprintf(name, sizeof(name), "const-%d", ctx);
   virgl_renderer_context_create(ctx, strlen(name), name);

   struct virgl_renderer_resource_create_args rt = {
      .handle = res_id(ctx, R_RT), .target = TEST_PIPE_TEXTURE_2D,
      .format = VIRGL_FORMAT_R8G8B8A8_UNORM, .bind = VIRGL_BIND_RENDER_TARGET, .width = 16,
      .height = 16, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&rt, NULL, 0);
   virgl_renderer_ctx_attach_resource(ctx, res_id(ctx, R_RT));
   make_buffer(ctx, R_POS, VIRGL_BIND_VERTEX_BUFFER, 3 * 16);
   make_buffer(ctx, R_UBO, VIRGL_BIND_CONSTANT_BUFFER, 256);

   emit_state(c, ctx);
   const float pos[3][4] = { { -1, -1, 0, 1 }, { 3, -1, 0, 1 }, { -1, 3, 0, 1 } };
   emit_write(c, res_id(ctx, R_POS), pos, sizeof(pos));
   const float white[4] = { 1, 1, 1, 1 };
   emit_write(c, res_id(ctx, R_UBO), white, sizeof(white));
   check(submit(ctx, c) == 0, "setup");
}

static void teardown(int ctx)
{
   virgl_renderer_context_destroy(ctx);
   for (int r = R_RT; r < R_COUNT; r++)
      virgl_renderer_resource_unref(res_id(ctx, r));
}

static void read_stripes(int ctx, uint32_t got[4])
{
   static uint32_t pixels[16 * 16];
   memset(pixels, 0, sizeof(pixels));
   struct iovec iov = { pixels, sizeof(pixels) };
   struct virgl_box box = { 0, 0, 0, 16, 16, 1 };
   if (virgl_renderer_transfer_read_iov(res_id(ctx, R_RT), ctx, 0, 16 * 4, 0, &box, 0, &iov, 1))
      memset(pixels, 0x11, sizeof(pixels));
   for (int s = 0; s < 4; s++)
      got[s] = pixels[8 * 16 + 4 * s + 2];
}

static void check_stripes(int ctx, int n, const uint32_t *want, const char *what)
{
   uint32_t got[4];
   char text[256];
   read_stripes(ctx, got);
   for (int s = 0; s < n; s++) {
      snprintf(text, sizeof(text), "%s: stripe %d (0x%08x, expected 0x%08x)", what, s, got[s],
               want[s]);
      check(got[s] == want[s], text);
   }
}

static const uint32_t colours[4] = { RED, GREEN, BLUE, YELLOW };

static void case_vs(struct cmds *c, int ctx)
{
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "vertex constants before each of 4 draws, one submit");
   check_stripes(ctx, 4, colours, "vertex constants per draw");
}

static void case_fs(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_PLAIN, FS_CONST);
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_FRAGMENT, 2, 1, colours[3 - s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "fragment constants before each of 4 draws, one submit");
   const uint32_t want[4] = { YELLOW, BLUE, GREEN, RED };
   check_stripes(ctx, 4, want, "fragment constants per draw");
}

static void case_both(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_CONST, FS_MUL);
   const uint32_t vs[4] = { WHITE, YELLOW, WHITE, BLUE }, fs[4] = { RED, GREEN, BLUE, WHITE };
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, vs[s]);
      emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, fs[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "both stages' constants before each draw");
   const uint32_t want[4] = { RED, GREEN, BLUE, BLUE };
   check_stripes(ctx, 4, want, "vertex colour times fragment constant");
}

static void case_stale(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_CONST, FS_MUL);
   emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, WHITE);
   check(submit(ctx, c) == 0, "fragment constants alone");
   /* six submits: the fragment constants' ring buffer takes a later submit */
   for (int k = 0; k < 6; k++) {
      emit_stripe(c, k % 4);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[k % 4]);
      emit_draw(c);
      check(submit(ctx, c) == 0, "vertex constants and a draw, one submit");
   }
   check_stripes(ctx, 4, colours, "fragment constants from 6 submits back");
}

static void case_short(struct cmds *c, int ctx)
{
   emit_stripe(c, 0);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_draw(c);
   emit_stripe(c, 1);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 2, 1, RED);     /* the colour vec4 is missing */
   emit_draw(c);
   emit_stripe(c, 2);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, BLUE);
   emit_draw(c);
   check(submit(ctx, c) == 0, "2 of 4 vec4s sent between two full ones");
   const uint32_t want[3] = { GREEN, ZERO, BLUE };
   if (!const_ubo) {
      /* uniforms: the missing part was never defined */
      uint32_t got[4];
      read_stripes(ctx, got);
      check(got[0] == GREEN && got[2] == BLUE, "short constants: the full draws around it");
      return;
   }
   check_stripes(ctx, 3, want, "short constants read as zero");
}

static void case_index(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_INDEX, FS_VARYING);
   for (int s = 0; s < 4; s++) {
      float val[5][4];
      memset(val, 0, sizeof(val));
      val[0][0] = 3 - s;
      for (int k = 0; k < 4; k++)
         for (int i = 0; i < 4; i++)
            val[1 + k][i] = ((colours[k] >> (8 * i)) & 0xff) / 255.0f;
      emit_stripe(c, s);
      emit_consts(c, TEST_SHADER_VERTEX, 5, (const float (*)[4])val);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "an index in the shader picks the colour");
   const uint32_t want[4] = { YELLOW, BLUE, GREEN, RED };
   check_stripes(ctx, 4, want, "indexed constants");

   float far[5][4];
   memset(far, 0, sizeof(far));
   far[0][0] = 100000;
   emit_stripe(c, 0);
   emit_consts(c, TEST_SHADER_VERTEX, 5, (const float (*)[4])far);
   emit_draw(c);
   far[0][0] = -100000;
   emit_consts(c, TEST_SHADER_VERTEX, 5, (const float (*)[4])far);
   emit_draw(c);
   check(submit(ctx, c) == 0, "an index far out of range is clamped (drawn)");
}

static void case_programs(struct cmds *c, int ctx)
{
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      if (s & 1) {
         emit_bind_shaders(c, VS_CONST8, FS_VARYING);
         emit_colour_consts(c, TEST_SHADER_VERTEX, 8, 6, colours[s]);
      } else {
         emit_bind_shaders(c, VS_CONST, FS_VARYING);
         emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      }
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "programs with 4 and 8 constants by turns");
   check_stripes(ctx, 4, colours, "4 and 8 constants");

   /* the 8-constant program with only the 4 vec4s of the last draw: zeros (block) */
   emit_stripe(c, 1);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_bind_shaders(c, VS_CONST8, FS_VARYING);
   emit_draw(c);
   check(submit(ctx, c) == 0, "a program with more constants than were sent");
   if (const_ubo)
      check_stripes(ctx, 2, (const uint32_t[2]){ RED, ZERO }, "more constants than sent");
}

static void case_subs(struct cmds *c, int ctx)
{
   emit_sub_ctx(c, VIRGL_CCMD_CREATE_SUB_CTX, 1);
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 1);
   emit_state(c, ctx);
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 0);
   check(submit(ctx, c) == 0, "a second sub context");
   for (int s = 0; s < 4; s++) {
      emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, s & 1);
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 0);
   check(submit(ctx, c) == 0, "two sub contexts by turns, one submit");
   check_stripes(ctx, 4, colours, "sub contexts");
   /* again, now sub context 1 first */
   for (int s = 0; s < 4; s++) {
      emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, !(s & 1));
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[3 - s]);
      emit_draw(c);
   }
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 0);
   check(submit(ctx, c) == 0, "two sub contexts, sub context 1 first");
   check_stripes(ctx, 4, (const uint32_t[4]){ YELLOW, BLUE, GREEN, RED }, "sub contexts again");
   /* the upload goes to sub context 1, which is destroyed before sub context 0 draws in
    * the same submit: sub context 0 must not use sub context 1's (deleted) buffer */
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 1);
   emit_stripe(c, 0);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, RED);
   emit_draw(c);
   emit_sub_ctx(c, VIRGL_CCMD_DESTROY_SUB_CTX, 1);
   emit_stripe(c, 1);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_draw(c);
   check(submit(ctx, c) == 0, "constants uploaded in a sub context destroyed in the submit");
   check_stripes(ctx, 2, (const uint32_t[2]){ RED, GREEN }, "after the sub context is gone");
}

static void case_ubo(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_UBO, FS_VARYING);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_UNIFORM_BUFFER, 0, VIRGL_SET_UNIFORM_BUFFER_SIZE));
   emit(c, TEST_SHADER_VERTEX);
   emit(c, 1);
   emit(c, 0);
   emit(c, 16);
   emit(c, res_id(ctx, R_UBO));
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 1, 0, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "constants and a uniform buffer in one shader");
   check_stripes(ctx, 4, colours, "constants times a white uniform buffer");
}

static void case_odd(struct cmds *c, int ctx)
{
   emit_stripe(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_CONSTANT_BUFFER, 0, 2));    /* no data */
   emit(c, TEST_SHADER_VERTEX);
   emit(c, 0);
   emit_draw(c);
   emit_stripe(c, 1);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_draw(c);
   check(submit(ctx, c) == 0, "a constants command with no data");
   if (const_ubo)
      check_stripes(ctx, 2, (const uint32_t[2]){ ZERO, GREEN }, "no data: zeros");

   emit_stripe(c, 2);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, BLUE);
   emit_draw(c);
   emit_stripe(c, 3);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_CONSTANT_BUFFER, 0, 2 + 16));   /* runs past the end */
   emit(c, TEST_SHADER_VERTEX);
   emit(c, 0);
   submit(ctx, c);
   uint32_t got[4];
   read_stripes(ctx, got);
   check(got[2] == BLUE, "a cut-off constants command: the draw before it");
}

static void case_counts(struct cmds *c, int ctx)
{
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "vertex constants before each of 4 draws, one submit");
   /* the program of the last draw, before a read-back binds another */
   GLint prog = 0;
   glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
   GLuint block = prog ? glGetUniformBlockIndex(prog, "vsconstblk") : GL_INVALID_INDEX;
   GLint plain = prog ? glGetUniformLocation(prog, "vsconst0") : -1;
   if (const_ubo)
      check(block != GL_INVALID_INDEX && plain == -1, "the program reads its constants "
            "from the block vsconstblk");
   else
      check(block == GL_INVALID_INDEX && plain != -1, "the program has the uniform vsconst0");
   check_stripes(ctx, 4, colours, "vertex constants per draw");
}

static struct totals totals_before;

static void check_counts(void)
{
   unsigned long long uploads = last.uploads - totals_before.uploads;
   unsigned long long binds = last.binds - totals_before.binds;
   unsigned long long own = last.own - totals_before.own;
   unsigned long long index = last.index - totals_before.index;
   unsigned long long windows = last.windows - totals_before.windows;
   char text[200];
   snprintf(text, sizeof(text), "4 constants commands and 4 draws: %llu uploads, %llu range binds, "
            "%llu index draws in %llu windows, %llu one by one", uploads, binds, index, windows, own);
   if (const_ubo == 2)
      check(uploads == 1 && binds == 0 && index == 4 && windows == 1 && own == 0, text);
   else if (const_ubo == 1)
      check(uploads == 1 && binds == 4 && index == 0 && windows == 0 && own == 0, text);
   else
      check(uploads == 0 && binds == 0 && index == 0 && own == 0, text);
}

static void case_many(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_CONST8, FS_VARYING);
   for (int k = 0; k < 800; k++) {
      emit_stripe(c, k % 4);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 8, 6, colours[(k / 4 + k) % 4]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "800 draws with their own 8 vec4s, one submit");
   uint32_t want[4];
   for (int s = 0; s < 4; s++)
      want[s] = colours[(796 / 4 + 796 + s) % 4];
   check_stripes(ctx, 4, want, "the last 4 of 800 draws");
}

static void check_many_counts(void)
{
   unsigned long long index = last.index - totals_before.index;
   unsigned long long windows = last.windows - totals_before.windows;
   char text[160];
   snprintf(text, sizeof(text), "800 draws: %llu index draws in %llu windows", index, windows);
   check(const_ubo == 2 ? index == 800 && windows >= 2 : index == 0, text);
}

static void case_inputs16(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_IN16, FS_VARYING);
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "a vertex shader with 16 inputs");
   check_stripes(ctx, 4, colours, "16 inputs: a range per draw");
}

static void check_inputs16_counts(void)
{
   unsigned long long binds = last.binds - totals_before.binds;
   unsigned long long index = last.index - totals_before.index;
   char text[160];
   snprintf(text, sizeof(text), "16 inputs: %llu range binds, %llu index draws", binds, index);
   check(const_ubo ? binds == 4 && index == 0 : binds == 0, text);
}

static void check_stale_counts(void)
{
   unsigned long long own = last.own - totals_before.own;
   char text[160];
   snprintf(text, sizeof(text), "stale fragment constants went one by one %llu times", own);
   check(const_ubo ? own >= 1 : own == 0, text);
}

static void case_far(struct cmds *c, int ctx)
{
   emit_shader(c, VS_FAR, TEST_SHADER_VERTEX, vs_far);
   submit(ctx, c);   /* refused: a compile error (all modes) */
   float green[4][4], red[4][4];
   for (int k = 0; k < 4; k++)
      for (int i = 0; i < 4; i++) {
         green[k][i] = ((GREEN >> (8 * i)) & 0xff) / 255.0f;
         red[k][i] = ((RED >> (8 * i)) & 0xff) / 255.0f;
      }
   /* the far read first, so a window would start at its constants */
   emit_bind_shaders(c, VS_FAR, FS_VARYING);
   emit_stripe(c, 0);
   emit_consts(c, TEST_SHADER_VERTEX, 4, (const float (*)[4])green);
   emit_draw(c);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   for (int k = 0; k < 800; k++) {
      emit_stripe(c, 1 + k % 3);
      emit_consts(c, TEST_SHADER_VERTEX, 4, (const float (*)[4])red);
      emit_draw(c);
   }
   submit(ctx, c);
   uint32_t got[4];
   read_stripes(ctx, got);
   char text[160];
   snprintf(text, sizeof(text), "CONST[0][3000] of 4: no other draw's constants (0x%08x)", got[0]);
   check(got[0] != RED, text);
}

static void case_separable(struct cmds *c, int ctx)
{
   emit_shader(c, VS_SEP, TEST_SHADER_VERTEX, vs_sep);
   emit_shader(c, FS_SEP, TEST_SHADER_FRAGMENT, fs_sep);
   emit_bind_shaders(c, VS_SEP, FS_SEP);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_LINK_SHADER, 0, VIRGL_LINK_SHADER_SIZE));
   emit(c, VS_SEP);
   emit(c, FS_SEP);
   for (int i = 0; i < 4; i++)
      emit(c, 0);
   check(submit(ctx, c) == 0, "separable shaders linked early");
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "separable shaders: vertex constants before each draw");
   if (separable_refused) {
      printf("skip: the host refused the separable link (as with uniforms)\n");
      return;
   }
   check_stripes(ctx, 4, colours, "separable shaders");
}

static void check_separable_counts(void)
{
   unsigned long long binds = last.binds - totals_before.binds;
   unsigned long long index = last.index - totals_before.index;
   char text[160];
   snprintf(text, sizeof(text), "separable: %llu index draws, %llu range binds", index, binds);
   if (separable_refused)
      return;
   check(const_ubo == 2 ? index == 4 : const_ubo == 1 ? binds == 4 : index == 0 && binds == 0,
         text);
}

static void check_zeroed(float mark);

static void case_zeroed(struct cmds *c, int ctx)
{
   const float mark = 0.123f;
   float pattern[8][4];
   for (int k = 0; k < 8; k++)
      for (int i = 0; i < 4; i++)
         pattern[k][i] = mark;
   emit_bind_shaders(c, VS_CONST8, FS_VARYING);
   for (int k = 0; k < 200; k++) {
      emit_stripe(c, k % 4);
      emit_consts(c, TEST_SHADER_VERTEX, 8, (const float (*)[4])pattern);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "a submit of 200 x 8 vec4s of a pattern");
   emit_bind_shaders(c, VS_CONST, FS_MUL);
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, WHITE);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "then small vertex and fragment constants");
   if (const_ubo)
      check_zeroed(mark);
   check_stripes(ctx, 4, colours, "small constants after a big submit");
}

/* the buffer the last draw's fragment constants are bound from (the submit's upload):
 * before a read-back binds another program */
static void check_zeroed(float mark)
{
   GLint prog = 0, binding = -1, buf = 0, prev = 0, size = 0;
   glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
   GLuint block = prog ? glGetUniformBlockIndex(prog, "fsconstblk") : GL_INVALID_INDEX;
   if (block != GL_INVALID_INDEX)
      glGetActiveUniformBlockiv(prog, block, GL_UNIFORM_BLOCK_BINDING, &binding);
   if (binding >= 0)
      glGetIntegeri_v(GL_UNIFORM_BUFFER_BINDING, binding, &buf);
   glGetIntegerv(GL_COPY_READ_BUFFER, &prev);   /* the binding (GL_COPY_READ_BUFFER_BINDING) */
   unsigned marks = 0;
   if (buf) {
      glBindBuffer(GL_COPY_READ_BUFFER, buf);
      glGetBufferParameteriv(GL_COPY_READ_BUFFER, GL_BUFFER_SIZE, &size);
      uint32_t *words = calloc(1, size > 0 ? size : 4), want;
      memcpy(&want, &mark, 4);
      glGetBufferSubData(GL_COPY_READ_BUFFER, 0, size, words);
      for (GLint i = 0; i < size / 4; i++)
         marks += words[i] == want;
      free(words);
      glBindBuffer(GL_COPY_READ_BUFFER, prev);
   }
   char text[200];
   snprintf(text, sizeof(text), "the uploaded constants buffer (%d bytes) holds %u words of the "
            "earlier submit", size, marks);
   check(buf && size > 0 && marks == 0, text);
}

static void run_case(int n)
{
   static struct cmds c;
   int ctx = n;
   printf("case %d\n", n);
   c.n = 0;
   setup(&c, ctx);
   switch (n) {
   case 1: case_vs(&c, ctx); break;
   case 2: case_fs(&c, ctx); break;
   case 3: case_both(&c, ctx); break;
   case 4: case_stale(&c, ctx); break;
   case 5: case_short(&c, ctx); break;
   case 6: case_index(&c, ctx); break;
   case 7: case_programs(&c, ctx); break;
   case 8: case_subs(&c, ctx); break;
   case 9: case_ubo(&c, ctx); break;
   case 10: case_odd(&c, ctx); break;
   case 11: case_counts(&c, ctx); break;
   case 12: case_many(&c, ctx); break;
   case 13: case_inputs16(&c, ctx); break;
   case 14: case_far(&c, ctx); break;
   case 15: case_separable(&c, ctx); break;
   case 16: case_zeroed(&c, ctx); break;
   }
   teardown(ctx);
   if (n == 4)
      check_stale_counts();
   if (n == 11)
      check_counts();
   if (n == 12)
      check_many_counts();
   if (n == 13)
      check_inputs16_counts();
   if (n == 15)
      check_separable_counts();
   totals_before = last;
}

int main(int argc, char **argv)
{
   int only = argc > 1 ? atoi(argv[1]) : 0;

   setvbuf(stdout, NULL, _IONBF, 0);
   const char *env = getenv("OMACVM_VIRGL_CONST_UBO");
   const_ubo = env && !strcmp(env, "0") ? 0 : env && !strcmp(env, "1") ? 1 : 2;
   printf("shader constants: %s\n", const_ubo == 2 ? "uniform buffers, vertex window index" :
          const_ubo == 1 ? "uniform buffers, a range per draw" : "uniforms");
   setenv("OMACVM_VIRGL_CACHE_STATS", "1", 1);
   setenv("VIRGL_USE_INTEGER", "1", 1);

   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   virgl_set_log_callback(log_cb, NULL, NULL);
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }

   for (int n = 1; n <= 16; n++)
      if (!only || only == n)
         run_case(n);

   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "const ubo: FAILED" : "const ubo: all checks passed");
   return failures != 0;
}
