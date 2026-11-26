# BorosKit precision audit and follow-up - 2026-11-26

Original BorosKit document written for this project. Agent "vulkan-engine", branch `agent/precision` (from main
`c6b6be6`). Rule: `~/boros6/BOROSCMF-FRAMEWORK.md` section 8 (user priority 2026-11-25: precision, consistency,
stability): identical results everywhere; deterministic; double precision for every number a user reads or an
export is built from; explicit `fma()` where a multiply-add matters; float only on the GPU for pictures; every
shown / exported number has a written accuracy requirement and a phantom test.

## In plain words

Every BorosKit calculation that produces a number a person reads (ROI area, length, angle, mean, SD, centre,
mesh area and volume) or a coordinate written to a 3D file now runs in double precision, with the
multiply-add steps written out so every computer gets the same bits. Each of these has a written accuracy
requirement and a test with a known exact answer, run on the Mac and in the Windows/Linux build. The largest
change in any number: **0.0000069 mm** (a camera distance in the 3D export files); ROI results moved by at most
0.00014 mm2 (area), 0.00014 degree (angle) and 1e-7 cm (length) - always toward the exact answer. Mesh vertex
storage (float32, like the GPU and the STL format) is the one open item; it needs a user decision (section 5).

## 1. Audit: every path that produces a user-visible number or exported geometry

Legend: **D** double, **F** float. "Compiler-dependent multiply-add" = was a result decided by `a*b+c` without
an explicit fma (since D3 `-ffp-contract=off` no compiler fuses anything, so the remaining question is only
whether an fma *should* be explicit).

| Path (file) | User sees / export | Before | Float used for | Compiler-dependent multiply-add | Action (this branch) |
|---|---|---|---|---|---|
| ROI area `BKROIPolygonAreaPixels`, `BKROIAreaCm2` (BKROICore.c) | ROI area cm2 (app: ROI.m `Area`, `roiArea`) | **F** shoelace (Horos-compatible) | coordinates + sum | no (D3); fmaf explicit | **D** + explicit fma; oval = pi a b in D |
| ROI length `BKROILength` | length cm / px (ROI.m `Length`) | F result, D `sy/sin(atan)` | result | no | **D** `sqrt(fma(sx,sx,sy*sy))` (sqrt correctly rounded) |
| ROI angle `BKROIAngle` | angle deg (ROI.m `Angle`) | **F** arms, acos of float cosine | everything | no | **D** `atan2(|a x b|, a.b)` with fma; accurate near 0/180 |
| ROI centre `BKROICentroid` | ROI centre | F shares, D sum | shares | no | **D** sum + one division |
| ROI statistics `BKROIStatsOfRuns/OfValues` | mean, SD, min, max, total (DCMPix.m `computeROI`) | D sum, **F** squared differences, F results | SD terms, results | no | **D** end to end, two-pass SD with fma; results double |
| ROI moments `BKROIMoments` | skewness, kurtosis | D | - | no | unchanged (D) |
| ROI inside pixels `BKROIInsideRuns`, oval outline | which pixels count | Horos float/integer rule | crossing points, oval angle | no | **unchanged on purpose** (Horos-identical pixel choice; tie cases documented 2026-11-25) |
| Point value `BKROIPointValue` | HU under a point ROI | scan value (float32 storage) | image data | - | unchanged (image data, see 3) |
| Angle arc `BKAngleCore` | drawing only | F | arc points | - | unchanged (picture) |
| Mesh area / volume (BKMesh.mm) | mesh area mm2 / volume mm3 | D sums (simd double, Objective-C) | - | no | **moved to C++ core** `meshcore::SurfaceArea/EnclosedVolume` (D + fma), BKMesh calls it; same in CMake |
| Mesh smoothing / decimation (BKMeshProcessingCore.cpp) | exported meshes | D maths, **F storage** | vertex storage | no | unchanged; storage = open item (5) |
| Surface extraction GPU (BKSurfaceExtractor) / CPU reference (BKSurfaceCore.c) | bone / skin surfaces, exported | GPU **F**; CPU ref D maths, F output | GPU positions, storage | no | documented boundary (3); bound proven by golden (3e-6 voxel GPU vs CPU) |
| Scene export (BKSceneExportCore.cpp) OBJ/VRML/Inventor/RIB | exported coordinates, normals, camera | D placement, **rounded to F** before writing | written numbers | no | **D** placement with fma chain, written as shortest exact double text |
| STL / PLY / OBJ mesh files (BKMeshIO.mm) | exported meshes | F (mesh storage; binary STL/PLY are float32 by format) | storage / format | - | unchanged; open item (5) |
| Camera maths `BKCameraMath`, picking `BKVolumeRayCore`, `BKMeshCameraAxes` | 3D point picked, distances in 3D | D | GPU plane packing only | no | unchanged (D) |
| Curve / panorex geometry `BKCurveCore`, `BKMPRGeometryCore`, `BKSlab*Core`, `BKScanGeometryCore`, `BKHeightBandCore` | CPR / MPR geometry, heights | D | GPU parameter packing only | no | unchanged (D); GPU boundary (3) |
| Curved reformat CPU reference `BKReformatComputeRows` | CPR picture values | F (mirror of the GPU kernel) | everything (on purpose) | no | unchanged: it is the GPU picture reference (3) |
| Contour / knots / rigid fit (`BKContourCore`, `BKKnotInterpCore`, `BKRigidFitCore`) | registration, contours | D | - | no | unchanged (D) |
| DICOM pixel values (`BKDicomCore`) | HU values | value * slope + intercept in D, stored **F** | image storage (Horos format) | no | unchanged (3) |
| TF bake, slab colour, fusion, stereo, display, overlay cores | pictures | F | GPU tables / pictures | no | unchanged (pictures) |

