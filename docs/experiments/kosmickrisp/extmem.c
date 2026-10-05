// extmem: what external memory / semaphore handle types the (Venus) device offers (what Dawn checks)
#include <stdio.h>
#include <string.h>
#include <vulkan/vulkan.h>
int main(void) {
  VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
  VkInstanceCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
  VkInstance inst; vkCreateInstance(&ci, NULL, &inst);
  uint32_t n = 1; VkPhysicalDevice pd; vkEnumeratePhysicalDevices(inst, &n, &pd);
  const struct { const char *name; VkExternalSemaphoreHandleTypeFlagBits t; } st[] = {
    {"sem OPAQUE_FD", VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT}, {"sem SYNC_FD", VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT}};
  for (int i = 0; i < 2; i++) {
    VkPhysicalDeviceExternalSemaphoreInfo si = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO, .handleType = st[i].t };
    VkExternalSemaphoreProperties sp = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES };
    vkGetPhysicalDeviceExternalSemaphoreProperties(pd, &si, &sp);
    printf("%-16s features 0x%x exportFrom 0x%x\n", st[i].name, sp.externalSemaphoreFeatures, sp.exportFromImportedHandleTypes);
  }
  const struct { const char *name; VkExternalMemoryHandleTypeFlagBits t; } mt[] = {
    {"img OPAQUE_FD", VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT}, {"img DMA_BUF", VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT}};
  for (int i = 0; i < 2; i++) {
    VkPhysicalDeviceExternalImageFormatInfo ei = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO, .handleType = mt[i].t };
    VkPhysicalDeviceImageFormatInfo2 fi = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, .pNext = &ei,
      .format = VK_FORMAT_R8G8B8A8_UNORM, .type = VK_IMAGE_TYPE_2D, .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT };
    VkExternalImageFormatProperties ep = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES };
    VkImageFormatProperties2 p = { .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2, .pNext = &ep };
    VkResult r = vkGetPhysicalDeviceImageFormatProperties2(pd, &fi, &p);
    printf("%-16s optimal r=%d features 0x%x\n", mt[i].name, r, ep.externalMemoryProperties.externalMemoryFeatures);
  }
  return 0;
}
