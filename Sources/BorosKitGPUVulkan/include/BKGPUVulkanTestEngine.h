// BorosKitGPUVulkan: BKGPUVulkanTestEngine.h - makes the Vulkan engine (through MoltenVK on a Mac) available as the
// TEST engine of BKGPUEngine.h. Call once at app launch; nothing starts until the user picks the test engine.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Boros 6 MoltenVK test switch).
//
// PORTING NOTES: plain C entry point (callable from Objective-C / manual retain-release code). Vulkan is never bundled:
// the device comes from the user's installed Vulkan SDK (see BKVulkanLoader.cpp for the search order and the MoltenVK
// driver selection). A build without the SDK headers registers a stub that reports "built without the Vulkan SDK".
#ifndef BK_GPU_VULKAN_TEST_ENGINE_H
#define BK_GPU_VULKAN_TEST_ENGINE_H
#ifdef __cplusplus
extern "C" {
#endif
void BKGPUVulkanTestEngineInstall(void);
#ifdef __cplusplus
}
#endif
#endif
