# BorosKit Vulkan engine - kickoff plan

Original BorosKit document written for this project. Written 2026-11-24 by agent "vulkan-kickoff"
on branch `agent/vulkan-kickoff` (BorosKit `29ecaec`). Builds on VULKAN-PORT-PLAN.md (the rules and
the first design), VULKAN-PREP-AUDIT-2026-11-14.md, and today's VULKAN-READINESS-AUDIT-2026-11-24.md
(the evidence; finding numbers below refer to it). STATUS 2026-11-25: M1-M5 done on agent/vulkan-engine - see VULKAN-ENGINE-PROGRESS.md.

## In plain words (for the user)

**What we are building.** One BorosKit with two engines underneath: the Metal engine we have (Mac,
iPad) and a new Vulkan engine (Windows, Linux - and, for testing only, this Mac). The maths stays
in one shared place, so both engines compute the same thing. The Metal pictures are the reference:
the Vulkan pictures, surfaces and numbers must match them within the tolerances we agreed (+-1 grey
level, a tiny share of edge pixels allowed; geometry within 1/10000 of a voxel).

**What changes in Boros 6.** Nothing you can see. Boros 6 stays a Mac app on Metal. The Vulkan
engine is for BorosCMF / a Windows-Linux version later.

**How we test it on this Mac.** Apple does not support Vulkan, but a free translator called
MoltenVK runs Vulkan programs on the Mac's own graphics chip. We use it only for testing while we
build; it is never put into Boros 6. Before release, the same tests must also run on a real
Windows or Linux PC with NVIDIA and AMD cards.

**The first goal (milestone 1).** On this Mac, through MoltenVK: the Vulkan engine draws (a) one
plain triangle and (b) the bone surface of our test phantom with the same camera and lighting as the
Metal reference picture, and a test program says "matches Metal" (or shows exactly where it does not).

**What has to happen first.** About 3 sessions of tidying inside BorosKit that you will not see in
the app (moving the last bits of shared maths out of the Metal files, fixing two small portability
bugs, adding a build for Windows/Linux). Then the Vulkan part itself.

**Decisions I need from you** (section 9): which build tools may be used (all free, permissive
licences, never shipped inside Boros), installing the Vulkan SDK on this Mac (one download), whether
we may re-record the reference pictures after pinning the CPU maths, how text is drawn on
Windows/Linux, and whether a Windows/Linux test PC is available.

**Honest size.** Milestone 1: about 6-9 sessions from today (prep + skeleton). The off-screen
engine for everything BorosKit draws today, checked on this Mac: about 15-20 sessions. With
on-screen windows on Windows/Linux and real NVIDIA/AMD testing: about 22-30 sessions plus your test
time. That is more than the "6-10 sessions" I said on 2026-11-12; that figure counted only the
renderer code, not the preparation, the build/test system, windows/text on other systems, or testing
on other graphics cards (section 8).

---

## Contents

1. Where we start (summary of the audit)
2. Backend abstraction: the shape of the GPU interface
3. Shader strategy: one source, two languages (options and licences)
4. MoltenVK on this Mac vs a Linux/Windows PC
5. Build system: SwiftPM + CMake
6. Test strategy: same references for both engines
7. Order of porting, and milestone 1 step by step
8. Phases with honest effort estimates
9. Decisions needed from the user
10. Risks
11. Rules that apply to every step

---

## 1. Where we start

Strong already (audit sections 3, 5, 6):
- 26 plain-C/C++ cores (24 `.c`, 2 `.cpp`); 24 compile as strict C99/C++17 with no Apple headers (2 small fixes needed).
- Every GPU parameter block already has a std430-compatible layout (no float3, no bool, 32-bit types).
- Compute kernels use only core features (no argument buffers, ICBs, mesh shaders, subgroups, atomics).
- A golden-output harness (36 reference files) whose case definitions and file readers are plain C
  (`Tests/BorosKitGoldenTests/BKGoldenCore.c`) - a Vulkan runner can reuse them unchanged.
- GPU selection (`BKGPUChoiceCore`) and the shader-math policy (`BKMetalDevice`, Relaxed) are in place.

Missing (audit top 10): no GPU interface (1); Objective-C parameter builders and three camera copies
(2); Metal-only shader text (3); GPU struct headers not plain C, few size/offset pins (4); compute
writes to the screen image + layered overlays (5); two portability bugs (6); run-time workgroup
sizes (7); no plain-C tests (8); CPU fp-contraction not pinned (9); behaviour in the Boros 6 native
views (10).

---

## 2. Backend abstraction

### 2.1 Layers

