// BorosKit Vulkan tests: shared helpers (validation message counting, device start, readback).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (steps M7 / M9).

#ifndef BK_VULKAN_TEST_SUPPORT_H
#define BK_VULKAN_TEST_SUPPORT_H

#include "BKGPUVulkan.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

namespace bktest {

using namespace boroskit::gpu;

// Every validation-layer / driver warning or error is printed and counted: milestone 1 requires zero.
struct Messages { int warnings = 0, errors = 0; };
inline void CountMessage(void *context, bool isError, const char *text)
{
    Messages *m = static_cast<Messages *>(context);
    (isError ? m->errors : m->warnings)++;
    std::printf("VALIDATION %s: %s\n", isError ? "ERROR" : "warning", text);
}

// What: the Vulkan device with validation + synchronisation validation, or nullptr (reason printed).
inline std::unique_ptr<Device> StartDevice(Messages *messages)
{
    VulkanOptions o;
    o.validation = std::getenv("BK_VULKAN_NO_VALIDATION") == nullptr;
    o.synchronizationValidation = o.validation;
    o.message = CountMessage;
    o.messageContext = messages;
    std::unique_ptr<Device> device;
    Status s = makeVulkanDevice(o, &device);
    if (s != Status::Ok) {
        std::printf("FAIL: no Vulkan device (status %d)\n", (int)s);
        return nullptr;
    }
    std::printf("Vulkan device: %s (driver %s), validation %s\n", device->name(), vulkanDriverName(*device),
                o.validation ? "on (incl. synchronisation)" : "OFF");
    return device;
}

// What: copies a texture into CPU memory (tight rows) and returns the bytes.
inline bool ReadTexture(Device &device, Texture &texture, std::vector<uint8_t> *out, uint32_t bytesPerTexel)
{
    const TextureDesc &d = texture.desc();
    uint64_t bytes = (uint64_t)d.width * d.height * d.depth * bytesPerTexel;
    Status s;
    std::unique_ptr<Buffer> buffer = device.makeBuffer(bytes, Memory::Readback, UsageCopyDestination, &s);
    if (!buffer) return false;
    std::unique_ptr<CommandList> list = device.begin(&s);
    if (!list || list->readback(texture, *buffer) != Status::Ok || device.submit(*list, true) != Status::Ok) return false;
    out->resize((size_t)bytes);
    std::memcpy(out->data(), buffer->map(), (size_t)bytes);
    buffer->unmap();
    return true;
}

}  // namespace bktest

#endif
