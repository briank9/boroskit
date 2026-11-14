# BorosKit: plan for a second GPU backend (Vulkan)

Written 2026-11-13 on branch `test/vulkan-prep` (based on 7a34474).
Original BorosKit document written for this project.

## In plain words

BorosKit draws everything with Apple's **Metal** today. Windows and Linux do not have
Metal. The plan is to add a second engine on **Vulkan** (the cross-platform equivalent)
after the Metal side is finished. Metal stays the **reference**: the Vulkan pictures,
surfaces and numbers must match Metal's within agreed tolerances.

This document covers:

1. what was checked and changed on this branch;
2. the ten most important findings;
3. a module-by-module audit against the agreed rules;
4. the GPU features that Vulkan only *optionally* has, and the fallbacks;
5. the code that still depends on the Horos-derived LGPL files;
6. a proposed small "GPU interface" so most code does not care which engine runs;
7. how the GPU programs (shaders) should be shared between Metal and Vulkan;
8. the order in which to port the modules;
9. the large jobs left for later;
10. the golden-output test harness (how the two engines will be compared);
11. the tools needed on Windows, Linux and this Mac.

The agreed rules referred to below:

| Rule | Short name |
|---|---|
| 1 | Backend-neutral logic in plain C/C++ cores; Metal/Objective-C files thin |
| 2 | Shared GPU structs in one plain C header per module, std430: no float3, no bool, explicit 32-bit types |
| 3 | Kernels translatable 1:1 to GLSL/HLSL; subgroup/threadgroup tricks behind one helper; no argument buffers, ICBs or mesh shaders |
| 4 | Every optional GPU feature documented, with a manual fallback |
| 5 | CPU reference implementations + golden-number tests, deterministic whatever the thread count |
| 6 | Parallel CPU work only through `BKParallelFor` (BKParallel.h) |
| 7 | A "PORTING NOTES" section at the top of each new header |
| L | Licence-free: no copied/translated third-party code or tables, no new dependencies, nothing new built on the LGPL files |

---

## 1. What was done on this branch

