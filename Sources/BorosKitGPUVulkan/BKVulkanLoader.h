// BorosKitGPUVulkan: BKVulkanLoader - BorosKit's own Vulkan function loader (no third-party meta-loader).
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (step M6).
//
// PORTING NOTES:
//   - Opens the system Vulkan loader at run time (dlopen / LoadLibrary), takes vkGetInstanceProcAddr from it,
//     and fetches exactly the functions listed below into one table. VK_NO_PROTOTYPES: nothing links against
//     libvulkan, so a machine without Vulkan simply gets Status::NotFound.
//   - Lists are X-macros: adding a function = one line here.
//   - Headers: the official <vulkan/vulkan.h> of the installed SDK (user decision D2), never copied.

#ifndef BK_VULKAN_LOADER_H
#define BK_VULKAN_LOADER_H

#ifndef VK_NO_PROTOTYPES
#define VK_NO_PROTOTYPES
#endif
#include <vulkan/vulkan.h>
#include <string>

namespace boroskit {
namespace gpu {
namespace vk {

// Functions that exist before an instance.
#define BK_VK_GLOBAL_FUNCTIONS(X) \
    X(vkCreateInstance) X(vkEnumerateInstanceExtensionProperties) X(vkEnumerateInstanceLayerProperties) \
    X(vkEnumerateInstanceVersion)

// Instance-level functions.
#define BK_VK_INSTANCE_FUNCTIONS(X) \
    X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceProperties) \
    X(vkGetPhysicalDeviceProperties2) X(vkGetPhysicalDeviceFeatures) X(vkGetPhysicalDeviceFeatures2) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkGetPhysicalDeviceMemoryProperties) \
    X(vkGetPhysicalDeviceFormatProperties) X(vkEnumerateDeviceExtensionProperties) X(vkCreateDevice) \
    X(vkGetDeviceProcAddr)

// Optional instance-level functions (an extension may be missing).
#define BK_VK_INSTANCE_OPTIONAL_FUNCTIONS(X) \
    X(vkCreateDebugUtilsMessengerEXT) X(vkDestroyDebugUtilsMessengerEXT)

// Device-level functions (Vulkan 1.3 core).
#define BK_VK_DEVICE_FUNCTIONS(X) \
    X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkDeviceWaitIdle) X(vkQueueSubmit) X(vkQueueWaitIdle) \
    X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) X(vkBindBufferMemory) \
    X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) \
    X(vkCreateImageView) X(vkDestroyImageView) X(vkCreateSampler) X(vkDestroySampler) \
    X(vkAllocateMemory) X(vkFreeMemory) X(vkMapMemory) X(vkUnmapMemory) \
    X(vkCreateShaderModule) X(vkDestroyShaderModule) \
    X(vkCreateDescriptorSetLayout) X(vkDestroyDescriptorSetLayout) X(vkCreatePipelineLayout) \
    X(vkDestroyPipelineLayout) X(vkCreateGraphicsPipelines) X(vkDestroyPipeline) \
    X(vkCreateDescriptorPool) X(vkDestroyDescriptorPool) X(vkAllocateDescriptorSets) X(vkUpdateDescriptorSets) \
    X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) X(vkFreeCommandBuffers) \
    X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences) \
    X(vkCmdPipelineBarrier) X(vkCmdCopyBuffer) X(vkCmdCopyBufferToImage) X(vkCmdCopyImageToBuffer) \
    X(vkCmdBeginRendering) X(vkCmdEndRendering) X(vkCmdBindPipeline) X(vkCmdBindDescriptorSets) \
    X(vkCmdSetViewport) X(vkCmdSetScissor) X(vkCmdDraw) X(vkCmdDrawIndexed) X(vkCmdBindIndexBuffer) \
    X(vkCreateComputePipelines) X(vkCmdDispatch)

#define BK_VK_DECLARE(name) PFN_##name name = nullptr;
struct Functions {
    PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr = nullptr;
    BK_VK_GLOBAL_FUNCTIONS(BK_VK_DECLARE)
    BK_VK_INSTANCE_FUNCTIONS(BK_VK_DECLARE)
    BK_VK_INSTANCE_OPTIONAL_FUNCTIONS(BK_VK_DECLARE)
    BK_VK_DEVICE_FUNCTIONS(BK_VK_DECLARE)
};
#undef BK_VK_DECLARE

// What: opens the system Vulkan loader and fills the global functions. false = no Vulkan on this machine.
// What (2026-11-26): the libvulkan file the loader search would open, WITHOUT opening it ("" = none found).
std::string FindLoaderFile();
// What (2026-11-26): the path of the libvulkan that was opened ("" before / if none).
const char *LoaderPath();
// What: vkGetInstanceProcAddr of the loader (opening it the first time), or nullptr when there is no Vulkan.
PFN_vkGetInstanceProcAddr LoaderEntry();

bool LoadGlobal(Functions &f);
// What: instance-level functions (the required ones must all be found; optional ones may stay null).
bool LoadInstance(Functions &f, VkInstance instance);
// What: device-level functions; false if one is missing (driver below Vulkan 1.3).
bool LoadDevice(Functions &f, VkDevice device);

}  // namespace vk
}  // namespace gpu
}  // namespace boroskit

#endif  // BK_VULKAN_LOADER_H
