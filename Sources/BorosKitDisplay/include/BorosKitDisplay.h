// BorosKitDisplay umbrella header: the 2D image display layer (Metal image + CoreGraphics
// overlays) shared by the Mac and iPad apps. See README "Display".
#import "BKViewTransform.h"
#import "BKImageLayerRenderer.h"
#import "BKOverlay.h"
#import "BKTextLayoutCore.h"   // 2026-11-14: plain-C placement of view-pinned labels
#import "BKTextOverlay.h"      // 2026-11-14: view-pinned text labels (WL/WW, orientation letters ...)
#import "BKImageView.h"
#import "BKVolumeView.h"
