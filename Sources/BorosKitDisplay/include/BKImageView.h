// BorosKitDisplay: BKImageView
//
// What it is: a thin on-screen view that shows a BKImage with BKImageLayerRenderer
// (Metal, in a CAMetalLayer) and draws BKOverlay items (CoreGraphics, in a separate
// layer on top). An NSView on macOS, a UIView on iOS/iPadOS — same API on both.
//
// Why so thin: everything that matters (image drawing, overlays, coordinate math) lives
// in platform-neutral classes. This view only owns the layers and offers interaction
// METHODS (pan, zoom, rotate, window/level) instead of wiring up mouse or touch events
// itself, because a Mac (mouse, scroll wheel, trackpad) and an iPad (touch, pinch,
// Apple Pencil) should drive them differently. The app's view controller or a subclass
// maps its own events to these calls.
//
// Coordinates: view points with the origin at the top-left, y down, on both platforms
// (the macOS view is flipped).

#import <TargetConditionals.h>
#import "BKImageLayerRenderer.h"
#import "BKOverlay.h"
#import "BKViewTransform.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#define BKPlatformView NSView
#else
#import <UIKit/UIKit.h>
#define BKPlatformView UIView
#endif

NS_ASSUME_NONNULL_BEGIN

@class BKImageView;

// Told about changes the user made through the interaction methods, so the app can sync
// other views (linked zoom, WL shown in the corner, etc.).
@protocol BKImageViewDelegate <NSObject>
@optional
- (void)imageViewDidChangeViewTransform:(BKImageView *)imageView;
- (void)imageViewDidChangeWindowLevel:(BKImageView *)imageView;
@end

@interface BKImageView : BKPlatformView

// The Metal renderer (created with the default GPU unless one is assigned). nil only if
// the machine has no Metal device.
@property (nonatomic, strong, nullable) BKImageLayerRenderer *renderer;

@property (nonatomic, weak, nullable) id<BKImageViewDelegate> delegate;

// The image shown. Setting a new image resets the view to fit if `keepsImageFitted`.
@property (nonatomic, strong, nullable) BKImage *image;

// Overlays drawn above the image, in order (later on top).
@property (nonatomic, copy) NSArray<BKOverlayItem *> *overlays;

// Current transform (forwarded to the renderer). Setting it redraws.
@property (nonatomic) BKViewTransform viewTransform;

// YES: re-fit the image when the view resizes or a new image arrives. Turns NO when the
// user zooms or pans, YES again after -resetView.
@property (nonatomic) BOOL keepsImageFitted;

// Window/level shortcuts (forwarded to the renderer).
@property (nonatomic) double windowCenter;
@property (nonatomic) double windowWidth;

// How strongly -adjustWindowLevelByDeltaX:deltaY: reacts (units of value per point).
// Default 2 (Horos-like feel for CT).
@property (nonatomic) double windowLevelSensitivity;

// Redraws image and overlays (call after changing renderer settings or overlay items).
- (void)setNeedsRedraw;

// Interaction — call these from mouse, trackpad, touch or Pencil handlers.
- (void)panByViewDelta:(CGSize)delta;                             // drag
- (void)zoomByFactor:(CGFloat)factor aroundViewPoint:(CGPoint)p;  // wheel / pinch
- (void)rotateByDegrees:(CGFloat)degrees;                         // rotate gesture
- (void)adjustWindowLevelByDeltaX:(CGFloat)dx deltaY:(CGFloat)dy; // WL drag: x = width, y = level
- (void)resetView;                                                // fit, no rotation/flip

// Coordinate helpers (view points <-> image pixels) and the pixel value under a point
// (NAN outside the image), for the corner readout and tools.
- (CGPoint)imagePointForViewPoint:(CGPoint)viewPoint;
- (CGPoint)viewPointForImagePoint:(CGPoint)imagePoint;
- (float)pixelValueAtViewPoint:(CGPoint)viewPoint;

@end

NS_ASSUME_NONNULL_END
