# BorosKit accuracy check

An automatic check that the images BorosKit makes are **the right way round** and
**measure the right distances**. It exists because an earlier bug mirrored the image
left/right. It must pass before the Metal engine becomes the default renderer in Boros 6.

## How it works

The tests build a test scan in code, a **phantom**. No patient data is used. Because the
phantom is made by the program, the exact position of everything in it is known in
millimetres:

| Marker | Where (from the phantom's centre) | Value |
|---|---|---|
| Sphere, radius 3 mm | 12 mm to the patient's **left** | 1000 |
| Sphere, radius 3 mm | 12 mm to the **front** (anterior) | 500 |
| Rod, 10 mm long | 8 to 18 mm toward the **head** (superior) | 200 |
| Dot pair 1 | left-right, exactly **40.0 mm** apart | 2000 |
| Dot pair 2 | diagonal front-bottom to back-top, exactly **40.0 mm** apart | 1500 |

The scan is made deliberately awkward:
- **Voxels are not cubes:** 0.3 x 0.4 x 0.5 mm.
- **The origin is far from zero.**
- **The voxel grid is stored three ways:** the usual way, tilted 17 degrees, and
  "backwards" (rows running to the patient's right, slices toward the feet).

The markers sit at the same patient positions in all three versions. A viewer that mixed
up the storage order with the patient's real directions (which is how mirror bugs happen)
would fail.

Each image path then renders the phantom, and the test measures where each marker
appears. The measurement uses the centre of each bright spot, accurate to a small fraction
of a pixel. Each result is compared with where the marker must be.

## What is checked

1. **MPR slices and slabs** (`BKAccuracyMPRTests`, Metal `BKVolumeRenderer`, set up with
   exactly the same camera math as Boros 6's `BorosMetalSlabRenderer`):
   - Axial, coronal and sagittal thick MIP slabs, for all three grid layouts:
     - every marker is at its expected pixel;
     - it is on the correct side;
     - nothing appears at the mirrored spot;
     - the dot pairs measure 40 mm.
   - Thin slices (axial, coronal, sagittal and a 30-degree oblique slice): every pixel is
     compared with a simple CPU calculation (trilinear interpolation, written separately
     in the test), and the 40 mm pairs are measured.
2. **3D window** (`BKAccuracy3DTests`, `BKVolumeCamera` + `BKVolumeScene`, the objects
   `BKVolumeView` draws with): all six standard views, through both drawing paths:
   - the on-screen path (MIP), where markers are told apart by their grey level;
   - the offscreen 3D (composite) path, where markers are solid objects.

   One perspective view is checked too. The expected sides come from the physical
   situation, not from the engine code.
3. **CPR / panorex** (`BKAccuracyCPRTests`, `CPRGenerator`): straightened and stretched
   (panorex) images, with linear and cubic interpolation, on two paths through the 40 mm
   dots: a straight path and a dental-arch-shaped curve. Checks:
   - the image length along the path;
   - where the dots are and how far apart they are along the path;
   - every pixel against the CPU reference.
4. **2D display** (`BKAccuracyDisplayTests`, `BKViewTransform` + `BKImageLayerRenderer`):
   - one known image pixel is followed through zoom, pan, flips and rotation, against
     numbers worked out by hand, both in the math and on the real GPU drawing;
   - 40 mm stays 40 mm on screen with non-square pixels and rotation.

## The conventions the code uses (confirmed by the tests)

Patient coordinates are DICOM "LPS", in millimetres:
- **+x** = toward the patient's **left**
- **+y** = toward the **back** (posterior)
- **+z** = toward the **head** (superior)

| Image | Screen right | Screen top | Convention |
|---|---|---|---|
| Axial MPR | patient **left** | front (anterior) | radiological (seen from the feet) |
| Coronal MPR | patient **left** | head | radiological (seen from the front) |
| Sagittal MPR | back (posterior); the face is on the **left** | head | seen from the patient's left |
| 3D Anterior view | patient left | head | |
| 3D Posterior view | patient right | head | |
| 3D Left view | back | head | |
| 3D Right view | front | head | |
| 3D Inferior view (from the feet) | patient left | front | same as axial |
| 3D Superior view (from above) | patient right | front | |

The MPR engine itself just follows the image's "right" and "down" directions that the app
gives it. Boros 6 passes the standard DICOM directions shown above, so the patient's left
is on the screen's right in axial and coronal images (radiological convention).

The renderer's rule is: image right = cross(view direction, up).

**CPR layout:**
- **Columns:** column 0 is the start of the curve, and column i shows the point i x step
  along the curve (step = curve length / image width).
- **Rows:** the middle row is on the curve; rows run along `initialNormal` (straightened)
  or `projectionNormal` (panorex), both chosen by the app.

## How to run

```sh
cd BorosKit
# only the accuracy check (about 1 second of tests, plus the build)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BKAccuracy
# one part, e.g. the MPR tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BKAccuracyMPRTests
```

Every measurement is printed on a line starting with `ACCURACY |`. To see them all:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BKAccuracy 2>&1 | grep "^ACCURACY"
```

The GPU tests skip themselves on a computer without a Metal GPU.

## Latest results (2026-11-11, Apple M1 Pro, macOS)

All 13 accuracy tests pass. The goal for positions and distances was "within half a
voxel", which is 0.15 mm here.

| Check | Result |
|---|---|
| MPR marker positions (81 measurements, 3 grids x 3 planes + thin slices) | largest error **0.005 mm** |
| MPR 40 mm distances (slabs and thin slices, incl. oblique) | 39.996 to 40.001 mm (largest error **0.004 mm**) |
| MPR left/right, top/bottom, mirrored spots | all correct, mirrored spots empty, in every grid layout |
| MPR GPU vs CPU reference (15 thin slices, ~48,000 pixels each) | largest difference **2.3 HU**, average **0.007 HU** |
| 3D standard views, marker positions (18) | largest error **0.004 mm**; all on the correct side |
| 3D 40 mm dot pairs (6 views) | 39.998 to 40.001 mm |
| 3D composite + perspective views | every marker opaque at its spot, see-through at the mirrored spot |
| CPR straight path, length and dots | 50.000 mm (true 50.000); dots **40.000 mm** apart |
| CPR straight path, linear, vs CPU reference | **0.00 HU** difference |
| CPR curved arch, length | 62.659 mm (true 62.684): **0.025 mm (0.04 %) short** |
| CPR curved arch, distance between dots along the curve | 52.651 to 52.658 mm (true 52.684): 0.03 mm short |
| CPR curved arch, linear, vs CPU reference | largest 57 HU at the steepest edges (equal to a shift of about 0.03 mm), average 0.46 HU |
| CPR cubic (the app's default) vs ideal phantom | largest 69 HU, average 0.6 HU (closer to the ideal phantom than linear) |
| 2D display, known pixel to screen (7 cases + 4 on the GPU) | exact (error 0.000 points) |
| 2D display, 40 mm with non-square pixels + rotation | 40.000000 mm |

### Findings

- **Fixed (separate commit):** `-[CPRVolumeData getFloatRun:…]` refused (with an assertion)
  to read a run that ends on the last pixel of a row, such as a whole row. It is used by
  ROI pixel statistics in the app. The bounds check was off by one.
- **Not a bug, noted:** on curved paths the CPR engine first splits the curve into short
  straight pieces (as Horos always did). So the length along a curve comes out about
  0.04 % short: 0.025 mm on a 63 mm arch, far below one voxel.
- **Not a bug, noted:** small soft objects (here the 0.8 mm dots) look slightly less
  bright in every view than their true peak. Each pixel blends the voxels around it. The
  pixel values match the CPU reference exactly, so this is how sampling works, not an
  engine error.
