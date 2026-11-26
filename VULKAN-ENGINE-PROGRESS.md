# BorosKit Vulkan engine - progress notes

Original BorosKit document written for this project. Plan: VULKAN-ENGINE-KICKOFF.md (section 7.3).

## 2026-11-25 - agent "vulkan-engine", branch `agent/vulkan-engine` (worktree ~/BorosKit-worktrees/vulkan-engine)

Base: BorosKit `e5938c7` (test/mesh-transparency, contains test/overlay-engine). User decisions used:
D1 yes, D2 yes, D3 yes, D7 = option C, D8 go ahead. Nothing pushed, nothing merged, Boros 6 untouched.

### In plain words
The preparation steps M1-M5 are done: small portability fixes, the GPU settings blocks are now plain C
with their memory layout checked by the compiler, the 3D-mesh settings block is computed in plain C,
there is a CMake build + a test program that runs on any computer, and the "GPU interface" header is
written. The Metal pictures did not change at all. The Vulkan part itself (M6-M10) could not start
because the Vulkan SDK is not installed on this Mac (install steps below).

### Commits (all on agent/vulkan-engine)
| Commit | Step | What |
|---|---|---|
| `a29a03c` | M1 | `BKOnce.h` (portable run-once, replaces `pthread_once` in BKSurfaceCore.c); `BKParallel.h` moved to BorosKitVec (C++-guarded). The `size_t` fix in BKVolumeRayCore was already in the base. |
| `d595d48` | M2 | `BKGPUTypes.h` (bk_float2/4/4x4, layout-assert macros, BK_MAX_CLIP_PLANES); BKShaderTypes.h / BKMeshShaderTypes.h without simd and without the LGPL N3 include; size + offset pins on every GPU block; ONE `BK_OVERLAY_PARAMS_FIELDS` list for C and Metal; check script also compiles cores with plain-struct types. |
| `2baad04` | M3 | `BKMeshUniformsFill` + `BKMeshCameraAxes`, `BKMeshCameraHalfSize`, `BKMeshDepthRange`, `BKMeshUniformsSetModel` (inverse-transpose), `BKMeshUniformsSetColor` in BKMeshDrawCore (plain C); BKMeshRenderer.m calls them. |
| `d27440d` | M4 | `CMakeLists.txt`, `cmake/BorosKitSources.cmake` (one explicit list, drift check), `Tests/BorosKitCoreTestsC/` own test runner. |
| `330a3ea` | M5 | `Sources/BorosKitGPU/include/BKGPU.h` (interface only) + CPU stand-in device test. |
| (this file) | notes | progress notes. |

### Test results (final commit)
- `swift test -c release`: all suites pass - Surface 21, Render 197, Mesh 88, Display 62, Core 28, Accuracy 13; golden normal mode 12/12.
- Golden STRICT: output identical, line for line, to the base commit `e5938c7`, after every step.
  **Note:** the base itself is not "zero difference" in strict mode: 9 known differences, all inside the
  agreed tolerance (slice_linear_lut_rotated 4 levels in 2 channels; the 3 surfaces 1.53e-6 voxel; the 3
  vr `.values.pfm` ~1e-7..3e-5; mip_persp_full 1 level / 3.5 HU in 4 pixels). They date from the
  2026-11-14 switch to Relaxed GPU math (references never re-recorded). Both mesh-render cases are exactly 0.
- `docs/tools/check-portable-cores.sh`: 38/38 cores clean (both GPU-type paths).
- CMake 4.4.5 + AppleClang on this Mac: build clean, `ctest` 19/19 passed (284 checks + interface test),
  incl. golden phantom hash bit-identical to the Mac reference. Not yet run on Windows / Linux.

### Surprising things
1. **Apple simd normalize is not 1/sqrt.** On arm64 (no fast-math) `simd_normalize` uses Apple's own
   approximate rsqrt + Newton steps (a few ULP). Portable C cannot reproduce it bit for bit, so the mesh
   camera frame is now built in double (same formula as BKCameraRight) and rounded once. The golden
   mesh pictures still came out identical.
2. **SwiftPM stale module.** A NEW header in `BorosKitVec/include` was not noticed by the explicit-module
   build (old BorosKitVec.pcm -> "expected parameter declarator"). Touching `BKVec.h` fixed it. If Boros 6's
   Xcode build of the package shows strange errors after pulling these commits: clean build folder once.
