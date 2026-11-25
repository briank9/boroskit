# BorosKit Vulkan readiness audit - 2026-11-24

Original BorosKit document written for this project.

Read-only audit by agent "vulkan-kickoff". BorosKit at `29ecaec` (branch `agent/vulkan-kickoff`,
same commit as `test/overlay-engine`); Boros 6 native views at boros6 `820fc0818`. Line numbers are
as of those commits. Rules checked: VULKAN-PORT-PLAN.md rules 1-7 + L, section 14 (no Apple simd in
cores), and the follow-up audit VULKAN-PREP-AUDIT-2026-11-14.md. The step-by-step plan that follows
from this audit is VULKAN-ENGINE-KICKOFF.md.

## In plain words

BorosKit is in good shape for a second engine in one important way: almost all of the *maths* now
lives in small plain-C/C++ files (26 of them) that compile without any Apple code, and the GPU
parameter blocks already have the memory layout Vulkan needs. What is missing is the *middle
layer*: every BorosKit module still talks to Metal directly from Objective-C, the GPU programs
exist only as Metal text, and some settings blocks are still filled in by Objective-C code. Also,
the new native 3D windows in Boros 6 contain some behaviour (mouse feel, the 3D scissors cut, the
stereo picture, text over the 3D picture) that a Windows/Linux program would have to copy by hand
unless it moves into BorosKit first. None of this is hard to fix, but it must be done before the
first Vulkan picture is compared with Metal's, or the two engines will drift apart.

## Contents

1. How the audit was done (and a re-runnable check)
2. Top findings, ranked (blockers first)
3. Module-by-module audit
4. Shader inventory (there are no `.metal` files)
5. GPU struct check list (std430 / std140 / sizes / pins)
6. Apple types and simd in the plain-C/C++ cores
7. Objective-C-only APIs that need a backend-neutral layer
8. Licence / provenance headers
9. Test coverage per core
10. Boros 6 native views (since 2026-11-17): logic that should move into BorosKit
11. Status of the 2026-11-14 "top 10 preparation steps"
12. Other agents working in parallel (what they touch)

---

## 1. How the audit was done

- Every source and header under `Sources/` (169 files, 7 targets) read or grepped for: Metal API
  use, `simd_`, `N3*`/`CPRVolumeData`, CoreGraphics/CoreText, GCD/`pthread`, Accelerate, shader
  source strings and their Metal-only constructs, every `setBytes`/`newBuffer...` (all CPU->GPU
  data), workgroup-size choices.
- GPU structs measured with clang's record-layout dump (`-Xclang -fdump-record-layouts`), so the
  sizes and offsets in section 5 are what the compiler really does, not what the comments say.
