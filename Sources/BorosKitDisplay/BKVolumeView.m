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

// What: the display link's target; forwards each screen refresh to the view.
// Why: a display link keeps a strong reference to its target. Pointing it at this small
// object (which holds the view weakly) means the view can still be freed normally.
@interface BKVolumeViewDisplayLinkProxy : NSObject
@property (nonatomic, weak) BKVolumeView *view;
@end

@interface BKVolumeView ()
- (void)displayLinkFired;
@end

@implementation BKVolumeViewDisplayLinkProxy
// What: one screen refresh happened. Why: see -[BKVolumeView displayLinkFired].
- (void)tick:(id)link
{
    [self.view displayLinkFired];
}
@end

// Screen refreshes with nothing to draw before the display link is paused again.
// Why: a running display link wakes the app 120 times a second; pausing it when the
// picture is still costs nothing and it restarts on the next change.
static const NSUInteger kBKIdleTicksBeforePause = 30;

@implementation BKVolumeView {
    CAMetalLayer *_metalLayer;
    BOOL _redrawScheduled;   // a frame is queued on the main queue (fallback without display link)
    BOOL _frameInFlight;     // the GPU is still working on the previous frame
    BOOL _redrawPending;     // something changed while a frame was in flight
    BOOL _autoInteraction;   // interaction started by a move (ends after idleDelay)
    // Frame pacing (see -setNeedsRedraw). Typed `id` because CADisplayLink exists on the
    // Mac only from macOS 14, while the package still supports macOS 12.
    id _displayLink;
    BKVolumeViewDisplayLinkProxy *_displayLinkProxy;
    BOOL _needsFrame;        // a change is waiting for the next screen refresh
    NSUInteger _idleTicks;   // refreshes in a row with nothing to draw
    // Timing log (logsFrameTiming): frames and GPU time summed over about one second.
    CFTimeInterval _timingStart;
    NSUInteger _timingFrames;
    double _timingGPUSum;
    NSInteger _timingWorstLevel;
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
    _followsDisplayRefreshRate = YES;
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

// What: the view was put in (or taken out of) a window.
// Why: the display link belongs to the screen the window is on, so it is made here.
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self updateDisplayLink];
}
#else
// What: UIKit layout pass.
- (void)layoutSubviews
{
    [super layoutSubviews];
    [self updateLayerGeometry];
}

// What: the view was put in (or taken out of) a window. Why: see the macOS version.
- (void)didMoveToWindow
{
    [super didMoveToWindow];
    [self updateDisplayLink];
}
#endif

#pragma mark - Frame pacing

// What: the screen's top refresh rate (60 on most displays, 120 on ProMotion).
- (NSInteger)screenMaximumFramesPerSecond
{
#if TARGET_OS_OSX
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSInteger fps = screen.maximumFramesPerSecond;
#else
    NSInteger fps = (self.window.screen ?: UIScreen.mainScreen).maximumFramesPerSecond;
#endif
    return fps > 0 ? fps : 60;
}

// What: creates the display link when the view is in a window and removes it otherwise.
// Also sets the time budget for a frame while the user moves the model to one screen
// refresh (8.3 ms at 120 Hz), so the adaptive quality aims for a new picture at every
// refresh instead of every second one.
// Why (smoother rotation): before, a frame was drawn whenever a mouse event arrived.
// Mouse events and screen refreshes do not line up, so some refreshes showed no new
// picture and others had one ready too early, which looks like stutter. With a display
// link, frames are drawn in step with the screen.
// Without a display link (macOS 12-13) the older event-driven drawing is used.
- (void)updateDisplayLink
{
    [_displayLink invalidate];
    _displayLink = nil;
    if (!self.window) return;

    if (_followsDisplayRefreshRate)
        _scene.targetInteractiveFrameTime = 1.0 / (double)[self screenMaximumFramesPerSecond];

    if (!_displayLinkProxy) {
        _displayLinkProxy = [[BKVolumeViewDisplayLinkProxy alloc] init];
        _displayLinkProxy.view = self;
    }
    // All CADisplayLink use sits inside this check (macOS 14+ / iOS 15+); older systems
    // keep _displayLink nil and use the event-driven drawing.
    if (@available(macOS 14.0, iOS 15.0, *)) {
#if TARGET_OS_OSX
        CADisplayLink *link = [self displayLinkWithTarget:_displayLinkProxy selector:@selector(tick:)];
#else
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:_displayLinkProxy selector:@selector(tick:)];
#endif
        if (!link) return;
        NSInteger fps = [self screenMaximumFramesPerSecond];
        link.preferredFrameRateRange = CAFrameRateRangeMake(MIN(60, fps), fps, fps);
        // Common modes: keep drawing while a menu is open or the mouse is held down.
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        link.paused = !_needsFrame;
        _displayLink = link;
    }
}

// What: one screen refresh. Draws if something changed and the GPU has finished the
// previous frame; pauses the link after a short time with nothing to draw.
- (void)displayLinkFired
{
    if (_needsFrame && !_frameInFlight) {
        _needsFrame = NO;
        _idleTicks = 0;
        [self renderFrame];
    } else if (!_needsFrame && !_frameInFlight && ++_idleTicks > kBKIdleTicksBeforePause) {
        [_displayLink setPaused:YES];
    }
}

// What: stops the display link. Why: it would otherwise keep firing at the proxy.
- (void)dealloc
{
    [_displayLink invalidate];
}

#pragma mark - Drawing

// What: asks for a frame; many requests before it is drawn collapse into one.
// Why: mouse events arrive faster than frames; drawing each would queue up latency.
// With a display link the frame is drawn at the next screen refresh; otherwise on the
// next turn of the main queue (the original behaviour).
- (void)setNeedsRedraw
{
    if (_displayLink) {
        _needsFrame = YES;
        _idleTicks = 0;
        [_displayLink setPaused:NO];
        return;
    }
    if (_redrawScheduled) return;
    _redrawScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_redrawScheduled = NO;
        [self renderFrame];
    });
}

// What: adds one finished frame to the timing log and prints a line about once a second.
// Why: to measure, on real scans, how many pictures per second the 3D view really shows
// and how long the GPU needs for each, instead of judging smoothness by eye.
- (void)recordFrameForTimingLog
{
    if (!_logsFrameTiming) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (_timingFrames == 0 || now - _timingStart > 2.0) {   // first frame, or after a pause
        _timingStart = now;
        _timingFrames = 0;
        _timingGPUSum = 0;
        _timingWorstLevel = 0;
    }
    _timingFrames++;
    _timingGPUSum += _scene.lastFrameTime;
    _timingWorstLevel = MAX(_timingWorstLevel, _scene.currentQualityLevel);
    CFTimeInterval elapsed = now - _timingStart;
    if (elapsed >= 1.0) {
        NSLog(@"BKVolumeView timing: %.0f frames/s, GPU %.1f ms per frame, lowest quality level %ld of %lu, drawable %.0f x %.0f, %@",
              _timingFrames / elapsed, 1000.0 * _timingGPUSum / _timingFrames, (long)_timingWorstLevel,
              (unsigned long)_scene.qualityLevels.count - 1, _metalLayer.drawableSize.width, _metalLayer.drawableSize.height,
              _scene.interacting ? @"moving" : @"still");
        _timingFrames = 0;
    }
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
            [view recordFrameForTimingLog];
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