3. **C cores cannot #include headers of another SwiftPM target that contains Objective-C** (modules import
   the whole module). So BKMeshDrawCore writes `right = normalize(forward x up)` itself; a ctest proves it
   is bit-identical to BKCameraRight.

### NEEDS THE USER'S DECISION: D3 in the Mac build (`-ffp-contract=off` in Package.swift)
CMake uses `-ffp-contract=off` (as decided). Applying the same flag to Package.swift was tried and
**reverted (not committed)**, because it changes more than the last bit:
- **ROI core vs the recorded old Horos values** (`BKROICoreTests testAgainstRecordedOldValues`, 57 failed
  checks): polygon masks move at the edges - concave polygon 1259 inside pixels vs Horos 1262 (mean
  -54.006 vs -54.348), self-crossing 999 vs 1004; areas differ ~1e-6 relative; oval outline points in the
  last bits. Reason: Horos (and BKROICore today) are compiled with FMA contraction on; the "inside pixel"
  test then flips for pixels exactly on an edge.
- Golden (all inside tolerance except the byte-exact ones): TF table hash changes (`tf_entry_1000_ch1`
  0.53311973810 -> 0.53311967849); camera numbers ~1e-16; the 4 scene-export files differ in the 8th digit
  (e.g. `7.85410166` -> `7.85410213`; a `6.16e-19` becomes exact `0`); vr values pfm a few more channels;
  mip_persp_full gets *better* (0 levels). Saved diffs: `.agent-scratch/d3-references.diff`,
  `.agent-scratch/d3-package-swift.diff` (git-ignored, worktree only).
- Choices: (a) pin it everywhere, re-record the golden files once and loosen the Horos-ROI comparison to
  "a few pixels on exact edges"; (b) pin it everywhere except BorosKitDisplay (ROI keeps exact Horos
  parity on the Mac, but the Windows/Linux ROI results will differ slightly from the Mac); (c) leave the
  Mac build as it is (CMake only pinned) - then Mac vs Windows/Linux may differ in the last bit.
  Recommendation: (a) - the goal is identical results on every platform; the ROI differences are
  edge pixels only.

### M0: Vulkan SDK - NOT installed (checked: no vulkaninfo, glslc, glslangValidator, spirv-val, no
VULKAN_SDK, no ~/VulkanSDK, nothing in Homebrew). Steps for the user (about 15 minutes, ~1-2 GB):
1. In Safari open **vulkan.lunarg.com** -> "SDK" -> "Download" -> the **macOS** row -> the latest
   version (a `.dmg` file, e.g. `vulkansdk-macos-1.4.xxx.dmg`). No account is needed.
2. Double-click the downloaded `.dmg` in Downloads; a window opens. Double-click **InstallVulkan**.
   If macOS says it cannot check the app: System Settings -> Privacy & Security -> "Open Anyway".
3. In the installer click Next. Keep the suggested folder (`/Users/serdalkocak/VulkanSDK/<version>`).
   On the components page leave the default ticks (they include MoltenVK, the validation layers and
   the shader tools). Do NOT tick anything that says "System Global Installation" unless asked;
   the default is fine. Click Next / Install, type your Mac password if asked, then Finish.
4. Open **Terminal** and paste (one line, then Enter):
   `echo 'source ~/VulkanSDK/*/setup-env.sh' >> ~/.zprofile`
   Then close Terminal and open it again.
5. Check: in the new Terminal type `vulkaninfo --summary` and Enter. Success = a list that mentions
   "Apple M1 Pro" and "MoltenVK". Also `glslc --version` should print a version.
6. Tell Claude "the Vulkan SDK is installed". Nothing of this goes into Boros 6.
(Written from memory, no web search: the exact button names / setup-env path may differ slightly by
version - verify on the page. The SDK tools are build-time only, licences per decision D1.)

### Where to resume
1. User decides D3-in-Package.swift (above). If (a): re-apply `.agent-scratch/d3-package-swift.diff`,
   `BK_GOLDEN_RECORD=1 swift test -c release --filter BKGoldenTests`, review `git diff References/`,
   adjust BKROICoreTests' old-value comparison, commit once with the reasons.
2. After the SDK is installed: M6 (`Sources/BorosKitGPUVulkan/`, CMake only: own loader, instance with
   portability enumeration + validation, device via BKGPUChoiceCore, own sub-allocator, staging,
   readback, pipelines from embedded SPIR-V, automatic barriers), then M7 triangle, M8 mesh GLSL over
   shared `.bksl` bodies, M9 golden runner (`meshrender_bone_ortho` via `BKMeshUniformsFill`), M10 PNG
   side by side.
