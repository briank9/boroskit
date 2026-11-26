// BorosKitMeshRender: BKMeshPass - drawing meshes, lines and points, written ONCE for every GPU backend (C++17).
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan phase 2: "Objective-C classes become wrappers over
// passes"). The logic is BKMeshRenderer's drawing code (2026-11-13 .. 11-25), moved here operation for operation.
//
// PORTING NOTES:
//   - Backend-neutral: uses only BKGPU.h (boroskit::gpu) and the plain-C cores (BKMeshDrawCore, BKMeshShaderTypes).
//     BKMeshRenderer (Objective-C, Metal) is now a thin wrapper that turns its objects into MeshPassItems (wrapping
//     the Metal buffers / textures it already caches) and calls encode on a MetalDevice. A Windows / Linux program
//     calls the same encode on a VulkanDevice. Metal output is unchanged (golden strict 0).
//   - Shaders by name (Metal: BKMeshShaderSource library, added to the device by the caller; Vulkan: embedded
//     SPIR-V): bk_mesh_vertex / bk_mesh_vertex_textured, bk_mesh_fragment[_distance][_textured], bk_line_vertex,
//     bk_point_vertex, bk_line_fragment[_distance]. Pipelines are made the first time a kind of object is drawn.
//   - Slots: storage buffer 0 = vertices (BKMeshGPUVertex / packed float x3 for lines and points), uniform block 1 =
//     BKMeshUniforms (vertex + fragment), storage buffer 2 = texture coordinates, sampled texture 0 + sampler 0.
//   - Order: solid meshes, then solid lines and points, then everything see-through farthest first (stable sort by
//     the box-centre distance). An untextured see-through mesh is drawn twice: depth-only (LESS + write), then colour
//     with LESS_OR_EQUAL and no depth write (one clean layer). Target 1 (ray distance) is written by solid objects only.
//   - Only C++ inside (whole file guarded): it sits in a module that C / Objective-C files also see.
//
// Plain language: the recipe for drawing 3D surfaces, lines and points - which object first, which settings, which
// GPU program - kept in one place so the Mac engine and the Windows / Linux engine draw the same picture.

#ifndef BK_MESH_PASS_H
#define BK_MESH_PASS_H

#ifdef __cplusplus

#include "BKGPU.h"
#include "BKMeshDrawCore.h"
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace boroskit {
namespace meshpass {

enum class ItemKind : int32_t { Mesh = 0, Lines = 1, Points = 2 };

// One thing to draw (already filtered: visible, opacity > 0, size > 0, uploaded). Buffers are borrowed.
struct Item {
    ItemKind kind = ItemKind::Mesh;
    gpu::Buffer *vertices = nullptr;          // mesh: BKMeshGPUVertex[]; lines / points: packed float x3
    gpu::Buffer *indices = nullptr;           // mesh: uint32 x 3 per triangle
    uint32_t indexCount = 0;                  // mesh: triangles * 3
    uint32_t vertexCount = 0;                 // lines: segments * 6; points: points * 6
    gpu::Buffer *textureCoordinates = nullptr;// textured mesh: packed float x2 (nullptr = untextured)
    gpu::Texture *texture = nullptr;          // textured mesh: RGBA8
    int32_t samplerIndex = 0;                 // (interpolate ? 2 : 0) + (repeat ? 1 : 0)
    float model[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };   // placement, column-major
    float color[3] = { 1, 1, 1 };
    float opacity = 1;
    int32_t useVertexColors = 0;              // mesh: object asks for them AND the mesh has colours
    int32_t hasNormals = 0;
    int32_t lit = 1;
    int32_t ownMaterial = 0;                  // 1 = `material` replaces the pass lighting
    BKMeshLighting material = { 0.2f, 0.8f, 0.2f, 10.0f };
    gpu::CullMode cull = gpu::CullMode::None;
    int32_t wireframe = 0;
    float lineHalfWidth = 0;                  // lines: half the width; points: half the size (pixels)
    BKVec3f boundsMin = { 0, 0, 0 }, boundsMax = { 0, 0, 0 };   // patient mm (placed), for the depth range / order
    int32_t solid = 1;                        // mesh: opacity >= 1 and no see-through texels; lines / points: opacity >= 1
};

// One picture.
struct Frame {
    BKMeshCamera camera;
    BKMeshLighting lighting = { 0.2f, 0.8f, 0.2f, 10.0f };
    gpu::Texture *color = nullptr;            // RGBA8 / BGRA8 target
    gpu::Texture *distance = nullptr;         // optional R32Float ray-distance target (same size)
    int32_t clear = 1;
    float clearColor[4] = { 0, 0, 0, 0 };
    int32_t area[4] = { 0, 0, 0, 0 };         // drawing area x, y, w, h in pixels (top-left origin); 0 size = whole target
};

// Results: 0 = drawn; otherwise BKMeshRenderer's error codes (so its messages stay the same).
enum Result : int32_t {
    Ok = 0,
    ZeroDirection = 31, UpParallel = 32, NoEncoder = 35, ZeroFieldOfView = 36, PipelineFailed = 41, NoDepthTarget = 42,
};

class MeshPass {
public:
    // `device` must outlive the pass. Makes the four texture samplers (BKMeshTextureSample's rules).
    explicit MeshPass(gpu::Device &device);
    bool valid() const { return samplers_[3] != nullptr; }

    // What: records the picture into `list` (one render pass). Objects in `items` order within each group.
    int32_t encode(gpu::CommandList &list, const Frame &frame, const Item *items, size_t count);

private:
    struct PipelineKey;
    gpu::RenderPipeline *pipeline(int32_t shape, int32_t depthMode, gpu::CullMode cull, bool wireframe, gpu::Format color,
                                  bool withDistance);
    gpu::Texture *depthTarget(uint32_t width, uint32_t height);

    gpu::Device &device_;
    std::unique_ptr<gpu::Sampler> samplers_[4];
    std::unique_ptr<gpu::Texture> depth_;
    std::map<std::string, std::unique_ptr<gpu::RenderPipeline>> pipelines_;
};

}  // namespace meshpass
}  // namespace boroskit

#endif  // __cplusplus
#endif  // BK_MESH_PASS_H