## 2. Written accuracy requirements and their phantom tests

Each test runs in BOTH builds: CMake/ctest (`bk_core_tests <name>`) and the Mac XCTest suite (the same C file is
compiled into `BKROIAccuracyTests.m`; mesh through `BKMeshAccuracyTests.m`). "Exact" = bit-identical to the
mathematically exact double result (`BK_CHECK_SAME`), which also proves Mac and Windows/Linux agree bit for bit.

| Id | Requirement (shown precision) | Phantom (known answer) | Test tolerance | Test |
|---|---|---|---|---|
| REQ-ROI-LENGTH | length to 0.01 mm | 3-4-5 triangle with 0.5 x 0.25 mm pixels = 5 mm; oblique 50.086 mm line | exact; 1e-9 mm | roi_accuracy_length |
| REQ-ROI-ANGLE | angle to 0.1 deg | 90, 45, 0, 180, 60 deg; unequal pixel sizes 90 / 45 deg | exact / 1e-12 deg | roi_accuracy_angle |
| REQ-ROI-AREA | area to 0.001 cm2 | 10 x 10 px square at 0.5 x 0.7 mm = 0.35 cm2; concave L (both windings) far from origin = 5 px; rectangle; oval pi a b | exact / 1e-15 cm2 / 4 ulp | roi_accuracy_area |
| REQ-ROI-STATS | mean / SD / min / max / total to 0.01 | values 1..1000 (mean 500.5, SD sqrt(N(N+1)/12)); CT-like +-1000 HU (SD exact formula); 1 and 0 pixels | exact / 1e-12 relative | roi_accuracy_stats |
| REQ-ROI-CENTRE | centre to 0.01 mm | mean of 3 points | exact | roi_accuracy_centre |
| REQ-MESH-AREA / -VOLUME | area 0.01 mm2, volume 0.01 mm3 | 2 x 3 x 4 mm box = 52 mm2 / 24 mm3, at the origin and far away | exact / 1e-9 relative | mesh_accuracy_box (+ XCTest) |
| REQ-EXPORT-GEOMETRY | exported coordinate = double placement result, round-trips exactly | float vertex 1.5 + translation 0.1 -> reads back exactly 1.6 (double); FormatDouble round trip | exact | export_accuracy_geometry (+ golden byte compare of the 4 scene files) |