```
 Boros 6 (Mac app, Obj-C)          BorosCMF / test runner (C++, Windows / Linux / Mac)
        |                                          |
 BorosKit Objective-C API  (BKVolumeRenderer, BKMeshRenderer, ... unchanged names, thin wrappers)
        |                                          |
 BorosKit "passes" (C++17, one per module: MeshPass, SurfacePass, RaycastPass, SlabPass,
                    ReformatPass, DisplayPass, OverlayPass, StereoPass)      <- written ONCE
        |   use: plain-C cores (camera, params builders, plans, tables)  +  the GPU interface
        |
 boroskit::gpu interface (C++17 header, no Metal / Vulkan types)            <- BKGPU.h
        |                                   |
 MetalDevice (Obj-C++ .mm, Apple)     VulkanDevice (C++, Vulkan loader only)
        |                                   |
 Surface (presentation, per platform: CAMetalLayer | VkSurfaceKHR from Win32 / X11 / Wayland / Metal layer)
```

The passes own the *order of GPU work* (which kernel, which buffers, what sizes) - today that lives
in each Objective-C class. Moving it into C++ passes over an interface is what makes "written once"
true. The Objective-C classes keep their names and behaviour for Boros 6.

### 2.2 The interface (C++17, status codes, no exceptions)

Refines VULKAN-PORT-PLAN.md section 6 with the additions from the 2026-11-14 audit section 4.
Sketch only - the real header comes in phase 2, with PORTING NOTES:

```cpp
// Sources/BorosKitGPU/include/BKGPU.h  - Original BorosKit code written for this project.
namespace boroskit::gpu {

enum class Status : int32_t { Ok = 0, OutOfMemory, Unsupported, DeviceLost, InvalidArgument, CompileFailed };
enum class Format : uint32_t { R8Unorm, R16Unorm, R32Float, R32Uint, RGBA8Unorm, BGRA8Unorm,
                               RGBA16Float, RGBA32Float, Depth32Float };
enum class Memory : uint32_t { DeviceOnly, Upload, Readback };   // private / shared-write / shared-read
enum Usage : uint32_t { Sampled = 1, Storage = 2, RenderTarget = 4, CopySrc = 8, CopyDst = 16, DepthTarget = 32 };

struct Limits {                       // filled at start-up; checked by every pass
    uint64_t maxBufferBytes, maxStorageBufferRange, memoryBudgetBytes;
    uint32_t maxImage2D, maxImage3D, maxComputeWorkgroupInvocations, maxComputeWorkgroupSize[3];
    uint32_t maxPushConstantBytes, subgroupSize, vendorID;
    bool linearFilterR16Unorm3D, linearFilterRGBA32Float, linearFilterR32Float,
         depth32Float, independentBlend, unifiedMemory;
};

struct TextureDesc { Format format; uint32_t width, height, depth; uint32_t usage; const char *label; };
struct SamplerDesc { bool linear; bool normalizedCoords; bool repeat; };      // always no mipmaps

// One binding table per pipeline, numbered by slot. The backend maps slots to its own model:
// Metal: buffer(n) / texture(n) / sampler(n) index spaces; Vulkan: descriptor set 0, binding =
// kind base + n (buffers 0-15, sampled textures 16-31, storage images 32-39, samplers 40-47).
enum class SlotKind : uint32_t { UniformBlock, StorageBuffer, SampledTexture, StorageImage, Sampler };
struct SlotLayout { SlotKind kind; uint32_t slot; bool writes; };   // "writes" drives barriers
struct Binding { SlotKind kind; uint32_t slot; class Buffer *buffer; uint64_t offset;
                 class Texture *texture; const void *bytes; uint32_t byteCount; };  // bytes <= 4 KB

struct ShaderRef { const char *name; };          // looked up in the module's shader table (section 3)

struct ComputeDesc { ShaderRef kernel; uint32_t workgroup[3]; const SlotLayout *slots; uint32_t slotCount; };
struct BlendTarget { Format format; bool blend; bool premultipliedOver; bool writeEnabled; };
struct RenderDesc { ShaderRef vertex, fragment; BlendTarget color[2]; uint32_t colorCount;
                    bool depthTest, depthWrite; bool cullBack; bool frontCounterClockwise;
                    const SlotLayout *slots; uint32_t slotCount; };   // no vertex-input layouts:
                                                                     // vertices are pulled from storage buffers
struct PassTargets { class Texture *color[2]; uint32_t colorCount; class Texture *depth;
                     bool clear; float clearColor[2][4]; float clearDepth;      // +infinity allowed
                     float viewport[4]; int32_t scissor[4]; };

class Buffer  { public: virtual ~Buffer() = default; virtual uint64_t size() const = 0;
                virtual void *map() = 0; virtual void unmap() = 0; };
class Texture { public: virtual ~Texture() = default; virtual const TextureDesc &desc() const = 0; };
class Sampler { public: virtual ~Sampler() = default; };
class ComputePipeline { public: virtual ~ComputePipeline() = default; };
class RenderPipeline  { public: virtual ~RenderPipeline() = default; };

class CommandList {
public:
    virtual ~CommandList() = default;
    virtual Status upload(Texture &, const void *data, uint32_t rowBytes, uint32_t sliceBytes,
                          uint32_t z0, uint32_t slices) = 0;                  // staging inside
    virtual Status upload(Buffer &, uint64_t offset, const void *data, uint64_t bytes) = 0;
    virtual void   readback(Texture &, Buffer &) = 0;                         // also 3D -> buffer
    virtual void   dispatch(ComputePipeline &, const Binding *, uint32_t n,
                            uint32_t gx, uint32_t gy, uint32_t gz) = 0;
    virtual void   beginPass(const PassTargets &) = 0;
    virtual void   draw(RenderPipeline &, const Binding *, uint32_t n, uint32_t vertexCount,
                        Buffer *indices = nullptr, uint32_t indexCount = 0) = 0;
    virtual void   endPass() = 0;
    virtual void   timestamp(uint32_t index) = 0;                             // adaptive quality
};

class Device {
public:
    virtual ~Device() = default;
    virtual const Limits &limits() const = 0;
    virtual const char *name() const = 0;                                    // for BKGPUChoiceCore
    virtual std::unique_ptr<Buffer>  makeBuffer(uint64_t bytes, Memory, uint32_t usage) = 0;
    virtual std::unique_ptr<Texture> makeTexture(const TextureDesc &) = 0;
    virtual std::unique_ptr<Sampler> makeSampler(const SamplerDesc &) = 0;
    virtual std::unique_ptr<ComputePipeline> makeCompute(const ComputeDesc &, Status *) = 0;
    virtual std::unique_ptr<RenderPipeline>  makeRender(const RenderDesc &, Status *) = 0;
    virtual std::unique_ptr<CommandList> begin() = 0;
    virtual Status submit(CommandList &, bool wait, void (*done)(void *ctx, Status) = nullptr, void *ctx = nullptr) = 0;
};

// Presentation is separate (only on-screen views need it).
class Surface {
public:
    virtual ~Surface() = default;
    virtual Status resize(uint32_t w, uint32_t h) = 0;
    virtual Texture *acquire() = 0;          // a RenderTarget | CopyDst image; never written by compute
    virtual Status present(CommandList &) = 0;
};

Status makeMetalDevice(void *mtlDevice, std::unique_ptr<Device> *out);       // Obj-C++ file
Status makeVulkanDevice(const char *preferredName, std::unique_ptr<Device> *out);  // BKGPUChoiceCore inside
}
```

