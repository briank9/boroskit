// BorosKitGPUVulkan: BKVulkanLoader - see BKVulkanLoader.h.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (step M6).

#include "BKVulkanAvailable.h"
#if BK_HAVE_VULKAN_HEADERS   // 2026-11-26: else BKVulkanStub.cpp (build without the SDK)
#include "BKVulkanLoader.h"
#include <cstdlib>
#include <string>
#include <vector>
#include <sys/stat.h>
#if defined(__APPLE__)
#include <dirent.h>
#endif

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace boroskit {
namespace gpu {
namespace vk {

// What (2026-11-26, Boros 6 MoltenVK test switch): the newest ~/VulkanSDK/<version>/macOS folder, or "" if none.
// Why: the Vulkan SDK installs there by default; the app never bundles Vulkan, it uses the user's installed SDK.
#if defined(__APPLE__)
static std::string NewestHomeSDK()
{
    const char *home = std::getenv("HOME");
    if (!home) return std::string();
    std::string root = std::string(home) + "/VulkanSDK";
    DIR *dir = opendir(root.c_str());
    if (!dir) return std::string();
    std::string best;
    while (struct dirent *e = readdir(dir)) {
        if (e->d_name[0] == '.') continue;
        std::string candidate = root + "/" + e->d_name + "/macOS";
        struct stat st;
        if (stat((candidate + "/lib/libvulkan.1.dylib").c_str(), &st) != 0) continue;
        // Version folders are dotted numbers; compare part by part.
        if (best.empty()) { best = candidate; continue; }
        std::string a = e->d_name, b = best.substr(root.size() + 1);
        b = b.substr(0, b.find('/'));
        bool newer = false;
        size_t i = 0, j = 0;
        while (i < a.size() || j < b.size()) {
            long x = std::strtol(a.c_str() + i, nullptr, 10), y = std::strtol(b.c_str() + j, nullptr, 10);
            if (x != y) { newer = x > y; break; }
            i = a.find('.', i); j = b.find('.', j);
            if (i == std::string::npos || j == std::string::npos) { newer = i != std::string::npos; break; }
            i++; j++;
        }
        if (newer) best = candidate;
    }
    closedir(dir);
    return best;
}
#endif

static std::string gLoaderPath;   // which libvulkan was opened (for the log / Preferences note)

// What: the library handle and vkGetInstanceProcAddr, found once per process. Why: the loader stays open
// for the life of the program (closing it while devices exist would crash).
// Search order (macOS): VULKAN_SDK/lib, the newest ~/VulkanSDK/<version>/macOS/lib, /usr/local/lib, then the
// default dyld search. 2026-11-26: before opening, when the caller has not chosen a driver (VK_DRIVER_FILES /
// VK_ICD_FILENAMES unset), MoltenVK's ICD file next to the found loader is selected (the SDK also registers other
// drivers, e.g. KosmicKrisp), and MoltenVK's fast math is switched off unless set (precision rule: no fast math).
static void *OpenLoader()
{
#if defined(_WIN32)
    return (void *)LoadLibraryA("vulkan-1.dll");
#else
    std::vector<std::string> dirs;
#if defined(__APPLE__)
    if (const char *sdk = std::getenv("VULKAN_SDK")) dirs.push_back(std::string(sdk) + "/lib");
    std::string home = NewestHomeSDK();
    if (!home.empty()) dirs.push_back(home + "/lib");
    dirs.push_back("/usr/local/lib");
    for (const std::string &d : dirs) {
        std::string lib = d + "/libvulkan.1.dylib";
        struct stat st;
        if (stat(lib.c_str(), &st) != 0) continue;
        if (!std::getenv("VK_DRIVER_FILES") && !std::getenv("VK_ICD_FILENAMES")) {
            std::string icd = d + "/../share/vulkan/icd.d/MoltenVK_icd.json";
            if (stat(icd.c_str(), &st) == 0) setenv("VK_DRIVER_FILES", icd.c_str(), 0);
        }
        if (!std::getenv("MVK_CONFIG_FAST_MATH_ENABLED")) setenv("MVK_CONFIG_FAST_MATH_ENABLED", "0", 0);
        if (void *h = dlopen(lib.c_str(), RTLD_NOW | RTLD_LOCAL)) { gLoaderPath = lib; return h; }
    }
    const char *fallback = "libvulkan.1.dylib";
#else
    const char *fallback = "libvulkan.so.1";
#endif
    if (void *h = dlopen(fallback, RTLD_NOW | RTLD_LOCAL)) { gLoaderPath = fallback; return h; }
    return nullptr;
#endif
}

const char *LoaderPath()
{
    return gLoaderPath.c_str();
}

PFN_vkGetInstanceProcAddr LoaderEntry()
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

#endif   // BK_HAVE_VULKAN_HEADERS
