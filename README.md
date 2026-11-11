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
   **Display (`BorosKitDisplay`)**: started. The 2D viewer layer: Metal draws
   a slice or slab image on screen and Core Graphics draws the ROIs, curves and
   measurements on top. It replaces the old OpenGL drawing in Horos' image views.
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

### 3D presets (`BKPreset`, `BKPresetLoader`)

**What it does:** reads the same 3D preset files the VR window uses, such as
"Standard", "Bone + Skin", "Glossy" and "Vascular", and sets up the Metal engine to
show the same look.

**Why:** people know these looks. The new engine has to show the same image for the
same preset, so the move away from VTK isn't noticed.

**How:** a preset file names a colour table, an opacity table and a lighting setting.
The loader looks these names up the way Horos does:
- **Colour tables:** "<name>.plist" in the user's CLUTs folder first, then the app's
  built-in CLUTs folder. You pass both folders to the loader.
- **Opacity tables and lighting:** the built-in ones are generated with the same
  formulas Horos uses. You can add the user's own from their settings.

It then builds the colour/opacity rule exactly as `VRView` hands it to VTK:
- **Simple presets:** a 256-colour table and an opacity curve stretched across the
  window (WL/WW). Like VTK, colours 0–254 are spaced evenly across the window.
- **Advanced (16-bit) presets:** colour and opacity points placed directly at HU
  values. Opacity is the curve height squared, and it falls to 0 at the volume's
  lowest and highest value.
- **Lighting:** ambient, diffuse, specular and specular power from the named lighting
  preset, or off.
- **Projection:** parallel, or perspective at 30° or 60°.

**Supported:** all 29 built-in presets load with every name resolved (they are in the
tests). Also supported: the built-in and user colour tables (Red/Green/Blue
plists), saved 16-bit CLUT files ("curves"/"colors"), the user's own opacity tables
and lighting presets, and XML or binary plists. None of these need AppKit, so it works
on iPad too.

**Not supported yet:**
- **The preset's background colour** is stored in the preset. The offscreen renderer
  outputs a transparent background; the interactive 3D view (`BKVolumeView`) paints
  the preset's colour behind the volume.
- **Convolution filters** (e.g. "Basic Smooth 5x5", which Horos applies to the volume
  before rendering) are stored by name but not applied.
- **"Inverted polarity"** (a macOS display setting Horos checks) is ignored.
- **Very old OsiriX presets** that stored archived NSColor objects can't be read.

**If a name can't be found**, the loader falls back the way Horos does: "No CLUT",
"Linear Table" or "Default" lighting. The preset's `warnings` list says what happened.

## The 2D display (`BorosKitDisplay`)

### What it does, in plain terms

This is the start of the new image viewer that Boros 6 (and later the iPad app)
will use instead of Horos' OpenGL viewer. It has three parts:

- **The image** (`BKImageLayerRenderer`): the graphics chip draws the slice or
  slab with window/level, an optional colour table, invert, zoom, pan, rotation,
  flips, and blocky (nearest) or smooth (linear) pixels. The real CT values are
  kept at full precision on the chip, so window/level works on the actual
  Hounsfield units, not on a pre-made 8-bit picture.