All existing tests still pass; the total is now **186 tests, 0 failures**
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release`).
Every fix below was checked with the golden harness in **strict mode** (zero tolerance),
so they provably change no pixel, vertex or number on this Mac.

| Commit | What |
|---|---|
| `1950fa6` | `BKVolumeTexture -initWithFloatVoxels:...`: upload a volume from plain floats + a plain matrix, without the LGPL `CPRVolumeData`. A test proves both upload paths render identical bytes. |
| `cbd6d21` | **Golden-output harness** (new test target `BorosKitGoldenTests`, section 10). |
| `5f83c9b` | `BKRenderParams` made std430: float4 instead of float3, the 3x3 matrix as 3 float4 columns, explicit end padding, PORTING NOTES. Byte layout unchanged. |
| `377c53c` | Volume shader buffers hold only 32-bit words (brick lists and the RGBA8 output were 8/16-bit types, which need optional Vulkan features). |
| `262e992` | `BKDisplayParams`: explicit 32-bit ints, compile-time size check (80 bytes); PORTING NOTES for the display and mesh shader headers. |
| `fd54fb9` | New plain-C core `BKRenderCore.h/.c`: transfer-function evaluation and 4096-entry bake, the "visible entries" count for empty-space skipping, brick-grid sizing, the 16-bit storage choice and a portable voxel-to-16-bit conversion (proven identical to Apple's Accelerate routine, including exact halfway cases). The Objective-C classes now call it. |
| `89cd68c` | Ray caster: optional **manual filtering** (rule 4). Off by default on the Mac (no change); on automatically on GPUs that cannot filter 32-bit float textures (some iPads). A golden test measures manual vs hardware filtering (finding 1). |

---

## 2. The ten most important findings

1. **Three sources of small number differences are not yet under control** - they
   matter more for "pixel perfect" than anything else:
   - *GPU filter precision.* The GPU's built-in linear filter blends neighbouring voxels
     with 8-bit weights. Measured on the phantom: MIP / thin-MPR **float values** differ
     from exact interpolation by up to **~5 HU** next to sharp edges (the 2500 HU ball),
     in 2-4% of pixels; the displayed 8-bit pictures stay within +-1 grey level. Other
     GPU makers use the same 8-bit minimum, but round differently, so Metal and Vulkan
     will disagree by similar amounts unless both use the *manual* filter for outputs
     where HU values are measured or exported. Recommendation: manual filtering for
     MPR/MIP/average float output on both backends; hardware filter only for the
     interactive 3D picture.
   - *Metal "fast math".* All four Metal libraries are compiled with Apple's default,
     fast math ON (`BKVolumeRenderer.m:132`, `BKSurfaceExtractor.m:136`,
     `BKMeshRenderer.m:252`, `BKImageLayerRenderer.m:104`). Fast math may reorder and
     approximate maths, which Vulkan compilers will not copy. Measured by switching it
     off: everything stays within tolerance (2D display: 2 channels change by up to 4;
     MIP: up to 3.5 HU in 4 edge pixels; meshes ~4e-6 voxel). Recommendation: switch it
     off (`fastMathEnabled = NO`, or `mathMode = .safe` on newer systems) in one
     deliberate commit and re-record the references.
   - *Fused multiply-add on the CPU.* Apple clang may fuse `a*b+c` (`-ffp-contract=on`
     by default); GCC and MSVC behave differently. The mesh smoothing/decimation and the
     transfer-function bake can then differ in the last bit, and decimation *decisions*
     can flip. Recommendation: set the same contraction flag explicitly for the C/C++
     cores in Package.swift and in CMake (and use clang everywhere), then re-record.
2. **LGPL entanglement of the public APIs.** `BKVolumeRenderer`, `BKVolumeTexture`,
   `BKVolumeCamera`, `BKVolumeScene`, `BKMeshRenderer`, `BKMesh`, `BKImageLayerRenderer`,
   `BKOverlay`, `BKVolumeView` and even the "plain C" `BKClipPlanes` use `N3Vector`,
   `N3Plane`, `N3AffineTransform` from the Horos-derived `N3Geometry.h`;
   `BKVolumeCamera.m` does all its maths with N3 functions (43 uses). Section 5 lists all.
   BorosKit needs its own small neutral geometry types before the N3 rewrite.
3. **Camera and frame maths live in Objective-C, three times over** (rule 1):
   `BKVolumeRenderer.m:291-380` (`fillParams`), `BKMeshRenderer.m:336-358` (the same
   camera frame again) plus depth range, sorting and normal matrix at
   `BKMeshRenderer.m:451-610`, and all of `BKVolumeCamera.m`. These must become one
   C camera core shared by both backends.
4. **The ray caster relied on optional filtering with no fallback** (rule 4) - fixed in
   `89cd68c`. Its colour table (RGBA32Float) is sampled with linear filtering, which
   some iPad GPUs cannot do (`MTLDevice.supports32BitFloatFiltering`); the renderer now
   switches to manual filtering automatically there. This was also a latent iPad bug.
5. **GPU structs and buffers broke the std430 rule** - fixed: float3/float3x3 in
   `BKRenderParams`, `uint3` grid constant, 8-bit and 16-bit buffer types in the volume
   shader, plain `int` in `BKDisplayParams`. Surface and mesh-render structs were already
   compliant.
6. **No CPU reference for the ray caster, the 2D display or the mesh drawing** (rule 5).
   Surface extraction (exact CPU reference) and mesh processing (CPU code) are covered.
   A CPU reference ray caster for MIP/MinIP/average/thin slice with manual filtering
   would let both backends be checked to the exact HU, independent of each other.
7. **Shaders are Metal source text inside four `.mm` files** with no sharing mechanism
   yet. Section 7 recommends "shared kernel bodies + thin per-backend entry points".
8. **The on-screen 3D view writes into the screen buffer from a compute program**
   (`BKVolumeView.m:120` `framebufferOnly = NO`; `BKShaderSource.mm:421`
   `bk_raycast_texture`). In Vulkan, writing to swapchain images from compute (storage
   usage, especially BGRA8) is optional. Plan: ray-cast into an RGBA8 storage image,
   then copy/blit or draw it to the swapchain.
9. **Surface kernels pick their workgroup size at run time** (`BKSurfaceExtractor.m:148`,
   `threads_per_threadgroup` in `BKSurfaceShaderSource.mm:239/303`). Vulkan fixes the
   size when the pipeline is built: use a specialization constant (`local_size_x_id`)
   and query `maxComputeWorkGroupInvocations`. Small rule-3 deviation: `bk_surface_classify`
   uses its own threadgroup array and barriers outside the scan helper
   (`BKSurfaceShaderSource.mm:244-270`); harmless (core Vulkan), but worth folding into
   one helper.
10. **Mesh geometry and file reading are Objective-C++** (rule 1): `BKMesh.mm`
    (normals 219-280, welding 289, edge report 373, area 417, volume 431, box/sphere
    445-523) and all of `BKMeshIO.mm` (STL/PLY/OBJ parsing) use Foundation and Apple
    `simd` types. They must move into the C++ core for Windows/Linux. Also `BKParallel.h`
    lives only in BorosKitMesh, so the Surface and Render cores cannot use it (rule 6).

Smaller findings: `BKViewTransform` is C but uses `CGFloat`/`CGAffineTransform`
(CoreGraphics, Apple-only); `BKMeshUnprojectPixel` (`BKMeshRenderer.h:210`) is "plain C"
but takes Apple `simd_float3`; 7 BorosKitSurface source/header files carry a
"Copyright (c) 2026 Serdal Kocak" line, against the agreed header style (left alone: the
copyright question is still open); 43 non-Horos source files lack the provenance line
"Original BorosKit code written for this project; contains no third-party code."

---

## 3. Module-by-module audit

### BorosKitCore

- **Backend-neutral already:** `BKClipPlanes` (plain C plane maths, VTK conversion, GPU
  packing as float4).
- **Metal-specific:** nothing.
- **LGPL:** everything else in this module is Horos-derived (CPR engine, N3 geometry,
  Bezier paths); the CPR operations use `NSOperationQueue` (rule 6) but are to be
  rewritten anyway. `BKClipPlanes.h:16` imports `N3Geometry.h` and its API is built on
  `N3Plane`/`N3Vector`/`BOOL`/`NSUInteger` (`BKClipPlanes.m:12-60`).
- **To do:** neutral types (`BKVec3d`, `BKPlane`, column-major `double[16]`) in a new
  plain-C header here; re-express BKClipPlanes on them; move `BKParallel.h` here.

### BorosKitRender (volume ray casting, camera, presets)

- **Backend-neutral already:** `BKRenderCore.c` (new: transfer function, skipping
  tables, 16-bit storage), `BKShaderTypes.h` (now std430), quality-ladder functions in
  `BKVolumeScene.m:20-70` (C, but take `NSArray`/`NSInteger`), preset parsing
  (`BKPreset*`, Foundation plist code - Apple-side by nature, keep).
- **Metal-specific (correctly thin):** `BKVolumeRenderer.m` pipelines/dispatch,
  `BKVolumeTexture.m` upload (chunked blit), `BKVolumeScene.m:343` frame encoding.
- **Rule violations left:**
  - rule 1: `BKVolumeRenderer.m:291-380` camera frame, view size, slab/clip normals,
    step size, all in Objective-C with `simd`; `BKVolumeCamera.m` (whole file);
    `BKVolumeScene.m:152-160` (box corners via N3); `BKVolumeScene.m:330`
    (`renderSizeForTargetSize`).
  - rule 1: `BKVolumeTexture.m:109-171` uses Accelerate (`vDSP_*`) - fine on Apple, the
    portable twin is now `BKRenderQuantizeToSteps` (tested identical).
  - rule 5: no CPU reference ray caster.
- **Shaders (`BKShaderSource.mm`):** compute only; one 3D texture + one 2D table + plain
  buffers. Optional features: linear filtering of R16_UNORM 3D (fallback: manual, new),
  linear filtering of R32G32B32A32_SFLOAT (fallback: manual, new), RGBA8 storage writes
  to the drawable (see finding 8). `bk_upscale` samples RGBA8 linearly (core in Vulkan).
- **LGPL:** `BKVolumeRenderer.h:25`, `BKVolumeTexture.h:27`, `BKVolumeCamera.h:18`
  (N3 types); `BKVolumeRenderer.m:18`, `BKVolumeScene.m:15`, `BKVolumeTexture.m:14`
  (`CPRVolumeData`); `BKVolumeScene.m:152` (`N3AffineTransformInvert`).

### BorosKitDisplay (2D image layer, overlays, on-screen views)

- **Backend-neutral already:** `BKDisplayShaderTypes.h` (now explicit 32-bit, size
  checked), `BKViewTransform` (C functions, but CoreGraphics types).
- **Metal-specific:** `BKImageLayerRenderer.m` (texture upload 188-193, colour table
  220-241, render pass), `BKImageView.m` / `BKVolumeView.m` (CAMetalLayer views - stay
  per-platform; Windows/Linux need their own window code).
- **Rule violations left:** rule 1: `BKImageLayerRenderer.m` `paramsWithScale`
  (view-to-image inverse, window maths) and the colour-table expansion belong in C;
  `BKViewTransform` should use plain doubles. `BKOverlay` draws with CoreGraphics (Apple
  only): on Windows/Linux overlays need another 2D drawing route (to be decided; not a
  GPU-backend question).
- **Shader (`BKDisplayShaderSource.mm`):** full-screen triangle + fragment shader,
  `texelFetch`-style reads only (bilinear by hand), so no optional filtering needed.
  Vulkan: flip y (negative viewport height).
- **LGPL:** `BKImageLayerRenderer.h:19` (`N3Vector` origin/row/column),
  `BKOverlay.h:21` + `BKOverlay.m:14/271-292` (`N3BezierPath`, `N3VectorApplyTransform`),
  `BKVolumeView.h/.m` (N3 crop/clip API).

### BorosKitMesh (meshes, smoothing, decimation, files, scene export)

- **Backend-neutral already:** `BKMeshProcessingCore.cpp/.h` (Taubin smoothing, quadric
  decimation, normals; deterministic, multithreaded through `BKParallelFor`),
  `BKSceneExportCore.cpp/.h` (OBJ/MTL, VRML, Inventor, RIB writers), `BKParallel.h`.
  These are the model for the rest.
- **Rule violations left:** rule 1: `BKMesh.mm` geometry and `BKMeshIO.mm` parsing (finding
  10); public API in Apple `simd` types and `BOOL` fields in `BKSceneMaterial` (host-only,
  fine for the Apple API, but the C++ core needs its own).
- **LGPL:** `BKMesh.h:27` (`N3AffineTransform` convenience methods, `BKMesh.mm:166-178`).
- **No GPU code.** For Vulkan only a CMake build is needed (plus the precision flag).

### BorosKitMeshRender (drawing meshes and lines)

- **Backend-neutral already:** `BKMeshShaderTypes.h` (std430/std140-compatible),
  `BKMeshUnprojectPixel` (C, but Apple `simd` types).
- **Metal-specific:** `BKMeshRenderer.m` pipelines (blend, depth, 2 colour targets).
- **Rule violations left:** rule 1: `BKMeshRenderer.m:336-358` (camera frame, duplicate of
  the volume renderer's), `451-510` (scene depth range, transparent sorting),
  `540-566` (projection sizes), `604` (normal matrix) - all should be one C "frame plan"
  function; rule 5: no CPU reference rasteriser (picking maths is shared).
- **Shader (`BKMeshShaderSource.mm`):** vertex/fragment; derivatives for flat normals
  (core in Vulkan), lines as quads (no wide-line feature needed), packed float3 point
  buffer (read as a float array in GLSL). Vulkan: flip y, D32_SFLOAT depth, rasteriser
  sub-pixel precision may differ by GPU (edge pixels; covered by the outlier allowance).
- **LGPL:** `BKMeshRenderer.h:143-145` (`N3Vector` camera properties).

### BorosKitSurface (GPU marching cubes)

- **Backend-neutral already:** everything that matters - `BKSurfaceCore.c/.h` (generated
  table, plan, prefix sum, exact CPU reference), `BKSurfaceShaderTypes.h` (std430). It
  already had PORTING NOTES and a manual sampling path. **This is the best first module
  to port.**
- **Metal-specific (thin):** `BKSurfaceExtractor.m`.
- **Rule violations left:** finding 9 (runtime workgroup size; values16 array outside the
  helper); `BKSurfaceExtractor.m:206` reads `volume.volumeTransform` (an N3 type, only
  its fields); header copyright lines.
- **Optional features:** linear filtering of R16_UNORM 3D (fallback: manual sampling, exists).

---

## 4. Optional Vulkan features BorosKit relies on

| Feature | Used by | Vulkan status | Fallback |
|---|---|---|---|
| Linear filtering of R16_UNORM 3D images | ray caster, surface sampling at resolution < 1 | optional format feature (`SAMPLED_IMAGE_FILTER_LINEAR`) | manual trilinear: `BKVolumeRenderer.manualFiltering` (new), `BKSurfaceSamplingManualTrilinear` (exists) |
| Linear filtering of R32G32B32A32_SFLOAT | ray caster colour table | optional | manual 2-entry blend (new, same switch) |
| 8-bit / 16-bit values in storage buffers | (was) volume shader | optional (`storageBuffer8/16BitAccess`) | removed: 32-bit words only (`377c53c`); Surface packs 16-bit by hand |
| Compute writes to the swapchain image | 3D view | optional (storage usage of the surface format) | ray-cast into an RGBA8 storage image, then copy/draw |
| Wide lines | - | optional | not used: lines are drawn as quads |
| Linear filtering of R32_SFLOAT | - | optional | not used: 2D display interpolates by hand |
| 3D image size 2048 per side | volume texture | Vulkan guarantees only 256 (`maxImageDimension3D`); desktop GPUs give 2048+ | check the limit; refuse or bricking for larger scans |
| Push constants > 128 bytes | - | guaranteed only 128 | all parameter blocks go in small buffers (display params, 80 bytes, may use push constants) |
| Subgroup operations | - | optional detail | not used (scan uses shared memory) |

The 3D-size row is new: Metal allows 2048 per side on all Apple GPUs; Vulkan only
guarantees 256, so the Vulkan backend must read `maxImageDimension3D` and say so clearly.

---

## 5. Code that still depends on the LGPL (Horos-derived) files

The LGPL files are `CPRVolumeData`, `CPRGenerator*`, the CPR operations, `N3Geometry`,
`N3Bezier*` (BorosKitCore). Not rewritten now, as agreed. New code on this branch
(`BKRenderCore`, the golden harness) does **not** use them; the harness touches N3 only
by building `N3Vector` values to call the existing public API.

| File | What it uses |
|---|---|
| `BorosKitCore/include/BKClipPlanes.h`, `BKClipPlanes.m` | `N3Plane`, `N3Vector` in the whole API |
| `BorosKitRender/include/BKVolumeRenderer.h`, `BKVolumeRenderer.m` | N3 camera/slab/crop/clip properties; `-setVolumeData:(CPRVolumeData *)` |
| `BorosKitRender/include/BKVolumeTexture.h`, `BKVolumeTexture.m` | `N3AffineTransform volumeTransform`; `-initWithVolumeData:` (the new float initializer avoids it) |
| `BorosKitRender/include/BKVolumeCamera.h`, `BKVolumeCamera.m` | all maths: `N3VectorNormalize/CrossProduct/Add/ScalarMultiply/...` |
| `BorosKitRender/include/BKVolumeScene.h`, `BKVolumeScene.m` | `-setVolumeData:`, `N3AffineTransformInvert`, `N3VectorApplyTransform` (`:152-156`) |
| `BorosKitDisplay/include/BKImageLayerRenderer.h` | `N3Vector` origin/row/column of `BKImage` |
| `BorosKitDisplay/include/BKOverlay.h`, `BKOverlay.m` | `N3BezierPath`, `N3VectorApplyTransform` (`:271-292`) |
| `BorosKitDisplay/include/BKVolumeView.h`, `BKVolumeView.m` | N3 crop box / clip plane API |
| `BorosKitMesh/include/BKMesh.h`, `BKMesh.mm` | `N3AffineTransform` conversion methods |
| `BorosKitMeshRender/include/BKMeshRenderer.h`, `BKMeshRenderer.m` | `N3Vector` camera properties |
| `BorosKitSurface/BKSurfaceExtractor.m:206` | reads `volume.volumeTransform` fields |
| Tests: Accuracy, Render, Display, Mesh, Core, Surface tests | `CPRVolumeData` to build volumes, N3 types |

Most uses are the plain structs `N3Vector`/`N3Plane`/`N3AffineTransform` (the latter is
Apple's `CATransform3D`). Real N3 *functions* are used by `BKVolumeCamera.m`,
`BKVolumeScene.m`, `BKOverlay.m`, `BKClipPlanes.m`. Suggested order: introduce BorosKit's
own `BKVec3d` / `BKPlane` / `BKMat4d` first (plain C, licence-free), switch the BorosKit
APIs to them (with small converters in the app), then rewrite N3 itself last.

---

## 6. Proposed backend abstraction (small C++ GPU interface)

Goal: the module code (surface extraction, ray casting, mesh drawing, 2D display) is
written **once** against a small interface; `MetalDevice` and `VulkanDevice` implement it.
Only what BorosKit actually uses, nothing more.

```cpp
// boroskit/gpu/BKGPU.h  (plain C++17, no Metal / Vulkan headers)
namespace boroskit::gpu {

enum class Format { R16Unorm, R32Float, RGBA8Unorm, BGRA8Unorm, RGBA32Float, Depth32Float };
enum class Memory { DeviceOnly, Upload, Readback };      // private / shared(write) / shared(read)
enum Usage : uint32_t { Sampled = 1, Storage = 2, RenderTarget = 4, CopySrc = 8, CopyDst = 16 };

struct Limits {                         // filled by the backend at start-up
    uint64_t maxBufferBytes, memoryBudgetBytes;
    uint32_t maxImage3D, maxWorkgroupInvocations;
    bool linearFilterR16Unorm3D, linearFilterRGBA32Float, storageWriteToSwapchain;
};

class Buffer  { public: virtual ~Buffer() = default; virtual uint64_t size() const = 0;
                virtual void *map() = 0; virtual void unmap() = 0; };
class Texture { public: virtual ~Texture() = default; virtual uint32_t width() const = 0;
                virtual uint32_t height() const = 0; virtual uint32_t depth() const = 0;
                virtual Format format() const = 0; };

struct Sampler { bool linear; bool normalizedCoords; };   // always clamp-to-edge in BorosKit

struct Binding {                        // one slot of a kernel / draw
    enum Kind { BufferSlot, TextureSlot, StorageTextureSlot, SmallConstant } kind;
    uint32_t slot; Buffer *buffer = nullptr; Texture *texture = nullptr;
    Sampler sampler{}; const void *bytes = nullptr; uint32_t byteCount = 0;  // <= 4 KB
};

class ComputePipeline { public: virtual ~ComputePipeline() = default;
                        virtual uint32_t workgroupSize() const = 0; };
struct RenderPipelineDesc { const char *vertex, *fragment; Format color[2]; uint32_t colorCount;
                            bool depth, premultipliedBlend, depthWrite; };
class RenderPipeline { public: virtual ~RenderPipeline() = default; };

struct RenderTarget { Texture *color[2]; uint32_t colorCount; Texture *depth;
                      bool clear; float clearColor[2][4]; float viewport[4]; };

class CommandList {
public:
    virtual ~CommandList() = default;
    virtual void upload(Texture &dst, const void *data, uint32_t rowBytes, uint32_t imageBytes,
                        uint32_t z0, uint32_t slices) = 0;               // staging handled inside
    virtual void copyToBuffer(Texture &src, Buffer &dst) = 0;           // readback
    virtual void dispatch(ComputePipeline &, const Binding *, uint32_t count,
                          uint32_t groupsX, uint32_t groupsY, uint32_t groupsZ) = 0;
    virtual void barrier() = 0;                                         // compute -> compute/copy
    virtual void beginRenderPass(const RenderTarget &) = 0;
    virtual void draw(RenderPipeline &, const Binding *, uint32_t count, uint32_t vertexCount,
                      Buffer *indices = nullptr, uint32_t indexCount = 0) = 0;
    virtual void endRenderPass() = 0;
};

class Device {
public:
    virtual ~Device() = default;
    virtual const Limits &limits() const = 0;
    virtual std::unique_ptr<Buffer>  makeBuffer(uint64_t bytes, Memory) = 0;
    virtual std::unique_ptr<Texture> makeTexture(Format, uint32_t w, uint32_t h, uint32_t d, uint32_t usage) = 0;
    virtual std::unique_ptr<ComputePipeline> makeCompute(const char *kernelName, uint32_t workgroupSize) = 0;
    virtual std::unique_ptr<RenderPipeline>  makeRender(const RenderPipelineDesc &) = 0;
    virtual std::unique_ptr<CommandList> begin() = 0;
    virtual int submit(CommandList &, bool wait) = 0;                   // 0 = ok, else a status code
};

std::unique_ptr<Device> makeMetalDevice(void *mtlDevice);   // Objective-C++ file
std::unique_ptr<Device> makeVulkanDevice(int adapterIndex); // C++ file, Vulkan loader only
}
```

Design choices, in plain words:

- **Status codes, not exceptions**, like `BKSurfaceStatus` today (simple across C, C++,
  Objective-C).
- **Bindings by slot number**, one table per kernel. Both backends map slot numbers the
  same way (Metal `[[buffer(n)]]`/`[[texture(n)]]`; Vulkan one descriptor set, binding n).
- **Small constant blocks** (<= 4 KB) are copied in (`setBytes` on Metal; a ring buffer or
  push constants on Vulkan).
- **No argument buffers, indirect commands, mesh shaders, bindless** (rule 3).
- The on-screen part (CAMetalLayer, Vulkan swapchain, window systems) stays *outside*
  this interface: views ask the device for a texture to render into and present it
  themselves.
- The existing Objective-C classes (`BKVolumeRenderer`, `BKSurfaceExtractor`, ...)
  remain the Apple API; internally they become thin wrappers over the shared C++ module
  code + `MetalDevice`. Port one module at a time (section 8), checking the golden
  harness in strict mode after each step.

---

## 7. How to share the GPU programs between Metal and Vulkan

Options considered:

| Option | How | For | Against |
|---|---|---|---|
| A. Twin files + checker | Hand-write MSL and GLSL separately; a test compiles both and the golden harness compares results | Simple; Metal untouched | Two copies of every algorithm drift apart; every fix twice |
| B. One source, translated by tools | Write GLSL/HLSL, compile to SPIR-V, translate to MSL with SPIRV-Cross / Apple's converter | One source | Third-party tools in the build; the Metal reference itself would become generated code and must be re-validated; harder to read and debug on the Mac |
| **C. Shared kernel bodies + thin per-backend entry points (recommended)** | The maths (ray tracing, marching-cubes steps, shading) is written once in a restricted C-like subset (`.bksl` text files, or the existing string pieces). Each backend adds a short prelude that maps the subset's names onto its language, plus hand-written entry points (the kernel signatures and bindings, ~10-20 lines each) | One copy of the algorithms; Metal code stays readable and is still the reference; no third-party tools in the product; it extends what BorosKit already does for the parameter structs (macro text pasted into both) | Needs discipline: a written subset and a compile check |

**Recommendation: C**, because it keeps a single copy of the algorithms (the part that
must match), keeps the Metal reference human-readable and unchanged in behaviour, and adds
no dependencies. Rules for the shared subset:

- types only through names that both preludes define: `bk_float2/3/4`, `bk_uint2/3/4`,
  `bk_int3`, `bk_float3x3`, `bk_float4x4` (MSL: `float3`...; GLSL: `#define bk_float3 vec3`);