3. Open small follow-ups: XCTest targets could call the plain-C test functions (needs a .m shim because
   of the module rule above); run CMake/ctest on a Linux or Windows PC (D6).

## 2026-11-25 (later) - D3 applied everywhere (user decision: option (a), "we need it to be universal")

### What changed
- `Package.swift`: `-ffp-contract=off` for every BorosKit library target (Vec, Core, Render, Display, Mesh,
  MeshRender, Surface), C, Objective-C and C++ files alike; no fast-math anywhere. Same flag as CMake.
- `BKROICore.c`: the two places where the recorded Horos build's compiler had fused a multiply-add are now
  written as an explicit `fma()` / `fmaf()` (oval outline point `x + w*cos`, the area shoelace sum). fma is
  correctly rounded by every C99 library, so this is the same on every platform AND keeps the outlines and
  areas bit-identical to the recorded Horos values (no tolerance needed there).
- `BKROICoreTests.m` inside-pixel rule (documented in the test): (1) the mask built from the RECORDED curve
  must give the recorded pixels exactly (zero tolerance; statistics of that mask exact as before); (2) every
  corner of our own curve must fall in the same whole pixel as the recorded corner, except a corner that lies
  within 1e-9 pixel of a pixel boundary (a floating-point tie; the curves agree to ~1e-14). Horos builds the
  mask from whole-pixel corners, so only such tie corners can move a pixel; nothing else was loosened.
  Effect today: polygon-concave 2 tie corners (own mask 1259 pixels, Horos 1262), polygon-self-crossing 4
  tie corners (999 vs 1004); all other ROIs identical. The probe test (1e-9 on-outline rule) is unchanged.
- New ctest `golden_cpu_numbers` / `golden_cpu_meshes` (Tests/BorosKitCoreTestsC/BKGoldenCPUCoresTest.cpp):
  the CMake build recomputes the colour-table bake, the surface plan, Taubin smoothing and decimation (1 and
  all threads) and compares them with ZERO tolerance (raw bytes for meshes) with the Mac-recorded references.

### Golden references re-recorded ONCE (reason: D3, user decision 2026-11-25)
Caused by D3 (CPU maths no longer fused):
| File | Old | New |
|---|---|---|
| numbers_core.txt | tf_table_hash 3378587455/1769865870 (high/low32); tf_entry_1000_ch1 0.53311973810195923; camera_up_x -0.018028311236297209, camera_up_z 0.92541657839832336, camera_focal_y -1.8833548014929038 | 251569618/1776313157; 0.53311967849731445 (one float step); -0.018028311236297195, 0.92541657839832347, -1.8833548014929034 (~1e-16) |
| scene_export_scene.obj / .wrl / .iv (byte sizes 4570 / 5120 / 5289, unchanged) | e.g. vertex `7.85410166`, `6.14589834` | `7.85410213`, `6.14589787` (8th digit, float rounding of the moved box) |
| scene_export_scene.rib (4553 -> 4540 bytes) | transform term `6.16492489e-19`, translation `-1.15093295e-14 5.32907052e-15` | exact `0`, `1.42108547e-14 7.10542736e-15` |
| scene_export_scene.mtl | unchanged | unchanged |
GPU drift that already existed since the 2026-11-14 Relaxed-math switch (the 9 strict differences of the base,
folded into this one re-record so strict mode is zero again; all were inside tolerance):
| File | Change old -> new |
|---|---|
| surface_bone_300 / surface_skin_m500 / surface_bone_res05_smooth1_manual .bkmesh | same counts, identical triangles, positions max 1.9e-6 mm, normals 0 |
| slice_linear_lut_rotated.rgba.pam | 2 channels, max 4 grey levels |
| vr_ortho_anterior / vr_ortho_left_clipped_unlit / vr_persp_oblique .values.pfm (accumulated opacity) | 680 / 338 / 303 values, max 4.8e-7 / 2.9e-7 / 2.8e-5 |
| mip_persp_full.values.pfm | 2 of 7680 values, max 0.108 HU (D3 + drift; its .rgba.pam now matches the old file exactly, not re-recorded) |
Follow-on (input surface above + D3):
| mesh_smooth_taubin10.bkmesh / mesh_decimate_50.bkmesh | same counts, identical triangles; positions max 5.7e-6 / 8.2e-5 mm, normals max 3.9e-6 / 2.0e-5 |
MANIFEST.txt updated with the new sizes / hashes.