Design choices, in plain words:
- **Barriers are automatic.** Each `SlotLayout` says whether a kernel writes a resource; the Vulkan
  backend tracks each texture's/buffer's last use and inserts the barrier and image-layout change
  itself (Metal already tracks hazards for us). BorosKit has few resources per frame, so simple
  tracking is enough and removes the most common class of Vulkan bugs (missing barriers).
- **No vertex-input layouts.** Vertices are read from storage buffers by vertex index, exactly as
  the Metal shaders already do (`packed_float3` by `vertex_id`). One less thing that can differ.
- **Descriptors:** one descriptor set per draw/dispatch from a per-frame pool that is reset when the
  frame's fence signals (core Vulkan; `VK_KHR_push_descriptor` as an optional speed-up later).
- **Small constants** (`bytes`, <= 4 KB) go into a per-frame upload ring buffer (Vulkan) /
  `setBytes` (Metal). Blocks <= 128 bytes may use push constants (e.g. `BKDisplayParams`, 80 B).
- **Workgroup sizes are fixed at pipeline creation** (specialization constants in Vulkan; the
  Metal backend just uses the same numbers) - finding 7.
- **The screen image is never written by compute** (finding 5): the 3D view ray-casts into an RGBA8
  storage image, then a tiny draw (or blit) copies it into the `Surface` image, with the overlay
  pass drawn on top in the same frame (native-view item N5).
- **Memory:** a small own sub-allocator in the Vulkan backend (big blocks per memory type, simple
  free list). No third-party allocator (the well-known ones are MIT-licensed code - not allowed).
  Uploads go through a staging buffer, or straight into device-local + host-visible memory where the
  driver offers it (ReBAR), as planned in VULKAN-PORT-PLAN.md section 12.
- **Function loading:** our own ~100-line loader (`dlopen`/`LoadLibrary` of the system Vulkan loader,
  `vkGetInstanceProcAddr`), no third-party meta-loader.
- **Errors:** `Status` everywhere (C, C++ and Objective-C friendly), logged by the caller.

### 2.3 What the Metal side looks like after phase 2
`MetalDevice` implements the interface; `BKSurfaceExtractor`, then the others, become wrappers that
build a pass and run it on `MetalDevice`. After each module switch the golden harness must pass in
**strict mode** (zero difference) - the refactor must not change a single Metal pixel.

---

## 3. Shader strategy

### 3.1 Options (licences as I understand them; no web search was done - verify the exact licence
file of the version actually installed before adopting any tool)

