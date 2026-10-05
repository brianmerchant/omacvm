// semtest.c: OPAQUE_FD semaphores across two Vulkan devices (like Chrome's GL and Dawn) + Dawn's adapter check.
// Build: gcc -O1 -o semtest semtest.c -lvulkan
// 1. prints what Dawn's SupportsExternalImages() looks at (extensions, OPAQUE_FD semaphore features);
// 2. device A fills a buffer and signals an exported OPAQUE_FD semaphore; device B imports it (permanent),
//    waits on it in a submit and signals a fence; repeated N times on the same shared payload, both directions.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

typedef struct { VkInstance inst; VkPhysicalDevice pd; VkDevice dev; VkQueue q; VkCommandPool pool; uint32_t qf; } Ctx;

static int has_ext(VkPhysicalDevice pd, const char *name) {
  uint32_t n = 0; vkEnumerateDeviceExtensionProperties(pd, NULL, &n, NULL);
  VkExtensionProperties *e = calloc(n, sizeof *e); vkEnumerateDeviceExtensionProperties(pd, NULL, &n, e);
  int r = 0; for (uint32_t i = 0; i < n; i++) if (!strcmp(e[i].extensionName, name)) r = 1;
  free(e); return r;
}

static void make(Ctx *c) {
  VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
  VkInstanceCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
  CK(vkCreateInstance(&ci, NULL, &c->inst));
  uint32_t n = 1; vkEnumeratePhysicalDevices(c->inst, &n, &c->pd);
  c->qf = 0;
  float pr = 1;
  VkDeviceQueueCreateInfo qi = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &pr };
  const char *exts[] = { "VK_KHR_external_semaphore_fd", "VK_KHR_external_memory_fd" };
  VkDeviceCreateInfo di = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi,
                            .enabledExtensionCount = 1, .ppEnabledExtensionNames = exts };
  CK(vkCreateDevice(c->pd, &di, NULL, &c->dev));
  vkGetDeviceQueue(c->dev, 0, 0, &c->q);
  VkCommandPoolCreateInfo pi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
  CK(vkCreateCommandPool(c->dev, &pi, NULL, &c->pool));
}

static VkSemaphore sem_new(Ctx *c, int exportable) {
  VkExportSemaphoreCreateInfo ex = { .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO, .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT };
  VkSemaphoreCreateInfo si = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = exportable ? &ex : NULL };
  VkSemaphore s; CK(vkCreateSemaphore(c->dev, &si, NULL, &s)); return s;
}

// Fills a host-visible buffer with v on the GPU, waiting on w (if any), signalling s (if any) and fence f.
typedef struct { VkBuffer b; VkDeviceMemory m; uint32_t *p; VkCommandBuffer cb; VkFence f; } Job;
static void job_init(Ctx *c, Job *j) {
  VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 1 << 20, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
  CK(vkCreateBuffer(c->dev, &bi, NULL, &j->b));
  VkMemoryRequirements mr; vkGetBufferMemoryRequirements(c->dev, j->b, &mr);
  VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(c->pd, &mp);
  uint32_t t = 0;
  for (t = 0; t < mp.memoryTypeCount; t++)
    if ((mr.memoryTypeBits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) break;
  VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
  CK(vkAllocateMemory(c->dev, &ai, NULL, &j->m)); CK(vkBindBufferMemory(c->dev, j->b, j->m, 0));
  CK(vkMapMemory(c->dev, j->m, 0, VK_WHOLE_SIZE, 0, (void **)&j->p));
  VkCommandBufferAllocateInfo ci = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = c->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
  CK(vkAllocateCommandBuffers(c->dev, &ci, &j->cb));
  VkFenceCreateInfo fi = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
  CK(vkCreateFence(c->dev, &fi, NULL, &j->f));
}
static void job_run(Ctx *c, Job *j, uint32_t v, VkSemaphore w, VkSemaphore s) {
  CK(vkResetCommandBuffer(j->cb, 0));
  VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
  CK(vkBeginCommandBuffer(j->cb, &bi));
  vkCmdFillBuffer(j->cb, j->b, 0, VK_WHOLE_SIZE, v);
  CK(vkEndCommandBuffer(j->cb));
  VkPipelineStageFlags st = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
  VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = w ? 1 : 0, .pWaitSemaphores = &w, .pWaitDstStageMask = &st,
                      .commandBufferCount = 1, .pCommandBuffers = &j->cb, .signalSemaphoreCount = s ? 1 : 0, .pSignalSemaphores = &s };
  CK(vkResetFences(c->dev, 1, &j->f));
  CK(vkQueueSubmit(c->q, 1, &si, j->f));
}