### Test results after D3
- `swift test -c release` with `BK_GOLDEN_STRICT=1`: all suites pass (Surface 21, Render 197, Mesh 88,
  Golden 12, Display 62, Core 28, Accuracy 13). Golden strict: every comparison max difference 0.
- `docs/tools/check-portable-cores.sh`: all cores clean.
- CMake + ctest: 21/21 passed; CPU cores bit-identical to the SwiftPM build (73 strict checks: phantom,
  colour table, surface plan, smoothing, decimation).
- Boros 6 impact when it picks up this BorosKit: CPU results change in the last digits as listed (colour
  tables, exports, mesh smoothing/decimation), and the two ROI shapes above can include/exclude a pixel whose
  corner sits exactly on a pixel boundary. Nothing visible otherwise.

### Where to resume
Vulkan SDK is being installed by the user. Next: check `vulkaninfo --summary`, then M6 (see above).

## 2026-11-26 - M6-M10: MILESTONE 1 PASSED (agent "vulkan-engine", branch agent/vulkan-engine)

Base: fast-forwarded to BorosKit main 9b18762 (agent/vulkan-engine + agent/ios-cutoff merge).
Vulkan SDK 1.4.363.1 installed by the user (~/VulkanSDK/1.4.363.1/macOS; tools + layers also in /usr/local).

### In plain words
The new Vulkan engine draws on this Mac (through MoltenVK). It drew the test triangle exactly right, and it
drew the golden bone surface **bit for bit identical** to the Metal reference picture: every pixel and every
ray distance the same (max difference 0), for the milestone case and for the see-through perspective case
too. The Vulkan checking layer (incl. synchronisation checks) reported nothing. Boros 6 is unchanged.
Picture for the user: `milestone1-pictures/meshrender_bone_ortho_metal_vs_vulkan.png`
(Metal | Vulkan | difference x 40, all black = no difference); also `..._persp_seethrough_...png`.

### What was built
- **M8 Metal half** (`df9c99f`): mesh shader maths moved into `BorosKitMeshRender/include/BKMeshShaderBodies.h`
  (shared Metal/GLSL subset, option C), field list into `BKMeshUniformFields.h`; `BKMeshBoxDepthExtent` (C) used by
  BKMeshRenderer. Golden strict unchanged (0 differences), all 8 SwiftPM suites pass.
