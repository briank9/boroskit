// BorosKitGPUVulkan: BKGPUVulkan.h - making the Vulkan implementation of the BKGPU.h interface.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan engine kickoff, step M6).
//
// PORTING NOTES:
//   - Built by CMake only (never by Package.swift / Boros 6). Needs the Vulkan headers of the installed SDK at
//     build time (user decision D2) and, at run time, only the system Vulkan loader (libvulkan / vulkan-1.dll),
//     which BorosKit opens itself (BKVulkanLoader.cpp) - nothing is linked.
//   - This header itself has no Vulkan types, so callers (tests, BorosCMF) do not need the Vulkan headers.
//   - On macOS the driver is MoltenVK (Vulkan on Metal; testing only). Choose it with the standard loader
//     variable VK_DRIVER_FILES=<SDK>/share/vulkan/icd.d/MoltenVK_icd.json (the SDK also brings a second
//     Metal-based driver, KosmicKrisp, with the same GPU name).
//
// Plain language: "start the Vulkan engine", with the option to switch on Khronos' checking layer, which
// reports every misuse of Vulkan; tests count those reports and fail on any.

#ifndef BK_GPU_VULKAN_H
#define BK_GPU_VULKAN_H

#ifdef __cplusplus   // 2026-11-26: C++ only (the module is also imported from Objective-C)
#include "BKGPU.h"

namespace boroskit {
namespace gpu {

struct VulkanOptions {
    const char *preferredName = nullptr;        // GPU name (BKGPUChoiceCore); nullptr / "" = automatic
    bool validation = false;                    // VK_LAYER_KHRONOS_validation (refused if not installed)
    bool synchronizationValidation = false;     // + its synchronisation checks (needs validation)
    // Called for every validation / driver message of severity warning or error. `context` is passed back.
    void (*message)(void *context, bool isError, const char *text) = nullptr;
    void *messageContext = nullptr;
};

// What: the Vulkan Device. Status::NotFound when there is no Vulkan loader or no GPU, Unsupported when the
// GPU lacks Vulkan 1.3 (dynamic rendering) or the validation layer was asked for but is missing.
Status makeVulkanDevice(const VulkanOptions &options, std::unique_ptr<Device> *out);

// What: the driver's name (e.g. "MoltenVK") of a Device made by makeVulkanDevice, for logs ("" otherwise).
const char *vulkanDriverName(const Device &device);

// What (2026-11-26, Boros 6 MoltenVK test switch): true when a Vulkan loader (libvulkan) can be opened on this machine
// (opens it the first time); `path` (may be null) receives the loader that was found. Always false in a build made
// without the Vulkan SDK headers (BK_HAVE_VULKAN_HEADERS 0) - the backend is then a stub (makeVulkanDevice: NotFound).
bool vulkanLoaderAvailable(const char **path);

// What: 1 when this build contains the real Vulkan backend (the SDK headers were found at build time).
int vulkanBackendBuilt();

}  // namespace gpu
}  // namespace boroskit

#endif  // __cplusplus
#endif  // BK_GPU_VULKAN_H