- no references, pointers or address-space words (`device`, `constant`, `thread`) inside
  shared functions: parameters by value; buffers/textures reached through macros that each
  prelude defines (`BK_PARAMS.field`, `BK_READ_VOLUME(x,y,z)`, `BK_SAMPLE_VOLUME(coord)`,
  `BK_TABLE(i)`), because GLSL cannot pass buffers to functions;
- no methods on objects (`tex.sample(...)`): only those macros;
- no `half`, no `bool` in memory, no 3-vectors in memory, no implicit int/float mixing;
- only built-ins that exist with the same meaning in both: `min max clamp mix floor ceil
  fract abs sqrt dot cross normalize length` (`mix`, not `lerp`); `rint` maps to
  `roundEven`; `fabs` to `abs`; `popcount` to `bitCount`;
- workgroup memory, barriers and scans only inside named helpers
  (`bk_workgroup_exclusive_scan`), each with its Vulkan twin in the GLSL prelude;
- loops with plain integer counters; no recursion; no function pointers.

Checker: a unit test that assembles each GLSL kernel and compiles it with `glslangValidator`
(when installed) plus the existing GPU/CPU struct-size tests, plus the golden harness. The
small render shaders (2D display, mesh drawing; ~100 lines each) can stay as twin files
(option A) if the subset makes them awkward: they are short and fully covered by golden
images.

