// BorosKitGPUVulkan: BKVulkanAvailable.h - is the real Vulkan backend compiled into this build?
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
//
// What: BK_HAVE_VULKAN_HEADERS is 1 when the Vulkan SDK headers (<vulkan/vulkan.h>) are on the include path (the
// installed SDK's include folder: /usr/local/include, or ~/VulkanSDK/<version>/macOS/include added by Package.swift,
// or VULKAN_SDK in CMake). Without them the backend sources compile to nothing and BKVulkanStub.cpp provides the
// entry points (no Vulkan device). Why: Boros 6 must build on a Mac without the Vulkan SDK (user decision D2:
// Vulkan headers come from the installed SDK only, nothing is vendored).
#ifndef BK_VULKAN_AVAILABLE_H
#define BK_VULKAN_AVAILABLE_H
#if defined(BK_FORCE_NO_VULKAN_HEADERS)   // (check of the no-SDK build: clang -DBK_FORCE_NO_VULKAN_HEADERS)
#define BK_HAVE_VULKAN_HEADERS 0
#elif defined(__has_include)
#if __has_include(<vulkan/vulkan.h>)
#define BK_HAVE_VULKAN_HEADERS 1
#endif
#endif
#ifndef BK_HAVE_VULKAN_HEADERS
#define BK_HAVE_VULKAN_HEADERS 0
#endif
#endif
