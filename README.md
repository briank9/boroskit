# BorosKit

BorosKit is the shared imaging engine behind **Boros**, a fork of Horos for oral
and maxillofacial imaging. The goal is to make one engine that both the Mac app
and a future iPad app can use, so the image math is written and tested once.

## How it is organized

BorosKit is split into three layers. Only the first one exists so far.

1. **Core (`BorosKitCore`)**: available now. This layer holds the data and does
   the math: holding a CT volume in memory, the 3D geometry (vectors, transforms,
   curves), and **building the images**, meaning the panorex, the cross-sections
   and the oblique slices. Its output is a grid of pixel values. It uses no
   windows, buttons or on-screen drawing, so the same code runs on macOS and
   iOS/iPadOS.
2. **Render**: planned. This layer will draw images and 3D volumes on screen
   quickly, using Apple's Metal graphics system, which works on both Mac and
   iPad. It will replace the old OpenGL/VTK drawing over time.
3. **App screens**: kept separately for each device. Windows, toolbars, mouse
   handling, touch and Apple Pencil stay in each app, because a Mac and an iPad
   should feel different.

## What has been moved in so far

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

## Building and testing

```sh
# macOS build and tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# iOS build check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme BorosKit -destination 'generic/platform=iOS' build
```

The tests build a small artificial volume and generate a straight CPR and a
curved, panorex-style CPR from it. They then check the image size and that the
pixel values come from the right places.

## Notes
- The engine code uses manual memory management (retain/release), like Horos.
  The package compiles it with `-fno-objc-arc` so its behaviour doesn't change.
- `QuartzCore` is linked only for `CATransform3D`, the 4×4 matrix type that the
  geometry code is built on. It is pure math, available on macOS and iOS, and
  not used for drawing.
- License: LGPL, inherited from Horos/OsiriX. See the headers in each file.
