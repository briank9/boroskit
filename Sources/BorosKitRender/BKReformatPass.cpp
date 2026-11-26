// BorosKitRender: BKReformatPass.cpp - see BKReformatPass.h.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 #5): same bindings, workgroup and dispatch as the
// Metal code in BKCurvedReformat.mm had, so the Metal pictures stay bit-identical.

#include "BKReformatPass.h"

#include <cstring>

namespace boroskit {
namespace render {

using namespace boroskit::gpu;

struct ReformatPass::Impl {
    Device &device;
    std::unique_ptr<ComputePipeline> kernel;
    std::unique_ptr<Sampler> sampler;
    explicit Impl(Device &d) : device(d) {}
};

ReformatPass::ReformatPass(Device &device) : impl_(new Impl(device)) {}
ReformatPass::~ReformatPass() = default;

Status ReformatPass::prepare()
{
    Impl &m = *impl_;
    if (m.kernel) return Status::Ok;
    SlotLayout slots[5];
    slots[0].kind = SlotKind::StorageBuffer; slots[0].slot = 0;
    slots[1].kind = SlotKind::StorageBuffer; slots[1].slot = 1;
    slots[2].kind = SlotKind::StorageBuffer; slots[2].slot = 2; slots[2].writes = true;
    slots[3].kind = SlotKind::SampledTexture; slots[3].slot = 0;
    slots[4].kind = SlotKind::Sampler; slots[4].slot = 0;
    ComputeDesc cd;
    cd.kernel.name = "bk_curved_reformat";
    cd.workgroup[0] = 8; cd.workgroup[1] = 8; cd.workgroup[2] = 1;
    cd.slots = slots;
    cd.slotCount = 5;
    cd.label = "bk_curved_reformat";
    Status s = Status::Ok;
    m.kernel = m.device.makeCompute(cd, &s);
    if (!m.kernel) return s;
    SamplerDesc sd;   // nearest, clamp: never filters (texelFetch / read only)
    m.sampler = m.device.makeSampler(sd, &s);
    if (!m.sampler) { m.kernel.reset(); return s; }
    return Status::Ok;
}

std::unique_ptr<Buffer> ReformatPass::makeFrames(const BKReformatFrame *frames, uint32_t count, Status *status)
{
    std::unique_ptr<Buffer> b = impl_->device.makeBuffer((uint64_t)sizeof(BKReformatFrame) * count, Memory::Upload, UsageStorage, status);
    void *mapped = b ? b->map() : nullptr;
    if (!mapped) { if (status) *status = Status::OutOfMemory; return nullptr; }
    std::memcpy(mapped, frames, sizeof(BKReformatFrame) * count);
    b->unmap();
    return b;
}

Status ReformatPass::encode(CommandList &list, const BKReformatParams &params, Buffer &frames, Texture &volume, Buffer &values)
{
    Impl &m = *impl_;
    if (!m.kernel) return Status::InvalidArgument;
    Binding b[5];
    b[0].kind = SlotKind::StorageBuffer; b[0].slot = 0; b[0].bytes = &params; b[0].byteCount = sizeof params;
    b[1].kind = SlotKind::StorageBuffer; b[1].slot = 1; b[1].buffer = &frames;
    b[2].kind = SlotKind::StorageBuffer; b[2].slot = 2; b[2].buffer = &values;
    b[3].kind = SlotKind::SampledTexture; b[3].slot = 0; b[3].texture = &volume;
    b[4].kind = SlotKind::Sampler; b[4].slot = 0; b[4].sampler = m.sampler.get();
    return list.dispatch(*m.kernel, b, 5, (params.width + 7) / 8, (params.height + 7) / 8, 1);
}

}  // namespace render
}  // namespace boroskit
