# BorosKit

BorosKit is the shared imaging engine behind **Boros**, a fork of Horos for oral
and maxillofacial imaging. The goal is to make one engine that both the Mac app
and a future iPad app can use, so the image math is written and tested once.

## How it is organized

BorosKit is split into three layers. The first two live in this package.

1. **Core (`BorosKitCore`)**: available now. This layer holds the data and does
   the math: holding a CT volume in memory, the 3D geometry (vectors, transforms,
   curves), and **building the images**, meaning the panorex, the cross-sections
   and the oblique slices. Its output is a grid of pixel values. It uses no
   windows, buttons or on-screen drawing, so the same code runs on macOS and
   iOS/iPadOS.
2. **Render (`BorosKitRender`)**: started. This layer uses the graphics chip
   (GPU) through Apple's **Metal**, which works on both Mac and iPad, to turn a
   CT volume into pictures: 3D renderings, MIP/MinIP/average projections, and
   thick or thin slabs (the MPR slices). It replaces the old VTK + OpenGL
   rendering step by step. So far it renders off-screen into pixel buffers; the
   on-screen views come in later steps.
3. **App screens**: kept separately for each device. Windows, toolbars, mouse
   handling, touch and Apple Pencil stay in each app, because a Mac and an iPad
   should feel different.

## What has been moved in so far (Core)

This is the **CPR engine**: the code that turns a curve drawn through a CT scan
into a straightened or "stretched" (panorex-style) image, plus slab/MIP options.
It was copied from Boros/Horos with the same class names, so the Mac app and
existing plugins keep working when they switch to it.

| Files | What they do |
|---|---|
| `CPRVolumeData` | A CT volume in memory plus its position in the patient |
| `CPRGenerator`, `CPRGeneratorOperation` | Runs image requests, synchronously or in the background |
| `CPRGeneratorRequest` | Describes the wanted image (straightened, stretched/panorex, oblique slice) |
| `CPRStraightenedOperation`, `CPRStretchedOperation`, `CPRObliqueSliceOperation` | Build each kind of image |
| `CPRHorizontalFillOperation`, `CPRProjectionOperation` | Sampling the volume, and the slab modes (MIP, MinIP, mean) |
| `CPRUnsignedInt16ImageRep` | A 16-bit pixel buffer, used for DICOM export |
| `N3Geometry`, `N3BezierCore`, `N3BezierCoreAdditions`, `N3BezierPath` | 3D vectors, transforms and curves |

### Changes made while moving it
- **Mac-only imports replaced.** `Cocoa` and `ApplicationServices` were swapped
  for `Foundation` and `CoreGraphics`.
- **Outdated thread-safety calls modernized.** `OSAtomic` and `OSMemoryBarrier`
  were replaced with standard C11 `<stdatomic.h>`. They behave the same.
- **`CPRUnsignedInt16ImageRep` no longer depends on AppKit.** It used to be an
  AppKit `NSImageRep` that was never actually drawn. It is now a plain object
  with the same name and methods.
- **`CPRVolumeData` no longer reads Horos' `DCMPix` objects.** It now takes the
  plain numbers instead: origin, orientation and spacing. The new initializer is
  `initWithFloatBytesNoCopy:…origin:orientation:spacingX:spacingY:spacingZ:freeWhenDone:`.
  The math is the same as before. The Mac app keeps a small
  `CPRVolumeData (DCMPixAndVolume)` category that reads those values from
  `DCMPix` and calls this initializer.
- **Mac-only helpers fenced off.** The `NSPoint` helpers in `N3Geometry.h` are
  only compiled on macOS. New `CGPoint` versions work on both platforms.

Each changed spot has a `BorosKit:` comment explaining what changed and why.

## The Metal render engine (`BorosKitRender`)

### What it does, in plain terms
For every pixel of the output picture, the GPU sends a straight line (a "ray")
through the CT volume and looks at the values along it:

- **Composite (3D)**: each value gets a colour and a see-through-ness from a
  *transfer function* (e.g. air invisible, soft tissue faint, bone solid
  white). The colours are blended front to back with simple lighting, which
  gives the familiar 3D volume rendering.
- **MIP / MinIP / Average**: keeps the brightest, darkest or mean value along
  the ray.
- **Slab**: limits each ray to a slice of a chosen thickness around a plane.
  With thickness 0 it takes exactly one sample on the plane, which is a normal
  MPR slice. This is what will replace the hidden VTK renderers that Horos
  uses today to draw the MPR views and the CPR slab.
- **Camera**: orthographic (parallel rays, used for MPR, slabs and measurements)
  or perspective (an eye point, for 3D viewing). All positions are in patient
  millimetres, the same coordinate system the CPR engine uses.
