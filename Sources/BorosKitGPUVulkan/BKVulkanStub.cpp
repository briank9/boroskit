// BorosKitGPUVulkan: BKVulkanStub.cpp - the entry points of a build made WITHOUT the Vulkan SDK headers.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
// See BKVulkanAvailable.h. With the headers this file is empty (the real backend is BKVulkanDevice.cpp).

#include "BKVulkanAvailable.h"
#include "BKGPUVulkan.h"

#if !BK_HAVE_VULKAN_HEADERS
namespace boroskit {
namespace gpu {

Status makeVulkanDevice(const VulkanOptions &, std::unique_ptr<Device> *out)
{
    if (out) out->reset();
    return Status::NotFound;   // built without the Vulkan SDK
}

const char *vulkanDriverName(const Device &)
{
    return "";
}

bool vulkanLoaderAvailable(const char **path)
{
    if (path) *path = "";
    return false;
}

bool vulkanLoaderInstalled(const char **path)
{
    if (path) *path = "";
    return false;
}

int vulkanBackendBuilt()
{
    return 0;
}

}  // namespace gpu
}  // namespace boroskit
#endif
