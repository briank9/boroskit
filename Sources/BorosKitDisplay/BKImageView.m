// BorosKitDisplay: BKImageView implementation (macOS NSView / iOS UIView). See header.

/* BOROS OVERVIEW (plain language)
 * This file is the on-screen panel that shows one 2D scan slice.
 * It stacks two layers: the CT picture, painted by the graphics chip, and a thin
 * layer of marks (measurements, curves, labels) drawn on top. Keeping them separate
 * means moving a mark does not force the whole picture to be redrawn.
 * It handles mouse, trackpad and touch input for pan, zoom, rotate, flip and
 * brightness/contrast changes, and keeps the picture and marks lined up using the
 * same view transform. It works on both the Mac and the iPad.
 */

#import "BKImageView.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// A CALayer that draws the overlay items with CoreGraphics.
// Why a separate layer: overlays change often (dragging a handle) while the image does
// not; redrawing only this layer avoids re-rendering the Metal image.
@interface BKOverlayLayer : CALayer
@property (nonatomic, copy) NSArray<BKOverlayItem *> *items;
@property (nonatomic) BKViewTransform transform2D;
@end

@implementation BKOverlayLayer

// What: draws the overlays in view coordinates with a top-left origin.
// Why the flip: on macOS a layer's drawing context is y-up unless its contents are
// flipped; iOS layer contexts are already y-down. BKDrawOverlays expects y-down.
- (void)drawInContext:(CGContextRef)ctx
{
#if TARGET_OS_OSX
    if (!self.contentsAreFlipped) {
        CGContextTranslateCTM(ctx, 0, self.bounds.size.height);
        CGContextScaleCTM(ctx, 1, -1);
    }
#endif
    BKDrawOverlays(ctx, self.items ?: @[], self.transform2D);
}

@end

@implementation BKImageView {
    CAMetalLayer *_metalLayer;
    BKOverlayLayer *_overlayLayer;
    double _fallbackWindowCenter;
    double _fallbackWindowWidth;
}

#pragma mark - Setup

#if TARGET_OS_OSX
// What: designated initialisers for AppKit. Why: both code- and nib-created views work.
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

// What: y-down view coordinates on the Mac. Why: matches the image grid and iOS.
- (BOOL)isFlipped
{
    return YES;
}
#else
// What: designated initialisers for UIKit.
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

// What: creates the two layers (Metal image below, overlays above) and the renderer.
// Why: shared by every initialiser on both platforms.
- (void)commonInit
{
#if TARGET_OS_OSX
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
#endif
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.opaque = YES;
    _overlayLayer = [BKOverlayLayer layer];
    _overlayLayer.opaque = NO;
    _overlayLayer.needsDisplayOnBoundsChange = YES;
    [self.layer addSublayer:_metalLayer];
    [self.layer addSublayer:_overlayLayer];

    _overlays = @[];
    _keepsImageFitted = YES;
    _windowLevelSensitivity = 2.0;
    _fallbackWindowCenter = 40;
    _fallbackWindowWidth = 400;

    NSError *error = nil;
    _renderer = [[BKImageLayerRenderer alloc] initWithDevice:nil error:&error];
    if (!_renderer)
        NSLog(@"BKImageView: no Metal renderer (%@)", error);
    _metalLayer.device = _renderer.device;
}

#pragma mark - Layout

// What: device pixels per point for the current screen.
// Why: the drawable must match the screen's real resolution (Retina = 2).
- (CGFloat)displayScale
{
#if TARGET_OS_OSX
    CGFloat scale = self.window ? self.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
#else
    CGFloat scale = self.traitCollection.displayScale;
#endif
    return scale > 0 ? scale : 1.0;
}

