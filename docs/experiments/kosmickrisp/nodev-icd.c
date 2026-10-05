/* A Vulkan driver that loads and makes an instance but has no device: the
 * "loads but has no device" case of virgl-darwin-kosmickrisp-fallback.patch. */
#include <stdint.h>
#include <string.h>
typedef void (*fn)(void);
static int instance;
static int create_instance(const void *info, const void *alloc, void **out) { *out = &instance; return 0; }
static void destroy_instance(void *i, const void *alloc) {}
static int enumerate_devices(void *i, uint32_t *count, void **devices) { *count = 0; return 0; }
fn vk_icdGetInstanceProcAddr(void *i, const char *name) {
  if (!strcmp(name, "vkCreateInstance")) return (fn)create_instance;
  if (!strcmp(name, "vkDestroyInstance")) return (fn)destroy_instance;
  if (!strcmp(name, "vkEnumeratePhysicalDevices")) return (fn)enumerate_devices;
  return 0;
}
int vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *v) { if (*v > 5) *v = 5; return 0; }