- **The drawings on top** (`BKOverlay`): lines, polygons, smooth curves (the
  panorex curve comes straight from the CPR engine's curve), handles, rectangles,
  ellipses, text labels and a scale bar. They are drawn with Apple's standard 2D
  drawing (Core Graphics), which looks crisp and works the same on Mac and iPad.
  Line widths and text sizes stay the same on screen at any zoom.
- **The view** (`BKImageView`): the on-screen box that holds both, an `NSView`
  on the Mac and a `UIView` on iPad with the same functions. It offers actions
  such as pan, zoom around a point, rotate, window/level drag and reset, but it
  does not decide which mouse button or finger gesture triggers them: the Mac and
  iPad apps each wire up their own.

### Why overlays can't drift off the anatomy

One description of "where the image sits on screen" (`BKViewTransform`: zoom,
pan, rotation, flips, non-square pixels) is used by the image drawing, by every
overlay and by the mouse/touch conversion. In Horos these were separate pieces of
math in several places. Tests check that every combination converts back and
forth exactly.

### Conventions

- Image coordinates are pixels with the origin at the top-left, y down; pixel
  (i, j) has its centre at (i + 0.5, j + 0.5).
- View coordinates are points with the origin at the top-left, y down, on both
  platforms (the Mac view is "flipped" to match).
- Window/level: values at or below `center - width/2` are black, at or above
  `center + width/2` white, linear in between (the same rule as Horos).

### Limits for now

- One grayscale (float) image per view; no colour (RGB) images and no fusion
  overlay of a second series yet.
- Drawing happens on the main thread when asked (`setNeedsRedraw`); there is no
  animation loop, which is fine for a viewer that only changes on user input.
- Not yet used by Boros 6: adopting it in the app's image view is the next part
  of step 3 (see below).

## The interactive 3D view (`BKVolumeView`, `BKVolumeScene`, `BKVolumeCamera`)

### What it does, in plain terms

This is the Metal replacement for the VTK view in the 3D (VR) window, for Mac and
iPad. It has three parts:

- **The camera** (`BKVolumeCamera`, in Render): what you look at and from where.
  It does the moves of the VR window: trackball rotate (a drag across the whole
  view turns 200°, like VTK), pan (the volume follows the pointer exactly), zoom,
  roll, reset, and the standard views. The standard views match the Horos
  buttons: front (`coView`), left side (`saView`, also Horos' reset view), right
  side (`saViewOpposite`), from the feet (`axView`), plus back and from above.
  Switching views keeps the zoom, as in Horos.
- **The scene** (`BKVolumeScene`, in Render): everything that is shown, without
  the screen: the volume, the camera, the preset, window/level, the background
  colour and the quality while you move. The window/level drag uses the VR
  window's formula: per mouse step, level -= dy x WW/100 and width += dx x WW/100.
  For simple presets this moves the colours and opacity; for 16-bit presets it
  moves and stretches the first curve, as Horos' CLUT editor does.
- **The view** (`BKVolumeView`, in Display): an `NSView` on the Mac and a `UIView`
  on iPad. The graphics chip draws the 3D image straight into the screen, so no
  pixels are copied back and the app never waits for the GPU. Like the 2D view,
  it offers actions (rotate, pan, zoom, roll, window/level, standard views, crop,
  clipping plane) and each app decides which mouse or touch gesture triggers them.

### Quality while you move (adaptive, not always lower)

Horos always lowers the resolution while you rotate, which makes the image swim
even on fast computers. Here the scene measures how long each frame takes on the
graphics chip and only lowers quality **if full quality would miss the frame
budget** (16 ms, about 60 frames per second, by default):

- If full quality fits, rotation stays at full quality.
- If not, it steps down one level at a time: 75 % resolution, 50 %, then 50 % with
  half as many samples per ray, then 35 %. It steps back up when there is clearly
  room (the finer level is estimated to fit in 80 % of the budget), so it doesn't
  flicker between levels.
- A full-quality frame is always drawn once you stop (after 0.25 s without a move,
  or when the app says the drag ended).

The decision is two small functions (`BKInitialInteractiveQualityLevel`,
`BKNextInteractiveQualityLevel`) with their own tests. `currentQualityLevel`,
`lastFrameTime` and `lastFullQualityFrameTime` show what is happening.

### Also new in the renderer

- **Render into a GPU texture** (`-encodeRenderToTexture:commandBuffer:...`):
  the same ray-casting code as the offscreen render (one shared function in the
  shader, so they cannot drift apart), written straight into the screen image
  over the background colour.
- **Clipping plane** (`clipPlane`, `clipPlaneEnabled`): cuts away everything on
  one side of a plane. This is the building block for the VR window's scissors.
- **Lighting** was already in place: the light sits at the viewer, and each sample
  gets ambient + diffuse + specular light from the local surface direction (the
  value gradient), with the preset's lighting values.

### Limits for now

- The view isn't used by Boros 6 yet (see step 4 below).
- No PET/CT fusion (a second, blended volume), no 3D measurements or point
  picking on the surface, and no movie/turntable export yet.
- Volumes larger than 2048 voxels per side can't be loaded onto the GPU.

## The plan, step by step

1. **Metal volume engine**: this package. Done: composite, MIP, MinIP and
   average, slabs, both cameras, cropping, transfer functions, tests.
2. **Switch the MPR views and the CPR slab to it**, removing the hidden VTK
   renderers (the source of past crashes), in Boros 6.
3. **New 2D image display** (started: `BorosKitDisplay`): Metal draws the image (with window/level and colour
   tables); overlays (ROIs, the panorex curve, crosshairs, measurements) are
   drawn with Apple's standard 2D drawing (Core Graphics), which works with
   touch and Apple Pencil on iPad.
4. **3D window on Metal** (started: `BKVolumeView`) in Boros 6, behind a switch, so it can be compared
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
