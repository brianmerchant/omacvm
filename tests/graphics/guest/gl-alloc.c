/* gl-alloc: what a GLES app sees when it goes past the host's memory budget for guest
 * resources (virgl-resource-memory-budget.patch). Surfaceless EGL (robust context where
 * offered); makes N textures of SIZE x SIZE RGBA, draws into each through an FBO and
 * reads one pixel back. One JSON line per texture: readback ok?, glGetError,
 * glGetGraphicsResetStatusEXT. Stops at the first lost context.
 * Build: cc -O2 -o gl-alloc gl-alloc.c -lEGL -lGLESv2
 * Usage: gl-alloc [N=64] [SIZE=4096]   (4096: 64 MB per texture) */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
   int n = argc > 1 ? atoi(argv[1]) : 64, size = argc > 2 ? atoi(argv[2]) : 4096;
   setvbuf(stdout, NULL, _IOLBF, 0);
   EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
   if (!eglInitialize(dpy, NULL, NULL)) {
      printf("{\"error\":\"eglInitialize\"}\n");
      return 2;
   }
   const char *exts = eglQueryString(dpy, EGL_EXTENSIONS);
   int robust = exts && strstr(exts, "EGL_EXT_create_context_robustness");
   eglBindAPI(EGL_OPENGL_ES_API);
   EGLint attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2,
                      robust ? EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT : EGL_NONE,
                      EGL_LOSE_CONTEXT_ON_RESET_EXT, EGL_NONE };
   EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attrs);
   if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
      printf("{\"error\":\"context\"}\n");
      return 2;
   }
   PFNGLGETGRAPHICSRESETSTATUSEXTPROC reset_status =
      (PFNGLGETGRAPHICSRESETSTATUSEXTPROC)eglGetProcAddress("glGetGraphicsResetStatusEXT");
   GLuint *tex = calloc(n, sizeof *tex), fbo;
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   int ok_count = 0;
   for (int i = 0; i < n; i++) {
      glGenTextures(1, &tex[i]);
      glBindTexture(GL_TEXTURE_2D, tex[i]);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, size, size, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
      GLenum err = glGetError();
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex[i], 0);
      GLenum fbs = glCheckFramebufferStatus(GL_FRAMEBUFFER);
      float c = (i % 7) / 7.0f;
      glViewport(0, 0, size, size);
      glClearColor(c, 0.5f, 1.0f - c, 1.0f);
      glClear(GL_COLOR_BUFFER_BIT);
      unsigned char px[4] = {0};
      glReadPixels(size / 2, size / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
      int want = (int)(c * 255.0f + 0.5f);
      int ok = abs(px[0] - want) <= 1 && abs(px[1] - 128) <= 1;
      GLenum err2 = glGetError();
      GLenum rs = reset_status ? reset_status() : 0;
      ok_count += ok;
      printf("{\"texture\":%d,\"mb\":%d,\"ok\":%s,\"tex_error\":\"0x%x\",\"fb_status\":\"0x%x\","
             "\"error\":\"0x%x\",\"reset\":\"0x%x\"}\n", i + 1, (int)((i + 1LL) * size * size * 4 >> 20),
             ok ? "true" : "false", err, fbs, err2, rs);
      if (rs)
         break;
   }
   printf("{\"done\":true,\"ok\":%d,\"robust\":%s}\n", ok_count, robust ? "true" : "false");
   for (int i = 0; i < n; i++)
      if (tex[i])
         glDeleteTextures(1, &tex[i]);
   glDeleteFramebuffers(1, &fbo);
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
   eglTerminate(dpy);
   return 0;
}
