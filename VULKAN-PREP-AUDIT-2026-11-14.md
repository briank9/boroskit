# Metal / Vulkan code sharing - preparation audit of 2026-11-14

Read-only audit by an agent of BorosKit (branch test/volume-geometry, 4d9f8ba). Complements
VULKAN-PORT-PLAN.md (see section 6 there for what is out of date). Line numbers as of that commit.

## 1. Neutral logic still in Objective-C / Metal files
- "Plain C" cores still use Apple simd (not on Windows/Linux): BKCameraMath, BKBoxWidgetMath,
  BKCropBoxCore, BKMeshDrawCore (#include <simd/simd.h>, simd_double3...). Truly portable today:
  BKRenderCore.c, BKGPUChoiceCore.c, BKSurfaceCore.c. -> neutral BKVec3d/BKVec3f/BKMat4 header (plan step R1).
- GPU struct headers not plain C: BKShaderTypes.h:29 (simd) + :31 BKClipPlanes.h -> N3Geometry.h (LGPL);
  BKMeshShaderTypes.h:40-44 simd types. Surface/display headers already use the right pattern
  (#ifndef __METAL_VERSION__, bk_u32/bk_i32).
- Camera maths duplicated in 5 places, none using BKCameraMath: BKVolumeRenderer.m:315-420 (fillParams),
  BKMeshRenderer.m:530-547 / 801-812 / 994-1000 / 670-737 / 895, BKVolumeCamera.m (BKRotateVector :23,
  millimetresPerViewPoint/pan :174-192), BKMeshUnprojectPixel (BKMeshRenderer.m:965) = BKCameraRayThroughViewPoint,
  applyToRenderer (BKVolumeCamera.m:207) = setCameraFromVolumeCamera (BKMeshRenderer.m:503). Volume and mesh
  param blocks describe the camera differently (full size / 2*tan vs half size / tan).
- Geometry-layer contract (added 2026-11-14) only in shader code: ray distance (BKMeshShaderSource.mm:156-160,
  :260 vs bk_trace BKShaderSource.mm:206-220), texel mapping (:443-446), slab rejection + compositing
  (:309-322, :378-380, :424), +infinity sentinel (BKMeshRenderer.m:748). No CPU reference; protocol uses Metal types.
- Other neutral pieces in Obj-C: frame planning (BKVolumeScene.m:430-460, :332), quality ladder (:20-75, NSArray),
  volume bounds (:144-156, N3), WL drag (BKVolumeScene.m:226, BKImageView.m:314) + advanced-curve window fit
  (:262-290), preset->TF maths (BKTransferFunction.m:113-140 incl. VTK 255/254 quirk, BKPreset.m:113-152 opacity y^2,
  grayscaleRamp), mesh draw ordering (BKMeshRenderer.m:670-737), vertex packing (:160-175), patient bounds
  (:140-155), volume upload chunking/min-max with vDSP (BKVolumeTexture.m:108-160; no max-3D-size check),
  display params/LUT (BKImageLayerRenderer.m:223-279), workgroup sizes (BKVolumeRenderer.m:470/519, :633/649;
  BKSurfaceExtractor.m:149, 232-234), duplicate plane helpers (BKCutPlanesKeepPoint/BKBoxClipPlanes vs
  BKClipPlanesKeepPoint/Pack).

## 2. Shaders
- Shareable bodies (option C: shared body + per-backend entry points): volume bk_sample, bk_transfer,
  bk_gradient, brick helpers, bk_trace, bk_geometry_at, bk_brick_ranges, bk_classify_bricks; all surface
  kernels; mesh clip/view depth/shading/ray distance/line+point expansion; display read + window/LUT.
  A shared "camera" shader include for volume + mesh would guarantee geometry distances agree.
- Build-time single-source tools (SPIRV-Cross, DXC, Slang, glslang): licence question open - user decision.
- Metal-only features to map: constexpr sampler (BKShaderSource.mm:203-204, :500) -> immutable samplers;
  access::write formats; get_width -> imageSize; threadgroup arrays/barriers; packed_float3/2 -> float[];
  thread float & -> inout; [[vertex_id]]/[[color(1)]]; rint -> roundEven.
- NEW RISK: fast math is ON in all four shader libraries (default MTLCompileOptions: BKVolumeRenderer.m:139,
  BKMeshRenderer.m:433, BKImageLayerRenderer.m:105, BKSurfaceExtractor.m:137) while shaders rely on INFINITY /
  isinf (ray misses, 1/dv, the new +infinity "no object" sentinel). -> turn fast math off (+ -ffp-contract) and
  re-record golden references. NEEDS USER DECISION.
- Plan section 4 misses: independentBlend (mesh pipeline, BKMeshRenderer.m:611-619), D32_SFLOAT not guaranteed,
  image layout transitions (geometry images, 1x1 placeholders).

## 3. Shared CPU<->GPU structs
| Struct | Layout | Size test |
|---|---|---|
| BKRenderParams (464 B) | std430 OK, header not plain C | CPU==Metal only (BKVolumeRendererTests.m:90); not pinned, no offsetof |
| BKMeshUniforms (272 B) | OK, simd types | CPU==Metal only (BKMeshRendererTests.m:76); not pinned |
| BKMeshGPUVertex (40 B), strides 8/12 | OK | none |
| BKSurfaceParams (336 B) | OK, portable | pinned + GPU |
| BKDisplayParams (80 B) | OK, portable | _Static_assert only |
-> add _Static_assert size + offsets to every header (CPU==Metal proves nothing about std430).

## 4. Minimal backend interface (additions to plan section 6)
Binding-number mapping table (Metal separate buffer/texture/sampler ranges vs Vulkan bindings), samplers,
per-attachment blend/write mask + clear values (incl. +inf), cull/front face, depth state, viewport/scissor,
vertex streams + index buffer, 3D-texture->buffer readback, GPU timestamps (adaptive quality), completion
callbacks, render->compute barriers.
Functions: deviceEnumerate/choose, limits, bufferCreate/map, textureCreate(fmt,w,h,d,usage),
textureUpload(chunked), copyTextureToBuffer, samplerCreate, computePipeline(name, wgSize),
renderPipeline(desc), cmdBegin, dispatch, barrier, beginPass(targets, clears), setState, draw/drawIndexed,
endPass, timestamp, submit(wait|callback), acquireImage/present (view side).

## 5. Tests
- Neutral logic but Obj-C XCTest (can't run on Windows/Linux): BKCameraMathTests, BKCropBoxCoreTests,
  BKBoxWidgetMathTests, BKRenderCoreTests, BKSurfaceTableTests, BKGPUChoiceTests (part), BKMeshProcessingTests,
  BKSceneExportTests. Only BKGoldenCore.c is C. -> plain-C test runner.
- Golden gaps: geometry compositing, mesh lines/points/textures/culling (BKGoldenMetal.m:205 sets no lines),
  rotated 6-plane crop, boxMin/boxMax crop, useClip, camera slab, on-screen path (bk_raycast_texture + bk_upscale),
  preset->TF, BKCameraMath/CropBoxCore/BoxWidgetMath numbers. numbers_core.txt camera values come from Obj-C/N3.

## 6. Out of date in VULKAN-PORT-PLAN.md
"186 tests" (now ~243); moved line refs (fillParams :315-420; mesh :530-547, :670-737, :895; fast-math lines above;
BKMeshUnprojectPixel BKMeshRenderer.h:297); sections 2/3/9 don't mention BKCameraMath/BKCropBoxCore/
BKBoxWidgetMath/BKMeshDrawCore (R2 "not started" but cores exist, simd-bound, unused by renderers); "mesh structs
already compliant" (layout yes, header no); preset parsing (plist Apple-side OK, preset->TF maths must be shared);
sections 4/6/13 gaps above; CLAUDE.md branch name.

## Top 10 preparation steps
1. Neutral vector/matrix header; port BKCameraMath, BKBoxWidgetMath, BKCropBoxCore, BKMeshDrawCore off simd. Medium.
2. GPU struct headers plain C (drop simd/N3; split BK_MAX_CLIP_PLANES out of BKClipPlanes.h) + _Static_asserts + BKMeshGPUVertex test. Small.
3. One C camera->GPU frame builder (BKRenderParamsFill, BKMeshUniformsFill) on BKCameraMath; remove the 5 copies; re-record strict. Large.
4. Geometry-compositing C core + golden cases (in front / behind / MIP); neutral protocol types. Medium.
5. Fast math off + -ffp-contract, re-record (matters more with +inf sentinels). Small - user decision.
6. Preset/TF + window maths into BKRenderCore. Medium.
7. Frame plan in C (quality ladder, render size, sample spacing, mesh ordering, workgroup sizes). Medium.
8. Wider golden coverage (mesh lines/points/textures/culling, crop planes, slab, on-screen + upscale, camera/crop numbers). Medium.
9. Shader sharing groundwork: shared bodies + Metal entry points, starting with Surface + a shared camera include; binding table. Large.
10. Plain-C test runner + update VULKAN-PORT-PLAN.md. Medium.
