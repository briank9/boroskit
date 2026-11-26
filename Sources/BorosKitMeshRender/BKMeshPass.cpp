// BorosKitMeshRender: BKMeshPass - see include/BKMeshPass.h.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan phase 2). The steps and their order are those of
// -[BKMeshRenderer encodeRenderToColorTexture:...] before this date; comments name the dated decisions they keep.

#include "BKMeshPass.h"
#include "BKMeshShaderTypes.h"
#include <algorithm>
#include <cmath>
#include <cstring>

namespace boroskit {
namespace meshpass {

using namespace gpu;

namespace {

// Pipeline shapes and depth modes (see pipeline()).
enum Shape : int32_t { ShapeMesh = 0, ShapeMeshTextured = 1, ShapeLines = 2, ShapePoints = 3, ShapeMeshDepthOnly = 4 };
enum DepthMode : int32_t {
    DepthSolid = 0,     // LESS + write: solid objects, and the depth-only pass of a see-through mesh
    DepthSeeThrough = 1,// LESS, no write: see-through lines / points / textured meshes
    DepthNearest = 2,   // LESS_OR_EQUAL, no write: colour pass of an untextured see-through mesh (2026-11-25)
};

}  // namespace

MeshPass::MeshPass(Device &device) : device_(device)
{
    // 2026-11-14: texture samplers (BKMeshTextureSample's rules): linear or nearest, repeat or clamp to the edge,
    // no mipmaps. Index = (interpolate ? 2 : 0) + (repeat ? 1 : 0).
    for (int i = 0; i < 4; i++) {
        SamplerDesc sd;
        sd.linear = (i & 2) != 0;
        sd.repeat = (i & 1) != 0;
        sd.normalizedCoordinates = true;
        samplers_[i] = device_.makeSampler(sd, nullptr);
    }
}

// What: the depth buffer, kept while the size stays the same (creating it every frame would waste bandwidth).
Texture *MeshPass::depthTarget(uint32_t width, uint32_t height)
{
    if (depth_ && depth_->desc().width == width && depth_->desc().height == height) return depth_.get();
    TextureDesc d;
    d.format = Format::Depth32Float;
    d.width = width;
    d.height = height;
    d.usage = UsageDepthTarget;
    d.label = "BKMeshPass depth";
    depth_ = device_.makeTexture(d, nullptr);
    return depth_.get();
}

// What: the pipeline for one shape / depth mode / cull / fill / target format, made once and cached.
// The colour state is BKMeshRenderer's configurePipeline: target 0 premultiplied "over" (always enabled), target 1
// (ray distance, R32Float) written by solid objects only; Depth32Float.
RenderPipeline *MeshPass::pipeline(int32_t shape, int32_t depthMode, CullMode cull, bool wireframe, Format color, bool withDistance)
{
    std::string key = std::to_string(shape) + "-" + std::to_string(depthMode) + "-" + std::to_string((int)cull) + "-" +
                      std::to_string(wireframe) + "-" + std::to_string((int)color) + "-" + std::to_string(withDistance);
    auto found = pipelines_.find(key);
    if (found != pipelines_.end()) return found->second.get();

    bool transparent = depthMode != DepthSolid || shape == ShapeMeshDepthOnly;
    RenderDesc d;
    switch (shape) {
        case ShapeMeshTextured:
            d.vertex.name = "bk_mesh_vertex_textured";
            d.fragment.name = withDistance ? "bk_mesh_fragment_distance_textured" : "bk_mesh_fragment_textured";
            break;
        case ShapeLines:
        case ShapePoints:
            d.vertex.name = shape == ShapeLines ? "bk_line_vertex" : "bk_point_vertex";
            d.fragment.name = withDistance ? "bk_line_fragment_distance" : "bk_line_fragment";
            break;
        default:   // ShapeMesh, ShapeMeshDepthOnly (same vertex function: identical depths, [[invariant]])
            d.vertex.name = "bk_mesh_vertex";
            d.fragment.name = withDistance ? "bk_mesh_fragment_distance" : "bk_mesh_fragment";
            break;
    }
    d.color[0].format = color;
    d.color[0].premultipliedOver = true;
    d.color[0].writeEnabled = shape != ShapeMeshDepthOnly;
    d.colorCount = 1;
    if (withDistance) {
        d.color[1].format = Format::R32Float;
        d.color[1].premultipliedOver = false;
        // See-through surfaces must not count as "the surface that stops the ray".
        d.color[1].writeEnabled = !transparent;
        d.colorCount = 2;
    }
    d.hasDepth = true;
    d.depthFormat = Format::Depth32Float;
    d.depthCompare = depthMode == DepthNearest ? DepthCompare::LessOrEqual : DepthCompare::Less;
    d.depthWrite = depthMode == DepthSolid;
    d.cull = cull;
    d.wireframe = wireframe;
    d.invariantPosition = true;
    SlotLayout slots[5] = {
        { SlotKind::StorageBuffer, 0, false, true, false },   // vertices / points
        { SlotKind::UniformBlock, 1, false, true, true },     // BKMeshUniforms
        { SlotKind::StorageBuffer, 2, false, true, false },   // texture coordinates
        { SlotKind::SampledTexture, 0, false, false, true },
        { SlotKind::Sampler, 0, false, false, true },
    };
    d.slots = slots;
    d.slotCount = shape == ShapeMeshTextured ? 5 : 2;
    d.label = "BKMeshPass";
    std::unique_ptr<RenderPipeline> p = device_.makeRender(d, nullptr);
    RenderPipeline *raw = p.get();
    if (p) pipelines_[key] = std::move(p);
    return raw;
}

int32_t MeshPass::encode(CommandList &list, const Frame &frame, const Item *items, size_t count)
{
    const TextureDesc &target = frame.color->desc();
    bool withDistance = frame.distance != nullptr;
    int32_t ax = frame.area[0], ay = frame.area[1], aw = frame.area[2], ah = frame.area[3];
    if (aw <= 0 || ah <= 0) { ax = 0; ay = 0; aw = (int32_t)target.width; ah = (int32_t)target.height; }

    BKVec3d right, up, forward;
    int32_t cameraStatus = BKMeshCameraAxes(&frame.camera, &right, &up, &forward);
    if (cameraStatus == BKMeshCameraZeroDirection) return ZeroDirection;
    if (cameraStatus == BKMeshCameraUpParallel) return UpParallel;
    // The GPU floats the renderer always used for the depth extent (camera position and forward rounded once).
    BKVec3f cameraF = BKV3f((float)frame.camera.position.x, (float)frame.camera.position.y, (float)frame.camera.position.z);
    BKVec3f forwardF = BKV3f((float)forward.x, (float)forward.y, (float)forward.z);
    bool perspective = frame.camera.projection == 1;

    // 1. Groups with their depth extent: solid meshes, solid lines + points, everything see-through.
    struct Entry { const Item *item; float sortDistance; };
    std::vector<Entry> opaque, opaqueLines, transparent;
    float nearest = INFINITY, farthest = -INFINITY;
    for (size_t i = 0; i < count; i++) {
        const Item &it = items[i];
        float sortDistance = BKMeshBoxDepthExtent(it.boundsMin, it.boundsMax, cameraF, forwardF, &nearest, &farthest);
        Entry e = { &it, sortDistance };
        if (it.kind == ItemKind::Mesh) (it.solid ? opaque : transparent).push_back(e);
        else (it.solid ? opaqueLines : transparent).push_back(e);
    }
    // See-through objects: farthest first, so nearer ones are blended over farther ones (stable: equal distances
    // keep their order).
    std::stable_sort(transparent.begin(), transparent.end(), [](const Entry &a, const Entry &b) { return a.sortDistance > b.sortDistance; });

    // 2. Depth range: just enclose the scene (BKMeshDepthRange, 2026-11-25 M3).
    float nearDistance, farDistance;
    BKMeshDepthRange(nearest, farthest, perspective ? 1 : 0, &nearDistance, &farDistance);
    bool anything = (opaque.size() + opaqueLines.size() + transparent.size()) > 0 && std::isfinite(nearDistance) &&
                    std::isfinite(farDistance) && farDistance > nearDistance;

    // The pipelines every frame needs (as before: made up front, so a failure is reported before drawing).
    Format colorFormat = target.format;
    if (!pipeline(ShapeMesh, DepthSolid, CullMode::None, false, colorFormat, withDistance) ||
        !pipeline(ShapeMesh, DepthNearest, CullMode::None, false, colorFormat, withDistance) ||
        !pipeline(ShapeLines, DepthSolid, CullMode::None, false, colorFormat, withDistance) ||
        !pipeline(ShapeLines, DepthSeeThrough, CullMode::None, false, colorFormat, withDistance) ||
        !pipeline(ShapeMeshDepthOnly, DepthSolid, CullMode::None, false, colorFormat, withDistance))
        return PipelineFailed;
    Texture *depth = depthTarget(target.width, target.height);
    if (!depth) return NoDepthTarget;

    // 3. The render pass: colour (+ ray distance, cleared to +infinity) + depth (cleared to 1, not kept).
    PassTargets pass;
    pass.color[0] = frame.color;
    pass.clearColor[0] = frame.clear != 0;
    for (int k = 0; k < 4; k++) pass.clearValue[0][k] = frame.clearColor[k];
    pass.colorCount = 1;
    if (withDistance) {
        pass.color[1] = frame.distance;
        pass.clearColor[1] = true;
        pass.clearValue[1][0] = INFINITY;
        pass.clearValue[1][1] = pass.clearValue[1][2] = pass.clearValue[1][3] = 0;
        pass.colorCount = 2;
    }
    pass.depth = depth;
    pass.clearDepth = 1.0f;
    pass.viewport[0] = ax; pass.viewport[1] = ay; pass.viewport[2] = aw; pass.viewport[3] = ah;
    if (list.beginPass(pass) != Status::Ok) return NoEncoder;
    if (!anything) { list.endPass(); return Ok; }

    // Shared camera part of the uniforms (BKMeshUniformsFill, 2026-11-25 M3).
    BKMeshUniforms base;
    int32_t status = BKMeshUniformsFill(&base, &frame.camera, (float)aw, (float)ah, nearDistance, farDistance, frame.lighting);
    if (status != BKMeshCameraOK) {
        list.endPass();
        return status == BKMeshCameraZeroDirection ? ZeroDirection : status == BKMeshCameraUpParallel ? UpParallel : ZeroFieldOfView;
    }

    const std::vector<Entry> *groups[3] = { &opaque, &opaqueLines, &transparent };
    for (int g = 0; g < 3; g++) {
        bool see = (g == 2);
        for (const Entry &e : *groups[g]) {
            const Item &it = *e.item;
            BKMeshUniforms u = base;
            Binding b[5];
            b[0].kind = SlotKind::StorageBuffer; b[0].slot = 0; b[0].buffer = it.vertices;
            b[1].kind = SlotKind::UniformBlock; b[1].slot = 1; b[1].bytes = &u; b[1].byteCount = sizeof u;
            if (it.kind != ItemKind::Mesh) {
                // 2026-11-14: lines (rectangles, 6 vertices per segment) and points (squares, 6 per point): flat colour,
                // never culled, filled (2026-11-21), identity normal matrix.
                BKMeshUniformsSetModel(&u, it.model, 0);
                BKMeshUniformsSetColor(&u, it.color[0], it.color[1], it.color[2], it.opacity);
                u.lit = 0;
                u.lineHalfWidth = it.lineHalfWidth;
                RenderPipeline *p = pipeline(it.kind == ItemKind::Lines ? ShapeLines : ShapePoints, see ? DepthSeeThrough : DepthSolid,
                                             CullMode::None, false, colorFormat, withDistance);
                if (!p) { list.endPass(); return PipelineFailed; }
                list.draw(*p, b, 2, it.vertexCount);
                continue;
            }
            // Meshes: per-object culling and wireframe (2026-11-14 / 11-21), optional texture (2026-11-14).
            bool textured = it.textureCoordinates && it.texture;
            uint32_t bindingCount = 2;
            if (textured) {
                b[2].kind = SlotKind::StorageBuffer; b[2].slot = 2; b[2].buffer = it.textureCoordinates;
                b[3].kind = SlotKind::SampledTexture; b[3].slot = 0; b[3].texture = it.texture;
                b[4].kind = SlotKind::Sampler; b[4].slot = 0; b[4].sampler = samplers_[it.samplerIndex & 3].get();
                bindingCount = 5;
            }
            BKMeshUniformsSetModel(&u, it.model, 1);
            BKMeshUniformsSetColor(&u, it.color[0], it.color[1], it.color[2], it.opacity);
            u.useVertexColors = it.useVertexColors;
            u.hasNormals = it.hasNormals;
            u.lit = it.lit;
            if (it.ownMaterial) {
                u.ambient = it.material.ambient;
                u.diffuse = it.material.diffuse;
                u.specular = it.material.specular;
                u.specularPower = it.material.specularPower;
            }
            // SEE-THROUGH MESHES (2026-11-25): first a depth-only pass that keeps this mesh's NEAREST surface in each
            // pixel, then the colour pass drawn only there (LESS_OR_EQUAL, no depth write): one clean layer whatever
            // order the triangles are stored in. Textured meshes keep the single pass (see-through texels must not
            // hide what is behind them).
            bool twoPass = see && !textured;
            if (twoPass) {
                RenderPipeline *dp = pipeline(ShapeMeshDepthOnly, DepthSolid, it.cull, it.wireframe != 0, colorFormat, withDistance);
                if (!dp) { list.endPass(); return PipelineFailed; }
                list.draw(*dp, b, bindingCount, 0, 0, it.indices, it.indexCount);
            }
            int32_t mode = !see ? DepthSolid : (twoPass ? DepthNearest : DepthSeeThrough);
            RenderPipeline *p = pipeline(textured ? ShapeMeshTextured : ShapeMesh, mode, it.cull, it.wireframe != 0, colorFormat, withDistance);
            if (!p) { list.endPass(); return PipelineFailed; }
            list.draw(*p, b, bindingCount, 0, 0, it.indices, it.indexCount);
        }
    }
    list.endPass();
    return Ok;
}

}  // namespace meshpass
}  // namespace boroskit