---

## 8. Port order

0. **Foundations.** CMake build of the plain C/C++ cores on Windows/Linux (`BKSurfaceCore.c`,
   `BKRenderCore.c`, `BKMeshProcessingCore.cpp`, `BKSceneExportCore.cpp`, the golden core);
   a C++ golden runner reading `Tests/BorosKitGoldenTests/References`; precision flags fixed
   (finding 1); the GPU interface (section 6) with a Metal implementation behind the
   existing classes; a Vulkan device skeleton tested under MoltenVK on this Mac.
1. **BorosKitMesh cores** (CPU only): build, run, compare the golden meshes and export bytes.
   Quick win; proves the precision flags.
2. **BorosKitSurface** (compute only, exact CPU reference already there): first real Vulkan
   module. Golden check: identical triangle lists, positions within 1e-4 voxel.
3. **BorosKitRender** ray caster, after the camera/params C core (refactors R2, R3) and the
   neutral geometry types (R1). Golden check: 8-bit images within +-1, values per the
   precision policy.
4. **BorosKitDisplay** 2D image layer (one full-screen draw; simple).
5. **BorosKitMeshRender** (raster pipeline: depth, blending, 2 targets).
6. **On-screen presentation** on Windows/Linux (swapchain, resize, interaction), adaptive
   quality (`BKVolumeScene`), overlays (needs a 2D drawing choice, not CoreGraphics).
