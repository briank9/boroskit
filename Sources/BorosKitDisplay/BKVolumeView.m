// BorosKitDisplay: BKVolumeView implementation (macOS NSView / iOS UIView). See header.

/* BOROS OVERVIEW (plain language)
 * This file is the on-screen 3D view of the scan, where the clinician sees the jaw
 * and skull as a solid model that can be turned around, rather than as slices.
 * The picture is redrawn by the graphics chip (Metal) whenever something changes.
 * Gestures rotate, pan and zoom the model. The view can also switch between preset
 * looks (different tissue emphasis), crop the volume, cut it with a clipping plane,
 * and adjust brightness and contrast.
 * While the user is moving the model it draws a fast, lower-detail picture, then a
 * sharp full-quality frame once the movement stops, which keeps motion smooth.
 */

#import "BKVolumeView.h"
#import "BKPreset.h"
#import <QuartzCore/QuartzCore.h>

@implementation BKVolumeView {
    CAMetalLayer *_metalLayer;
    BOOL _redrawScheduled;   // a frame is queued on the main queue
    BOOL _frameInFlight;     // the GPU is still working on the previous frame
    BOOL _redrawPending;     // something changed while a frame was in flight
    BOOL _autoInteraction;   // interaction started by a move (ends after idleDelay)
}

#pragma mark - Setup

#if TARGET_OS_OSX
// What: AppKit initialisers. Why: views from code and from nibs both work.
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        [self commonInit];
    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder]))
        [self commonInit];
    return self;
}

// What: y-down coordinates on the Mac. Why: same as iOS and the rest of BorosKit.
- (BOOL)isFlipped
{
    return YES;
}
#else
// What: UIKit initialisers.
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
        [self commonInit];
    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder]))
        [self commonInit];
    return self;
}
#endif

// What: creates the Metal layer and the scene.
// Why: framebufferOnly = NO because the ray-cast kernel WRITES into the drawable
// (compute), instead of drawing triangles into it.
- (void)commonInit
{
#if TARGET_OS_OSX
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
#endif
    _idleDelay = 0.25;
    NSError *error = nil;
    _scene = [[BKVolumeScene alloc] initWithDevice:nil error:&error];
    if (!_scene)
        NSLog(@"BKVolumeView: no Metal renderer (%@)", error);

    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _scene.renderer.device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = NO;
    _metalLayer.opaque = YES;
    [self.layer addSublayer:_metalLayer];
}

#pragma mark - Layout

// What: device pixels per point. Why: the drawable must match the real screen resolution.
- (CGFloat)displayScale
{
#if TARGET_OS_OSX
    CGFloat scale = self.window ? self.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
#else
    CGFloat scale = self.traitCollection.displayScale;
#endif
    return scale > 0 ? scale : 1.0;
}

// What: sizes the Metal layer and its drawable to the view, then redraws.
- (void)updateLayerGeometry
{
    CGRect bounds = self.bounds;
    CGFloat scale = [self displayScale];
    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // no implicit animation while resizing
    _metalLayer.frame = bounds;
    _metalLayer.contentsScale = scale;
    _metalLayer.drawableSize = CGSizeMake(MAX(1, bounds.size.width * scale), MAX(1, bounds.size.height * scale));
    [CATransaction commit];
    [self setNeedsRedraw];
}

#if TARGET_OS_OSX
// What: AppKit layout pass / backing scale changes. Why: keep the drawable sharp.
- (void)layout
{
    [super layout];
    [self updateLayerGeometry];
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self updateLayerGeometry];
}
#else
// What: UIKit layout pass.
- (void)layoutSubviews
{
    [super layoutSubviews];
    [self updateLayerGeometry];
}
#endif

#pragma mark - Drawing

// What: asks for a frame; many requests before it is drawn collapse into one.
// Why: mouse events arrive faster than frames; drawing each would queue up latency.
- (void)setNeedsRedraw
{
    if (_redrawScheduled) return;
    _redrawScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_redrawScheduled = NO;
        [self renderFrame];
    });
}

// What: encodes one frame into the next drawable and presents it, without waiting.
// Why: at most one frame is in flight; changes during it trigger exactly one follow-up
// frame, so the picture always catches up with the latest camera.
- (void)renderFrame
{
    if (!_scene || !_scene.volumeTexture) return;
    if (_frameInFlight) {
        _redrawPending = YES;
        return;
    }
    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) return;

    id<MTLCommandBuffer> commandBuffer = [_scene.renderer.commandQueue commandBuffer];
    NSError *error = nil;
    if (![_scene encodeFrameToTexture:drawable.texture commandBuffer:commandBuffer error:&error]) {
        NSLog(@"BKVolumeView: cannot render (%@)", error);
        return;
    }
    _frameInFlight = YES;
    __weak BKVolumeView *weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BKVolumeView *view = weakSelf;
            if (!view) return;
            view->_frameInFlight = NO;
            if (view->_redrawPending) {
                view->_redrawPending = NO;
                [view setNeedsRedraw];
            }
        });
    }];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