// What: sizes both layers to the view, updates the transform's view size, redraws.
// Why: called from the platform's layout pass (AppKit -layout / UIKit -layoutSubviews).
- (void)updateLayerGeometry
{
    CGRect bounds = self.bounds;
    CGFloat scale = [self displayScale];
    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // no implicit animations when resizing
    _metalLayer.frame = bounds;
    _metalLayer.contentsScale = scale;
    _metalLayer.drawableSize = CGSizeMake(MAX(1, bounds.size.width * scale), MAX(1, bounds.size.height * scale));
    _overlayLayer.frame = bounds;
    _overlayLayer.contentsScale = scale;
    [CATransaction commit];

    BKViewTransform t = self.viewTransform;
    t.viewWidth = bounds.size.width;
    t.viewHeight = bounds.size.height;
    if (_keepsImageFitted)
        t = [self fittedTransformFrom:t];
    [self applyTransform:t notify:NO];
}

#if TARGET_OS_OSX
- (void)layout
{
    [super layout];
    [self updateLayerGeometry];
}

// What: re-layout when moving between Retina and non-Retina screens.
- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self updateLayerGeometry];
}
#else
- (void)layoutSubviews
{
    [super layoutSubviews];
    [self updateLayerGeometry];
}
#endif

#pragma mark - State

// What: returns `t` reset to fit the view (centred, no pan/rotation/flip).
// Why: used for new images, resizes while fitted, and -resetView.
- (BKViewTransform)fittedTransformFrom:(BKViewTransform)t
{
    t.panX = 0;
    t.panY = 0;
    t.rotationDegrees = 0;
    t.flipHorizontal = NO;
    t.flipVertical = NO;
    t.zoom = 1;
    t.zoom = BKViewTransformFitZoom(t);
    return t;
}

- (BKViewTransform)viewTransform
{
    return _renderer ? _renderer.viewTransform : BKViewTransformMakeFit(1, 1, 1, 1);
}

// What: stores a transform set by the app and redraws. Why: public setter — callers
// that set a transform explicitly are no longer "fitted".
- (void)setViewTransform:(BKViewTransform)viewTransform
{
    [self applyTransform:viewTransform notify:NO];
}

// What: pushes a transform to the renderer and overlays, redraws, optionally tells the
// delegate. Why: single path so image and overlays can never use different transforms.
- (void)applyTransform:(BKViewTransform)t notify:(BOOL)notify
{
    _renderer.viewTransform = t;
    [self setNeedsRedraw];
    if (notify && [_delegate respondsToSelector:@selector(imageViewDidChangeViewTransform:)])
        [_delegate imageViewDidChangeViewTransform:self];
}

// What: hands the image to the renderer and refits if requested.
- (void)setImage:(nullable BKImage *)image
{
    _image = image;
    _renderer.image = image;
    BKViewTransform t = self.viewTransform;
    t.viewWidth = self.bounds.size.width;
    t.viewHeight = self.bounds.size.height;
    if (_keepsImageFitted)
        t = [self fittedTransformFrom:t];
    [self applyTransform:t notify:NO];
}

// What: replaces the overlay list and redraws only the overlay layer.
- (void)setOverlays:(NSArray<BKOverlayItem *> *)overlays
{
    _overlays = [overlays copy] ?: @[];
    _overlayLayer.items = _overlays;
    [_overlayLayer setNeedsDisplay];
}

- (double)windowCenter { return _renderer ? _renderer.windowCenter : _fallbackWindowCenter; }
- (double)windowWidth  { return _renderer ? _renderer.windowWidth : _fallbackWindowWidth; }

// What/why: window/level setters forward to the renderer and redraw the image.
- (void)setWindowCenter:(double)windowCenter
{
    _fallbackWindowCenter = windowCenter;
    _renderer.windowCenter = windowCenter;
    [self setNeedsRedraw];
}

- (void)setWindowWidth:(double)windowWidth
{
    _fallbackWindowWidth = windowWidth;
    _renderer.windowWidth = windowWidth;
    [self setNeedsRedraw];
}

#pragma mark - Drawing