- New read-only script **`docs/tools/check-portable-cores.sh`** (committed with this audit):
  compiles every `*.c` core as strict C99 (`-std=c99 -pedantic -Werror -fno-modules`) and every
  `*.cpp` core as C++17 with the portable thread path (`-DBK_PARALLEL_USE_STD_THREAD=1`), and lists
  any Apple / non-Windows header a core pulls in. It writes nothing. Run it from the BorosKit folder:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh docs/tools/check-portable-cores.sh`.
  Result today: 24 of 26 cores clean; 1 does not compile as strict C99, 1 needs pthreads (Windows problem) - section 6.
- Boros 6 native views read at `820fc0818` with `git show` (no checkout, nothing changed there).
- Tests counted from source: **343 XCTest methods** (Render 142, Mesh 87, Display 59, Surface 21,
  Accuracy 13, Golden 12, Core 9), **36 golden reference files**. The suite was not re-run by this
  agent (docs-only task; other agents are building); last recorded full run in the notes: all passed.
- This Mac: macOS 26.6.2, Apple M1 Pro, Xcode 27.2, CMake 4.4.5 (Homebrew). **No Vulkan SDK,
  no glslang/glslc, spirv-cross, spirv-val, slangc or dxc installed** - needed before milestone 1.

---

## 2. Top findings, ranked

Blocker = must be fixed before the first Vulkan-vs-Metal comparison. Size: S < 1 session,
M 1-2 sessions, L 3+ sessions (a "session" = one long working session of Claude, plus user test).

| # | Finding | Where | Kind | Size |
|---|---|---|---|---|
| 1 | **No GPU interface.** Every module creates pipelines, buffers and command encoders directly in Objective-C Metal code; there is nothing a second backend can plug into (plan R7). | `BKVolumeRenderer.m` (library + pipelines 150-185, dispatch 472-760), `BKMeshRenderer.m` (440-930), `BKSurfaceExtractor.m` (130-430), `BKImageLayerRenderer.m` (100-360), `BKOverlayRenderer.mm` (85-192), `BKCurvedReformat.mm` (130-243) | Blocker | L |
| 2 | **GPU parameter blocks are filled by Objective-C + Apple simd, and the camera frame is built three times** (not via the existing plain-C `BKCameraMath`). A Vulkan backend would have to copy this code, and the copies would drift (plan R2/R3). | `BKVolumeRenderer.m:348-436` (`fillParams`, simd normalize/cross at 370-382, perspective size 388-395); `BKMeshRenderer.m:532-547` (frame), `797-830` (uniforms), `899` (normal matrix via `simd_inverse`), `1000` (fov again), `969` (`BKMeshUnprojectPixel` duplicates `BKCameraRayThroughViewPoint`); `BKImageLayerRenderer.m:259` (`paramsWithScale`), `223` (LUT expansion) | Blocker (milestone 1 needs the mesh one) | M |
| 3 | **Shaders exist only as Metal text inside 7 `.mm` files**, no shared bodies, no GLSL, no build step for SPIR-V (plan R6). | section 4 | Blocker | L |
| 4 | **GPU struct headers are not plain C:** `BKShaderTypes.h:29` includes `<simd/simd.h>` and `:31` includes `BKClipPlanes.h`, which `#import`s the LGPL Objective-C `N3Geometry.h` (`BKClipPlanes.h:16`) just to get `BK_MAX_CLIP_PLANES` (6); `BKMeshShaderTypes.h:40` includes simd. Only `BKDisplayParams` has a `_Static_assert`; no struct has offset pins; `BKOverlayParams` is written twice by hand (MSL `BKOverlayRenderer.mm:30-35`, C `:74-79`). | section 5 | Blocker (small) | S |
| 5 | **The 3D view writes the ray-cast straight into the screen image from a compute kernel**, and the 3D windows' text and cube are separate Core Animation layers composited by macOS. Vulkan: compute writes to swapchain images are optional (BGRA8 storage usually missing), and there is no layer compositor. | `BKVolumeView.m:117-120` (`framebufferOnly = NO`), `BKShaderSource.mm:473-475` (`bk_raycast_texture`, `access::write target`); `BorosNativeOverlay.mm:90-98` (CoreGraphics text layer), `355-374` (cube in its own `CAMetalLayer`) | Blocker for on-screen, not for milestone 1 | M |
| 6 | **Two cores do not compile as portable C:** `BKVolumeRayCore.c:53` uses `size_t` without including `<stddef.h>` (works in Xcode only because modules leak it; fails `-std=c99 -fno-modules`); `BKSurfaceCore.c:25,119,259,265` uses `pthread_once` (no pthreads with MSVC/clang-cl on Windows). `BKParallel.h` still lives inside BorosKitMesh, so other cores cannot use the one parallel helper (plan R5). | `check-portable-cores.sh` output | Blocker for CMake build | S |
| 7 | **Workgroup sizes chosen at run time from the Metal pipeline** (`maxTotalThreadsPerThreadgroup`, `threadExecutionWidth`) and read in the kernel via `threads_per_threadgroup`. Vulkan fixes `local_size` when the pipeline is built (plan R13). | `BKSurfaceExtractor.m:147-152` (`BKRowThreads`), `231-235` (`BKDispatchPairs`); `BKSurfaceShaderSource.mm:239-244` | Blocker for surface port | S |
| 8 | **No plain-C test runner; all 343 tests are Objective-C XCTest**, so none of the core tests can run on Windows/Linux. Golden gaps: mesh lines/points/textures/culling, rotated crop planes, `useClip`, view slab, on-screen path (`bk_raycast_texture` + `bk_upscale`), curved reformat, 2D overlay engine, preset->TF numbers. | `Tests/` | Blocker for "same tests on both" | M |
| 9 | **CPU floating-point contraction not pinned for the cores.** Only the golden test target gets `-ffp-contract=off` (`Package.swift:185-187`); the cores compile with Apple clang's default (`on`). GCC/MSVC differ, so mesh smoothing/decimation and TF bakes can differ in the last bit and flip decimation decisions (plan finding 1 / R9, CPU half still open). GPU half is done: shaders compile with `MTLMathModeRelaxed` (`BKMetalDevice.m:42-45`), which keeps INF/NaN correct but still allows re-association - see the kickoff plan, risk table. | `Package.swift` | Blocker for golden on Windows/Linux | S (+ user decision to re-record) |
| 10 | **Behaviour that must be identical on every platform still lives in the Boros 6 native views**, not in BorosKit: mouse/wheel feel differs between the three 3D windows, the 3D scissors cut, the picking opacity table, stereo mixing, the ROI-to-3D mask, text over the 3D picture. Detail in section 10. | `BorosVolumeNativeView.mm`, `BorosSurfaceNativeView.mm`, `BorosROIVolumeNativeView.mm`, `BorosROIShapes.mm`, `BorosNativeOverlay.mm` | Must move before BorosCMF/Windows needs it | M-L |

Further findings (not blockers):

- 11. LGPL types in public BorosKit APIs: 22 non-Horos files still use (5 more mention N3 only in comments) `N3Vector`/`N3Plane`/
  `N3AffineTransform`/`CPRVolumeData` (largest: `BKVolumeCamera.m` 43 uses, `BKVolumeRenderer.m` 20,
  `BKVolumeRenderer.h` 14, `BKOverlay.m` 12, `BKVolumeScene.m` 12). Not a Vulkan blocker (the Vulkan
  backend only needs the cores), but the Objective-C API cannot be reused off Apple, and the native
  views keep feeding `CPRVolumeData` (section 10). Plan R1/R10.
- 12. 3D texture size limit hard-coded to 2048 (`BKVolumeTexture.m:43-45`, `90-91`); Vulkan only
  guarantees 256 (`maxImageDimension3D`). Must become a device limit.
- 13. Accelerate `vDSP_*` in `BKVolumeTexture.m:109-110` (min/max) and `167-171` (quantise). Portable
  twin `BKRenderQuantizeToSteps` exists and is proven identical; min/max has none (trivial).
- 14. `BKVolumeScene.m:15-60` quality ladder is C but typed with `NSArray`/`NSInteger`;
  `renderSizeForTargetSize` (`:353`) and WL drag (`:254`) are Objective-C. Frame planning for
  adaptive quality is needed identically on both backends.
- 15. Preset -> transfer function maths in Objective-C: `BKTransferFunction.m:113-140` (VTK 255/254
  spacing quirk), `BKPreset.m:112-152` (opacity y*y). Must be one C core, or Vulkan pictures of the
  same preset will differ.
- 16. Mesh draw ordering (transparent sort, `BKMeshRenderer.m:725`) and vertex packing (`:159-186`)
  in Objective-C (`BKMeshDrawCore` exists and is a natural home).
- 17. `BKViewTransform` is C but uses `CGFloat`/`CGAffineTransform` (`BKViewTransform.h`).
- 18. Text for overlays is rasterised by CoreText/CoreGraphics in Apple glue (`BKTextOverlay.m`,
  `BKOverlay.m`, `BorosNativeOverlay.mm`); `BKOverlayCore` takes text as finished pictures. Windows/
  Linux need their own glyph source - a licence decision (kickoff plan, section 9).

