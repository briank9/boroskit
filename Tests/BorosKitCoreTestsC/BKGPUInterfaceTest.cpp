// BorosKit plain-C/C++ core tests: BKGPU.h (the backend-neutral GPU interface) compiles as plain C++17
// and can be implemented. Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (step M5).
//
// What: a tiny CPU-only "device" that implements every method of the interface (buffers in ordinary
// memory; pipelines, textures and command lists answer Status::Unsupported). It is NOT a renderer - it
// only proves that the header is complete, self-contained (no Apple / Vulkan headers) and that a
// backend can be written against it. Its own executable: bk_gpu_interface_test (ctest gpu.interface).

#include "BKGPU.h"
#include <cstdio>
#include <cstring>
#include <type_traits>
#include <vector>

using namespace boroskit::gpu;

namespace {

int gFailures = 0;
#define BK_GPU_CHECK(cond) do { if (!(cond)) { std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); gFailures++; } } while (0)

class CPUBuffer final : public Buffer {
public:
    explicit CPUBuffer(uint64_t bytes) : storage_(bytes) {}
    uint64_t size() const override { return storage_.size(); }
    void *map() override { return storage_.data(); }
    void unmap() override {}
private:
    std::vector<uint8_t> storage_;
};

class CPUDevice final : public Device {
public:
    CPUDevice() { limits_.maxBufferBytes = 1u << 20; limits_.unifiedMemory = true; }
    const Limits &limits() const override { return limits_; }
    const char *name() const override { return "BorosKit CPU test device"; }
    std::unique_ptr<Buffer> makeBuffer(uint64_t bytes, Memory, uint32_t, Status *status) override {
        if (bytes == 0 || bytes > limits_.maxBufferBytes) { if (status) *status = Status::InvalidArgument; return nullptr; }
        if (status) *status = Status::Ok;
        return std::unique_ptr<Buffer>(new CPUBuffer(bytes));
    }
    std::unique_ptr<Texture> makeTexture(const TextureDesc &, Status *status) override { return refuse<Texture>(status); }
    std::unique_ptr<Sampler> makeSampler(const SamplerDesc &, Status *status) override { return refuse<Sampler>(status); }
    std::unique_ptr<ComputePipeline> makeCompute(const ComputeDesc &, Status *status) override { return refuse<ComputePipeline>(status); }
    std::unique_ptr<RenderPipeline> makeRender(const RenderDesc &, Status *status) override { return refuse<RenderPipeline>(status); }
    std::unique_ptr<CommandList> begin(Status *status) override { return refuse<CommandList>(status); }
    Status submit(CommandList &, bool, void (*)(void *, Status), void *) override { return Status::Unsupported; }
private:
    template <typename T> static std::unique_ptr<T> refuse(Status *status) { if (status) *status = Status::Unsupported; return nullptr; }
    Limits limits_;
};

}  // namespace

// The interface types stay plain values where a pass fills them in.
static_assert(std::is_trivially_copyable<Binding>::value, "Binding is copied into per-frame lists");
static_assert(std::is_trivially_copyable<RenderDesc>::value && std::is_trivially_copyable<ComputeDesc>::value,
              "pipeline descriptions are plain values");
static_assert(kSlotBase[(int)SlotKind::SampledTexture] == 16 && kSlotBase[(int)SlotKind::StorageImage] == 32 &&
              kSlotBase[(int)SlotKind::Sampler] == 40, "Vulkan binding ranges of PORTING NOTES");
static_assert(std::has_virtual_destructor<Device>::value && std::is_abstract<Device>::value, "Device is an interface");

int main()
{
    std::unique_ptr<Device> device(new CPUDevice());
    Status status = Status::NotFound;
    std::unique_ptr<Buffer> buffer = device->makeBuffer(64, Memory::Upload, UsageStorage, &status);
    BK_GPU_CHECK(status == Status::Ok && buffer && buffer->size() == 64);
    if (buffer) {
        std::memset(buffer->map(), 7, 64);
        BK_GPU_CHECK(static_cast<const uint8_t *>(buffer->map())[63] == 7);
        buffer->unmap();
    }
    BK_GPU_CHECK(device->makeBuffer(0, Memory::Upload, UsageStorage, &status) == nullptr && status == Status::InvalidArgument);
    ComputeDesc compute;
    compute.kernel.name = "bk_surface_classify";
    compute.workgroup[0] = 256;
    BK_GPU_CHECK(device->makeCompute(compute, &status) == nullptr && status == Status::Unsupported);
    RenderDesc render;
    BK_GPU_CHECK(render.colorCount == 1 && render.cull == CullMode::None && render.depthCompare == DepthCompare::Less);
    BK_GPU_CHECK(std::strcmp(device->name(), "BorosKit CPU test device") == 0 && device->limits().unifiedMemory);
    std::printf("%s BKGPU.h interface (%d failures)\n", gFailures ? "FAILED" : "ok    ", gFailures);
    return gFailures ? 1 : 0;
}
