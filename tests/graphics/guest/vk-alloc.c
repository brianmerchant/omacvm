/* vk-alloc: what a Vulkan (Venus) app sees past the host's GPU memory budget
 * (virgl-venus-memory-budget.patch). Allocates N blocks of MB megabytes from the first
 * memory type with the wanted property (device-local, or host-visible with "host") until
 * vkAllocateMemory fails; prints one JSON line per block, then frees them all and checks
 * that one block fits again (the budget got the bytes back).
 * keepfd: each block is made exportable, exported as a dma-buf fd and freed, and the fd
 * is kept (the guest's kernel then lets the host context's resource go while the blob
 * lives on). The budget must still count every kept block: blocks past it are refused.
 * After the fds are closed one block fits again.
 * Build: cc -O2 -o vk-alloc vk-alloc.c -lvulkan
 * Usage: vk-alloc [N=64] [MB=256] [device|host|keepfd] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

static VkResult alloc_exportable(VkDevice dev, uint32_t type, int mb, VkDeviceMemory *mem)
{
   VkExportMemoryAllocateInfo export = {
      .sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
      .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
   VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                               .pNext = &export, .allocationSize = (VkDeviceSize)mb << 20,
                               .memoryTypeIndex = type };
   return vkAllocateMemory(dev, &ai, NULL, mem);
}

/* make exportable, export a dma-buf fd, free the memory, keep the fd: n times */
static int keep_fds(VkDevice dev, uint32_t type, int n, int mb)
{
   PFN_vkGetMemoryFdKHR get_fd =
      (PFN_vkGetMemoryFdKHR)vkGetDeviceProcAddr(dev, "vkGetMemoryFdKHR");
   int *fds = calloc(n, sizeof *fds);
   int kept = 0;
   VkResult last = VK_SUCCESS;
   for (int i = 0; i < n; i++) {
      VkDeviceMemory mem = VK_NULL_HANDLE;
      int fd = -1;
      last = alloc_exportable(dev, type, mb, &mem);
      if (last == VK_SUCCESS) {
         VkMemoryGetFdInfoKHR gi = { .sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
                                     .memory = mem,
                                     .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
         last = get_fd(dev, &gi, &fd);
         vkFreeMemory(dev, mem, NULL);
      }
      printf("{\"block\":%d,\"kept_mb\":%lld,\"result\":%d}\n", i + 1,
             (long long)(kept + (last == VK_SUCCESS)) * mb, last);
      if (last != VK_SUCCESS)
         break;
      fds[kept++] = fd;
   }
   for (int i = 0; i < kept; i++)
      close(fds[i]);
   /* the guest's kernel frees each blob when its last fd closes: give the host a moment */
   VkResult r = VK_ERROR_UNKNOWN;
   for (int t = 0; t < 20 && r != VK_SUCCESS; t++) {
      VkDeviceMemory again = VK_NULL_HANDLE;
      if (t)
         usleep(100 * 1000);
      r = alloc_exportable(dev, type, mb, &again);
      if (again)
         vkFreeMemory(dev, again, NULL);
   }
   printf("{\"done\":true,\"kept\":%d,\"refused_with\":%d,\"after_close\":%d}\n", kept,
          last, r);
   vkDestroyDevice(dev, NULL);
   return 0;
}

int main(int argc, char **argv)
{
   int n = argc > 1 ? atoi(argv[1]) : 64, mb = argc > 2 ? atoi(argv[2]) : 256;
   int host = argc > 3 && !strcmp(argv[3], "host");
   int keepfd = argc > 3 && !strcmp(argv[3], "keepfd");
   setvbuf(stdout, NULL, _IOLBF, 0);
   VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                             .apiVersion = VK_API_VERSION_1_1 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                .pApplicationInfo = &app };
   VkInstance inst;
   if (vkCreateInstance(&ici, NULL, &inst)) {
      printf("{\"error\":\"vkCreateInstance\"}\n");
      return 2;
   }
   uint32_t count = 1;
   VkPhysicalDevice pd;
   if (vkEnumeratePhysicalDevices(inst, &count, &pd) < 0 || !count) {
      printf("{\"error\":\"no device\"}\n");
      return 2;
   }
   VkPhysicalDeviceProperties props;
   vkGetPhysicalDeviceProperties(pd, &props);
   VkPhysicalDeviceMemoryProperties mp;
   vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   VkMemoryPropertyFlags want = host ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                                     : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
   uint32_t type = 0;
   while (type < mp.memoryTypeCount && !(mp.memoryTypes[type].propertyFlags & want))
      type++;
   if (type == mp.memoryTypeCount) {
      printf("{\"error\":\"no memory type\"}\n");
      return 2;
   }
   float prio = 1.0f;
   VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                   .queueCount = 1, .pQueuePriorities = &prio };
   const char *fd_exts[] = { VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
                             VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
                              .enabledExtensionCount = keepfd ? 2 : 0,
                              .ppEnabledExtensionNames = fd_exts };
   VkDevice dev;
   if (vkCreateDevice(pd, &dci, NULL, &dev)) {
      printf("{\"error\":\"vkCreateDevice\"}\n");
      return 2;
   }
   printf("{\"device\":\"%s\",\"memory_type\":%u,\"flags\":\"0x%x\"}\n", props.deviceName, type,
          mp.memoryTypes[type].propertyFlags);
   if (keepfd)
      return keep_fds(dev, type, n, mb);
   VkDeviceMemory *mem = calloc(n, sizeof *mem);
   int ok = 0;
   VkResult last = VK_SUCCESS;
   for (int i = 0; i < n; i++) {
      VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                  .allocationSize = (VkDeviceSize)mb << 20,
                                  .memoryTypeIndex = type };
      last = vkAllocateMemory(dev, &ai, NULL, &mem[i]);
      printf("{\"block\":%d,\"mb\":%lld,\"result\":%d}\n", i + 1, (long long)(i + 1) * mb, last);
      if (last != VK_SUCCESS) {
         mem[i] = VK_NULL_HANDLE;
         break;
      }
      ok++;
   }
   for (int i = 0; i < n; i++)
      if (mem[i])
         vkFreeMemory(dev, mem[i], NULL);
   VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                               .allocationSize = (VkDeviceSize)mb << 20,
                               .memoryTypeIndex = type };
   VkDeviceMemory again = VK_NULL_HANDLE;
   VkResult r = vkAllocateMemory(dev, &ai, NULL, &again);
   if (again)
      vkFreeMemory(dev, again, NULL);
   printf("{\"done\":true,\"ok\":%d,\"refused_with\":%d,\"after_free\":%d}\n", ok, last, r);
   vkDestroyDevice(dev, NULL);
   vkDestroyInstance(inst, NULL);
   return 0;
}
