// BorosKitGPUVulkan: BKGPUVulkanTestEngine.mm - see include/BKGPUVulkanTestEngine.h.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".

#import <Foundation/Foundation.h>
#include "BKGPUVulkanTestEngine.h"
#include "BKGPUVulkan.h"
#import "BKGPUEngineBridge.h"
#include <cstdio>

using namespace boroskit::gpu;

// What: starts the test device: no validation layers (an app, not a test program), the GPU chosen automatically.
static Status BKGPUVulkanTestFactory(std::unique_ptr<Device> *out, std::string *description, std::string *reason)
{
    if (!vulkanBackendBuilt()) {
        *reason = "this build has no Vulkan engine (built without the Vulkan SDK)";
        return Status::NotFound;
    }
    const char *loader = "";
    if (!vulkanLoaderAvailable(&loader)) {
        *reason = "Vulkan SDK not found (looked in VULKAN_SDK, ~/VulkanSDK, /usr/local/lib)";
        return Status::NotFound;
    }
    VulkanOptions options;
    Status s = makeVulkanDevice(options, out);
    if (s != Status::Ok) {
        char text[160];
        std::snprintf(text, sizeof text, "no usable Vulkan 1.3 GPU via %s (status %d)", loader, (int)s);
        *reason = text;
        return s;
    }
    char text[512];
    std::snprintf(text, sizeof text, "%s, driver %s, loader %s", (*out)->name(), vulkanDriverName(**out), loader);
    *description = text;
    return Status::Ok;
}

extern "C" void BKGPUVulkanTestEngineInstall(void)
{
    BKGPURegisterTestEngine(BKGPUVulkanTestFactory);
}
