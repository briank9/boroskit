// BorosKitDisplay: BKDisplayPass.cpp - see BKDisplayPass.h.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 #6): same pipeline (blend), bindings and draw as
// BKImageLayerRenderer.m used directly on Metal, so the Metal pictures stay bit-identical.

#include "BKDisplayPass.h"

#include <map>
#include <utility>

namespace boroskit {
namespace display {

using namespace boroskit::gpu;

struct DisplayPass::Impl {
    Device &device;
    std::map<std::pair<int, bool>, std::unique_ptr<RenderPipeline>> pipelines;   // (target format, blended)
    std::unique_ptr<Sampler> sampler;
    explicit Impl(Device &d) : device(d) {}
};

DisplayPass::DisplayPass(Device &device) : impl_(new Impl(device)) {}
DisplayPass::~DisplayPass() = default;

Status DisplayPass::prepare()
{
    if (impl_->sampler) return Status::Ok;
    SamplerDesc sd;   // nearest, clamp: only so texelFetch has a sampler object (Vulkan)
    Status s = Status::Ok;
    impl_->sampler = impl_->device.makeSampler(sd, &s);
    return impl_->sampler ? Status::Ok : s;
}

Status DisplayPass::encode(CommandList &list, const BKDisplayParams &params, Texture &image, Texture &lut, Format target,
                           bool blended)
{
    Impl &m = *impl_;
    if (!m.sampler) return Status::InvalidArgument;
    std::unique_ptr<RenderPipeline> &pipeline = m.pipelines[std::make_pair((int)target, blended)];
    if (!pipeline) {
        SlotLayout slots[4];
        slots[0].kind = SlotKind::StorageBuffer; slots[0].slot = 0;
        slots[1].kind = SlotKind::SampledTexture; slots[1].slot = 0;
        slots[2].kind = SlotKind::SampledTexture; slots[2].slot = 1;
        slots[3].kind = SlotKind::Sampler; slots[3].slot = 0;
        for (SlotLayout &s : slots) s.vertexStage = false;   // fragment only (as the Metal code bound them)
        RenderDesc rd;
        rd.vertex.name = "bk_display_vertex";
        rd.fragment.name = "bk_display_fragment";
        rd.color[0].format = target;
        rd.color[0].straightOverKeepAlpha = blended;
        rd.slots = slots;
        rd.slotCount = 4;
        rd.label = "bk_display";
        Status s = Status::Ok;
        pipeline = m.device.makeRender(rd, &s);
        if (!pipeline) return s;
    }
    Binding b[4];
    b[0].kind = SlotKind::StorageBuffer; b[0].slot = 0; b[0].bytes = &params; b[0].byteCount = sizeof params;
    b[1].kind = SlotKind::SampledTexture; b[1].slot = 0; b[1].texture = &image;
    b[2].kind = SlotKind::SampledTexture; b[2].slot = 1; b[2].texture = &lut;
    b[3].kind = SlotKind::Sampler; b[3].slot = 0; b[3].sampler = m.sampler.get();
    return list.draw(*pipeline, b, 4, 3);
}

}  // namespace display
}  // namespace boroskit
