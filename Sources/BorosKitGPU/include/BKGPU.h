// BorosKitGPU: BKGPU.h - the small, backend-neutral GPU interface of BorosKit (C++17).
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (Vulkan engine kickoff, step M5; design:
// VULKAN-ENGINE-KICKOFF.md section 2.2, refining VULKAN-PORT-PLAN.md section 6).
// Implemented by: VulkanDevice (Sources/BorosKitGPUVulkan, CMake only, milestone 1, 2026-11-26) and MetalDevice
// (BKGPUMetal.mm in this target, SwiftPM, phase 2, 2026-11-26). First module on it: the mesh renderer
// (BorosKitMeshRender/include/BKMeshPass.h). Compute pipelines are declared but not implemented yet (phase 4).
//
// PORTING NOTES (read first):
//   - Plain C++17 + <cstdint> / <memory>. No Apple, Metal, Objective-C or Vulkan types or headers, so the
//     BorosKit "passes" (MeshPass, SurfacePass, RaycastPass ... written once, phase 2) compile everywhere.
//     The backends live elsewhere: MetalDevice (Objective-C++ .mm, Apple) and VulkanDevice (C++, Vulkan
//     loader only, CMake build only - never in Package.swift, never in Boros 6).
//   - Errors are Status codes (no exceptions), so C, C++ and Objective-C callers can all use them.
//   - Metal is the reference. Every rule below is chosen so that Metal and Vulkan give the same pictures:
//       * Clip space: +y UP, depth 0..1 (Metal's convention). The Vulkan backend flips with a negative
//         viewport height (core since Vulkan 1.1), so shaders and BKMeshUniforms stay identical.
//       * Front face = counter-clockwise with y up (BKMeshDrawCore.h). Vulkan: VK_FRONT_FACE_COUNTER_CLOCKWISE
//         together with the flipped viewport.
//       * No vertex-input layouts: vertex shaders read their vertices from storage buffers by vertex index
//         (what the Metal shaders already do with packed floats), so no attribute format can differ.
//       * Workgroup sizes are fixed when a compute pipeline is created (ComputeDesc::workgroup): Vulkan
//         needs that (specialization constants); the Metal backend simply uses the same numbers
//         (readiness audit finding 7).
//       * The screen image is never written by a compute kernel (finding 5): compute writes a Storage
//         texture, a draw copies it into the Surface image.
//       * Barriers / image layouts are automatic: SlotLayout::writes tells the backend which resources a
//         pipeline writes; the Vulkan backend tracks each resource's last use and inserts the barrier
//         itself (Metal tracks hazards on its own). BorosKit uses few resources per frame, so this is cheap.
//       * Bindings are numbered slots per kind. Metal: buffer(n) / texture(n) / sampler(n). Vulkan:
//         descriptor set 0, binding = kind base + n: buffers 0-15, sampled textures 16-31, storage
//         images 32-39, samplers 40-47 (kSlotBase below). One descriptor set per draw / dispatch from a
//         per-frame pool.
//       * Small constants (Binding::bytes, at most kMaxInlineBytes) go to a per-frame upload ring
//         (Vulkan) / setBytes (Metal); blocks of at most 128 bytes may become push constants.
//       * Optional GPU features are reported in Limits; a pass checks them and refuses with
//         Status::Unsupported (and a log line) instead of drawing something wrong. Manual filtering in
//         the shaders exists for the filter features (VULKAN-PORT-PLAN.md section 4).
//   - Memory (Vulkan): BorosKit's own small sub-allocator (big blocks per memory type, simple free list);
//     no third-party allocator. Uploads go through staging, or straight into device-local + host-visible
//     memory where offered. Function loading: our own loader (dlopen / LoadLibrary + vkGetInstanceProcAddr).
//   - Not covered yet (on purpose; added when a pass needs it): mipmaps, MSAA, texture arrays, indirect draws,
//     multiple queues. Subgroup operations stay out of the shared kernels (VULKAN-PORT-PLAN.md rule 3).
//
// Plain language: this file lists what BorosKit asks of ANY graphics card - "make a picture of this size",
// "run this program on these buffers", "draw these triangles", "give me the result back" - without saying
// how Metal or Vulkan does it. Each engine then fills in the how.

#ifndef BK_GPU_H
#define BK_GPU_H

// C++ only. The guard keeps this header harmless inside the SwiftPM module, which C / Objective-C files may see.
#ifdef __cplusplus

#include <cstdint>
#include <memory>

namespace boroskit {
namespace gpu {

// ---- Results -----------------------------------------------------------------------------------------------
enum class Status : int32_t {
    Ok = 0,
    OutOfMemory,        // a buffer / texture / pool could not be allocated
    Unsupported,        // the GPU lacks a feature this request needs (see Limits)
    DeviceLost,         // the GPU stopped (driver reset, unplugged); the Device must be recreated
    InvalidArgument,    // a size of 0, a slot out of range, a missing shader ...
    CompileFailed,      // a shader did not compile / link into a pipeline
    NotFound,           // no GPU at all, or the shader name is unknown
};

// ---- Formats, memory, usage ----------------------------------------------------------------------------------
enum class Format : uint32_t {
    R8Unorm, R16Unorm, R32Float, R32Uint,
    RGBA8Unorm, BGRA8Unorm,          // BGRA8 only as a Surface / render target, never as a storage image
    RGBA16Float, RGBA32Float,
    Depth32Float,                    // fallback when missing: see Limits::depth32Float
};

enum class Memory : uint32_t {
    DeviceOnly,   // GPU memory (Metal private); filled through CommandList::upload
    Upload,       // CPU writes, GPU reads (Metal shared, write-combined)
    Readback,     // GPU writes, CPU reads (Metal shared)
};

// Usage bits of a buffer or texture (combine with |).
enum Usage : uint32_t {
    UsageSampled = 1u << 0,        // read by shaders (textures: filtered or texelFetch)
    UsageStorage = 1u << 1,        // read / written by compute (storage buffer / storage image)
    UsageRenderTarget = 1u << 2,   // colour target of a render pass
    UsageCopySource = 1u << 3,
    UsageCopyDestination = 1u << 4,
    UsageDepthTarget = 1u << 5,
    UsageIndex = 1u << 6,          // 32-bit index buffer of a draw
};

// ---- What the GPU can do (filled when the Device is made; every pass checks it) -------------------------------
struct Limits {
    uint64_t maxBufferBytes = 0;            // largest single buffer
    uint64_t maxStorageBufferRange = 0;     // largest range bound as one storage buffer
    uint64_t memoryBudgetBytes = 0;         // what we may use (0 = unknown)
    uint32_t maxImage2D = 0;                // largest 2D texture side
    uint32_t maxImage3D = 0;                // largest 3D texture side (Vulkan guarantees only 256)
    uint32_t maxComputeWorkgroupInvocations = 0;
    uint32_t maxComputeWorkgroupSize[3] = { 0, 0, 0 };
    uint32_t maxComputeSharedBytes = 0;     // workgroup ("threadgroup") memory
    uint32_t maxPushConstantBytes = 0;      // Metal: setBytes limit; Vulkan: push constants (>= 128)
    uint32_t subgroupSize = 0;              // information only (not used by shared kernels)
    uint32_t vendorID = 0;                  // PCI vendor id where known (0x10DE NVIDIA, 0x1002 AMD, 0x8086 Intel, 0x106B Apple)
    bool linearFilterR16Unorm3D = false;    // 3D R16 scans with the GPU's linear filter
    bool linearFilterRGBA32Float = false;   // the colour table (RGBA32F) with linear filter
    bool linearFilterR32Float = false;      // float scans with linear filter
    bool depth32Float = false;              // Depth32Float as a depth target
    bool independentBlend = false;          // different blend per colour target (mesh pass needs it)
    bool wireframe = false;                 // triangle edges only (Vulkan: fillModeNonSolid)
    bool unifiedMemory = false;             // CPU and GPU share memory (Apple, integrated GPUs)
    bool timestamps = false;                // CommandList::timestamp works
};

// ---- Resources ---------------------------------------------------------------------------------------------
enum class TextureType : uint32_t { Texture2D, Texture3D };

struct TextureDesc {
    TextureType type = TextureType::Texture2D;
    Format format = Format::RGBA8Unorm;
    uint32_t width = 1, height = 1, depth = 1;   // depth > 1 only for Texture3D
    uint32_t usage = UsageSampled;              // Usage bits
    const char *label = nullptr;                // for debuggers / validation messages
};

struct SamplerDesc {           // never mipmapped (BorosKit draws at 1:1 or reads exact texels)
    bool linear = false;       // false = nearest
    bool repeat = false;       // false = clamp to the edge texel
    bool normalizedCoordinates = true;
};

class Buffer {
public:
    virtual ~Buffer() = default;
    virtual uint64_t size() const = 0;
    virtual void *map() = 0;          // Upload / Readback memory only (nullptr otherwise)
    virtual void unmap() = 0;
};

class Texture {
public:
    virtual ~Texture() = default;
    virtual const TextureDesc &desc() const = 0;
};

class Sampler {
public:
    virtual ~Sampler() = default;
};

// ---- Pipelines -----------------------------------------------------------------------------------------------
// What kind of resource a slot holds.
enum class SlotKind : uint32_t { UniformBlock, StorageBuffer, SampledTexture, StorageImage, Sampler };

// Vulkan binding number of slot n of each kind: kSlotBase[kind] + n (see PORTING NOTES).
constexpr uint32_t kSlotBase[5] = { 0, 0, 16, 32, 40 };   // UniformBlock and StorageBuffer share 0-15
constexpr uint32_t kMaxSlotsPerKind[5] = { 16, 16, 16, 8, 8 };

struct SlotLayout {
    SlotKind kind = SlotKind::StorageBuffer;
    uint32_t slot = 0;
    bool writes = false;            // the pipeline writes it (drives automatic barriers)
    bool vertexStage = true;        // render pipelines: seen by the vertex shader
    bool fragmentStage = true;      // render pipelines: seen by the fragment shader
};

// Shaders are looked up by name in the module's shader table (Vulkan: SPIR-V embedded at build time;
// Metal: the library compiled from the module's MSL source).
struct ShaderRef { const char *name = nullptr; };

struct ComputeDesc {
    ShaderRef kernel;
    uint32_t workgroup[3] = { 1, 1, 1 };   // fixed here (Vulkan specialization constants)
    const SlotLayout *slots = nullptr;
    uint32_t slotCount = 0;
    const char *label = nullptr;
};

enum class CullMode : uint32_t { None, Back, Front };
enum class DepthCompare : uint32_t { Always, Less, LessOrEqual };

struct ColorTarget {
    Format format = Format::RGBA8Unorm;
    bool writeEnabled = true;          // false = depth-only pass (see-through meshes, 2026-11-25)
    bool premultipliedOver = false;    // blend: one, one-minus-source-alpha (premultiplied "over")
};

struct RenderDesc {
    ShaderRef vertex, fragment;
    ColorTarget color[2];
    uint32_t colorCount = 1;
    bool hasDepth = false;
    Format depthFormat = Format::Depth32Float;
    DepthCompare depthCompare = DepthCompare::Less;
    bool depthWrite = true;
    CullMode cull = CullMode::None;    // front face: counter-clockwise with y up (Metal: set per draw from the pipeline)
    bool wireframe = false;            // needs Limits::wireframe
    bool invariantPosition = false;    // vertex position bit-identical across pipelines (two-pass see-through)
    const SlotLayout *slots = nullptr;
    uint32_t slotCount = 0;
    const char *label = nullptr;
};

class ComputePipeline {
public:
    virtual ~ComputePipeline() = default;
};

class RenderPipeline {
public:
    virtual ~RenderPipeline() = default;
};

// ---- Recording work ------------------------------------------------------------------------------------------
constexpr uint32_t kMaxInlineBytes = 4096;   // largest Binding::bytes block

// One resource for one slot of a dispatch / draw. Exactly one of buffer / texture / sampler / bytes is set,
// matching `kind`.
struct Binding {
    SlotKind kind = SlotKind::StorageBuffer;
    uint32_t slot = 0;
    Buffer *buffer = nullptr;
    uint64_t offset = 0;              // into buffer
    Texture *texture = nullptr;
    Sampler *sampler = nullptr;
    const void *bytes = nullptr;      // small constants, copied when recorded (<= kMaxInlineBytes)
    uint32_t byteCount = 0;
};

struct PassTargets {
    Texture *color[2] = { nullptr, nullptr };
    uint32_t colorCount = 1;
    Texture *depth = nullptr;
    bool clearColor[2] = { true, true };          // false = keep what is there (load)
    float clearValue[2][4] = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 } };   // +infinity allowed (ray distance)
    float clearDepth = 1.0f;
    int32_t viewport[4] = { 0, 0, 0, 0 };         // x, y, width, height in pixels, top-left origin; 0 size = whole target
};

class CommandList {
public:
    virtual ~CommandList() = default;
    // Copies (outside a render pass). Staging is done inside the backend.
    virtual Status upload(Texture &texture, const void *data, uint32_t rowBytes, uint32_t sliceBytes,
                          uint32_t firstSlice, uint32_t sliceCount) = 0;
    virtual Status upload(Buffer &buffer, uint64_t offset, const void *data, uint64_t bytes) = 0;
    virtual Status readback(Texture &texture, Buffer &destination) = 0;   // rows tightly packed; 3D: slice after slice
    virtual Status copy(Buffer &source, uint64_t sourceOffset, Buffer &destination, uint64_t destinationOffset,
                        uint64_t bytes) = 0;
    // Compute (outside a render pass): groups x, y, z of the pipeline's fixed workgroup size.
    virtual Status dispatch(ComputePipeline &pipeline, const Binding *bindings, uint32_t bindingCount,
                            uint32_t groupsX, uint32_t groupsY, uint32_t groupsZ) = 0;
    // Drawing: one pass, any number of draws, then endPass.
    virtual Status beginPass(const PassTargets &targets) = 0;
    virtual void setScissor(int32_t x, int32_t y, int32_t width, int32_t height) = 0;   // pixels, top-left origin
    virtual Status draw(RenderPipeline &pipeline, const Binding *bindings, uint32_t bindingCount,
                        uint32_t vertexCount, uint32_t firstVertex = 0,
                        Buffer *indices = nullptr, uint32_t indexCount = 0) = 0;   // triangle lists only
    virtual void endPass() = 0;
    // GPU time stamp `index` (adaptive quality); ignored when Limits::timestamps is false.
    virtual void timestamp(uint32_t index) = 0;
};

// ---- The device ------------------------------------------------------------------------------------------------
class Device {
public:
    virtual ~Device() = default;
    virtual const Limits &limits() const = 0;
    virtual const char *name() const = 0;   // what the user sees in the GPU choice (BKGPUChoiceCore)
    virtual std::unique_ptr<Buffer> makeBuffer(uint64_t bytes, Memory memory, uint32_t usage, Status *status) = 0;
    virtual std::unique_ptr<Texture> makeTexture(const TextureDesc &desc, Status *status) = 0;
    virtual std::unique_ptr<Sampler> makeSampler(const SamplerDesc &desc, Status *status) = 0;
    virtual std::unique_ptr<ComputePipeline> makeCompute(const ComputeDesc &desc, Status *status) = 0;
    virtual std::unique_ptr<RenderPipeline> makeRender(const RenderDesc &desc, Status *status) = 0;
    virtual std::unique_ptr<CommandList> begin(Status *status) = 0;
    // Sends the work. wait = true returns when the GPU has finished; otherwise `done` (optional) is called
    // from a backend thread when it has.
    virtual Status submit(CommandList &work, bool wait, void (*done)(void *context, Status status) = nullptr,
                          void *context = nullptr) = 0;
};

// ---- Presentation (only on-screen views need it) ---------------------------------------------------------------
class Surface {
public:
    virtual ~Surface() = default;
    virtual Status resize(uint32_t width, uint32_t height) = 0;
    virtual Texture *acquire(Status *status) = 0;   // RenderTarget | CopyDestination image; never written by compute
    virtual Status present(CommandList &work) = 0;
};

// ---- Making a device (implemented by the backends, later) -----------------------------------------------------
// Metal (Objective-C++ file, Apple only): wraps an existing id<MTLDevice> passed as void*.
Status makeMetalDevice(void *metalDevice, std::unique_ptr<Device> *out);
// Vulkan (CMake build only): picks the GPU by name through BKGPUChoiceCore (nullptr / "" = automatic).
Status makeVulkanDevice(const char *preferredName, std::unique_ptr<Device> *out);

}  // namespace gpu
}  // namespace boroskit

#endif  // __cplusplus
#endif  // BK_GPU_H