#pragma mark - Content

// What: loads a volume and redraws. Why: one call for the app.
- (BOOL)setVolumeData:(CPRVolumeData *)volumeData error:(NSError **)error
{
    if (!_scene) return NO;
    BOOL ok = [_scene setVolumeData:volumeData error:error];
    [self setNeedsRedraw];
    return ok;
}

// What: applies a preset and redraws.
- (void)applyPreset:(BKPreset *)preset
{
    [_scene applyPreset:preset];
    [self setNeedsRedraw];
    [self notifyWindowLevel];
}

- (BKRenderMode)mode
{
    return _scene.mode;
}

// What: switches the render mode and redraws.
- (void)setMode:(BKRenderMode)mode
{
    _scene.mode = mode;
    [self setNeedsRedraw];
}

#pragma mark - Interaction

// What: marks the start of a move. Explicit brackets win over the automatic idle end.
- (void)beginInteraction
{
    _autoInteraction = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleEndInteraction) object:nil];
    [_scene beginInteraction];
}

// What: ends a move and draws a full-quality frame.
- (void)endInteraction
{
    _autoInteraction = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleEndInteraction) object:nil];
    [_scene endInteraction];
    [self setNeedsRedraw];
}

// What: called by every interaction method. Starts an interaction if none is running
// and (re)arms the idle timer that ends it. Why: callers that only forward moves (e.g.
// scroll wheel) still get adaptive quality and a final full-quality frame.
- (void)noteInteraction
{
    if (!_scene.interacting) {
        [_scene beginInteraction];
        _autoInteraction = YES;
    }
    if (_autoInteraction) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleEndInteraction) object:nil];
        [self performSelector:@selector(idleEndInteraction) withObject:nil afterDelay:_idleDelay];
    }
}

// What: the idle timer fired. Why: no move for idleDelay -> full quality.
- (void)idleEndInteraction
{
    if (_autoInteraction) [self endInteraction];
}

// What: view size in points, for camera moves measured in points.
- (CGSize)viewSize
{
    return self.bounds.size;
}

// What: helpers that redraw and tell the delegate. Why: every move ends with these.
- (void)cameraChanged
{
    [self setNeedsRedraw];
    if ([_delegate respondsToSelector:@selector(volumeViewDidChangeCamera:)])
        [_delegate volumeViewDidChangeCamera:self];
}

- (void)notifyWindowLevel
{
    if ([_delegate respondsToSelector:@selector(volumeViewDidChangeWindowLevel:)])
        [_delegate volumeViewDidChangeWindowLevel:self];
}

// What: trackball rotation for a drag. Why: the 3D rotate tool.
- (void)rotateByViewDelta:(CGSize)delta
{
    [self noteInteraction];
    [_scene.camera rotateByViewDelta:delta viewSize:[self viewSize]];
    [self cameraChanged];
}

// What: moves the volume with the pointer. Why: the pan tool.
- (void)panByViewDelta:(CGSize)delta
{
    [self noteInteraction];
    [_scene.camera panByViewDelta:delta viewSize:[self viewSize]];
    [self cameraChanged];
}

// What: zoom (orthographic) / dolly (perspective). Why: scroll wheel, pinch.
- (void)zoomByFactor:(CGFloat)factor
{
    [self noteInteraction];
    [_scene.camera zoomByFactor:factor];
    [self cameraChanged];
}

// What: spins the image around the viewing direction. Why: roll tool, rotate gesture.
- (void)rollByDegrees:(CGFloat)degrees
{
    [self noteInteraction];
    [_scene.camera roll:degrees];
    [self cameraChanged];
}

// What: the VR window's WL/WW drag. Why: same feel as Horos.
- (void)adjustWindowLevelByDeltaX:(CGFloat)dx deltaY:(CGFloat)dy
{
    [self noteInteraction];
    [_scene adjustWindowLevelByDeltaX:dx deltaY:dy];
    [self setNeedsRedraw];
    [self notifyWindowLevel];
}

// What: one of the standard view buttons (keeps the zoom).
- (void)showStandardView:(BKStandardView)view
{
    [_scene.camera showStandardView:view];
    [self cameraChanged];
}

// What: fit the volume and show the reset view.
- (void)resetView
{
    [_scene resetCamera];
    [self cameraChanged];
}

#pragma mark - Cropping and clipping

// What: sets the cropping box (voxel indices, inclusive) and redraws.
- (void)setCropMin:(N3Vector)cropMin max:(N3Vector)cropMax
{
    _scene.renderer.cropMin = cropMin;
    _scene.renderer.cropMax = cropMax;
    [self setNeedsRedraw];
}

// What: sets/clears the clipping plane and redraws.
- (void)setClipPlane:(N3Plane)plane enabled:(BOOL)enabled
{
    _scene.renderer.clipPlane = plane;
    _scene.renderer.clipPlaneEnabled = enabled;
    [self setNeedsRedraw];
}

@end