// What: renders the image into the next drawable and redraws the overlays.
// Why: Metal layers are not redrawn by the view system automatically; this is the one
// place that does it, synchronously on the calling (main) thread.
- (void)setNeedsRedraw
{
    _overlayLayer.transform2D = self.viewTransform;
    _overlayLayer.items = _overlays;
    [_overlayLayer setNeedsDisplay];

    if (!_renderer || self.bounds.size.width < 1 || self.bounds.size.height < 1)
        return;
    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable)
        return;
    id<MTLCommandBuffer> commandBuffer = [_renderer.commandQueue commandBuffer];
    NSError *error = nil;
    if (![_renderer encodeToCommandBuffer:commandBuffer texture:drawable.texture scale:_metalLayer.contentsScale error:&error]) {
        NSLog(@"BKImageView: draw failed: %@", error);
        return;
    }
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

#pragma mark - Interaction

// What: moves the image by a view-space delta (drag / two-finger pan).
- (void)panByViewDelta:(CGSize)delta
{
    BKViewTransform t = self.viewTransform;
    t.panX += delta.width;
    t.panY += delta.height;
    _keepsImageFitted = NO;
    [self applyTransform:t notify:YES];
}

// What: zooms keeping the image point under `p` fixed (scroll wheel / pinch centre).
- (void)zoomByFactor:(CGFloat)factor aroundViewPoint:(CGPoint)p
{
    if (!(factor > 0))
        return;
    _keepsImageFitted = NO;
    [self applyTransform:BKViewTransformZoomedAroundViewPoint(self.viewTransform, factor, p) notify:YES];
}

// What: rotates the image clockwise on screen (rotate gesture / menu command).
- (void)rotateByDegrees:(CGFloat)degrees
{
    BKViewTransform t = self.viewTransform;
    t.rotationDegrees = fmod(t.rotationDegrees + degrees, 360.0);
    _keepsImageFitted = NO;
    [self applyTransform:t notify:YES];
}

// What: Horos-style WL drag — horizontal changes the window width, vertical the level.
// Why: clinicians expect the same feel as in Horos; sensitivity is adjustable.
- (void)adjustWindowLevelByDeltaX:(CGFloat)dx deltaY:(CGFloat)dy
{
    double width = fmax(1.0, self.windowWidth + dx * _windowLevelSensitivity);
    double center = self.windowCenter + dy * _windowLevelSensitivity;
    _renderer.windowWidth = width;
    _renderer.windowCenter = center;
    _fallbackWindowWidth = width;
    _fallbackWindowCenter = center;
    [self setNeedsRedraw];
    if ([_delegate respondsToSelector:@selector(imageViewDidChangeWindowLevel:)])
        [_delegate imageViewDidChangeWindowLevel:self];
}

// What: back to fit-to-view, no rotation or flips (Horos "reset").
- (void)resetView
{
    _keepsImageFitted = YES;
    BKViewTransform t = self.viewTransform;
    t.viewWidth = self.bounds.size.width;
    t.viewHeight = self.bounds.size.height;
    [self applyTransform:[self fittedTransformFrom:t] notify:YES];
}

#pragma mark - Coordinates

- (CGPoint)imagePointForViewPoint:(CGPoint)viewPoint
{
    return BKViewTransformViewPointToImage(self.viewTransform, viewPoint);
}

- (CGPoint)viewPointForImagePoint:(CGPoint)imagePoint
{
    return BKViewTransformImagePointToView(self.viewTransform, imagePoint);
}

// What: the stored (unwindowed) pixel value under a view point, NAN outside.
// Why: the corner readout "X: .. Y: .. Value: .." in Horos.
- (float)pixelValueAtViewPoint:(CGPoint)viewPoint
{
    if (!_image)
        return NAN;
    CGPoint p = [self imagePointForViewPoint:viewPoint];
    if (p.x < 0 || p.y < 0 || p.x >= _image.width || p.y >= _image.height)
        return NAN;
    return [_image valueAtX:(NSUInteger)floor(p.x) y:(NSUInteger)floor(p.y)];
}

@end