- **Cropping box** to cut away parts of the volume, as in the current 3D window.

Every render gives back two pictures: an 8-bit colour image for the screen, and
a full-precision 32-bit value per pixel for diagnostic export (e.g. a MIP or slab
saved as 16-bit DICOM).

| Files | What they do |
|---|---|
| `BKVolumeTexture` | Copies a `CPRVolumeData` volume onto the GPU |
| `BKTransferFunction` | Colour + opacity per CT value; can hold Horos' simple (CLUT + opacity curve) and advanced presets |
| `BKVolumeRenderer`, `BKRenderResult` | Camera, modes, slab, cropping; renders and returns the pixels |
| `BKShaderSource.mm` | The GPU program (Metal shader) that does the ray casting |
| `BKShaderTypes.h` | The settings block shared by the CPU and the GPU |

### Design choices (and why)
- **Objective-C + Metal**, the same language as the Core and the Mac app, so
  the app can call it directly with no bridging layer. The render code uses
  automatic memory management (ARC); the Core keeps Horos' manual style.
- **Volume stored as 16-bit on the GPU** (`R16Unorm` with a scale and offset).
  It uses half the memory of 32-bit floats, which matters for large CBCTs on an
  iPad. The GPU can interpolate it on every Mac and iPad. Each voxel is stored
  within about 0.03 HU of its true value, so whole-number CT values round back
  exactly. 16-bit "half floats" were rejected: they cannot hold every CT value
  above 2048 exactly, which would change bright bone and metal in MIP exports.
- **Shader compiled when the app runs**, from source embedded in the library.
  That works the same whether BorosKit is built with `swift build`, Xcode, as a
  local package or a submodule. It costs a one-time compile of a few tens of
  milliseconds when the first renderer is created.
- **One definition of the CPU/GPU settings block.** The fields are written once
  in `BKShaderTypes.h` and pasted into the shader as text, so the two can't
  drift apart. A test also checks that both sides agree on its size.
- **Opacity is corrected for the sample spacing**, so changing render quality
  doesn't make the 3D image lighter or darker (Horos used its super-sampling
  factor for this).
- **Transfer functions** keep colour and opacity as separate point lists,
  exactly like the VTK classes Horos uses, so existing presets can be converted
  1:1 later.

### Limits for now
- The largest volume is 2048 voxels per side (a GPU limit for 3D textures).
- Rendering waits for the GPU to finish. That's fine for exports and tests;
  the on-screen views will need a non-blocking version.
- Single volume only: no PET/CT fusion yet.
- The lighting is simple (a light at the viewer). No shadows.

## The plan, step by step

1. **Metal volume engine**: this package. Done: composite, MIP, MinIP and
   average, slabs, both cameras, cropping, transfer functions, tests.
2. **Switch the MPR views and the CPR slab to it**, removing the hidden VTK
   renderers (the source of past crashes), in Boros 6.
3. **New 2D image display**: Metal draws the image (with window/level and colour
   tables); overlays (ROIs, the panorex curve, crosshairs, measurements) are
   drawn with Apple's standard 2D drawing (Core Graphics), which works with
   touch and Apple Pencil on iPad.
4. **3D window on Metal** in Boros 6, behind a switch, so it can be compared
   side by side with the old VTK version.
5. **Meshes**: bone surfaces, intraoral scans (STL/PLY) and implant models,
   drawn with Metal. This is the base for the CMF workspace and implant
   planning.
6. **Housekeeping**: VTK 9 and ITK 5.4 kept only for math (meshes, segmentation,
   registration), and the movie export moved from QTKit to AVFoundation.

## Building and testing

```sh
# macOS build and tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# iOS build check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme BorosKit-Package -destination 'generic/platform=iOS' build-for-testing
```

- **Core tests** build a small artificial volume and generate a straight CPR
  and a curved, panorex-style CPR from it. They then check the image size and
  that the pixel values come from the right places.
- **Render tests** run on the real GPU (they are skipped on a machine without
  one). They use a bright sphere in a dark, graded cube and check MIP, MinIP,
  average, thick and thin slabs (including in-between interpolation and real
  millimetre spacing), cropping, perspective, the 3D composite image, Horos-style
  presets, and that the CPU and GPU agree on the settings layout.

## Notes
- The engine code uses manual memory management (retain/release), like Horos.
  The package compiles it with `-fno-objc-arc` so its behaviour doesn't change.
- `QuartzCore` is linked only for `CATransform3D`, the 4×4 matrix type that the
  geometry code is built on. It is pure math, available on macOS and iOS, and
  not used for drawing.
- License: LGPL, inherited from Horos/OsiriX. See the headers in each file.
