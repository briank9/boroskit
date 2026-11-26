// BorosKitDisplay: BKOverlayPass.cpp - see BKOverlayPass.h.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 #6): the per-command logic of BKOverlayRenderer.mm
// moved one-to-one (same scissor rule, params, image choice, sampler choice, draw ranges), so the Metal pictures stay
// bit-identical.

#include "BKOverlayPass.h"

#include <algorithm>
#include <cstring>
#include <map>

namespace boroskit {
namespace display {

using namespace boroskit::gpu;

struct OverlayPass::Impl {
    Device &device;
    std::map<int, std::unique_ptr<RenderPipeline>> pipelines;   // key: target format
    std::unique_ptr<Sampler> nearest, linear;
    std::unique_ptr<Texture> white;
    explicit Impl(Device &d) : device(d) {}
};

OverlayPass::OverlayPass(Device &device) : impl_(new Impl(device)) {}
OverlayPass::~OverlayPass() = default;

Status OverlayPass::prepare()
{
    Impl &m = *impl_;
    if (m.white) return Status::Ok;
    SamplerDesc sd;
    m.nearest = m.device.makeSampler(sd, nullptr);
    sd.linear = true;
    m.linear = m.device.makeSampler(sd, nullptr);
    TextureDesc td;
    td.format = Format::RGBA8Unorm;
    td.usage = UsageSampled | UsageCopyDestination;
    td.label = "overlay white";
    std::unique_ptr<Texture> white = m.device.makeTexture(td, nullptr);
    const uint8_t w[4] = { 255, 255, 255, 255 };
    std::unique_ptr<CommandList> list = white ? m.device.begin(nullptr) : nullptr;
    if (!m.nearest || !m.linear || !list || list->upload(*white, w, 4, 4, 0, 1) != Status::Ok || m.device.submit(*list, true) != Status::Ok)
        return Status::OutOfMemory;
    m.white = std::move(white);
    return Status::Ok;
}

std::unique_ptr<Buffer> OverlayPass::makeVertices(const BKOverlayList *list, Status *status)
{
    uint32_t n = 0;
    const BKOverlayVertex *v = BKOverlayListVertices(list, &n);
    std::unique_ptr<Buffer> b = impl_->device.makeBuffer((uint64_t)sizeof(BKOverlayVertex) * (n ? n : 1), Memory::Upload, UsageStorage, status);
    void *mapped = b ? b->map() : nullptr;
    if (!mapped) return nullptr;
    if (n) std::memcpy(mapped, v, sizeof(BKOverlayVertex) * n);
    b->unmap();
    return b;
}

Status OverlayPass::makeImages(const BKOverlayList *list, CommandList &uploads, std::vector<std::unique_ptr<Texture>> *images)
{
    uint32_t ni = 0;
    const BKOverlayImage *im = BKOverlayListImages(list, &ni);
    images->clear();
    for (uint32_t i = 0; i < ni; i++) {
        TextureDesc td;
        bool mask = im[i].kind == BKOverlayImageAlpha8;
        td.format = mask ? Format::R8Unorm : Format::RGBA8Unorm;
        td.width = im[i].width;
        td.height = im[i].height;
        td.usage = UsageSampled | UsageCopyDestination;
        std::unique_ptr<Texture> t = impl_->device.makeTexture(td, nullptr);
        if (!t) return Status::OutOfMemory;
        uint32_t row = im[i].width * (mask ? 1 : 4);
        Status s = uploads.upload(*t, im[i].pixels, row, row * im[i].height, 0, 1);
        if (s != Status::Ok) return s;
        images->push_back(std::move(t));
    }
    return Status::Ok;
}

Status OverlayPass::encode(CommandList &list, const BKOverlayList *overlay, Buffer &vertices, Texture *const *images,
                           uint32_t imageCount, Format target, uint32_t width, uint32_t height)
{
    Impl &m = *impl_;
    if (!m.white) return Status::InvalidArgument;
    uint32_t nv = 0, nc = 0, ni = 0;
    BKOverlayListVertices(overlay, &nv);
    const BKOverlayCommand *c = BKOverlayListCommands(overlay, &nc);
    const BKOverlayImage *im = BKOverlayListImages(overlay, &ni);
    if (nv == 0 || nc == 0 || width == 0 || height == 0) return Status::Ok;   // nothing to draw
    std::unique_ptr<RenderPipeline> &pipeline = m.pipelines[(int)target];
    if (!pipeline) {
        SlotLayout slots[4];
        slots[0].kind = SlotKind::StorageBuffer; slots[0].slot = 0; slots[0].fragmentStage = false;
        slots[1].kind = SlotKind::StorageBuffer; slots[1].slot = 1;
        slots[2].kind = SlotKind::SampledTexture; slots[2].slot = 0; slots[2].vertexStage = false;
        slots[3].kind = SlotKind::Sampler; slots[3].slot = 0; slots[3].vertexStage = false;
        RenderDesc rd;
        rd.vertex.name = "bk_overlay_vertex";
        rd.fragment.name = "bk_overlay_fragment";
        rd.color[0].format = target;
        rd.color[0].premultipliedOver = true;   // opaque commands set alpha 1 in the shader: the same blend draws opaque
        rd.slots = slots;
        rd.slotCount = 4;
        rd.label = "bk_overlay";
        Status s = Status::Ok;
        pipeline = m.device.makeRender(rd, &s);
        if (!pipeline) return s;
    }
    for (uint32_t k = 0; k < nc; k++) {
        const BKOverlayCommand *cmd = &c[k];
        if (cmd->count == 0) continue;
        int32_t sx = 0, sy = 0, sw = (int32_t)width, sh = (int32_t)height;
        if (cmd->hasClip) {
            long x0 = std::max(0L, (long)cmd->clipX), y0 = std::max(0L, (long)cmd->clipY);
            long x1 = std::min((long)width, (long)cmd->clipX + cmd->clipW), y1 = std::min((long)height, (long)cmd->clipY + cmd->clipH);
            if (x1 <= x0 || y1 <= y0) continue;   // clipped away
            sx = (int32_t)x0; sy = (int32_t)y0; sw = (int32_t)(x1 - x0); sh = (int32_t)(y1 - y0);
        }
        list.setScissor(sx, sy, sw, sh);
        BKOverlayParams p;   // the shared GPU block (BKOverlayCore.h)
        p.viewSize = bk_make_float2((float)width, (float)height);
        p.imageSize = bk_make_float2(1, 1);
        p.mode = cmd->mode;
        p.opaque = cmd->ignoreAlpha;
        Texture *tex = m.white.get();
        if (cmd->mode != BKOverlayModeSolid && cmd->image >= 0 && (uint32_t)cmd->image < ni) {
            if ((uint32_t)cmd->image < imageCount && images[cmd->image]) tex = images[cmd->image];
            p.imageSize = bk_make_float2((float)im[cmd->image].width, (float)im[cmd->image].height);
        } else {
            p.mode = BKOverlayModeSolid;
        }
        Binding b[4];
        b[0].kind = SlotKind::StorageBuffer; b[0].slot = 0; b[0].buffer = &vertices;
        b[1].kind = SlotKind::StorageBuffer; b[1].slot = 1; b[1].bytes = &p; b[1].byteCount = sizeof p;
        b[2].kind = SlotKind::SampledTexture; b[2].slot = 0; b[2].texture = tex;
        b[3].kind = SlotKind::Sampler; b[3].slot = 0; b[3].sampler = cmd->linearFilter ? m.linear.get() : m.nearest.get();
        Status s = list.draw(*pipeline, b, 4, cmd->count, cmd->first);
        if (s != Status::Ok) return s;
    }
    list.setScissor(0, 0, (int32_t)width, (int32_t)height);
    return Status::Ok;
}

}  // namespace display
}  // namespace boroskit
