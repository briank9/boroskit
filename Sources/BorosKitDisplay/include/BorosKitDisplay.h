// BorosKitDisplay umbrella header: the 2D image display layer (Metal image + CoreGraphics
// overlays) shared by the Mac and iPad apps. See README "Display".
#import "BKViewTransform.h"
#import "BKImageLayerRenderer.h"
#import "BKOverlay.h"
#import "BKTextLayoutCore.h"   // 2026-11-14: plain-C placement of view-pinned labels
#import "BKOverlayCore.h"      // 2026-11-16: plain-C 2D overlay engine core (draw list -> triangles)
#import "BKOverlayRenderer.h"  // 2026-11-16: Metal renderer of the overlay draw list
#import "BKAngleCore.h"        // 2026-11-16: arc marking a measured angle (angle ROIs)
#import "BKROICore.h"          // 2026-11-16: ROI geometry, measurements, inside rule, statistics
#import "BKROIDraw.h"          // 2026-11-16: ROI drawing into the overlay draw list
#import "BKTextOverlay.h"      // 2026-11-14: view-pinned text labels (WL/WW, orientation letters ...)
#import "BKImageView.h"
#import "BKVolumeView.h"