7. **CPR / panorex** once the LGPL CPR engine is rewritten.

---

## 9. Big jobs left (not done here on purpose)

| # | Job | Why not now |
|---|---|---|
| R1 | BorosKit's own neutral geometry types (`BKVec3d`, `BKPlane`, `BKMat4d`) in Core; public APIs switched from N3 (with converters for the app) | API change across all modules and the app |
| R2 | One C camera core (frame building, ortho/perspective sizes, VTK-style moves, depth range, unproject) used by `BKVolumeRenderer`, `BKMeshRenderer`, `BKVolumeCamera` | Apple `simd_normalize` vs plain C may differ in the last bit: needs a deliberate re-record |
| R3 | Parameter builders in C: `fillParams` -> `BKRenderParamsFill(settings, &params)`; same for `BKMeshUniforms` and `BKDisplayParams` | Follows R1/R2 |
| R4 | `BKMesh` geometry and `BKMeshIO` parsing into the C++ core; `BKMesh` a thin wrapper | Large; needs its own tests |
| R5 | Move `BKParallel.h` to Core; use it in the Surface CPU reference and the render core | Include-path change across targets |
| R6 | Shader sharing (section 7) + GLSL compile check | Design step with the Vulkan work |
| R7 | GPU interface + Metal implementation behind the existing classes | Start with Surface |
| R8 | CPU reference ray caster (projection modes, manual filtering) | New code, ~300 lines + tests |
| R9 | Precision policy: Metal fast math off, manual filtering for HU-exact outputs, explicit `-ffp-contract`, then re-record | Changes outputs slightly (measured: within tolerance) - user decision |
| R10 | LGPL rewrites (CPRVolumeData, CPRGenerator*, N3Geometry, N3Bezier*) | Agreed for later |
| R11 | `BKViewTransform` on plain doubles; overlays' 2D drawing route for Windows/Linux | With the display port |
| R12 | Header provenance lines on 43 files; decision on the copyright lines in BorosKitSurface | Needs the copyright decision |
| R13 | Surface kernels: workgroup size as a specialization constant; fold `values16` into a helper | With the Surface port |