Recorded Horos values (`BKROICoreTests testAgainstRecordedOldValues`): pixel choice still identical (ties as
documented 2026-11-25); mean / total / min / max rounded to float equal Horos exactly; values Horos computed in
float arithmetic are within measured bounds of Horos' own rounding - area <= 32 float steps (measured 23.98),
length <= 2 (0.53), centre <= 4 (0.40), SD 4 (unchanged rule), angle <= 0.001 deg absolute (measured 0.000137:
Horos' acos of a float cosine loses digits on the nearly straight oval corners; ours is exact there).

## 3. The GPU / float boundary (where a float result meets a user)

- **Pictures** (volume rendering, MPR / MIP / slabs, curved reformat, 2D display, mesh drawing) are float on the GPU
  by design. A number read off a picture (HU under the cursor in a CPR or slab picture) is a GPU float value. In
  BorosKit there is no API that turns such a value into a displayed measurement; the app does that (section 6).
  Recommended follow-up when the native views show cursor values: compute them on the CPU in double from the scan
  (trilinear in double), not from the picture.
- **Scan values** are float32 (the Horos format, `BKDicomCore`): exact for integer-valued data (CT HU, 16-bit
  data up to 2^24); about 7 significant digits for fractional data (PET SUV etc.). Kept: changing it would double
  the memory of every scan.
- **Surfaces from the GPU** (marching cubes) have float32 vertex positions: error bound <= 0.5 float step of the
  coordinate (<= 7.6e-6 mm at 128 mm; measured GPU vs the double CPU reference: 3e-6 voxel), 1300 x below the
  0.01 mm requirement. Topology (which triangles) is identical to the CPU reference (golden).
- **Transcendental functions** (sin, cos, atan2, acos, tan) are not guaranteed to be correctly rounded by every
  C library (Apple / glibc / MSVC may differ in the last binary digit, ~1e-16 relative). Affected: ROI angle (via
  atan2), oval outline points, camera / curve maths. Effect on a shown number: none (1e-14 degree vs 0.1 degree
  shown). Making them bit-identical everywhere would need BorosKit's own correctly rounded implementations -
  listed as a follow-up for the user. +, -, *, /, sqrt and fma are exact IEEE operations and identical everywhere.

## 4. Golden references re-recorded ONCE (precision follow-up, user decision 2026-11-25)

Only the four scene-export files changed (all other references unchanged; Metal pictures unchanged):

| File | Size | Change |
|---|---|---|
| scene_export_scene.obj | 4570 -> 6214 bytes | 175 of 827 numbers longer (full double); largest change 3.5e-8 mm (`11.8541021` -> `11.85410213470459`) |
| scene_export_scene.wrl | 5120 -> 6802 | 180 of 723; largest 3.5e-8 mm |
| scene_export_scene.iv | 5289 -> 7015 | 185 of 736; largest 6.9e-6 mm (camera focal distance `195.448196` -> `195.44820285692063`) |
| scene_export_scene.rib | 4540 -> 6307 | 190 of 752; largest 6.9e-6 mm (same camera number) |
| scene_export_scene.mtl | unchanged | colours stay float |
| MANIFEST.txt | updated | sizes / hashes of the four files |

## 5. Open item for the user: mesh vertex storage (float32)

`BKMesh` stores vertices as float32 (Apple `simd_float3`), the same as the GPU vertex buffers and the binary STL /
PLY formats (which are float32 by definition). Everything computed FROM the mesh is double (area, volume,
smoothing / decimation maths, export placement), but each stored coordinate is rounded to float32 (<= 7.6e-6 mm at
128 mm). The rule asks for double for every number an STL / guide is built from. Making the mesh double means:
BKMesh API + storage double (2x memory for million-triangle scans), GPU upload converts to float, STL binary stays
float32 by format (ASCII STL / OBJ could carry double). Effort ~1-2 sessions; needs the user's decision (and is the
right moment to move BKMesh/BKMeshIO into the C++ core, plan R4).

## 6. Boros 6 app (read-only list, NOT changed): user-visible measurements kept in float

The app now gets double results from BorosKit but stores / computes several in float:

| Where (boros6 Horos/Sources) | What | Float detail |
|---|---|---|
| ROI.m `-(float) Area`, `Area:`, `plainArea`, `EllipseArea`, `roiArea` (1919-1955, 7679) | ROI areas | return float (BKROIAreaCm2 double result truncated to float) |
| ROI.m `-(float) Angle:::` (1975), `Length:` / `LengthFrom:` (2019-2026) | angle, length | return float |
| ROI.m `MesureLength:` (4174, 4195) | length along a ROI | float |
| ROI.h `rmean, rmax, rmin, rdev, rtotal, rskewness, rkurtosis` (135) and DCMPix.m `computeROI:` (3304+) | ROI statistics | float fields / float* outputs (BKROIStats now double) |
| ROI.m local `float area / length / angle` in drawing of the ROI text (5261, 5358, 6274, 6389, 6885, 6981, 7020, 7053, 7114, 7198, 7273, 7384, 7607-7631, 7730) | numbers drawn next to ROIs | float |
| ROI.m `calciumScore`, `calciumVolume`, `calciumMass` (7854-7891) | calcium scoring | float |
| ViewerController.m `-(float) computeVolume:` (20331-20341) | ROI volume (mm3 / cm3) | float |
| DCMView.m `-(float) getSUV` (14480) | SUV | float |
| DCMPix fImage (whole app) | scan values | float32 (Horos format; see 3) |

Suggested app follow-up: change these return types / fields to double (mechanical, compile-checked), and format
the shown text from the double.