| Option | Tools | Licence of the tools | Linked into BorosKit? | For | Against |
|---|---|---|---|---|---|
| A. Twin files: hand-written MSL (as today) + hand-written GLSL | glslang (`glslangValidator`) or shaderc (`glslc`) to compile GLSL -> SPIR-V; SPIRV-Tools (`spirv-val`, `spirv-opt`) | glslang: mainly BSD-3-Clause with some BSD-2/MIT/Apache-2.0 files, plus one generated parser file under GPL-3.0 *with the Bison exception*; shaderc: Apache-2.0; SPIRV-Tools: Apache-2.0 | no (build-time programs only) | simplest; Metal untouched | every algorithm twice; fixes must be made twice; drift |
| B1. GLSL as the one source -> SPIR-V -> MSL | glslang/shaderc + **SPIRV-Cross** (SPIR-V -> MSL) | SPIRV-Cross: Apache-2.0 | no (build-time) | one source | the Metal reference becomes generated code: must be re-validated; harder to read/debug on the Mac |
| B2. HLSL as the one source | **DXC** (HLSL -> SPIR-V) + SPIRV-Cross | DXC: University of Illinois/NCSA (LLVM-style, permissive) | no | HLSL is popular on Windows | same as B1, plus a large compiler to build/install on 3 systems |
| B3. Slang as the one source -> SPIR-V and MSL directly | **slangc** | Slang: originally MIT; since moving to Khronos (2024) Apache-2.0 with LLVM exception - verify | no | one modern source; native MSL output | young tool, large; generated Metal again |
| **C. Shared kernel bodies + thin hand-written entry points (recommended)** | glslc/glslang only (for the Vulkan half), spirv-val | as in A | no | one copy of the *algorithms*; Metal stays hand-written, readable and remains the reference; smallest tool footprint; continues the existing "field list pasted into both" trick | needs a written subset + a compile check (rules below) |

All options keep the rule "no third-party code in BorosKit": the tools only run at build time on
the developer machine; their *output* (our SPIR-V) carries no licence obligation from the tool (the
plain reading of BSD/Apache/NCSA - not legal advice). Nothing GPL/LGPL is linked, shipped or copied.
The one GPL-with-Bison-exception file inside glslang only matters if glslang itself is
redistributed, which we never do. Apple's own "Metal shader converter" (DXIL -> Metal) is under
Apple's proprietary licence and is not considered.

### 3.2 Recommendation: option C, with Slang (B3) as the fallback
Keep the decision in VULKAN-PORT-PLAN.md section 7. Concretely:
- New folder per module: `Sources/<Module>/Shaders/*.bksl` - plain-text shared bodies (`bk_trace`,
  `bk_sample`, `bk_transfer`, surface classify/emit bodies, `bk_project`, mesh shading, display
  window/LUT, overlay). Today they live as string pieces in the `.mm` files; they move out verbatim
  (strict golden unchanged).
- Two preludes: `bk_prelude_msl.h` (`#define bk_float3 float3` ...) and `bk_prelude_glsl.h`
  (`#define bk_float3 vec3`, `#define bk_rint roundEven`, `#define BK_SAMPLE_VOLUME(c) texture(...)`).
- Entry points written by hand per backend (~10-20 lines each): MSL in the existing `.mm` strings;
  GLSL in `Sources/BorosKitGPUVulkan/Shaders/*.comp|vert|frag`, which `#include` the prelude and
  the shared bodies.
- The struct field lists (`BK_RENDER_PARAMS_FIELDS` etc.) are pasted into GLSL `layout(std430)`
  blocks by the same macro trick; a test compiles a tiny shader that writes `sizeof` and selected
  `offsetof` values back (as `bk_params_size` does on Metal today).
- Subset rules: VULKAN-PORT-PLAN.md section 7 (no references/pointers/address spaces in shared
  functions, `mix` not `lerp`, `roundEven` for `rint`, no `half`, no `bool`/3-vectors in memory,
  workgroup memory only in named helpers, integer-counter loops, no recursion).
- Build step (CMake): `glslc --target-env=vulkan1.2 -O` (no fast-math flags) -> `.spv` ->
  `spirv-val` -> embedded as `static const uint32_t[]` via our own CMake script (`file(READ ... HEX)`),
  no third-party embed tool. On the Mac SwiftPM build, nothing changes (Metal compiles MSL at run
  time as today).
- If the subset becomes painful for the big ray caster, switch only that module to Slang (B3) after
  a measured comparison - the user decides.

---

## 4. MoltenVK on this Mac vs a Linux/Windows PC