- **M6** `Sources/BorosKitGPUVulkan/` (CMake only): `BKGPUVulkan.h` (options: validation, sync validation, message
  callback), `BKVulkanLoader` (own dlopen loader, X-macro function table, VK_NO_PROTOTYPES - nothing linked),
  `BKVulkanDevice.cpp` (Vulkan 1.3 core, dynamic rendering; portability enumeration/subset; GPU choice through
  BKGPUChoiceCore; own sub-allocator; buffers, 2D/3D textures, samplers, render pipelines, command lists with
  staging uploads, readback, automatic layout/memory barriers, per-list descriptor pool; negative-height
  viewport = Metal's y-up). Compute / Surface / timestamps: Status::Unsupported (later phases).
- **M7** `Tests/BorosKitGoldenVulkan/BKVulkanTriangleTest.cpp` + GLSL `bk_triangle_*`: 724 inside pixels exact,
  2158 outside exact, 190 edge pixels either - 0 wrong; 0 validation messages.
- **M8 Vulkan half**: GLSL `bk_prelude.glsl`, `bk_mesh_vertex.vert`, `bk_mesh_fragment_distance.frag` (entry points
  only, maths #included from BKMeshShaderBodies.h); CMake compiles with `glslc --target-env=vulkan1.3 -O`, checks
  with `spirv-val`, embeds the words with our own `cmake/BKEmbedSpirv.cmake`.
- **M9** `BKGoldenVulkan.cpp`: reads `surface_bone_300.bkmesh`, builds the settings block with the same C functions
  as Metal (BKMeshBoxDepthExtent, BKMeshDepthRange, BKMeshUniformsFill, SetModel, SetColor), mirrors the draw
  states (solid; see-through = depth-only pass + LESS_OR_EQUAL colour pass), compares with bk_golden_compare_*:
  meshrender_bone_ortho rgba + distance max difference 0; meshrender_bone_persp_seethrough also 0.
- **M10** `BKPNGWrite.c` (own PNG writer: stored deflate, CRC-32 / Adler-32 from the format description) and the
  side-by-side pictures.
- ctest: 23/23 (21 core + vulkan.triangle + vulkan.golden_mesh).

### How to build / run (VULKAN_SDK is not set in the user's shell; the ~/.zprofile line was not added)
```
export VULKAN_SDK=~/VulkanSDK/1.4.363.1/macOS        # needed when CMake configures (finds headers/glslc/spirv-val)
cmake -S . -B build-cmake -DCMAKE_BUILD_TYPE=Release && cmake --build build-cmake
ctest --test-dir build-cmake --output-on-failure    # tests set VK_DRIVER_FILES=MoltenVK + MVK_CONFIG_FAST_MATH_ENABLED=0
```
Without VULKAN_SDK at configure time the Vulkan part is skipped (message), the core tests still run. To make it
permanent the user can add `export VULKAN_SDK=$HOME/VulkanSDK/1.4.363.1/macOS` to ~/.zprofile (not done by the
agent, as instructed).

### Notes / surprises
- Bit-identical (not just within tolerance) is plausible because MoltenVK turns our SPIR-V into Metal on the same
  GPU; it proves the shared maths, layout, states and conventions are right, NOT other vendors' numbers (phase 9:
  NVIDIA/AMD PC needed, user decision D6).
- Extra run on the SDK's second Metal-based driver **KosmicKrisp** (Mesa): golden cases pass within tolerance
  (ortho rgba max difference 1 in one channel, rest 0), triangle not run there with validation because
  **KosmicKrisp + validation layer -> device creation refused (Status::Unsupported)** - not investigated yet
  (open item; likely the layer-settings / sync-validation path). It also lacks fillModeNonSolid (wireframe).
- Loader warns about duplicate layer manifests if the SDK layer folder is added while /usr/local has them; CMake
  only adds VK_ADD_LAYER_PATH when /usr/local lacks the validation layer.
- `MVK_CONFIG_FAST_MATH_ENABLED=0` is the MoltenVK environment setting as I remember it (should be verified in the
  SDK's MoltenVK docs); results were bit-identical anyway.
- Front-face winding with the flipped viewport (VK_FRONT_FACE_COUNTER_CLOCKWISE) is untested: the golden cases
  use no culling. Add a culling golden case before relying on it.

### Where to resume
1. Mesh pass completeness on Vulkan: lines, points, textured meshes, culling golden case (front-face check).
2. Phase 2 per the kickoff plan: MetalDevice implementing BKGPU.h, then a C++ MeshPass used by both backends.
3. Open: KosmicKrisp + validation refusal; asynchronous submit; compute pipelines (surface extraction, phase 4).

## 2026-11-26 - precision follow-up (branch agent/precision from main c6b6be6; user decision 2026-11-25)

Full audit, requirements, boundary and app list: **PRECISION-AUDIT.md**. Summary:
- BKROICore: area, length, angle, centre, statistics now DOUBLE with explicit fma (API types float -> double;
  BKROIStats fields double). Inside-pixel choice unchanged (Horos-identical).
- Mesh area / volume moved into the C++ core (meshcore::SurfaceArea / EnclosedVolume, double + fma); BKMesh calls it.
- Scene export: placement in double (fma chain), coordinates / normals / camera written as shortest exact double
  text (FormatDouble); colours stay float.
- Phantom accuracy tests with written requirements, in BOTH builds (ctest roi_accuracy_*, mesh_accuracy_box,
  export_accuracy_geometry; XCTest BKROIAccuracyTests includes the same C file, BKMeshAccuracyTests).
- Horos comparison: measured bounds documented (area 23.98 float steps, angle 0.000137 deg, length 0.53 steps).
- Re-recorded ONCE: the 4 scene-export files (+ MANIFEST); largest number change 6.9e-6 mm.
- Results: swift test -c release (BK_GOLDEN_STRICT=1) 456 tests, 0 failures, every reference comparison max
  difference 0; ctest 30/30 (incl. Vulkan milestone tests); check-portable-cores clean.
- Open for the user: BKMesh float32 storage (PRECISION-AUDIT.md 5); app float measurements (6); own correctly
  rounded sin/cos/atan2 if bit-identical angles across operating systems are required (3).

## 2026-11-26 - PHASE 2: shared GPU interface + MetalDevice + first module (mesh renderer) on it (branch agent/gpu-interface from main 68f62d3)

### In plain words
The mesh drawing (3D surfaces, lines, points, textured meshes, see-through objects) is now written ONCE, in
BorosKit's shared GPU language, and runs on both engines. On the Mac it runs on the Metal engine and draws exactly
the same pixels as before (strict golden: 0 differences; all 89 mesh tests pass). The same code on the Vulkan
engine draws the golden bone surfaces bit for bit like Metal, and a mixed test scene (lines, points, textures,
see-through, wireframe, culling) matches Metal except one pixel on a wireframe edge (inside the agreed tolerance).
Pictures: milestone1-pictures/feature_scene_metal_vs_vulkan.png (Metal | Vulkan | difference x 40).

### What was built
- `BorosKitGPU` SwiftPM target + product: `BKGPU.h` (now C++-guarded), `BKGPUMetal.h/.mm` = MetalDevice + glue
  (wrap an existing MTLTexture / MTLBuffer / MTLCommandBuffer; add a Metal library). Compute = Unsupported (phase 4).
- `BKMeshPass.h/.cpp` (BorosKitMeshRender, backend-neutral C++): all of BKMeshRenderer's drawing logic.
- `BKMeshRenderer.m` -> `.mm`: Metal glue only (object caches, wrapping, error messages). Public API unchanged.
- GLSL for the rest of MeshPass on Vulkan: bk_mesh_fragment, textured vertex / fragments, line / point vertex,
  line fragments (entry points over BKMeshShaderBodies.h; spirv-val clean).
- Shared tests `Tests/BorosKitGPUShared` (triangle, golden meshes via MeshPass, winding, feature scene), run by:
  Vulkan programs (ctest vulkan.*), the Mac XCTest suite on MetalDevice (BKGPUSharedTests.mm, strict), and
  `bk_gpu_cross` (CMake, Apple only: Metal AND Vulkan in one program, live cross-check).
- Winding (milestone-1 open item) answered: with the negative-height viewport + VK_FRONT_FACE_COUNTER_CLOCKWISE,
  Vulkan culls exactly like Metal and like BKMeshTriangleIsCulled (none / back / front) - test on both backends.
- Umbrella headers `BorosKitVec/include/BorosKitVec.h`, `BorosKitGPU/include/BorosKitGPU.h` (fix for the stale
  precompiled module; rule: list every new header there).

### Results
- swift test -c release with BK_GOLDEN_STRICT=1: 460 tests, 0 failures; golden strict 0 failures (both mesh-render
  references max difference 0 through BKMeshRenderer -> MeshPass -> MetalDevice).
- ctest 31/31 (incl. vulkan.triangle, vulkan.golden_mesh, gpu.metal_vs_vulkan); 0 Vulkan validation messages
  (with synchronisation validation). Feature scene Vulkan vs Metal: rgba 1 channel beyond +-1 (0.003 %, wireframe
  edge pixel), distance 1 value (0.013 %) - within the agreed 0.5 % edge allowance.

### For Boros 6 when this is merged (lead)
- No app code changes: BKMeshRenderer's Objective-C API is unchanged (new error codes only: 41 pipeline, 42 depth
  buffer, 43 target format other than RGBA8/BGRA8 + R32Float - Boros 6 uses BGRA8 drawables, fine).
- BorosKitMeshRender now depends on the new target BorosKitGPU (SwiftPM links it with the product automatically)
  and contains C++ (.mm / .cpp): Boros 6 already links libc++.
- Module cache: the umbrella headers change the generated module map of BorosKitVec, so a normal build should rebuild
  it; because the shared bench currently holds a STALE BorosKitVec module, clear the bench's
  build/Build/Intermediates.noindex/ExplicitPrecompiledModules/BorosKit* once (or do a clean build) before building.
- Configure CMake with VULKAN_SDK=$HOME/VulkanSDK/1.4.363.1/macOS for the Vulkan parts (not needed for Boros 6).

### Where to resume
1. Phase 3 / 4 per plan: surface extraction (compute pipelines in BKGPU.h: Metal + Vulkan), then the volume renderer.
2. A recorded golden case for lines / points / textured meshes (today only the live Metal-vs-Vulkan cross check).
3. Other Objective-C modules onto the interface one at a time (BKOverlayRenderer is small - a good next one).
