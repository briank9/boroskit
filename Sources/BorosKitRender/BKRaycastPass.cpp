// BorosKitRender: BKRaycastPass.cpp - the volume ray caster on the shared GPU interface (see BKRaycastPass.h).
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan step 7.1 #4b). The bindings, workgroup sizes and dispatch
// counts are the ones BKVolumeRenderer.m used directly on Metal, so the Metal pictures stay bit-identical.

#include "BKRaycastPass.h"
#include "BKRenderCore.h"

#include <cstring>
#include <vector>

namespace boroskit {
namespace render {

using namespace boroskit::gpu;

namespace {

SlotLayout Slot(SlotKind kind, uint32_t slot)
{
    SlotLayout s;
    s.kind = kind;
    s.slot = slot;
    return s;
}

Binding BufferAt(uint32_t slot, Buffer *buffer)
{
    Binding b;
    b.kind = SlotKind::StorageBuffer;
    b.slot = slot;
    b.buffer = buffer;
    return b;
}

Binding BytesAt(uint32_t slot, const void *bytes, uint32_t count)
{
    Binding b;
    b.kind = SlotKind::StorageBuffer;
    b.slot = slot;
    b.bytes = bytes;
    b.byteCount = count;
    return b;
}

Binding TextureAt(uint32_t slot, Texture *texture, SlotKind kind = SlotKind::SampledTexture)
{
    Binding b;
    b.kind = kind;
    b.slot = slot;
    b.texture = texture;
    return b;
}

std::unique_ptr<ComputePipeline> MakeKernel(Device &device, const char *name, uint32_t x, uint32_t y, uint32_t z,
                                            const std::vector<SlotLayout> &slots, Status *status)
{
    ComputeDesc cd;
    cd.kernel.name = name;
    cd.workgroup[0] = x; cd.workgroup[1] = y; cd.workgroup[2] = z;
    cd.slots = slots.data();
    cd.slotCount = (uint32_t)slots.size();
    cd.label = name;
    return device.makeCompute(cd, status);
}

// What: a 1-texel texture of `format` filled with zeros (so it is in a readable state on every backend).
std::unique_ptr<Texture> Placeholder(Device &device, TextureType type, Format format, uint32_t bytesPerTexel)
{
    TextureDesc td;
    td.type = type;
    td.format = format;
    td.usage = UsageSampled | UsageCopyDestination;
    td.label = "raycast placeholder";
    std::unique_ptr<Texture> t = device.makeTexture(td, nullptr);
    if (!t) return nullptr;
    const uint8_t zero[16] = { 0 };
    std::unique_ptr<CommandList> list = device.begin(nullptr);
    if (!list || list->upload(*t, zero, bytesPerTexel, bytesPerTexel, 0, 1) != Status::Ok || device.submit(*list, true) != Status::Ok)
        return nullptr;
    return t;
}

}  // namespace

struct RaycastPass::Impl {
    Device &device;
    std::unique_ptr<ComputePipeline> raycast, raycastTexture, brickRanges, classify;
    std::unique_ptr<Sampler> linear;
    std::unique_ptr<Texture> noColor, noDistance, noVolume, noTable;
    std::unique_ptr<Buffer> noBuffer;
    explicit Impl(Device &d) : device(d) {}