int main(int argc, char **argv) {
  int rounds = argc > 1 ? atoi(argv[1]) : 100;
  Ctx a, b; make(&a);
  VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(a.pd, &props);
  printf("device: %s\n", props.deviceName);
  printf("VK_KHR_external_memory_fd: %d, VK_EXT_external_memory_dma_buf: %d, VK_EXT_image_drm_format_modifier: %d, VK_KHR_external_semaphore_fd: %d\n",
         has_ext(a.pd, "VK_KHR_external_memory_fd"), has_ext(a.pd, "VK_EXT_external_memory_dma_buf"),
         has_ext(a.pd, "VK_EXT_image_drm_format_modifier"), has_ext(a.pd, "VK_KHR_external_semaphore_fd"));
  const VkExternalSemaphoreHandleTypeFlagBits types[2] = { VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT, VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT };
  int opaque_ok = 0;
  for (int i = 0; i < 2; i++) {
    VkPhysicalDeviceExternalSemaphoreInfo si = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO, .handleType = types[i] };
    VkExternalSemaphoreProperties sp = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES };
    vkGetPhysicalDeviceExternalSemaphoreProperties(a.pd, &si, &sp);
    printf("semaphore %s: features 0x%x\n", i ? "SYNC_FD" : "OPAQUE_FD", sp.externalSemaphoreFeatures);
    if (!i) opaque_ok = (sp.externalSemaphoreFeatures & 3) == 3;
  }
  int dawn = has_ext(a.pd, "VK_KHR_external_memory_fd") && has_ext(a.pd, "VK_KHR_external_semaphore_fd") && opaque_ok;
  printf("Dawn SupportsExternalImages (Linux desktop): %s\n", dawn ? "yes" : "no");
  if (!opaque_ok) return 1;

  make(&b);
  Job ja, jb; job_init(&a, &ja); job_init(&b, &jb);
  // A -> B semaphore, and B -> A semaphore, each shared once and reused every round.
  VkSemaphore ab_a = sem_new(&a, 1), ab_b = sem_new(&b, 0), ba_b = sem_new(&b, 1), ba_a = sem_new(&a, 0);
  int fd;
  VkSemaphoreGetFdInfoKHR gi = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR, .semaphore = ab_a, .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT };
  PFN_vkGetSemaphoreFdKHR getfd_a = (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(a.dev, "vkGetSemaphoreFdKHR");
  PFN_vkGetSemaphoreFdKHR getfd_b = (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(b.dev, "vkGetSemaphoreFdKHR");
  PFN_vkImportSemaphoreFdKHR imp_a = (PFN_vkImportSemaphoreFdKHR)vkGetDeviceProcAddr(a.dev, "vkImportSemaphoreFdKHR");
  PFN_vkImportSemaphoreFdKHR imp_b = (PFN_vkImportSemaphoreFdKHR)vkGetDeviceProcAddr(b.dev, "vkImportSemaphoreFdKHR");
  CK(getfd_a(a.dev, &gi, &fd));
  VkImportSemaphoreFdInfoKHR ii = { .sType = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR, .semaphore = ab_b, .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT, .fd = fd };
  CK(imp_b(b.dev, &ii));
  gi.semaphore = ba_b; CK(getfd_b(b.dev, &gi, &fd));
  ii.semaphore = ba_a; ii.fd = fd; CK(imp_a(a.dev, &ii));

  int bad = 0;
  for (int r = 0; r < rounds; r++) {
    // A writes r and signals; B waits, writes r+1, signals back; A waits and writes r+2.
    job_run(&a, &ja, r, VK_NULL_HANDLE, ab_a);
    job_run(&b, &jb, r + 1, ab_b, ba_b);
    CK(vkWaitForFences(b.dev, 1, &jb.f, VK_TRUE, 5000000000ull));
    CK(vkWaitForFences(a.dev, 1, &ja.f, VK_TRUE, 5000000000ull));
    if (ja.p[1000] != (uint32_t)r || jb.p[1000] != (uint32_t)r + 1) bad++;
    job_run(&a, &ja, r + 2, ba_a, VK_NULL_HANDLE);
    CK(vkWaitForFences(a.dev, 1, &ja.f, VK_TRUE, 5000000000ull));
    if (ja.p[77] != (uint32_t)r + 2) bad++;
  }
  // Temporary import of an exported payload, then a SYNC_FD export of a signalled OPAQUE semaphore.
  gi.semaphore = ab_a; CK(getfd_a(a.dev, &gi, &fd));
  VkSemaphore tmp = sem_new(&b, 0);
  ii.semaphore = tmp; ii.fd = fd; ii.flags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT; CK(imp_b(b.dev, &ii));
  job_run(&a, &ja, 7, VK_NULL_HANDLE, ab_a);
  job_run(&b, &jb, 8, tmp, VK_NULL_HANDLE);
  CK(vkWaitForFences(b.dev, 1, &jb.f, VK_TRUE, 5000000000ull));
  if (jb.p[5] != 8) bad++;
  job_run(&a, &ja, 9, VK_NULL_HANDLE, ab_a);
  gi.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT; CK(getfd_a(a.dev, &gi, &fd));
  printf("sync_fd from opaque semaphore: %s\n", fd >= 0 ? "ok" : "none");
  if (fd >= 0) close(fd);
  CK(vkDeviceWaitIdle(a.dev)); CK(vkDeviceWaitIdle(b.dev));
  printf("rounds %d, bad %d -> %s\n", rounds, bad, bad ? "FAIL" : "PASS");
  return bad != 0;
}