---

## 10. The golden-output harness

**What it is:** a test target (`Tests/BorosKitGoldenTests`) that builds fixed synthetic
scans, runs every BorosKit GPU operation on them with fixed settings, and compares the
results with reference files recorded from Metal. A Vulkan backend will be checked
against the **same files with the same tolerances**.

**Files:**

| File | Role |
|---|---|
| `BKGoldenCore.h/.c` | Plain C, reusable as is by a Vulkan runner: noise generator and hash (written for this project), the phantom, all case settings, image/mesh containers, PAM/PFM/mesh/number files, comparers |
| `BKGoldenMetal.h/.m` | The Metal "producer": runs each case through the real classes |
| `BKGoldenTests.m` | The XCTest runner (compare / record / strict) |
| `References/` | 35 reference files + `MANIFEST.txt` (size and hash of each), **2.0 MB in total** |

**The phantom** ("head", 64 x 64 x 48 voxels of 1 x 1 x 1.25 mm, centred on 0): air
around a soft-tissue ellipsoid (40 HU), a fat ball (-100), a bone ball (1000), a dense
"metal" ball (2500), a cylinder (400), a 5-step wedge (-500/0/250/600/1200), a curved
"jaw" tube (1500 HU) with a "nerve canal" (300 HU), partial-volume edges (2x2x2
sub-samples) and 15 HU noise from a fixed seed, rounded to whole HU. It uses only
+ - * / sqrt floor and is compiled with `-ffp-contract=off`, so it is bit-identical on
any platform; its hash is the first reference a port must match.

**What is covered:**

| Operation | Cases | Stored as |
|---|---|---|
| 3D volume render (composite) | front ortho, perspective oblique, left side unlit with a clip plane and skipping off | RGBA8 `.pam` + accumulated opacity `.pfm` |
| MIP / MinIP / average slabs, thin MPR | axial MIP 10 mm, axial MinIP 10 mm, coronal average 20 mm, oblique thin slice, full perspective MIP | RGBA8 `.pam` + HU `.pfm` |
| 2D image layer | nearest fit; linear + colour table + zoom/pan/rotate/flip + coloured background; linear inverted rotated flipped | RGBA8 `.pam` |
| Surface extraction | bone 300 HU, skin -500 HU (full resolution), bone at resolution 0.5 with smoothing and manual sampling | `.bkmesh` (positions, normals, triangles) |
| Mesh processing (CPU) | Taubin smoothing x10, 50% decimation of the bone surface | `.bkmesh` |
| Mesh render | bone ortho (solid), bone perspective (see-through 0.6) | RGBA8 `.pam` + ray distance `.pfm` |
| Scene export | ball + moved see-through box + outline + camera + background, all 4 formats | the files themselves (byte compare) |
| Numbers | phantom hash/stats; volume storage scale; baked colour table (hash + samples); surface plan; camera moves | `numbers_*.txt` |