---

## 3. Module-by-module audit

### BorosKitVec (2 files)
- Pure C99, header-only maths (`BKVec2f/3f/3d/4f`, `BKMat4d*` helpers). Clean in the check script.
- Missing from plan R1: `BKPlane`, `BKMat4f` (GPU matrices are float), `BKOnce` (portable one-time
  init to replace `pthread_once`), and a home for `BKParallelFor` (R5) - this target is the natural
  place for all four, since every core already depends on it.
- 3 of 29 inline functions not referenced by tests (`BKV3dDiv`, `BKV3f`, `BKV3fDot`).

### BorosKitCore (30 files)
- Neutral: none of its own except `BKClipPlanes` maths - and that is Objective-C (`BKClipPlanes.m`,
  `BOOL`/`NSUInteger`, N3 types, 18 N3 uses). `BK_MAX_CLIP_PLANES` sits in this header, which is why
  the GPU struct header drags in N3 (finding 4).
- Everything else is the Horos-derived LGPL CPR/N3 engine (rewrite agreed for later, R10).
- Rule 6: CPR operations use `NSOperationQueue` (to be rewritten anyway).

### BorosKitRender (52 files) - volume ray caster, camera, presets, curves, slab, GPU choice
- Neutral and clean (strict C99, no Apple headers): `BKRenderCore`, `BKCameraMath`, `BKBoxWidgetMath`,
  `BKCropBoxCore`, `BKCurveCore`, `BKCurvedReformatCore`, `BKGPUChoiceCore`, `BKOrientationCubeCore`,
  `BKScanGeometryCore`, `BKSlabCameraCore`, `BKSlabGeometryCore`, `BKStereoCore`.
  `BKVolumeRayCore` - one missing include (finding 6).
- Metal-specific (to become thin): `BKVolumeRenderer.m`, `BKVolumeTexture.m`, `BKVolumeScene.m`
  (frame encoding `:426-460`), `BKCurvedReformat.mm`, `BKMetalDevice.m`.
- Rule 1 violations left: findings 2, 12-15; `BKVolumeCamera.m` (whole file, N3 maths; its moves
  duplicate `BKCameraMath`).
- Rule 4 (optional features): manual filtering exists (`manualFiltering`); still needed for Vulkan:
  R16_UNORM 3D linear filter, RGBA32F linear filter, 3D size limit, storage-image writes (finding 5).
- Rule 3: compute only, simple bindings, no argument buffers / ICBs / mesh shaders. Good.

### BorosKitDisplay (33 files) - 2D image, 2D overlay engine, ROI maths, on-screen views
- Neutral and clean: `BKOverlayCore`, `BKROICore`, `BKROIDraw`, `BKAngleCore`, `BKTextLayoutCore`,
  `BKViewMatrix`, `BKViewOverlayDraw`, `BKViewPenState`. These are the best-prepared part of BorosKit
  for Vulkan: `BKOverlayCore` already outputs one triangle list + commands with a CPU reference
  rasteriser.
- Metal-specific: `BKImageLayerRenderer.m`, `BKOverlayRenderer.mm` (two tiny shaders), `BKImageView.m`
  and `BKVolumeView.m` (CAMetalLayer views - per platform by nature).
