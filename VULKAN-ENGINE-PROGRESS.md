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
