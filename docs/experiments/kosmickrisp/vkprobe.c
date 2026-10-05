// vkprobe: host-side check of a Vulkan driver for Venus.
// cc -I<mesa>/include vkprobe.c -o vkprobe ; VK_DRIVER_FILES=... ./vkprobe <libvulkan.1.dylib>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

int main(int argc, char **argv) {
  void *h = dlopen(argc > 1 ? argv[1] : "libvulkan.1.dylib", RTLD_NOW);
  if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
  PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr");
#define G(n) PFN_##n n = (PFN_##n)gipa(inst, #n)
  VkInstance inst = NULL;
  G(vkCreateInstance);
  const char *exts[] = { "VK_KHR_portability_enumeration", "VK_KHR_get_physical_device_properties2" };
  VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
  VkInstanceCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
    .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR, .enabledExtensionCount = 2, .ppEnabledExtensionNames = exts };
  VkResult r = vkCreateInstance(&ci, NULL, &inst);
  printf("vkCreateInstance %d\n", r);
  if (r) return 1;
  G(vkEnumeratePhysicalDevices); G(vkGetPhysicalDeviceProperties2); G(vkGetPhysicalDeviceFeatures2);
  G(vkEnumerateDeviceExtensionProperties); G(vkGetPhysicalDeviceExternalBufferProperties);
  uint32_t n = 0; vkEnumeratePhysicalDevices(inst, &n, NULL);
  printf("devices %u\n", n);
  if (!n) return 1;
  VkPhysicalDevice pd[4]; n = n > 4 ? 4 : n; vkEnumeratePhysicalDevices(inst, &n, pd);
  VkPhysicalDeviceDriverProperties drv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
  VkPhysicalDeviceProperties2 p = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drv };
  vkGetPhysicalDeviceProperties2(pd[0], &p);
  printf("device %s api %u.%u.%u driver %s %s\n", p.properties.deviceName, VK_API_VERSION_MAJOR(p.properties.apiVersion),
         VK_API_VERSION_MINOR(p.properties.apiVersion), VK_API_VERSION_PATCH(p.properties.apiVersion), drv.driverName, drv.driverInfo);
  VkPhysicalDeviceRobustness2FeaturesEXT rb = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
  VkPhysicalDeviceFeatures2 f = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &rb };
  vkGetPhysicalDeviceFeatures2(pd[0], &f);
  printf("nullDescriptor %u robustBufferAccess2 %u geometryShader %u logicOp %u shaderFloat64 %u tess %u\n",
         rb.nullDescriptor, rb.robustBufferAccess2, f.features.geometryShader, f.features.logicOp,
         f.features.shaderFloat64, f.features.tessellationShader);
  uint32_t ne = 0; vkEnumerateDeviceExtensionProperties(pd[0], NULL, &ne, NULL);
  VkExtensionProperties *e = calloc(ne, sizeof *e); vkEnumerateDeviceExtensionProperties(pd[0], NULL, &ne, e);
  int metal = 0; for (uint32_t i = 0; i < ne; i++) if (!strcmp(e[i].extensionName, "VK_EXT_external_memory_metal")) metal = 1;
  printf("extensions %u external_memory_metal %d\n", ne, metal);
  VkPhysicalDeviceExternalBufferInfo bi = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO,
    .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT };
  VkExternalBufferProperties bp = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES };
  vkGetPhysicalDeviceExternalBufferProperties(pd[0], &bi, &bp);
  printf("mtlheap buffer export features 0x%x\n", bp.externalMemoryProperties.externalMemoryFeatures);
  return 0;
}