- Apple-only drawing: `BKOverlay.m` (CoreGraphics + N3BezierPath, used for the 3D mirror text),
  `BKTextOverlay.m` (CoreText). For Vulkan: route everything through `BKOverlayCore` (gl-2d-final
  agent's direction) and add a glyph source (finding 18).
- Rule 1 left: `BKImageLayerRenderer.m:223-279` (LUT + params), `BKViewTransform` (CG types).

### BorosKitMesh (14 files) - meshes, smoothing, decimation, file reading, scene export
- Neutral and clean (C++17, portable thread path): `BKMeshProcessingCore.cpp`,
  `BKSceneExportCore.cpp`, `BKParallel.h` (GCD on Apple, `std::thread` otherwise - correct).
- Rule 1 left (plan R4): `BKMesh.mm` (normals, welding, area/volume, primitives) and `BKMeshIO.mm`
  (STL/PLY/OBJ parsing, 791 lines) are Foundation + simd. A Windows/Linux BorosCMF needs these.
- No GPU code: needs only a CMake build + precision flag.

### BorosKitMeshRender (13 files) - drawing meshes, lines, points, crop box, orientation cube
- Neutral: `BKMeshDrawCore.c` (clean), `BKMeshShaderTypes.h` layout (header not plain C, finding 4).
- Metal-specific: `BKMeshRenderer.m` (two colour targets, premultiplied blend on target 0 only,
  write mask off on target 1 for see-through passes `:605-621`, D32 depth, CCW front face `:791`),
  `BKOrientationCube.m`, `BKCropBox.m`, `BKMeshGeometryLayer.m`.
- Rule 1 left: finding 2 and 16. Vertex data is fetched by `vertex_id` from a buffer of
  `packed_float3`/`packed_float4` (`BKMeshShaderSource.mm:41-45`, `:107`, `:212`, `:268`) - easy to copy
  in Vulkan as a std430 `float[]` storage buffer (no vertex-input layouts needed).

### BorosKitSurface (7 files) - GPU marching cubes
- Neutral: `BKSurfaceCore.c` (generated tables, plan, prefix sum, exact CPU reference) - one
  Windows problem (`pthread_once`, finding 6). `BKSurfaceShaderTypes.h` is the model header (plain C,
  `bk_u32`, `__METAL_VERSION__` guard, size test incl. GPU).
- Metal-specific: `BKSurfaceExtractor.m`; finding 7 (run-time workgroup size); `:207` still reads
  the N3 `volumeTransform` fields.
- Copyright lines reported on 2026-11-13 are gone (none found today).
- Still the best first *compute* module to port (exact CPU reference).

---

## 4. Shader inventory

There are **no `.metal` files**. All GPU programs are Metal Shading Language text inside
Objective-C++ files, compiled at run time with `newLibraryWithSource:` and
`[BKMetalDevice shaderCompileOptions]` (Relaxed math by default since 2026-11-14).

| Source file | Entry points | Kind | Shareable maths (option C, kickoff plan section 3) |
|---|---|---|---|
| `BorosKitRender/BKShaderSource.mm` (577 lines) | `bk_raycast` :450, `bk_raycast_texture` :473, `bk_upscale` :495, `bk_brick_ranges` :510, `bk_classify_bricks` :539, `bk_params_size` :568 | compute | `bk_sample`, `bk_transfer`, `bk_gradient`, brick helpers, `bk_trace`, `bk_geometry_at` |
| `BorosKitRender/BKCurvedReformat.mm` (243) | `bk_curved_reformat` :96 | compute | `bkr_fetch`, `bkr_sample` (already written to `BKCurvedReformatCore` definitions, texelFetch only) |
| `BorosKitSurface/BKSurfaceShaderSource.mm` (386) | `bk_surface_sample` :154, `bk_surface_blur` :177, `bk_surface_classify` :230, `bk_surface_emit` :291, `bk_surface_params_size` :378 | compute | all bodies; scan helper `bk_workgroup_exclusive_scan` :101-118 |
| `BorosKitMeshRender/BKMeshShaderSource.mm` (301) | `bk_mesh_vertex` :96, `bk_mesh_vertex_textured` :105, `bk_mesh_fragment` :162, `bk_mesh_fragment_distance` :173, `bk_mesh_fragment_textured` :182, `bk_mesh_fragment_distance_textured` :188, `bk_line_vertex` :212, `bk_line_fragment` :248, `bk_line_fragment_distance` :254, `bk_point_vertex` :268, `bk_mesh_uniforms_size` :292 | vertex / fragment | `bk_project`, `bk_view_depth`, shading, ray distance, line/point expansion |
| `BorosKitDisplay/BKDisplayShaderSource.mm` (119) | `bk_display_vertex` :42, `bk_display_fragment` :64 | vertex / fragment | `bk_read`, window/LUT |
| `BorosKitDisplay/BKOverlayRenderer.mm` (192) | `bk_overlay_vertex` :43, `bk_overlay_fragment` :55 | vertex / fragment | tiny; GLSL already written in the comment `:12-17` |

Total: 6 shader sources (the volume library is one string assembled from pieces), 27 entry points
(4 of them only report a struct size for tests).

Metal-only constructs and their Vulkan equivalents:

| Construct | Where | Vulkan / GLSL |
|---|---|---|
| `constexpr sampler` (linear, clamp) | `BKShaderSource.mm:203-204`, `:500` | immutable sampler in the descriptor set layout, or a separate sampler binding |
| `texture2d<float, access::write>` | `BKShaderSource.mm:475` (screen), `:496` | `image2D` with `writeonly`, format qualifier `rgba8`; target must be a storage image, not the swapchain (finding 5) |
| `texture3d<float, access::read>` / `.read()` | `BKCurvedReformat.mm:38-96`, `BKDisplayShaderSource.mm:54` | `texelFetch` on `sampler3D` / `sampler2D` (or `image3D` `imageLoad`) |
| `threadgroup` arrays + `threadgroup_barrier` | `BKSurfaceShaderSource.mm:104-117`, `:243-244`, `:267-270` | `shared` arrays + `barrier()` (plus `memoryBarrierShared()`) |
| `[[threads_per_threadgroup]]` used as a value | `BKSurfaceShaderSource.mm:239` | `gl_WorkGroupSize` (a constant: needs a specialization constant, finding 7) |
| `packed_float3` / `packed_float4` buffers | `BKMeshShaderSource.mm:42-44`, `:107`, `:212`, `:268` | std430 `float` arrays, index `*3` / `*4` |
| `[[vertex_id]]`, `[[stage_in]]`, `[[color(1)]]` | mesh/display/overlay shaders | `gl_VertexIndex`, `layout(location)` varyings, `layout(location = 1) out` |
| `dfdx` / `dfdy` | `BKMeshShaderSource.mm:126` | `dFdx` / `dFdy` (core) |
| `rint` | `BKSurfaceShaderSource.mm:77`, `:168`, `:197`; `BKShaderSource.mm:529` | `roundEven` |
| `thread T &` out-parameters | scan helper, `bk_trace` | `inout` / `out` |
| `INFINITY`, `isinf` (ray misses, "no object" sentinel) | volume + mesh shaders | `1.0/0.0` constant or `uintBitsToFloat(0x7f800000)`; `isinf` (SPIR-V `IsInf`); keep fast math off in the GLSL compile |
| y up in clip space, `[[position]]` origin | all render shaders | negative viewport height (core since 1.1) or flip in the vertex shader |
| run-time compile from source | all 6 | SPIR-V compiled at build time, embedded as `uint32_t` arrays |

Not used anywhere (good): argument buffers, indirect command buffers, mesh/tile shaders, function
pointers, raytracing, SIMD-group functions (only mentioned in a comment, `BKSurfaceShaderSource.mm:101`),
atomics in shaders, half precision.

---

## 5. GPU struct check list

Sizes/offsets from the clang record layout (Apple arm64; same on x86_64 because only 4-byte scalars
and 16-byte vectors are used). "Shared text" = the field list is written once and pasted into both C
and the shader (the macro trick).

| Struct | Size / align | std430 | std140 | Shared text | Header plain C | Size pinned | Offsets pinned | Action |
|---|---|---|---|---|---|---|---|---|
| `BKRenderParams` (`BKShaderTypes.h`) | 464 / 16: 15 x vec4 (0-240), `clipPlanes[6]` vec4 (256-351), 16 floats (352-415), 2 uint + 10 int (416-463) | OK | OK (arrays of vec4 keep stride 16) | yes | **no** (simd + BKClipPlanes/N3) | CPU == Metal only (`BKVolumeRendererTests.m`) | no | own `bk_float4` typedef (`float[4]` aligned 16 in C, `float4` in MSL, `vec4` in GLSL); move `BK_MAX_CLIP_PLANES` into this header; `_Static_assert` size + `offsetof` of every 16-byte boundary |
| `BKMeshUniforms` (`BKMeshShaderTypes.h`) | 272 / 16: 2 x mat4 (0-127), 5 x vec4 (128-207), 8 floats, 4 int, 4 floats (incl. padding) | OK | OK | yes | **no** (simd) | CPU == Metal only (`BKMeshRendererTests.m`) | no | same as above; matrices as `float[16]` column-major in C |
| `BKMeshGPUVertex` | 40 / 4: `float[3]`, `float[3]`, `float[4]` | OK as `float[]` storage buffer (stride 40) | n/a | MSL `BKMeshVertexIn` hand-written (`BKMeshShaderSource.mm:41-45`) | yes | **none** | no | `_Static_assert(sizeof == 40)`; GLSL reads `float v[]` at `i*10` |
| line / point buffer | 12-byte stride `float[3]` | OK as `float[]` | n/a | - | yes | none | - | document (done in PORTING NOTES) |
| texture coordinates | 8-byte stride `float[2]` | OK | n/a | - | yes | none | - | - |
| `BKDisplayParams` (`BKDisplayShaderTypes.h`) | 80 / 4: 20 x 4-byte scalars | OK | OK | yes | yes | `_Static_assert` | no | add offsets; fits push constants (<= 128) |
| `BKSurfaceParams` (`BKSurfaceShaderTypes.h`) | 336 / 4: float/uint arrays + scalars | OK | **no** (arrays of scalars get stride 16) | yes | yes | yes, C and GPU (`BKSurfaceTableTests.m:207-208`, `BKSurfaceExtractorTests.m:452`) | no | bind as std430 storage buffer only (documented) |
| `BKReformatParams` (`BKCurvedReformatCore.h`) | 64 / 4: 16 x 4-byte scalars | OK | OK | yes | yes | no | no | add `_Static_assert` |
| `BKReformatFrame` | 48 / 4: 3 x `float[4]` | OK (vec4 stride 16) | OK | MSL reads `float4*` | yes | no | no | `_Static_assert` |
| `BKOverlayVertex` (`BKOverlayCore.h`) | 32 / 4: `float[2]` pos, `float[2]` uv, `float[4]` colour | OK (as vertex attributes or `float[]`) | n/a | MSL `BKOverlayVertexIn` hand-written (`BKOverlayRenderer.mm:22-26`) | yes | no | no | `_Static_assert(32)` |
| `BKOverlayParams` | 24 / 8 in MSL (`float2,float2,int,int`), C copy `BKOverlayParamsCPU` 24 / 4 | OK (vec2 align 8, offsets 0/8/16/20 match) | OK | **no - two hand copies** (`BKOverlayRenderer.mm:30-35` vs `:74-79`) | C copy yes | no | no | move to a shared field-list macro in `BKOverlayCore.h`; push constants in Vulkan |
| brick grid constant | `uint4` 16 bytes (`BKVolumeRenderer.m:476`) | OK | OK | n/a | simd in Obj-C | - | - | plain `uint32_t[4]` in the builder |
| background colour constant | `float4` 16 (`BKVolumeRenderer.m:729`) | OK | OK | n/a | simd | - | - | fold into `BKRenderParams` reserve or a 16-byte push constant |
| brick range / empty lists | `uint` per brick | OK | n/a | - | - | - | - | - |
| surface output | positions/normals `float4` (16 B), indices `uint` x 3 (`BKSurfaceExtractor.m:401-403`) | OK | n/a | - | - | tested via mesh | - | - |
| ray-cast outputs | RGBA8 as `uint` words, values `float` (`BKVolumeRenderer.m:618-619`) | OK (32-bit words only since `377c53c`) | n/a | - | - | golden | - | - |

Rule-2 summary: **every struct already has a std430-compatible layout**; no `float3`, no `bool`, no
8/16-bit types in GPU memory. What is missing is (a) plain-C headers for the two biggest blocks,
(b) compile-time size *and offset* pins (a CPU == Metal size test cannot catch a layout that both
compilers agree on but GLSL does not), (c) one shared definition for the overlay block and the two
vertex structs. `BKSurfaceParams` must never be bound as a std140 uniform buffer.

---

## 6. Apple types and simd in the plain-C/C++ cores

Output of `docs/tools/check-portable-cores.sh` at `29ecaec`:

- **Clean (24):** BKAngleCore, BKOverlayCore, BKROICore, BKROIDraw, BKTextLayoutCore, BKViewMatrix,
  BKViewOverlayDraw, BKViewPenState, BKMeshDrawCore, BKBoxWidgetMath, BKCameraMath, BKCropBoxCore,
  BKCurveCore, BKCurvedReformatCore, BKGPUChoiceCore, BKOrientationCubeCore, BKRenderCore,
  BKScanGeometryCore, BKSlabCameraCore, BKSlabGeometryCore, BKStereoCore, BKVec, and the C++ cores
  BKMeshProcessingCore, BKSceneExportCore (with `BK_PARALLEL_USE_STD_THREAD=1`).
- **Problem:** `BKVolumeRayCore.c:53` - `size_t` undeclared (add `#include <stddef.h>` to
  `BKVolumeRayCore.h`).
- **Problem (Windows):** `BKSurfaceCore.c` includes `<pthread.h>` for `pthread_once` (`:25`, `:119`,
  `:259`, `:265`) - replace with a `BKOnce` helper or build the tables eagerly.
- No core includes `<simd/simd.h>`: section 14 of the port plan is fully done for the `.c` files.
  `simd` remains in the **GPU struct headers** (finding 4) and in 13 public Objective-C headers
  (expected: Apple glue), and `BKVecSimd.h` is the agreed converter.

Also checked: no core uses `dispatch_*`, Accelerate, CoreGraphics or Objective-C.

---

## 7. Objective-C-only APIs that need a backend-neutral layer

What a Windows/Linux build needs from each, and where it should live:

| Today (Apple only) | Neutral piece still inside it | Neutral home (proposed) |
|---|---|---|
| `BKVolumeRenderer` | params builder, step size, skipping decision, workgroup grid, read-back formats | `BKRenderParamsFill()` in `BKRenderCore` + a C++ `RaycastPass` on the GPU interface |
| `BKVolumeTexture` | min/max, quantisation (twin exists), chunk plan, 3D limit check, brick grid size | `BKRenderCore` (+ device limits) |
| `BKVolumeScene` | quality ladder, render size, frame budget, WL drag, advanced-curve fit | new `BKFramePlanCore` (C) |
| `BKVolumeCamera` | all camera moves (duplicate of `BKCameraMath`, N3) | `BKCameraMath` (extend), `BKVolumeCamera` becomes a wrapper |
| `BKTransferFunction`, `BKPreset` | TF evaluation from presets (255/254 rule, y*y opacity, grey ramp) | `BKRenderCore` (bake already there) + new preset-to-points function |
| `BKPresetLoader` | plist parsing | stays Apple-side; a Windows build needs a reader for the same keys (later, with the app port) |
| `BKMeshRenderer` | camera frame, uniforms, depth range, transparent ordering, normal matrix, unproject/pick | `BKMeshDrawCore` (`BKMeshUniformsFill`, ordering) + `MeshPass` |
| `BKMesh`, `BKMeshIO` | geometry and STL/PLY/OBJ parsing | C++ core (plan R4) |
| `BKSurfaceExtractor` | dispatch sequence, buffer sizes (plan exists in `BKSurfaceCore`) | `SurfacePass` |
| `BKImageLayerRenderer`, `BKViewTransform` | view->image matrix, LUT expansion, display params | `BKDisplayParamsFill()` in a display core (on `BKViewMatrix`) |
| `BKOverlayRenderer` | none (already thin) | `OverlayPass` |
| `BKTextOverlay`, `BKOverlay` | text layout (partly in `BKTextLayoutCore`), glyph pictures | glyph source per platform + `BKOverlayCore` |
| `BKImageView`, `BKVolumeView` | presentation (CAMetalLayer, drawable, present) | per-platform `Surface` (kickoff plan section 2) |
| `BKMetalDevice` | GPU choice (already `BKGPUChoiceCore`), compile options | `Device` interface |
| `BKCurvedReformat` | already thin over `BKCurvedReformatCore` | `ReformatPass` |
| `BKCropBox`, `BKOrientationCube` | maths already in cores | wrappers over `MeshPass` |

---

## 8. Licence / provenance headers

- No LGPL header outside the Horos-derived CPR*/N3* files (the only other hit, `BKVec.h:10`, is a
  sentence saying N3 is LGPL). No "Copyright" line anywhere outside the Horos files.
- **63 non-Horos files lack the provenance line** "Original BorosKit code written for this project;
  contains no third-party code." (was 43 on 2026-11-13; new tests and older Render/Display/Mesh files):
  BKClipPlanes.h/.m; Display: BKDisplayShaderSource.mm, BKDisplayShaderTypes.h, BKImageLayerRenderer.h/.m,
  BKImageView.h/.m, BKOverlay.h/.m, BKViewTransform.h/.m, BKVolumeView.h/.m, BorosKitDisplay.h;
  Mesh: BKMesh.h/.mm, BKMeshIO.h/.mm, BorosKitMesh.h; MeshRender: BKMeshRenderer.m,
  BKMeshShaderSource.mm, BKMeshShaderTypes.h, BorosKitMeshRender.h; Render: BKBoxWidgetMath.c/.h,
  BKCameraMath.c/.h, BKPreset.h/.m, BKPresetLoader.h/.m, BKShaderSource.mm, BKShaderTypes.h,
  BKTransferFunction.h/.m, BKVolumeCamera.h/.m, BKVolumeRenderer.h/.m, BKVolumeScene.h/.m,
  BKVolumeTexture.h/.m, BKVolumeTexture+Bricks.h, BorosKitRender.h; Tests: the 4 Accuracy test files,
  BKPhantom.h/.m, BKClipPlanesTests.m, BKDisplayTests.m, BKVolumeViewTests.m, BKMeshRendererTests.m,
  BKMeshTests.m, BKBoxWidgetMathTests.m, BKCameraMathTests.m, BKEmptySpaceSkippingTests.m,
  BKPresetTests.m, BKVolumeRendererTests.m, BKVolumeSceneTests.m.
  The line is a statement of fact that must be true: whoever adds it should confirm each file was
  written for this project (they all appear to be, from their history and content).
- Headers without a PORTING NOTES / VULKAN section (rule 7): BKImageLayerRenderer.h, BKImageView.h,
  BKOverlay.h, BKViewTransform.h, BKVolumeView.h, BKParallel.h, BKMesh.h, BKMeshIO.h,
  BKMeshProcessing.h, BKSceneExport.h, BKVolumeTexture+Bricks.h, BKPreset.h, BKPresetLoader.h,
  BKTransferFunction.h, BKVecSimd.h, BKVolumeCamera.h, BKVolumeScene.h (+ 3 umbrella headers). Most
  pre-date rule 7.
- Third-party *code* found: none. Boros 6 native views call Horos (LGPL) helpers and ITK
  (Apache-2.0) - section 10.

---

## 9. Test coverage per core

Public functions declared in each core header vs. referenced anywhere in `Tests/` (script in the
audit session; C++ cores are covered through their Objective-C++ wrappers' tests):

| Core | Covered | Not referenced by any test |
|---|---|---|
| BKROICore | 22/22 | - |
| BKViewOverlayDraw | 7/7 | - |
| BKViewPenState | 3/3 | - |
| BKMeshDrawCore | 6/6 | - |
| BKCropBoxCore | 11/11 | - |
| BKCurvedReformatCore | 3/3 | - |
| BKGPUChoiceCore | 2/2 | - |
| BKScanGeometryCore | 9/9 | - |
| BKSlabGeometryCore | 3/3 | - |
| BKStereoCore | 2/2 | - |
| BKVolumeRayCore | 2/2 | - |
| BKViewMatrix | 12/13 | BKViewMatricesLoad |
| BKBoxWidgetMath | 16/17 | BKBoxFaceNormal |
| BKCameraMath | 10/11 | BKRotateVectorAroundAxis |
| BKCurveCore | 17/19 | BKCurvePolylinePlaneIntersections, BKCurveSegmentDerivative |
| BKSlabCameraCore | 16/18 | BKSlabCameraAxes, BKSlabCameraDirection |
| BKOverlayCore | 14/17 | BKOverlayFillTriangles, BKOverlayListImages, BKOverlayStrokeSegments |
| BKOrientationCubeCore | 14/17 | the 3 default-colour getters |
| BKRenderCore | 8/10 | BKRenderTFEvaluate, BKRenderTFGetRGBA (used inside the bake, not directly) |
| BKSurfaceCore | 8/12 | BKSurfaceGridTransform, BKSurfaceOutputBytes, BKSurfacePlanSetBlurAxis, BKSurfaceStatusMessage |
| BKTextLayoutCore | 3/4 | BKTextLayoutAnchorPoint |
| BKAngleCore | 4/5 | BKAngleLineCrossing |
| BKROIDraw | 13/20 | BKROIDrawAllHandles, BKROIDrawDots, BKROIDrawHandles, BKROIDrawLayer, BKROIDrawLine, BKROIDrawTAGT, BKROIDrawTextROI |
| BKVec | 26/29 | BKV3dDiv, BKV3f, BKV3fDot |
| BKMeshProcessingCore, BKSceneExportCore | via BKMeshProcessingTests (+ golden), BKSceneExportTests (+ golden byte compare) | - |

"Referenced" is not "fully tested", but the picture is good: every core has a test file; the gaps
are small and listed. The real gap is that **all of it is XCTest/Objective-C** (finding 8); only
`BKGoldenCore.c` is reusable as-is on Windows/Linux.

---

## 10. Boros 6 native views: logic that should move into BorosKit

Files at boros6 `820fc0818`: `BorosVolumeNativeView.mm` (2749 lines), `BorosSurfaceNativeView.mm`
(1689), `BorosROIVolumeNativeView.mm` (606), `BorosROIShapes.mm` (267), `BorosNativeOverlay.mm` (433).
They are good Mac glue: most maths already calls BorosKit cores (BKScanGeometryCore, BKCameraMath,
BKVolumeRayCore, BKStereoCore, BKCameraFindBallNear, BKOrientationCubeCore). The items below are
behaviour a Windows/Linux program (BorosCMF) would otherwise have to re-create by hand, and that the
golden harness cannot check while it lives in the app. Ranked:

| # | What | Where (boros6 820fc0818) | Why it matters for the second backend | Proposed home |
|---|---|---|---|---|
| N1 | **Mouse/wheel feel differs between the three 3D windows** (same tool, different maths): wheel zoom `1 + deltaY/100` (volume, `BorosVolumeNativeView.mm:1488`) vs `1 + scrollingDeltaY/100` (surface, `BorosSurfaceNativeView.mm:823`) vs `1.21^steps` (ROI volume, `BorosROIVolumeNativeView.mm:438`); drag zoom `pow(1.01, -dy)` (volume `:1401`) vs `BKTrackballDollyFactor` (surface `:800`, ROI `:415`); spin `dx*0.5` degrees (volume `:1402`) vs `BKTrackballSpinDegrees` (surface `:801-802`); yaw/pitch `-d/5` degrees (volume `:1359`) | the same user action must feel the same in every window and on every platform; today it cannot be tested | `BKInteractionCore` (C): tool + pointer delta (+ wheel/trackpad kind) -> camera operation, constants in one table, tested; views only translate events |
| N2 | **3D scissors cut**: outline filled with CoreGraphics into a screen mask (`:2139-2155`), every voxel projected with its own copy of the projection maths (`:2156-2219`, a self-check against `BKCameraProjectPoint` at `:2183-2193` proves it is a duplicate), parallel with `dispatch_apply` (`:2196`); outline smoothed with Horos `spline()` from LGPL `ROI.m` (`:2072`) | real image-editing maths, Apple-only, untested, partly LGPL-derived; BorosCMF needs exactly this kind of cut | `BKVolumeCutCore` (C): own polygon fill (even-odd/non-zero, written from the definition), voxel->screen via BKCameraMath, `BKParallelFor`; smoothing via `BKCurveCore`; CPU reference + tests (later a GPU kernel) |
| N3 | **Picking opacity table rebuilt in the app** (`:1571-1583`): 4096 entries over `controller minimumValue..maximumValue`, separately from the table the GPU uses (`BKRenderTFBake`, range `tfMin..tfMax`) | the spot picked can disagree with what is drawn; would differ again on Vulkan | call the same bake (`BKRenderCore`) for both the GPU and `BKVolumeRayCore` |
| N4 | **Stereo red/blue: GPU -> CPU -> mix -> upload -> blit every frame**: surface `:1332-1376` (incl. RGBA->BGRA swap loop `:1366`, `replaceRegion`), volume `:2668-2730` (RGB->RGBA copies `:2690-2698`, two full renders + read-backs) | slow, and the Vulkan backend would need the same read-back path; eye cameras built twice (`eyeCamera:` surface `:1317-1329`; volume `:2668-2679`) | eye cameras from `BKStereoCore` (exists); compose on the GPU (one tiny full-screen pass) behind the GPU interface; CPU `BKStereoComposeRedBlue` stays the reference |
| N5 | **Text and cube over the 3D picture are three separate layers** composited by Core Animation (CoreGraphics text layer `BorosNativeOverlay.mm:90-98`, cube `CAMetalLayer` `:355-374`); captures re-composite on the CPU with CoreGraphics text + a hand "over" loop (`:389-433`) | a Vulkan window has one swapchain image and no compositor; captures must match the screen | draw text + cube into the same frame through `BKOverlayCore` (one overlay pass) - joins the gl-2d-final agent's direction for 2D |
| N6 | **ROI outlines -> 3D mask uses Horos code**: `DCMPix fillROI:` (`BorosROIShapes.mm:79`), `roiMorphingBetween:` (`:150`), and the mask is wrapped in `CPRVolumeData` (`:85`) | LGPL-derived rasterisation feeds a BorosKit mesh; BorosCMF will need ROI->mesh | `BKROICore` already has masks (`BKROIMaskRuns` etc.): add "outline set -> 3D mask" + contour morphing as a core, CPU reference vs the recorded Horos masks |
| N7 | **Volumes reach BorosKit only as `CPRVolumeData` (LGPL)**: `BorosVolumeNativeView.mm:632-638`, `BorosSurfaceNativeView.mm:566`, `BorosROIShapes.mm:85` | keeps the LGPL type in the native path; `BKVolumeTexture -initWithFloatVoxels:` (neutral) already exists | switch to the float-voxel + plain matrix upload (`BKScanGeometryCore` gives the matrix) |
| N8 | **Camera conventions repeated per view**: standard views (`BorosVolumeNativeView.mm:965-981`, `BorosSurfaceNativeView.mm:664-676`, `BorosROIVolumeNativeView.mm:357-380`), framing box incl. 3D points (`:939-953`), "eye stays in the scan" in slab mode (`:955-963`, wheel `:1478-1486`), classic camera units mm x `factor` for saved states / fly-through (`:1079-1200`, surface `:1259-1283`), movie-frame camera (`:2426-2434`, surface `:1486`) - all in N3 maths | the same saved 3D state must open identically in every window and platform | `BKCameraMath` additions: `BKCameraStandardView`, `BKCameraFrameBox`, `BKCameraClampEyeToBox`, classic-units converters; views call them |
| N9 | **Small helpers copied three times**: `simd_float4x4` from `double[16]`, grid->local, placement (`BorosSurfaceNativeView.mm:52-71`, `BorosROIShapes.mm:24-41`, volume `:1543-1552`/`:2156-2160`), orientation letters (`BorosSurfaceNativeView.mm:74-90`, `BorosVolumeNativeView.mm:100-118`) | drift risk only | one Boros 6 glue file (app side) - not BorosKit |
| N10 | **Bone removal uses ITK** (`BorosVolumeNativeView.mm:2256`, `ITKSegmentation3D`) | third-party (ITK is Apache-2.0, not part of BorosKit); a Windows build would need ITK or a core | later: own 3D region growing + morphology core (BorosCMF segmentation tools need it anyway); keep ITK in the Mac app until then |
| N11 | Captures (`renderRGBWidth:` `:2310-2346`, `getRawPixels` `:2359-2392`) render + read back + flip on the CPU per view | fine on Mac; a Vulkan app needs the same "render offscreen, read back" path, which the GPU interface provides | GPU interface readback; no app change needed now |

None of these break the Mac app today. N1-N5 should be done **before** the Vulkan backend draws the
3D windows (phase 6+ of the kickoff plan); N6-N8 before BorosCMF uses them; N9-N11 whenever touched.
The files belong to other agents right now (vr-colour-fusion owns `BorosVolumeNativeView.*`), so these
are recommendations for after the current merges, not changes made here.

---

## 11. Status of the 2026-11-14 "top 10 preparation steps"

| 2026-11-14 step | Status at 29ecaec |
|---|---|
| 1 Neutral vector header; cores off simd | **Done** (BorosKitVec, section 14 of the plan; check script confirms) |
| 2 GPU struct headers plain C + static asserts | **Open** (finding 4) |
| 3 One camera -> GPU frame builder | **Open** (finding 2) |
| 4 Geometry-compositing core + golden | Open (Metal-only shader contract; tests exist in `BKVolumeGeometryTests.m`) |
| 5 Fast math off + `-ffp-contract` | **GPU half done** (Relaxed math, user-approved); **CPU half open** (finding 9) |
| 6 Preset/TF + window maths into BKRenderCore | Open (finding 15) |
| 7 Frame plan in C | Open (finding 14) |
| 8 Wider golden coverage | Open (finding 8) |
| 9 Shader sharing groundwork | Open (finding 3) |
| 10 Plain-C test runner + plan update | Open (finding 8); this audit + the kickoff plan update the plan |

---

## 12. Other agents working in parallel (2026-11-24)

At the time of this audit their BorosKit branches had **no commits and no uncommitted changes**
beyond `29ecaec`, so nothing of theirs is reflected above. Their areas overlap the Vulkan prep work:

| Agent | BorosKit area | Overlap with this plan |
|---|---|---|
| vr-colour-fusion | volume renderer / scene / shaders (`BKVolume*`, `BKShaderSource.mm`) | findings 2, 3, 5, 12-15: do the volume-renderer refactors **after** its merge |
| mpr-native | slab / MPR files | slab parameter path, `BKSlab*Core`; after merge |
| vtk-data | core geometry / maths | BorosKitVec additions (`BKPlane`, `BKMat4f`, `BKOnce`); coordinate names |
| gl-2d-final | 2D overlay engine (`BKOverlay*`) | N5, finding 18, `BKOverlayParams` shared text; after merge |

The kickoff plan therefore starts with work that touches none of their files (tools, CMake, the GPU
interface header, the Vulkan skeleton) and schedules the module refactors after the merges.
