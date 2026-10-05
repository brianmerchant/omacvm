// gdpa: does vkGetDeviceProcAddr return vkGetMemoryMetalHandleEXT with the extension enabled?
#include <dlfcn.h>
#include <stdio.h>
#include <vulkan/vulkan.h>
int main(int argc, char **argv) {
  void *h = dlopen(argv[1], RTLD_NOW);
  PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr");
  VkInstance inst; uint32_t api = argc > 2 ? VK_MAKE_API_VERSION(0, 1, atoi(argv[2]), 0) : VK_API_VERSION_1_3;
  const char *iext[] = { "VK_KHR_portability_enumeration" };
  VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = api };
  VkInstanceCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
    .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR, .enabledExtensionCount = 1, .ppEnabledExtensionNames = iext };
  printf("instance %d\n", ((PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance"))(&ci, NULL, &inst));
  uint32_t n = 1; VkPhysicalDevice pd;
  ((PFN_vkEnumeratePhysicalDevices)gipa(inst, "vkEnumeratePhysicalDevices"))(inst, &n, &pd);
  float prio = 1; VkDeviceQueueCreateInfo q = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
  const char *dext[] = { "VK_EXT_external_memory_metal" };
  VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &q,
    .enabledExtensionCount = 1, .ppEnabledExtensionNames = dext };
  VkDevice dev;
  printf("device %d\n", ((PFN_vkCreateDevice)gipa(inst, "vkCreateDevice"))(pd, &dci, NULL, &dev));
  PFN_vkGetDeviceProcAddr gdpa = (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr");
  printf("gdpa GetMemoryMetalHandleEXT %p props %p  gipa: %p\n", (void *)gdpa(dev, "vkGetMemoryMetalHandleEXT"),
         (void *)gdpa(dev, "vkGetMemoryMetalHandlePropertiesEXT"), (void *)gipa(inst, "vkGetMemoryMetalHandleEXT"));
  return 0;
}