| | MoltenVK on this Mac (M1 Pro) | Linux / Windows PC |
|---|---|---|
| What it is | Vulkan implemented on top of Metal (LunarG Vulkan SDK for macOS; Apache-2.0) | the GPU vendor's native Vulkan driver |
| What it proves | our Vulkan API use is correct (with validation layers), our GLSL compiles and gives the right pictures; fast edit-test loop on the user's own machine | real-world correctness and speed per vendor (NVIDIA, AMD, Intel) - rounding, filtering precision, edge rasterisation, memory limits |
| What it cannot prove | other vendors' numbers (it runs on the same Apple GPU, and translates our SPIR-V back to MSL internally) | - |
| Must-knows | instance needs `VK_KHR_portability_enumeration` + flag `VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR`; device must enable `VK_KHR_portability_subset` and respect its feature struct; switch MoltenVK's own fast-math setting off for golden runs (an `MVK_CONFIG_*` setting - check the SDK's MoltenVK documentation for the exact name); limits differ from desktop GPUs - always read `Limits` | install SDK (headers, loader, validation layers, glslc, spirv-val); clang/clang-cl for the C cores |
| CPU-only reference driver | - | **Mesa lavapipe** (Linux, MIT) or **SwiftShader** (Apache-2.0): Vulkan on the CPU, deterministic, no GPU needed - good for automatic test runs. Used as a *driver* at test time, never linked or shipped |

Plan: develop everything on this Mac through MoltenVK first (milestone 1 and the module ports),
with validation layers on and synchronisation validation enabled; zero validation messages is a
pass criterion. Then, before any release use, run the same golden runner on a Linux or Windows PC
with an NVIDIA and an AMD card (phase 9). MoltenVK is a development tool only: Boros 6 keeps its
Metal engine and never loads MoltenVK.

---

## 5. Build system: SwiftPM + CMake

- **SwiftPM (unchanged role):** Apple build of everything Boros 6 uses (Objective-C API, Metal
  backend, cores). New targets: `BorosKitGPU` (interface header + neutral helpers), and
  `BorosKitGPUMetal` (Metal implementation) once phase 2 starts. The Vulkan backend is **not** in
  `Package.swift`, so building Boros 6 never needs the Vulkan SDK.