    void bindTextures(const RaycastInputs &in, std::vector<Binding> &b)
    {
        b.push_back(TextureAt(0, in.volume));
        b.push_back(TextureAt(1, in.table));
        b.push_back(TextureAt(3, in.geometryColor ? in.geometryColor : noColor.get()));
        b.push_back(TextureAt(4, in.geometryDistance ? in.geometryDistance : noDistance.get()));
        b.push_back(TextureAt(5, in.blendVolume ? in.blendVolume : noVolume.get()));
        b.push_back(TextureAt(6, in.blendTable ? in.blendTable : noTable.get()));
        Binding s;
        s.kind = SlotKind::Sampler;
        s.slot = 0;
        s.sampler = linear.get();
        b.push_back(s);
    }
};

RaycastPass::RaycastPass(Device &device) : impl_(new Impl(device)) {}
RaycastPass::~RaycastPass() = default;

Status RaycastPass::prepare()
{
    Impl &m = *impl_;
    if (m.raycast) return Status::Ok;
    Status s = Status::Ok;
    std::vector<SlotLayout> textures = { Slot(SlotKind::SampledTexture, 0), Slot(SlotKind::SampledTexture, 1),
                                         Slot(SlotKind::SampledTexture, 3), Slot(SlotKind::SampledTexture, 4),
                                         Slot(SlotKind::SampledTexture, 5), Slot(SlotKind::SampledTexture, 6),
                                         Slot(SlotKind::Sampler, 0) };
    std::vector<SlotLayout> ray = textures;
    for (uint32_t i = 0; i < 5; i++) ray.push_back(Slot(SlotKind::StorageBuffer, i));
    m.raycast = MakeKernel(m.device, "bk_raycast", 8, 8, 1, ray, &s);
    if (!m.raycast) return s;
    std::vector<SlotLayout> onScreen = textures;
    for (uint32_t i = 0; i < 4; i++) onScreen.push_back(Slot(SlotKind::StorageBuffer, i));
    onScreen.push_back(Slot(SlotKind::StorageImage, 2));
    Status ignored = Status::Ok;
    m.raycastTexture = MakeKernel(m.device, "bk_raycast_texture", 8, 8, 1, onScreen, &ignored);   // optional
    std::vector<SlotLayout> ranges = { Slot(SlotKind::SampledTexture, 0), Slot(SlotKind::Sampler, 0),
                                       Slot(SlotKind::StorageBuffer, 0), Slot(SlotKind::StorageBuffer, 1) };
    m.brickRanges = MakeKernel(m.device, "bk_brick_ranges", 4, 4, 4, ranges, &s);
    std::vector<SlotLayout> classify = { Slot(SlotKind::StorageBuffer, 0), Slot(SlotKind::StorageBuffer, 1),
                                         Slot(SlotKind::StorageBuffer, 2), Slot(SlotKind::StorageBuffer, 3) };
    if (m.brickRanges) m.classify = MakeKernel(m.device, "bk_classify_bricks", 4, 4, 4, classify, &s);
    if (!m.brickRanges || !m.classify) { m.raycast.reset(); return s; }

    SamplerDesc sd;
    sd.linear = true;
    sd.repeat = false;
    sd.normalizedCoordinates = true;
    m.linear = m.device.makeSampler(sd, nullptr);
    m.noColor = Placeholder(m.device, TextureType::Texture2D, Format::RGBA8Unorm, 4);
    m.noDistance = Placeholder(m.device, TextureType::Texture2D, Format::R32Float, 4);
    m.noVolume = Placeholder(m.device, TextureType::Texture3D, Format::R16Unorm, 2);
    m.noTable = Placeholder(m.device, TextureType::Texture2D, Format::RGBA8Unorm, 4);
    m.noBuffer = m.device.makeBuffer(16, Memory::Upload, UsageStorage, nullptr);
    if (!m.linear || !m.noColor || !m.noDistance || !m.noVolume || !m.noTable || !m.noBuffer) {
        m.raycast.reset();
        return Status::OutOfMemory;
    }
    return Status::Ok;
}

bool RaycastPass::hasTextureOutput() const
{
    return impl_->raycastTexture != nullptr;
}

bool RaycastPass::WantsSkipping(bool skipsEmptySpace, const BKRenderParams &p)
{
    if (!skipsEmptySpace || p.mode == 3 /* BKRenderModeAverage */) return false;
    return p.colorVolume == 0 && p.useBlend == 0;
}

Status RaycastPass::makeTable(const float *rgba, std::unique_ptr<Texture> *table, std::unique_ptr<Buffer> *alphaCount)
{
    Device &device = impl_->device;
    TextureDesc td;
    td.format = Format::RGBA32Float;
    td.width = BK_TRANSFER_FUNCTION_ENTRIES;
    td.usage = UsageSampled | UsageCopyDestination;
    td.label = "transfer function table";
    std::unique_ptr<Texture> t = device.makeTexture(td, nullptr);
    if (!t) return Status::OutOfMemory;
    std::unique_ptr<CommandList> list = device.begin(nullptr);
    const uint32_t row = BK_TRANSFER_FUNCTION_ENTRIES * 4 * sizeof(float);
    if (!list || list->upload(*t, rgba, row, row, 0, 1) != Status::Ok || device.submit(*list, true) != Status::Ok)
        return Status::OutOfMemory;
    if (alphaCount) {
        // count[k] = how many of the first k entries have any opacity (the skipping test reads ranges of it).
        std::unique_ptr<Buffer> counts = device.makeBuffer((BK_TRANSFER_FUNCTION_ENTRIES + 1) * sizeof(uint32_t), Memory::Upload,
                                                           UsageStorage, nullptr);
        uint32_t *mapped = counts ? (uint32_t *)counts->map() : nullptr;
        if (!mapped) return Status::OutOfMemory;
        BKRenderAlphaPrefixCount(rgba, BK_TRANSFER_FUNCTION_ENTRIES, mapped);
        counts->unmap();
        *alphaCount = std::move(counts);
    }
    *table = std::move(t);
    return Status::Ok;
}

std::unique_ptr<Buffer> RaycastPass::makeBrickRanges(Texture &volume, const uint32_t grid[3], Status *status)
{
    Impl &m = *impl_;
    Device &device = m.device;
    uint64_t bricks = (uint64_t)grid[0] * grid[1] * grid[2];
    std::unique_ptr<Buffer> ranges = device.makeBuffer(bricks * sizeof(uint32_t), Memory::DeviceOnly, UsageStorage, status);
    if (!ranges) return nullptr;
    const uint32_t grid4[4] = { grid[0], grid[1], grid[2], 0 };   // uint4: no 3-vectors in GPU data
    std::vector<Binding> b = { TextureAt(0, &volume), BufferAt(0, ranges.get()), BytesAt(1, grid4, sizeof grid4) };
    Binding s;
    s.kind = SlotKind::Sampler;
    s.slot = 0;
    s.sampler = m.linear.get();
    b.push_back(s);
    std::unique_ptr<CommandList> list = device.begin(status);
    if (!list) return nullptr;
    Status r = list->dispatch(*m.brickRanges, b.data(), (uint32_t)b.size(), (grid[0] + 3) / 4, (grid[1] + 3) / 4, (grid[2] + 3) / 4);
    if (r == Status::Ok) r = device.submit(*list, true);
    if (status) *status = r;
    return r == Status::Ok ? std::move(ranges) : nullptr;
}

std::unique_ptr<Buffer> RaycastPass::encodeClassify(CommandList &list, const BKRenderParams &p, Buffer &brickRange,
                                                    Buffer &alphaCount, Status *status)
{
    Impl &m = *impl_;
    uint32_t gx = (uint32_t)p.brickGrid.x, gy = (uint32_t)p.brickGrid.y, gz = (uint32_t)p.brickGrid.z;
    // One 32-bit word per brick (no optional 8-bit storage needed in Vulkan; a 512^3 scan has 262,144 bricks = 1 MB).
    std::unique_ptr<Buffer> empty = m.device.makeBuffer((uint64_t)gx * gy * gz * sizeof(uint32_t), Memory::DeviceOnly, UsageStorage, status);
    if (!empty) return nullptr;
    std::vector<Binding> b = { BufferAt(0, &brickRange), BufferAt(1, &alphaCount), BufferAt(2, empty.get()),
                               BytesAt(3, &p, sizeof p) };
    Status r = list.dispatch(*m.classify, b.data(), (uint32_t)b.size(), (gx + 3) / 4, (gy + 3) / 4, (gz + 3) / 4);
    if (status) *status = r;
    return r == Status::Ok ? std::move(empty) : nullptr;
}

Status RaycastPass::encodeRaycast(CommandList &list, const BKRenderParams &p, const RaycastInputs &in, Buffer &colorOut,
                                  Buffer &valueOut)
{
    Impl &m = *impl_;
    if (!m.raycast) return Status::InvalidArgument;
    if (!in.volume || !in.table) return Status::InvalidArgument;
    std::vector<Binding> b;
    m.bindTextures(in, b);
    b.push_back(BytesAt(0, &p, sizeof p));
    b.push_back(BufferAt(1, &colorOut));
    b.push_back(BufferAt(2, &valueOut));
    b.push_back(BufferAt(3, in.brickEmpty ? in.brickEmpty : m.noBuffer.get()));
    b.push_back(BufferAt(4, in.brickRange ? in.brickRange : m.noBuffer.get()));
    // 8 x 8 tiles: neighbouring rays read neighbouring voxels (warm texture cache); the kernel skips threads outside.
    return list.dispatch(*m.raycast, b.data(), (uint32_t)b.size(), (p.width + 7) / 8, (p.height + 7) / 8, 1);
}

Status RaycastPass::encodeRaycastToTexture(CommandList &list, const BKRenderParams &p, const RaycastInputs &in, Texture &target,
                                           const float background[4])
{
    Impl &m = *impl_;
    if (!m.raycastTexture) return Status::Unsupported;
    if (!in.volume || !in.table) return Status::InvalidArgument;
    std::vector<Binding> b;
    m.bindTextures(in, b);
    b.push_back(BytesAt(0, &p, sizeof p));
    b.push_back(BytesAt(1, background, 4 * sizeof(float)));
    b.push_back(BufferAt(2, in.brickEmpty ? in.brickEmpty : m.noBuffer.get()));
    b.push_back(BufferAt(3, in.brickRange ? in.brickRange : m.noBuffer.get()));
    b.push_back(TextureAt(2, &target, SlotKind::StorageImage));
    return list.dispatch(*m.raycastTexture, b.data(), (uint32_t)b.size(), (p.width + 7) / 8, (p.height + 7) / 8, 1);
}

}  // namespace render
}  // namespace boroskit
