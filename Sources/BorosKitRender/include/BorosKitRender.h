// BorosKitRender: umbrella header. The GPU (Metal) rendering layer of BorosKit.
// Builds on BorosKitCore (volume data + geometry) and works on macOS and iOS/iPadOS.
// No OpenGL, VTK, AppKit or UIKit in this layer.

#import "BKTransferFunction.h"
#import "BKVolumeTexture.h"
#import "BKVolumeRenderer.h"
#import "BKPreset.h"
#import "BKPresetLoader.h"
#import "BKVolumeCamera.h"
#import "BKVolumeScene.h"
#import "BKVolumeGeometryLayer.h"   // objects drawn inside the volume picture (2026-11-14)
#import "BKRenderCore.h"      // plain-C maths shared with a future Vulkan backend
#import "BKCameraMath.h"
#import "BKScanGeometryCore.h"   // 2026-11-17: scan placement, orientation letters, trackball maths (plain C)
#import "BKStereoCore.h"         // 2026-11-17: red / blue stereo mixing (plain C)
#import "BKVolumeRayCore.h"      // 2026-11-18: what is under the mouse in a volume (plain C)
#import "BKVolumeFusionCore.h"   // 2026-11-24: colour scans + fusion in the 3D picture (plain C)
#import "BKSlabGeometryCore.h" // MPR / curved-MPR slab picture geometry (plain C, 2026-11-14)
#import "BKSlabCameraCore.h"   // MPR / curved-MPR slab camera + mouse tools (plain C, 2026-11-15)
#import "BKSlabViewCore.h"     // MPR / curved-MPR slab view rules: tools, WL drag, export formats (plain C, 2026-11-24)
#import "BKSlabScanCore.h"     // MPR / curved-MPR scan placement + substitution rules (plain C, 2026-11-24, mpr-colour)
#import "BKSlabBrickCore.h"    // MPR / curved-MPR slab pictures of scans bigger than one GPU texture (plain C, 2026-11-24)
#import "BKSlabColourCore.h"   // MPR / curved-MPR colour (RGB) slab look (plain C, 2026-11-24, mpr-colour)
#import "BKCurveCore.h"         // curved-MPR curve maths (plain C, 2026-11-15)
#import "BKCurvePath.h"         // curved-MPR path object (2026-11-15)
#import "BKCurvedReformatCore.h" // curved-MPR / cross-section picture definition + CPU reference (plain C, 2026-11-15)
#import "BKCurvedReformat.h"     // curved-MPR / cross-section pictures on the GPU (2026-11-15)
#import "BKVecSimd.h"        // Apple glue: BorosKit neutral vectors (BorosKitVec) <-> simd
#import "BKBoxWidgetMath.h"
#import "BKCropBoxCore.h"
#import "BKGPUChoiceCore.h"   // plain-C choice of the graphics card (shared with Vulkan)
#import "BKMetalDevice.h"     // the preferred Metal device (Settings "Graphics card")
#import "BKOrientationCubeCore.h" // plain-C orientation cube geometry, letters, corner camera (2026-11-14)