- **CMake (new, 3.24+):** `CMakeLists.txt` at the BorosKit root builds:
  - `boroskit_vec`, `boroskit_cores` (all plain-C/C++ cores, C99/C++17);
  - `boroskit_gpu` (interface) and `boroskit_gpu_vulkan` (backend + embedded SPIR-V);
  - `boroskit_passes` (the C++ passes, phase 2+);
  - `bk_core_tests` (plain-C unit tests, phase 1) and `bk_golden_vulkan` (golden runner);
  - works on macOS (against the SDK's loader + MoltenVK), Linux, Windows (clang-cl).
- **One list of sources.** `cmake/BorosKitSources.cmake` names every core file explicitly; a check
  (part of `docs/tools/`) fails if a `*Core.c/.cpp` exists in `Sources/` that is not listed, so SwiftPM
  and CMake cannot silently diverge.
- **Same floating-point rules everywhere** (finding 9): cores built with `-ffp-contract=off` and no
  fast-math on all compilers (Package.swift `cSettings`/`cxxSettings` of the core targets and CMake);
  clang on every platform (clang-cl on Windows), so the C maths behaves the same. Turning this on
  for SwiftPM may change the last bit of some CPU results -> re-record the golden references once,
  deliberately (user decision D3).
- **Portability gate:** `docs/tools/check-portable-cores.sh` (added with the audit) runs in every
  phase; CMake on Linux/Windows is the real proof later.
- **Compile flags for shaders:** no `-ffast-math`-like options; SPIR-V for Vulkan 1.2
  (MoltenVK supports 1.2; 1.3 features not needed).

---

## 6. Test strategy

1. **Same reference files, same tolerances.** The golden harness (`Tests/BorosKitGoldenTests`) is
   the contract: Metal recorded the references; the Vulkan runner (`bk_golden_vulkan`, C++) reads
   the same `References/` folder with the same `bk_golden_compare_*` functions from `BKGoldenCore.c`.
   First check of any port: the phantom hash.
2. **Tolerances (agreed 2026-11-13):** 8-bit images every channel +-1, except at most 0.5 % of
   channels (edge pixels); float images 1 HU, 1/255 opacity, 0.01 mm ray distance (same 0.5 %
   allowance); meshes same counts and identical triangle lists, positions within 1e-4 voxel, normals
   1e-3; exported files byte-identical; numbers 1e-6 relative. A bigger difference is a bug until
   explained.
3. **Live cross-check on this Mac:** an extra test renders each case with Metal *and* with Vulkan
   (MoltenVK) in the same run and compares them directly - catches a stale reference file.
4. **Plain-C core tests** (phase 1): a tiny own test runner (`Tests/BorosKitCoreTestsC/`, macros
   `BK_CHECK`, `BK_CHECK_NEAR`), with the expected numbers moved from the XCTest files of the cores;
   XCTest calls the same C test functions, so the Mac and other systems run *identical* checks.
   Start with the cores used by milestone 1 (BKVec, BKCameraMath, BKMeshDrawCore, the new uniforms
   builder), then all 26.
5. **Golden coverage to add** before the matching module is ported (audit finding 8): mesh
   lines/points/textures/culling, rotated crop planes, `useClip`, view slab, on-screen path, curved
   reformat, overlay engine (its CPU rasteriser is the reference), preset -> TF numbers.
6. **Validation layers** (`VK_LAYER_KHRONOS_validation`, synchronisation validation on) in every
   Vulkan test run: any message = failure.
7. **Per vendor** (phase 9): the golden runner on NVIDIA, AMD, Intel and lavapipe; speed tuning
   (VULKAN-PORT-PLAN.md section 12) may never move a result outside tolerance.
8. **Speed** (not a pass/fail): same cases timed on Metal and on Vulkan (MoltenVK numbers are only
   indicative; real numbers come from the PC).

---

## 7. Order of porting, and milestone 1

### 7.1 Order (each step: Metal refactor first with strict golden unchanged, then the Vulkan port)
1. **Cores** (CPU only): CMake build of all cores + plain-C tests; mesh processing and scene export
   golden files byte/tolerance-identical on the CMake build. Proves the precision flags.
2. **Mesh renderer** (first raster pipeline; milestone 1): `MeshPass` - solid meshes, then lines,
   points, see-through ordering, textured meshes, the ray-distance target, orientation cube, crop box.
3. **Surface extraction** (first compute module; exact CPU reference already exists): `SurfacePass`
   with specialization-constant workgroups. Placed here because it exercises compute, shared memory
   and big buffers before the much larger ray caster.
4. **Volume renderer**: params builder in C (R2/R3), `RaycastPass` (composite/MIP/MinIP/average,
   empty-space skipping, manual filtering, embedded geometry), on-screen path via storage image +
   copy (finding 5).
5. **Slab / MPR + curved reformat**: `SlabPass` (thin/thick slabs through the ray caster's values
   path) and `ReformatPass` (texelFetch only; CPU reference `BKReformatComputeRows`).
6. **2D display + 2D overlay engine**: `DisplayPass` (one full-screen triangle, texelFetch) and
   `OverlayPass` (BKOverlayCore triangles; the CPU rasteriser is the reference), text through a
   glyph source (decision D4); then the 3D windows' overlay in the same pass (item N5).
7. **Presentation** (`Surface` on Windows/Linux, resize, adaptive quality via timestamps).
8. **Vendor tuning + real-hardware golden runs.**

### 7.2 Milestone 1 definition
> On this Mac, through MoltenVK, a C++ test program built with CMake uses `VulkanDevice` to render
> (a) a single flat-coloured triangle and (b) the golden case `meshrender_bone_ortho` - the phantom's
> bone surface read from `References/surface_bone_300.bkmesh`, with the camera, colour and lighting
> of `kBKGoldenMeshRenderCases[0]` - into an offscreen RGBA8 + R32F (ray distance) target, reads it
> back, and compares it with `References/meshrender_bone_ortho.rgba.pam` / `.distance.pfm` using
> `bk_golden_compare_*` at the agreed tolerances. Pass = within tolerance AND zero validation-layer
> messages. The triangle must match a CPU-computed expected image exactly inside, +-1 at the edges.
> Metal is not changed in behaviour (golden strict mode passes on the SwiftPM build).

### 7.3 Milestone 1, step by step

| # | Step | Touches | Done when |
|---|---|---|---|
| M0 | User installs the LunarG Vulkan SDK for macOS (includes MoltenVK, loader, validation layers, glslc, spirv-val). I give click-by-click steps; no other installs. | user | `vulkaninfo` lists the Apple GPU via MoltenVK |
| M1 | Fix the two portability bugs: `#include <stddef.h>` in `BKVolumeRayCore.h`; `BKOnce` helper (or eager tables) replacing `pthread_once` in `BKSurfaceCore.c`; move `BKParallel.h` into BorosKitVec (R5). | BorosKitVec, BKVolumeRayCore.h, BKSurfaceCore.c | check script all clean; `swift test -c release` passes; golden strict unchanged |
| M2 | GPU struct headers plain C (finding 4): own `bk_float4`/`bk_float4x4` typedefs, `BK_MAX_CLIP_PLANES` moved out of `BKClipPlanes.h`, `_Static_assert` sizes + key `offsetof`s for every struct in audit section 5, shared field list for `BKOverlayParams`. | BKShaderTypes.h, BKMeshShaderTypes.h, BKClipPlanes.h, BKOverlayCore.h/BKOverlayRenderer.mm (after gl-2d-final merges) | builds; struct-size tests pass; golden strict unchanged |
| M3 | `BKMeshUniformsFill()` in `BKMeshDrawCore` (plain C on BKVec): camera frame via `BKCameraMath`, half sizes, depth range, normal matrix, lighting; `BKMeshRenderer.m` calls it (removes `:532-547`, `:797-830`, `:899`). | BorosKitMeshRender | golden strict unchanged (if the last bit moves because simd and C differ: report, user decides to re-record) |
| M4 | CMake skeleton: `boroskit_vec`, `boroskit_cores`, `BKGoldenCore.c`, plain-C test runner with the first core tests (BKVec, BKCameraMath, BKMeshDrawCore incl. the new fill function). `-ffp-contract=off`. | new `CMakeLists.txt`, `cmake/`, `Tests/BorosKitCoreTestsC/` | `cmake --build` + `ctest` pass on this Mac |
| M5 | `BKGPU.h` interface header (section 2.2) with PORTING NOTES; no implementation yet. | new `Sources/BorosKitGPU/` | compiles as C++17 with no Apple/Vulkan headers |
| M6 | `VulkanDevice` minimum: own loader, instance (portability enumeration, validation in debug), physical-device choice through `BKGPUChoiceCore`, device + queue, buffers/images with the own sub-allocator, staging upload, readback, render pass (classic `VkRenderPass`, or dynamic rendering where available), graphics pipeline from embedded SPIR-V, descriptor pool per frame, automatic barriers for the few resources used, fences. | new `Sources/BorosKitGPUVulkan/` (CMake only) | creates device on MoltenVK; validation clean |
| M7 | Triangle test: GLSL vert/frag compiled by `glslc` in CMake, drawn into RGBA8, compared with the CPU expectation. | test program | exact inside, +-1 at edges, validation clean |
| M8 | Mesh shaders in GLSL: entry points over shared bodies (`bk_project`, `bk_view_depth`, shading, ray distance) extracted to `.bksl` (the Metal `.mm` includes the same text; strict golden unchanged); two colour targets, premultiplied over on target 0, D32 depth (fallback D24/D32-S8 if `depth32Float` missing), CCW front face, negative viewport height. | BorosKitMeshRender shaders, Vulkan shader folder | GLSL compiles + `spirv-val` clean; Metal golden strict unchanged |
| M9 | Golden runner: read `surface_bone_300.bkmesh`, fill uniforms with `BKMeshUniformsFill` from `kBKGoldenMeshRenderCases[0]`, render, read back, compare `.pam` + `.pfm`; print `GOLDEN |` lines like the XCTest runner. | `Tests/BorosKitGoldenVulkan/` | **milestone 1 passed**; also case 1 (perspective see-through) attempted and reported |
| M10 | Notes: results, differences seen and why, update VULKAN-PORT-PLAN.md + To-Do; user sees one picture side by side (Metal vs Vulkan) as a PNG. | docs | user has seen it |

M1-M5 touch no file owned by today's agents except `BKOverlay*` in M2 (do that part after the
gl-2d-final merge). M6-M10 are new folders only. Boros 6 is not changed at all for milestone 1.

