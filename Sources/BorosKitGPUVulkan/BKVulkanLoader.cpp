// BorosKitGPUVulkan: BKVulkanLoader - see BKVulkanLoader.h.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (step M6).

#include "BKVulkanLoader.h"
#include <cstdlib>
#include <string>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace boroskit {
namespace gpu {
namespace vk {

// What: the library handle and vkGetInstanceProcAddr, found once per process. Why: the loader stays open
// for the life of the program (closing it while devices exist would crash).
static void *OpenLoader()
{
#if defined(_WIN32)
    return (void *)LoadLibraryA("vulkan-1.dll");
#else
    std::string names[4];
#if defined(__APPLE__)
    names[0] = "libvulkan.1.dylib";                       // DYLD search path / installed SDK in /usr/local/lib
    names[1] = "/usr/local/lib/libvulkan.1.dylib";
    if (const char *sdk = std::getenv("VULKAN_SDK")) names[2] = std::string(sdk) + "/lib/libvulkan.1.dylib";
#else
    names[0] = "libvulkan.so.1";
    names[1] = "libvulkan.so";
#endif
    for (const std::string &n : names) {
        if (n.empty()) continue;
        if (void *h = dlopen(n.c_str(), RTLD_NOW | RTLD_LOCAL)) return h;
    }
    return nullptr;
#endif
}

static PFN_vkGetInstanceProcAddr LoaderEntry()
{
    static void *library = OpenLoader();
    if (!library) return nullptr;
#if defined(_WIN32)
    return (PFN_vkGetInstanceProcAddr)(void *)GetProcAddress((HMODULE)library, "vkGetInstanceProcAddr");
#else
    return (PFN_vkGetInstanceProcAddr)dlsym(library, "vkGetInstanceProcAddr");
#endif
}

bool LoadGlobal(Functions &f)
{
    f.vkGetInstanceProcAddr = LoaderEntry();
    if (!f.vkGetInstanceProcAddr) return false;
    bool ok = true;
#define BK_VK_LOAD(name) f.name = (PFN_##name)f.vkGetInstanceProcAddr(VK_NULL_HANDLE, #name); ok = ok && f.name;
    BK_VK_GLOBAL_FUNCTIONS(BK_VK_LOAD)
#undef BK_VK_LOAD
    return ok;
}

bool LoadInstance(Functions &f, VkInstance instance)
{
    bool ok = true;
#define BK_VK_LOAD(name) f.name = (PFN_##name)f.vkGetInstanceProcAddr(instance, #name); ok = ok && f.name;
    BK_VK_INSTANCE_FUNCTIONS(BK_VK_LOAD)
#undef BK_VK_LOAD
#define BK_VK_LOAD_OPTIONAL(name) f.name = (PFN_##name)f.vkGetInstanceProcAddr(instance, #name);
    BK_VK_INSTANCE_OPTIONAL_FUNCTIONS(BK_VK_LOAD_OPTIONAL)
#undef BK_VK_LOAD_OPTIONAL
    return ok;
}

bool LoadDevice(Functions &f, VkDevice device)
{
    bool ok = true;
#define BK_VK_LOAD(name) f.name = (PFN_##name)f.vkGetDeviceProcAddr(device, #name); ok = ok && f.name;
    BK_VK_DEVICE_FUNCTIONS(BK_VK_LOAD)
#undef BK_VK_LOAD
    return ok;
}

}  // namespace vk
}  // namespace gpu
}  // namespace boroskit
