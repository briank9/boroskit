// BorosKitDisplay: BKVolumeView
//
// What it is: the on-screen interactive 3D view (the Metal replacement for the VTK view
// in the VR window). An NSView on macOS, a UIView on iOS/iPadOS, same API on both. The
// 3D image is ray-cast by the GPU straight into the screen's drawable (CAMetalLayer), so
// no pixels are copied back to the CPU and the main thread never waits for the GPU.
//
// Why so thin: everything that decides what is shown lives in BKVolumeScene (renderer,
// camera, preset, window/level, adaptive quality), which is platform-neutral and
// testable. Like BKImageView, this view offers interaction METHODS (rotate, pan, zoom,
// roll, window/level...) and does not wire mouse or touch itself: the Mac app maps its
// mouse/trackpad, the iPad app its gestures.
//
// Interaction quality: every interaction method marks the view as "interacting"; frames
// then use BKVolumeScene's adaptive quality, and a full-quality frame is drawn
// automatically `idleDelay` seconds after the last move.

#import <TargetConditionals.h>
#import "BKVolumeScene.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#define BKVolumePlatformView NSView
#else
#import <UIKit/UIKit.h>
#define BKVolumePlatformView UIView
#endif

@class BKPreset, CPRVolumeData;

NS_ASSUME_NONNULL_BEGIN

@class BKVolumeView;

// Told when the user changed the camera or window/level through the view, so the app
// can update its corner text, linked views, etc.
@protocol BKVolumeViewDelegate <NSObject>
@optional
- (void)volumeViewDidChangeCamera:(BKVolumeView *)view;
- (void)volumeViewDidChangeWindowLevel:(BKVolumeView *)view;
@end

@interface BKVolumeView : BKVolumePlatformView

// The scene shown (created with the default GPU; nil if the machine has no Metal GPU).
@property (nonatomic, strong, nullable) BKVolumeScene *scene;

@property (nonatomic, weak, nullable) id<BKVolumeViewDelegate> delegate;

// Seconds without interaction before the full-quality frame (default 0.25).
@property (nonatomic) NSTimeInterval idleDelay;

// YES (default): while the user moves the model, aim for one new picture per screen
// refresh (8.3 ms on a 120 Hz screen) by setting scene.targetInteractiveFrameTime when
// the view enters a window. Set NO to keep your own budget in the scene.
@property (nonatomic) BOOL followsDisplayRefreshRate;

// Diagnostic: when YES, logs frames per second, GPU time per frame and the quality level
// about once a second while the view is drawing (default NO).
@property (nonatomic) BOOL logsFrameTiming;

// Convenience: loads a volume into the scene (fits the camera) and redraws.
- (BOOL)setVolumeData:(CPRVolumeData *)volumeData error:(NSError * _Nullable * _Nullable)error;

// Applies a preset (colours, opacity, WL/WW, lighting, projection, background) and redraws.
- (void)applyPreset:(BKPreset *)preset;

// 3D / MIP / MinIP / mean.
@property (nonatomic) BKRenderMode mode;

// Asks for a new frame (coalesced: many calls before the next frame draw once).
- (void)setNeedsRedraw;

// --- Interaction (call from mouse, trackpad, touch or Pencil handlers) ------------------
- (void)rotateByViewDelta:(CGSize)delta;                          // trackball drag
- (void)panByViewDelta:(CGSize)delta;                             // pan drag (y down)
- (void)zoomByFactor:(CGFloat)factor;                             // wheel / pinch (> 1 = closer)
- (void)rollByDegrees:(CGFloat)degrees;                           // rotate gesture
- (void)adjustWindowLevelByDeltaX:(CGFloat)dx deltaY:(CGFloat)dy; // WL drag
- (void)showStandardView:(BKStandardView)view;                    // view buttons
- (void)resetView;                                                // fit + left view

// Explicit interaction brackets, for callers that know when a gesture starts/ends
// (mouseDown/mouseUp, gesture began/ended). Optional: the methods above also start
// an interaction, and it ends by itself after idleDelay.
- (void)beginInteraction;
- (void)endInteraction;

// --- Cropping and clipping (patient mm for the plane, voxel indices for the box) -------
- (void)setCropMin:(N3Vector)cropMin max:(N3Vector)cropMax;
- (void)setClipPlane:(N3Plane)plane enabled:(BOOL)enabled;
// Up to 6 extra planes (patient mm, normal side cut away), e.g. a rotated crop box.
// count 0 removes them. See -[BKVolumeRenderer setClipPlanes:count:].
- (void)setClipPlanes:(const N3Plane *)planes count:(NSUInteger)count;

@end

NS_ASSUME_NONNULL_END