---

## 8. Phases with honest effort estimates

Unit: one "session" = one long Claude working session (several hours of agent work) plus the
user's test where needed. Ranges, not promises; the bottleneck stays testing and the user's time.

| Phase | Content | Estimate |
|---|---|---|
| 0 | Prep inside BorosKit, Metal unchanged (M1-M3; `BKRenderParamsFill`; preset -> TF core; frame plan core; plain-C header pins; provenance lines confirmed; workgroup sizes fixed) | 3-4 |
| 1 | CMake + plain-C tests for all cores + C golden runner for CPU cases (M4 + rest) | 1-2 |
| 2 | GPU interface + `MetalDevice`; Objective-C classes become wrappers over passes, one module at a time, strict golden after each | 3-4 |
| 3 | `VulkanDevice` skeleton + milestone 1 (M5-M10) | 2-3 |
| 4 | Surface extraction on Vulkan | 1-2 |
| 5 | Volume renderer on Vulkan (all modes, skipping, manual filtering, embedded geometry, on-screen path) | 3-4 |
| 6 | Slab/MPR + curved reformat on Vulkan | 1-2 |
| 7 | 2D display + overlay engine + text on Vulkan; 3D-window overlay in one pass | 2-3 |
| 8 | Presentation on Windows/Linux (surface, resize, frame pacing, adaptive quality) | 2-3 |
| 9 | Real hardware: NVIDIA/AMD/Intel golden runs, fixes, vendor tuning | 2-3 (+ access to a PC) |
| | **Milestone 1 (phases 0 partly, 1 partly, 3)** | **~6-9** |
| | **Off-screen engine complete, checked on this Mac (0-7)** | **~15-20** |
| | **Including Windows/Linux windows and vendor testing (0-9)** | **~22-30** |

Not included: porting the Boros 6 app itself or BorosCMF's UI; the LGPL CPR/N3 rewrite (R10, needed
before CPR/panorex in a non-Mac app, agreed for after Mac testing); a CUDA module (only if measured
faster, VULKAN-PORT-PLAN.md section 12).

---

## 9. Decisions needed from the user

