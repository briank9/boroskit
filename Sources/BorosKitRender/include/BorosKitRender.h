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
#import "BKRenderCore.h"      // plain-C maths shared with a future Vulkan backend
#import "BKCameraMath.h"
#import "BKBoxWidgetMath.h"
#import "BKCropBoxCore.h"
#import "BKGPUChoiceCore.h"   // plain-C choice of the graphics card (shared with Vulkan)
#import "BKMetalDevice.h"     // the preferred Metal device (Settings "Graphics card")