Extra checks in the same target: CPU reference extractor vs Metal (both full-resolution
surfaces: identical triangles, 3e-6 voxel), GPU-stored volume vs the plain-C conversion
(identical), empty-space skipping on vs off (identical), smoothing/decimation 1 thread vs
all threads (identical), manual vs hardware filtering (finding 1), and a self-test showing
the comparers reject out-of-tolerance differences and the file formats round-trip.

**Tolerances (as agreed):** 8-bit images: every channel within +-1 grey level, except at
most 0.5% of channels (edge pixels); float images: 1 HU, 1/255 opacity, 0.01 mm ray
distance, same 0.5% allowance; meshes: same counts and identical triangle lists, positions
within 1e-4 voxel, normals within 1e-3; export files: byte-identical; numbers: 1e-6
relative. Cross-filter comparisons (manual vs hardware) use 1/256 of the value range for
float HU values (finding 1).

**How to run** (from the BorosKit folder):

```sh
# compare with the references (part of the normal test run)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release --filter BKGoldenTests

# zero tolerance: proves a refactor changed nothing at all
BK_GOLDEN_STRICT=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release --filter BKGoldenTests

# re-record after an INTENDED change (then review `git diff References/MANIFEST.txt`)
BK_GOLDEN_RECORD=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release --filter BKGoldenTests
```

Each comparison prints a line starting with `GOLDEN |` (largest difference, number of
pixels beyond tolerance). Images can be opened with GIMP or ImageMagick (`.pam`, `.pfm`
are standard Netpbm formats).

**How a Vulkan backend plugs in:** build `BKGoldenCore.c` into a small C++ test program
(CMake), write a Vulkan producer with the same six operations as `BKGoldenMetal.h`
(volume render, 2D image, surface, mesh render, volume read-back; the CPU mesh steps and
the export reuse the C++ cores), point it at `Tests/BorosKitGoldenTests/References`, and
call the same `bk_golden_compare_*` functions. First check: the phantom hash.

---

## 11. Tools needed

- **This Mac (now):** Xcode (as today). For the Vulkan path: the LunarG **Vulkan SDK for
  macOS**, which includes **MoltenVK** (Vulkan on top of Metal), the loader, validation
  layers and `glslangValidator`/`glslc`. Enable `VK_KHR_portability_enumeration`.
  MoltenVK runs on the same Apple GPU, so it checks the Vulkan *code*, not other GPU makers'
  rounding - real Windows/Linux GPUs (NVIDIA, AMD, Intel) are still needed before release.
- **Windows / Linux:** CMake (3.24 or newer), **clang** on all platforms (clang-cl on
  Windows) so floating-point behaviour matches the Mac, the **Vulkan SDK** (headers,
  loader, validation layers, `glslc`/shaderc or `glslangValidator`, `spirv-val`). Shaders
  are compiled to SPIR-V at **build** time and embedded as byte arrays; at run time only the
  Vulkan loader is needed, which comes with the graphics driver (it plays the role
  Metal.framework plays on the Mac; not a dependency BorosKit ships).
- **Build flags for the cores:** C99/C++17, `-ffp-contract=off` (or the agreed setting,
  identical everywhere), no `-ffast-math`.
- **Licences:** the SDK tools are only used to build; nothing from them is copied into
  BorosKit. No new libraries are linked into BorosKit.

## 12. NVIDIA (CUDA) and AMD support (user request 2026-11-14)

The user asked for CUDA support on NVIDIA cards and optimisation for AMD cards. Decisions and plan:

**Licence rule first.** CUDA (toolkit, runtime, cuDNN, TensorRT) is NVIDIA's proprietary software
under NVIDIA's licence and runs only on NVIDIA GPUs. BorosKit must stay licence-free and have no
third-party dependencies, so CUDA never goes into BorosKit itself.

- **Drawing and imaging (BorosKit):** Vulkan on every vendor (NVIDIA, AMD, Intel) through the GPU
  interface of section 6. Vulkan already reaches full speed on NVIDIA for this kind of work, so
  rendering does not need CUDA.
- **AI (BorosAI plug-in, outside BorosKit):** an optional, separately downloaded "accelerator pack":
  CUDA (cuDNN / TensorRT) on NVIDIA, ROCm/HIP (MIOpen) on AMD, and Core ML / Metal on Apple. The
  plug-in picks the best one present and falls back to the plain path (Vulkan compute or CPU) when
  none is installed. The core app runs and gives the same results without any vendor pack.
- **Optional CUDA compute backend for BorosKit operations (later, only if measurements show a real
  gain over Vulkan compute, e.g. very large surface extraction or registration):** it would be one
  more implementation of the section-6 GPU interface, shipped as a separate optional module, never
  required, and validated by the same golden harness.

**Vendor tuning inside the Vulkan backend** (chosen at start-up from `VkPhysicalDeviceProperties`
vendorID and subgroup properties; results must stay inside the golden tolerances on every vendor):

| Topic | AMD | NVIDIA | Intel / other |
|---|---|---|---|
| Subgroup (wave) size | 64 on GCN, 32 or 64 on RDNA: request with `VK_EXT_subgroup_size_control` and size workgroups as a multiple | 32 | query, default 32 |
| Workgroup sizes | specialization constants per vendor (fixes audit item R13: no run-time-chosen sizes) | same mechanism | same |
| Scan upload | device-local + host-visible memory (Resizable BAR / SAM) when offered, so the CPU writes the scan straight into GPU memory | same when offered | staging buffer |
| Overlap | async compute queue for surface building / brick pass while the graphics queue draws | same | single queue if no separate compute family |
| Precision | 16-bit maths (packed FP16) only where the golden tolerances still pass (e.g. colour blending, not HU values) | same | same |
| 3D textures | optimal tiling, R16_UNORM; manual trilinear path where linear filtering of R16 / R32F is missing (section 4) | same | same |