| # | Question | My recommendation |
|---|---|---|
| D1 | May we use these **build-time tools** (never shipped, never linked, no code copied): Vulkan SDK (loader, validation layers, MoltenVK for Mac testing), glslang/shaderc (`glslc`), SPIRV-Tools (`spirv-val`); CMake? Licences: Apache-2.0 / BSD / MIT (glslang has one GPL-with-Bison-exception generated file that only matters if glslang itself were redistributed). | yes |
| D2 | May the Vulkan backend **#include the official Vulkan headers** (Apache-2.0 OR MIT, the system API - like including Apple's Metal headers)? Writing our own copies of those declarations would be error-prone and gains nothing. | yes, from the installed SDK, not copied into the repository |
| D3 | **Pin CPU floating-point** (`-ffp-contract=off`, no fast-math) for all cores on all compilers, then **re-record** the golden references once if anything moves (measured on 2026-11-13 to be within tolerance). | yes, in phase 0 |
| D4 | **Text on Windows/Linux:** (a) use the operating system's font engine in the platform glue (DirectWrite on Windows; on Linux FreeType, whose FTL licence asks for a credit line), or (b) write BorosKit's own font rasteriser (TrueType outline reader + coverage rasteriser, ~1-2 sessions, fully licence-free), or (c) a fixed built-in bitmap font (fast, limited look). | (b) for licence-freedom, or (a) if a credit line is acceptable; decide before phase 7 |
| D5 | **Windows/Linux windows:** our own thin glue per system (Win32; X11 and/or Wayland) instead of a third-party window library. | own glue; Linux: start with X11 or Wayland only - decide with the app plan |
| D6 | Is a **Windows or Linux PC with an NVIDIA and/or AMD card** available for phase 9 (and earlier spot checks)? | needed before any release use |
| D7 | Shader approach: **option C** (shared bodies, Metal stays hand-written reference) vs one-source generation (Slang / SPIRV-Cross) | C; revisit only for the ray caster if C gets awkward |
| D8 | Start phase 0 **after** the five current agent branches are merged (they touch the same files). | yes |

---

## 10. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| MoltenVK is not a real Vulkan driver (translates to Metal, same Apple GPU) | passes on the Mac, fails or differs on NVIDIA/AMD | validation + sync validation always on; lavapipe runs; phase 9 on real cards before any use |
| Synchronisation bugs (missing barriers, wrong image layouts) | flicker, garbage, works on one vendor only | automatic barrier tracking in the backend; sync validation; few resources per frame |
| GPU filter precision differs per vendor (8-bit weights) | HU values differ up to ~5 HU next to sharp edges | manual trilinear for every HU-exact output (MPR, MIP, average, export) on both backends; hardware filter only for the interactive 3D picture (VULKAN-PORT-PLAN finding 1) |
| Metal "Relaxed" math still allows re-association; SPIR-V compilers do not by default | last-bit differences in 3D pictures | covered by tolerances; for a strict study switch Metal to Safe (3.3x slower, measured) |
| CPU FMA/contraction differs between compilers | decimation decisions flip; mesh golden fails on Windows | D3 (pin `-ffp-contract=off`, clang everywhere) |
| Optional Vulkan features missing (R16_UNORM 3D linear filter, RGBA32F filter, D32 depth, large 3D images, independent blend) | pass cannot run on some GPU | every pass checks `Limits`; manual filtering exists; refuse clearly with a message (and log) instead of drawing wrongly |
| 3D image size: Vulkan guarantees 256 per side, desktop GPUs give 2048+ | large CBCT (e.g. 727 slices) fine on desktop; tiny devices refuse | read `maxImage3D`; bricked upload later if ever needed |
| Discrete GPUs have no shared CPU/GPU memory | slower uploads, 2x memory during upload of a ~1 GB scan | chunked staging (already chunked on Metal); ReBAR path |
| Text and windows on Windows/Linux without third-party libraries | extra work; looks different from the Mac | D4/D5; text compared via the overlay CPU rasteriser |
| Swapchain colour handling differs (sRGB vs UNORM formats, colour spaces) | pictures look slightly brighter/darker on screen than in tests | render to UNORM offscreen images (as tests do), copy to a UNORM swapchain; document |
| Parallel agents change the same BorosKit files | merge conflicts, wasted work | D8; milestone-1 steps M4-M10 use new folders only |
| LGPL N3/CPR types in public APIs | the Objective-C API cannot be reused off Apple | passes take neutral types only; N3 stays at the Apple wrapper boundary until R10 |
| Two backends to maintain forever | every new feature costs twice the GPU glue | passes are written once; only the device layer is doubled; the golden harness catches drift |
| Effort estimates (section 8) | could grow with driver bugs or design changes | milestone 1 first, then re-estimate with real numbers |

---

## 11. Rules that apply to every step

- Licence-free: all code original, no third-party code/tables/allocators/loaders/window libraries
  copied or linked; only the system APIs (Metal, Vulkan headers per D2, OS window/font APIs in glue).
- Vulkan-ready rules of VULKAN-PORT-PLAN.md (1-7) and section 14 (no Apple simd in cores).
- Metal is the reference: each refactor of the Metal side must pass the golden harness in strict mode.
- PORTING NOTES and the provenance line at the top of every new header; plain-language comments
  ("What / Why", dated, agent name) in all new code.
- Test branches only; never push or merge without the user; never `rm` (use `trash`); no files in `/tmp`.
- Boros 6 stays on Metal; nothing Vulkan is built into the Mac app.