**Testing:** the golden harness (section 10) runs per vendor (NVIDIA, AMD, Intel, and MoltenVK on
the Mac). Speed tuning may never move results outside the agreed tolerances. Real NVIDIA and AMD
machines are needed for this; MoltenVK only exercises the Apple GPU.

Note: the vendor details above are from general knowledge, not from looking anything up (the user
asked for no web search); verify them on real hardware when the Vulkan backend is built.

### 12.1 GPU preference: which card draws (added 2026-11-14)

Macs (and PCs) can have several GPUs: integrated + discrete laptops, Mac Pro, external GPUs,
NVIDIA + AMD in one PC. The user picks the card in Boros 6 Settings > General "Graphics card";
it is stored as user default `BorosPreferredGPU` = the card **name** (`""` = Automatic). A name,
not an index or registry id, because it stays the same across restarts and backends.

- **One chooser for every backend:** `BKGPUChoiceCore.h` (plain C, BorosKitRender). The backend
  lists its adapters as `BKGPUAdapterDesc {name, vendorID, kind, isLowPower, isRemovable, handle,
  memoryBytes}` and calls `BKGPUChooseAdapter(list, count, preference, &status)`. Exact name match,
  else Automatic: real GPU before software (CPU) renderer, built-in before removable (an eGPU only
  when chosen), discrete/high-performance before integrated/low-power, more memory, then a
  deterministic tie-break. A chosen card that is not present (unplugged eGPU) falls back to
  Automatic and the status says so (Boros 6 logs it).
- **Metal today:** `BKMetalDevice` (MTLCopyAllDevices -> descriptions). Every BorosKit class that is
  given no device uses `+[BKMetalDevice preferredDevice]`; no `MTLCreateSystemDefaultDevice` is left
  in the package outside BKMetalDevice itself (iOS, or no device list). Unit tests: `BKGPUChoiceTests`.
- **Vulkan later:** one `BKGPUAdapterDesc` per `VkPhysicalDevice`: `deviceName`, `vendorID`
  (0x10DE NVIDIA, 0x1002 AMD, 0x8086 Intel), `deviceType` DISCRETE/INTEGRATED/VIRTUAL/CPU -> `kind`,
  DEVICE_LOCAL heap size -> `memoryBytes`; same function, same preference string (details in the
  header's PORTING NOTES). Two identical cards share a name; if that ever matters, extend the
  preference (e.g. deviceUUID) while keeping `""` and plain names working.
- **CUDA / ROCm accelerator packs (section 12):** read the same `BorosPreferredGPU` and match it
  against the name their runtime reports, so AI runs on the card that draws; Automatic among their
  own cards when the preferred card is another vendor's.
- Applies to windows opened after the change. Objects that share GPU data must be made on the same
  device (a texture of one card cannot be used by another), so app-wide GPU workers are kept per
  card and a window keeps the card it started on.

## 13. Objects inside the volume picture (added 2026-11-14)

What: opaque meshes / lines / points (e.g. the 3D window's 3D point balls) are hidden by bone in
front of them and hide bone behind them, like VTK's GPU ray caster with geometry.
How (Metal, to copy as is):
1. `BKVolumeGeometryLayer` (protocol, BorosKitRender) / `BKMeshGeometryLayer` (BorosKitMeshRender)
   draws the objects with the volume's camera into two images: RGBA8 colour premultiplied by
   opacity, and R32F ray distance in mm (+infinity = nothing), measured like the ray parameter t
   of `bk_trace` (orthographic: from the image plane along the view; perspective: from the eye).
2. The ray-cast kernels read both images at slots 3 / 4 (`p.useGeometry`, the former `reserved1`
   field: the parameter block is still 464 bytes). Composite: the ray ends at the object, then
   `color += (1 - alpha) * geomColor`. MIP / MinIP / average: objects laid over. The slab drops
   objects outside it; crop planes do not cut objects (both as in VTK).
Vulkan: same two images; a pipeline barrier (COLOR_ATTACHMENT_WRITE -> SHADER_READ, fragment ->
compute) between the object pass and the ray-cast (Metal orders them inside one command buffer).
Tests: `Tests/BorosKitMeshTests/BKVolumeGeometryTests.m` (ball in front seen, behind hidden, half
buried, outside the scan, empty pictures change nothing, slab, MIP, scene thumbnails exclude).

## 14. Rule clarification: no Apple simd in cores (2026-11-14)

Plain-C/C++ cores (BKCameraMath, BKBoxWidgetMath, BKCropBoxCore, BKMeshDrawCore, BKRenderCore ...)
must not use Apple `<simd/simd.h>`: it does not exist on Windows/Linux. An older licence note said
"use simd instead of the LGPL N3 types"; that was about leaving N3 behind, not a portability rule.
Cores use BorosKit's own neutral vector types (to be added: BKVec3d / BKVec3f / BKMat4, step R1);
simd stays only in Objective-C / Metal glue. DONE 2026-11-14: new pure-C target BorosKitVec (BKVec.h: BKVec2f/3f/3d/4f + static inline maths;
its own target because a C file importing BorosKitCore pulls in Objective-C headers). BKCameraMath,
BKBoxWidgetMath, BKCropBoxCore and BKMeshDrawCore (incl. BKCameraProjectPoint) now use it; Apple glue
converts with BorosKitRender/include/BKVecSimd.h. Their tests use BKVec too. Check: all five cores
(+ BKRenderCore) compile with `clang -std=c99 -pedantic -Werror -fno-modules` and no Apple headers.
Full suite 244 tests passed, golden references unchanged. Still open from R1: BKPlane / BKMat4d.
