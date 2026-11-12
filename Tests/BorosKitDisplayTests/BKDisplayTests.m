// Tests for BorosKitDisplay: the view transform (pure math), the Metal image renderer
// (on the real GPU; skipped if there is none) and the CoreGraphics overlays.
//
// GPU test setup: the view is made exactly the image size at zoom 1 with no pan, so
// view pixel (i, j) shows image pixel (i, j) and expected output values can be computed
// by hand from the window/level rule:  gray = clamp((value - (center - width/2)) / width).

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitDisplay.h"
#import "N3BezierPath.h"

static const CGFloat kEps = 1e-9;

@interface BKDisplayTests : XCTestCase
@end

// Records delegate calls.
@interface BKTestViewDelegate : NSObject <BKImageViewDelegate>
@property (nonatomic) int transformChanges;
@property (nonatomic) int windowChanges;
@end
@implementation BKTestViewDelegate
- (void)imageViewDidChangeViewTransform:(BKImageView *)imageView { self.transformChanges++; }
- (void)imageViewDidChangeWindowLevel:(BKImageView *)imageView { self.windowChanges++; }
@end

@implementation BKDisplayTests

#pragma mark - Helpers

// Makes a renderer or skips the test when the machine has no Metal device.
- (BKImageLayerRenderer *)rendererOrSkip
{
    if (!MTLCreateSystemDefaultDevice())
        return nil;
    NSError *error = nil;
    BKImageLayerRenderer *r = [[BKImageLayerRenderer alloc] initWithDevice:nil error:&error];
    XCTAssertNotNil(r, @"renderer: %@", error);
    return r;
}

// A transform that shows the image 1:1 (view size = image size, zoom 1, centred).
static BKViewTransform BKOneToOne(NSUInteger w, NSUInteger h)
{
    BKViewTransform t = BKViewTransformMakeFit(w, h, w, h);
    t.zoom = 1;
    return t;
}

// Reads one RGBA8 pixel from a renderer result (row 0 = top).
static void BKPixel(NSData *rgba, NSUInteger width, NSUInteger x, NSUInteger y, uint8_t out[4])
{
    const uint8_t *p = (const uint8_t *)rgba.bytes + (y * width + x) * 4;
    memcpy(out, p, 4);
}

// A 256 x 2 image whose value equals x (0..255).
static BKImage *BKRampImage(void)
{
    float pixels[256 * 2];
    for (int y = 0; y < 2; y++)
        for (int x = 0; x < 256; x++)
            pixels[y * 256 + x] = x;
    return [[BKImage alloc] initWithFloatPixels:pixels width:256 height:2 pixelSpacingX:1 pixelSpacingY:1];
}

#pragma mark - View transform (no GPU)

// Every combination of zoom, pan, rotation, flips and pixel aspect must round-trip
// image -> view -> image exactly (overlays and mouse both rely on this).
- (void)testRoundTripUnderZoomPanRotateFlipAspect
{
    CGFloat zooms[] = { 0.37, 1, 3.5 };
    CGFloat rotations[] = { 0, 37, 90, 180, 270, -45 };
    CGFloat spacingsY[] = { 1, 0.5, 2.25 };
    CGPoint samples[] = { {0, 0}, {12.5, 7.25}, {199.999, 99.5}, {-20, 300} };
    for (int zi = 0; zi < 3; zi++)
        for (int ri = 0; ri < 6; ri++)
            for (int si = 0; si < 3; si++)
                for (int f = 0; f < 4; f++) {
                    BKViewTransform t = BKViewTransformMakeFit(200, 100, 640, 480);
                    t.zoom = zooms[zi];
                    t.panX = 13.5; t.panY = -42;
                    t.rotationDegrees = rotations[ri];
                    t.pixelSpacingX = 1; t.pixelSpacingY = spacingsY[si];
                    t.flipHorizontal = (f & 1) != 0;
                    t.flipVertical = (f & 2) != 0;
                    for (int k = 0; k < 4; k++) {
                        CGPoint v = BKViewTransformImagePointToView(t, samples[k]);
                        CGPoint back = BKViewTransformViewPointToImage(t, v);
                        XCTAssertEqualWithAccuracy(back.x, samples[k].x, 1e-7);
                        XCTAssertEqualWithAccuracy(back.y, samples[k].y, 1e-7);
                    }
                }
}

// Fit: a 200 x 100 image in a 400 x 400 view gets zoom 2 and sits centred.
- (void)testFitCentresImage
{
    BKViewTransform t = BKViewTransformMakeFit(200, 100, 400, 400);
    XCTAssertEqualWithAccuracy(t.zoom, 2.0, kEps);
    CGPoint c = BKViewTransformImagePointToView(t, CGPointMake(100, 50));
    XCTAssertEqualWithAccuracy(c.x, 200, kEps);
    XCTAssertEqualWithAccuracy(c.y, 200, kEps);
    CGPoint corner = BKViewTransformImagePointToView(t, CGPointMake(0, 0));
    XCTAssertEqualWithAccuracy(corner.x, 0, kEps);
    XCTAssertEqualWithAccuracy(corner.y, 100, kEps);
}

// Rotation is clockwise on screen: the middle of the image's left edge moves to the top.
- (void)testRotation90IsClockwise
{
    BKViewTransform t = BKViewTransformMakeFit(100, 50, 100, 100);
    t.zoom = 1;
    t.rotationDegrees = 90;
    CGPoint p = BKViewTransformImagePointToView(t, CGPointMake(0, 25));
    XCTAssertEqualWithAccuracy(p.x, 50, kEps);
    XCTAssertEqualWithAccuracy(p.y, 0, kEps);
    // Rotated fit: the 100-wide image now needs 100 points of height -> zoom 1.
    XCTAssertEqualWithAccuracy(BKViewTransformFitZoom(t), 1.0, kEps);
}

// Horizontal flip mirrors left/right about the image centre.
- (void)testFlipHorizontal
{
    BKViewTransform t = BKOneToOne(100, 50);
    t.flipHorizontal = YES;
    CGPoint p = BKViewTransformImagePointToView(t, CGPointMake(10, 5));
    XCTAssertEqualWithAccuracy(p.x, 90, kEps);
    XCTAssertEqualWithAccuracy(p.y, 5, kEps);
}

// Non-square pixels: y spacing twice x spacing stretches the image vertically 2x.
- (void)testPixelAspectStretchesVertically
{
    BKViewTransform t = BKViewTransformMakeFit(100, 50, 100, 100);
    t.zoom = 1;
    t.pixelSpacingX = 0.5;
    t.pixelSpacingY = 1.0;
    CGPoint top = BKViewTransformImagePointToView(t, CGPointMake(50, 0));
    CGPoint bottom = BKViewTransformImagePointToView(t, CGPointMake(50, 50));
    XCTAssertEqualWithAccuracy(top.y, 0, kEps);
    XCTAssertEqualWithAccuracy(bottom.y, 100, kEps);
}

// Zooming around a point keeps the anatomy under that point still.
- (void)testZoomAroundViewPointKeepsAnchor
{
    BKViewTransform t = BKViewTransformMakeFit(300, 200, 500, 400);
    t.rotationDegrees = 30;
    CGPoint cursor = CGPointMake(123, 321);
    CGPoint before = BKViewTransformViewPointToImage(t, cursor);
    BKViewTransform z = BKViewTransformZoomedAroundViewPoint(t, 2.5, cursor);
    CGPoint after = BKViewTransformViewPointToImage(z, cursor);
    XCTAssertEqualWithAccuracy(z.zoom, t.zoom * 2.5, kEps);
    XCTAssertEqualWithAccuracy(after.x, before.x, 1e-7);
    XCTAssertEqualWithAccuracy(after.y, before.y, 1e-7);
}

// Scale bar: 0.25 mm pixels at zoom 2 = 0.125 mm per point; a ~100 pt bar -> 10 mm.
- (void)testScaleBarPicksRoundLength
{
    BKViewTransform t = BKViewTransformMakeFit(100, 100, 400, 400);
    t.pixelSpacingX = 0.25;
    t.pixelSpacingY = 0.25;
    t.zoom = 2;
    XCTAssertEqualWithAccuracy(BKViewTransformMillimetresPerViewPoint(t), 0.125, kEps);
    XCTAssertEqualWithAccuracy([[BKOverlayScaleBar scaleBar] lengthInMillimetresForTransform:t], 10.0, kEps);
}

#pragma mark - Metal image renderer (GPU)

// Window/level on full-float values: lower 0, width 255 -> gray equals the pixel value.
- (void)testWindowLevelOnFloatGradient
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    r.image = BKRampImage();
    r.viewTransform = BKOneToOne(256, 2);
    r.windowCenter = 127.5;
    r.windowWidth = 255;
    NSError *error = nil;
    NSData *out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:&error];
    XCTAssertNotNil(out, @"%@", error);
    for (NSUInteger x = 0; x < 256; x++) {
        uint8_t px[4];
        BKPixel(out, 256, x, 1, px);
        XCTAssertEqualWithAccuracy(px[0], x, 1, @"x=%lu", (unsigned long)x);
        XCTAssertEqual(px[0], px[1]);
        XCTAssertEqual(px[1], px[2]);
        XCTAssertEqual(px[3], 255);
    }
    // A narrower window clips: center 100, width 50 -> values <= 75 black, >= 125 white.
    r.windowCenter = 100;
    r.windowWidth = 50;
    out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:&error];
    uint8_t px[4];
    BKPixel(out, 256, 70, 0, px);  XCTAssertEqual(px[0], 0);
    BKPixel(out, 256, 130, 0, px); XCTAssertEqual(px[0], 255);
    BKPixel(out, 256, 100, 0, px); XCTAssertEqualWithAccuracy(px[0], (100.0 - 75.0) / 50.0 * 255.0, 1.0);
}

// A colour table is applied after window/level: index i -> (i, 255 - i, 0).
- (void)testColorTableApplied
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    uint8_t lut[768];
    for (int i = 0; i < 256; i++) { lut[i * 3] = i; lut[i * 3 + 1] = 255 - i; lut[i * 3 + 2] = 0; }
    r.image = BKRampImage();
    r.viewTransform = BKOneToOne(256, 2);
    r.windowCenter = 127.5;
    r.windowWidth = 255;
    r.colorTable = [NSData dataWithBytes:lut length:768];
    NSData *out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:NULL];
    uint8_t px[4];
    BKPixel(out, 256, 0, 0, px);   XCTAssertEqual(px[0], 0);   XCTAssertEqual(px[1], 255); XCTAssertEqual(px[2], 0);
    BKPixel(out, 256, 255, 0, px); XCTAssertEqual(px[0], 255); XCTAssertEqual(px[1], 0);
    BKPixel(out, 256, 100, 0, px); XCTAssertEqualWithAccuracy(px[0], 100, 1); XCTAssertEqualWithAccuracy(px[1], 155, 1);
}

// A finished colour picture (RGBA8) is shown as is: window/level, colour table and
// invert must not change it (Boros 6 uses this for images Horos has already coloured).
- (void)testColorImageShownUnchanged
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    uint8_t rgba[256 * 2 * 4];
    for (int y = 0; y < 2; y++)
        for (int x = 0; x < 256; x++) {
            uint8_t *q = rgba + (y * 256 + x) * 4;
            q[0] = x; q[1] = 255 - x; q[2] = 77; q[3] = 255;
        }
    r.image = [[BKImage alloc] initWithRGBA8Data:[NSData dataWithBytes:rgba length:sizeof(rgba)] width:256 height:2
                                   pixelSpacingX:1 pixelSpacingY:1];
    XCTAssertTrue(r.image.isColor);
    r.viewTransform = BKOneToOne(256, 2);
    r.windowCenter = 10;   // would turn a grey image almost white
    r.windowWidth = 5;
    r.invert = YES;
    uint8_t lut[768];
    memset(lut, 0, sizeof(lut));
    r.colorTable = [NSData dataWithBytes:lut length:768]; // would turn a grey image black
    NSData *out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:NULL];
    uint8_t px[4];
    BKPixel(out, 256, 0, 0, px);   XCTAssertEqual(px[0], 0);   XCTAssertEqual(px[1], 255); XCTAssertEqual(px[2], 77); XCTAssertEqual(px[3], 255);
    BKPixel(out, 256, 200, 1, px); XCTAssertEqual(px[0], 200); XCTAssertEqual(px[1], 55);  XCTAssertEqual(px[2], 77);
}

// Invert swaps black and white.
- (void)testInvert
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    r.image = BKRampImage();
    r.viewTransform = BKOneToOne(256, 2);
    r.windowCenter = 127.5;
    r.windowWidth = 255;
    r.invert = YES;
    NSData *out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:NULL];
    uint8_t px[4];
    BKPixel(out, 256, 0, 0, px);   XCTAssertEqual(px[0], 255);
    BKPixel(out, 256, 200, 0, px); XCTAssertEqualWithAccuracy(px[0], 55, 1);
}

// GPU flip matches the transform: output column x shows image column 255 - x.
- (void)testFlipHorizontalOnGPU
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    r.image = BKRampImage();
    BKViewTransform t = BKOneToOne(256, 2);
    t.flipHorizontal = YES;
    r.viewTransform = t;
    r.windowCenter = 127.5;
    r.windowWidth = 255;
    NSData *out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:NULL];
    for (NSUInteger x = 0; x < 256; x += 17) {
        uint8_t px[4];
        BKPixel(out, 256, x, 0, px);
        XCTAssertEqualWithAccuracy(px[0], 255 - x, 1, @"x=%lu", (unsigned long)x);
    }
}

// 180 degree rotation of a 4 x 4 image: output (x, y) shows image (3 - x, 3 - y).
- (void)testRotate180OnGPU
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    float pixels[16];
    for (int i = 0; i < 16; i++) pixels[i] = i;
    r.image = [[BKImage alloc] initWithFloatPixels:pixels width:4 height:4 pixelSpacingX:1 pixelSpacingY:1];
    BKViewTransform t = BKOneToOne(4, 4);
    t.rotationDegrees = 180;
    r.viewTransform = t;
    r.windowCenter = 7.5;
    r.windowWidth = 15;   // value v -> gray v * 17
    NSData *out = [r renderRGBA8WithWidth:4 height:4 scale:1 error:NULL];
    for (int y = 0; y < 4; y++)
        for (int x = 0; x < 4; x++) {
            uint8_t px[4];
            BKPixel(out, 4, x, y, px);
            int v = (3 - y) * 4 + (3 - x);
            XCTAssertEqualWithAccuracy(px[0], v * 17, 1, @"(%d,%d)", x, y);
        }
}

// Outside the image the background colour is shown.
- (void)testBackgroundOutsideImage
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    r.image = BKRampImage();
    BKViewTransform t = BKOneToOne(256, 2);
    t.panX = 1000;  // image pushed out of view
    r.viewTransform = t;
    r.backgroundColor = BKColorMake(0, 0, 1, 1);
    NSData *out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:NULL];
    uint8_t px[4];
    BKPixel(out, 256, 10, 0, px);
    XCTAssertEqual(px[0], 0); XCTAssertEqual(px[1], 0); XCTAssertEqual(px[2], 255);
}

// Linear interpolation blends between pixels when zoomed in; nearest does not.
- (void)testLinearVersusNearestInterpolation
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    float pixels[2] = { 0, 255 };
    r.image = [[BKImage alloc] initWithFloatPixels:pixels width:2 height:1 pixelSpacingX:1 pixelSpacingY:1];
    BKViewTransform t = BKViewTransformMakeFit(2, 1, 8, 4);
    t.zoom = 4;   // each image pixel = 4 x 4 points
    r.viewTransform = t;
    r.windowCenter = 127.5;
    r.windowWidth = 255;

    r.interpolation = BKImageInterpolationNearest;
    NSData *nearest = [r renderRGBA8WithWidth:8 height:4 scale:1 error:NULL];
    r.interpolation = BKImageInterpolationLinear;
    NSData *linear = [r renderRGBA8WithWidth:8 height:4 scale:1 error:NULL];

    uint8_t px[4];
    int intermediate = 0;
    int previous = -1;
    for (int x = 0; x < 8; x++) {
        BKPixel(nearest, 8, x, 2, px);
        XCTAssertTrue(px[0] == 0 || px[0] == 255, @"nearest must not blend (x=%d: %d)", x, px[0]);
        BKPixel(linear, 8, x, 2, px);
        XCTAssertGreaterThanOrEqual((int)px[0], previous, @"linear must increase left to right");
        previous = px[0];
        if (px[0] > 5 && px[0] < 250) intermediate++;
    }
    XCTAssertGreaterThan(intermediate, 0, @"linear should produce in-between values");
    BKPixel(linear, 8, 0, 2, px); XCTAssertEqual(px[0], 0);     // edge pixels not blended with the outside
    BKPixel(linear, 8, 7, 2, px); XCTAssertEqual(px[0], 255);
}

// Retina: scale 2 renders twice the device pixels for the same view.
- (void)testRetinaScale
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    r.image = BKRampImage();
    r.viewTransform = BKOneToOne(256, 2);
    r.windowCenter = 127.5;
    r.windowWidth = 255;
    NSData *out = [r renderRGBA8WithWidth:512 height:4 scale:2 error:NULL];
    for (NSUInteger x = 0; x < 256; x += 31) {
        uint8_t a[4], b[4];
        BKPixel(out, 512, 2 * x, 3, a);
        BKPixel(out, 512, 2 * x + 1, 3, b);
        XCTAssertEqualWithAccuracy(a[0], x, 1);
        XCTAssertEqual(a[0], b[0]);
    }
}

#pragma mark - BKImageView (interaction logic; no window needed)


// The view fits a new image, reads pixel values through the transform, and its
// interaction methods change state and notify the delegate.
- (void)testImageViewInteraction
{
    if (!MTLCreateSystemDefaultDevice()) return;
    BKImageView *view = [[BKImageView alloc] initWithFrame:CGRectMake(0, 0, 512, 4)];
    BKTestViewDelegate *delegate = [[BKTestViewDelegate alloc] init];
    view.delegate = delegate;
    view.image = BKRampImage();                      // 256 x 2 -> fitted at zoom 2

    XCTAssertEqualWithAccuracy(view.viewTransform.zoom, 2.0, kEps);
    XCTAssertEqualWithAccuracy([view pixelValueAtViewPoint:CGPointMake(201, 1)], 100.0f, 0);
    XCTAssertTrue(isnan([view pixelValueAtViewPoint:CGPointMake(-5, 1)]));

    [view zoomByFactor:2 aroundViewPoint:CGPointMake(201, 1)];
    XCTAssertFalse(view.keepsImageFitted);
    XCTAssertEqualWithAccuracy([view pixelValueAtViewPoint:CGPointMake(201, 1)], 100.0f, 0, @"zoom keeps the point under the cursor");
    [view panByViewDelta:CGSizeMake(10, 0)];
    [view rotateByDegrees:90];
    XCTAssertEqual(delegate.transformChanges, 3);

    view.windowCenter = 40; view.windowWidth = 400;
    [view adjustWindowLevelByDeltaX:10 deltaY:-5];
    XCTAssertEqualWithAccuracy(view.windowWidth, 420, kEps);
    XCTAssertEqualWithAccuracy(view.windowCenter, 30, kEps);
    XCTAssertEqual(delegate.windowChanges, 1);

    [view resetView];
    XCTAssertTrue(view.keepsImageFitted);
    XCTAssertEqualWithAccuracy(view.viewTransform.rotationDegrees, 0, kEps);
    XCTAssertEqualWithAccuracy(view.viewTransform.zoom, 2.0, kEps);
}

#pragma mark - Overlays (CoreGraphics, no GPU)

// Creates a 100 x 100 RGBA bitmap context with a top-left, y-down coordinate system
// (the drawing contract of BKDrawOverlays); memory row 0 is the top row.
static CGContextRef BKTestContext(uint8_t *buffer)
{
    memset(buffer, 0, 100 * 100 * 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buffer, 100, 100, 8, 400, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextTranslateCTM(ctx, 0, 100);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetShouldAntialias(ctx, false);
    return ctx;
}

// A line in image pixels lands where the transform says, with an unscaled line width.
- (void)testLineOverlayRegisteredWithImage
{
    uint8_t buffer[100 * 100 * 4];
    CGContextRef ctx = BKTestContext(buffer);
    BKViewTransform t = BKViewTransformMakeFit(50, 50, 100, 100); // zoom 2
    BKOverlayLine *line = [BKOverlayLine lineFrom:CGPointMake(10, 0) to:CGPointMake(10, 50)];
    line.strokeColor = BKColorMake(1, 0, 0, 1);
    line.lineWidth = 2;
    BKDrawOverlays(ctx, @[line], t);
    CGContextRelease(ctx);
    // image x = 10 -> view x = 20; width 2 covers columns 19 and 20.
    const uint8_t *row50 = buffer + 50 * 400;
    XCTAssertEqual(row50[20 * 4 + 0], 255);
    XCTAssertEqual(row50[19 * 4 + 0], 255);
    XCTAssertEqual(row50[23 * 4 + 3], 0, @"line must stay 2 points wide at zoom 2");
    XCTAssertEqual(row50[16 * 4 + 3], 0);
}

// The same overlay follows a horizontal flip.
- (void)testOverlayFollowsFlip
{
    uint8_t buffer[100 * 100 * 4];
    CGContextRef ctx = BKTestContext(buffer);
    BKViewTransform t = BKViewTransformMakeFit(50, 50, 100, 100);
    t.flipHorizontal = YES;
    BKOverlayPoint *dot = [BKOverlayPoint pointAt:CGPointMake(10, 25)];
    dot.strokeColor = BKColorMake(0, 1, 0, 1);
    BKDrawOverlays(ctx, @[dot], t);
    CGContextRelease(ctx);
    // image (10, 25) -> view (80, 50) after the flip.
    XCTAssertEqual(buffer[50 * 400 + 80 * 4 + 1], 255);
    XCTAssertEqual(buffer[50 * 400 + 20 * 4 + 1], 0);
}

// Hit-testing picks the nearest item within tolerance, or nothing.
- (void)testHitTest
{
    BKViewTransform t = BKViewTransformMakeFit(50, 50, 100, 100); // zoom 2
    BKOverlayLine *line = [BKOverlayLine lineFrom:CGPointMake(0, 10) to:CGPointMake(50, 10)]; // view y = 20
    BKOverlayPoint *handle = [BKOverlayPoint pointAt:CGPointMake(40, 40)];                  // view (80, 80)
    NSArray *items = @[line, handle];
    XCTAssertEqual(BKOverlayHitTest(items, CGPointMake(50, 22), 4, t), line);
    XCTAssertEqual(BKOverlayHitTest(items, CGPointMake(81, 79), 4, t), handle);
    XCTAssertNil(BKOverlayHitTest(items, CGPointMake(50, 50), 4, t));
    handle.hidden = YES;
    XCTAssertNil(BKOverlayHitTest(items, CGPointMake(81, 79), 4, t));
}

// An N3BezierPath (e.g. the CPR curve) converts to an image-space CGPath with curves kept.
- (void)testCurveFromBezierPath
{
    N3MutableBezierPath *bezier = [[N3MutableBezierPath alloc] init];
    [bezier moveToVector:N3VectorMake(0, 0, 5)];
    [bezier curveToVector:N3VectorMake(40, 0, 5) controlVector1:N3VectorMake(10, 30, 5) controlVector2:N3VectorMake(30, 30, 5)];
    // patient mm -> image pixels: 0.5 mm pixels, origin shifted by (10, 10) pixels.
    N3AffineTransform toImage = N3AffineTransformConcat(N3AffineTransformMakeScale(2, 2, 1),
                                                        N3AffineTransformMakeTranslation(10, 10, 0));
    BKOverlayCurve *curve = [BKOverlayCurve curveWithBezierPath:bezier patientToImage:toImage];
    CGRect box = CGPathGetPathBoundingBox(curve.imagePath);
    XCTAssertEqualWithAccuracy(CGRectGetMinX(box), 10, 1e-6);
    XCTAssertEqualWithAccuracy(CGRectGetMaxX(box), 90, 1e-6);
    XCTAssertEqualWithAccuracy(CGRectGetMinY(box), 10, 1e-6);
    XCTAssertGreaterThan(CGRectGetMaxY(box), 40);    // bulges towards the control points
    XCTAssertLessThan(CGRectGetMaxY(box), 70.0001);  // but not past them
    // Hit-test near the curve's apex (image x 50, y ~ 10 + 2 * 22.5 = 55) at zoom 1.
    BKViewTransform t = BKOneToOne(100, 100);
    CGPoint apex = BKViewTransformImagePointToView(t, CGPointMake(50, 55));
    XCTAssertLessThan([curve distanceFromViewPoint:apex transform:t], 1.0);
}

// Text, scale bar, rectangles and polygons draw without errors and touch pixels.
- (void)testTextScaleBarAndShapesDraw
{
    uint8_t buffer[100 * 100 * 4];
    CGContextRef ctx = BKTestContext(buffer);
    BKViewTransform t = BKViewTransformMakeFit(50, 50, 100, 100);
    t.pixelSpacingX = t.pixelSpacingY = 0.25;
    CGPoint tri[3] = { {5, 5}, {20, 5}, {12, 15} };
    BKOverlayText *label = [BKOverlayText text:@"12.3 mm" at:CGPointMake(5, 40)];
    label.drawsBackground = YES;
    NSArray *items = @[ [BKOverlayRect rectWithImageRect:CGRectMake(25, 25, 10, 10) ellipse:YES],
                        [BKOverlayPolyline polylineWithPoints:tri count:3 closed:YES],
                        label,
                        [BKOverlayScaleBar scaleBar] ];
    BKDrawOverlays(ctx, items, t);
    CGContextRelease(ctx);
    NSUInteger painted = 0;
    for (NSUInteger i = 0; i < 100 * 100; i++)
        if (buffer[i * 4 + 3] != 0) painted++;
    XCTAssertGreaterThan(painted, 100u);
}

#pragma mark - Fusion overlay (Boros 6)

// Boros 6 fusion: a half-transparent red picture, half as wide as the view and centred,
// is mixed over a grey ramp with its own alpha (like OpenGL's SRC_ALPHA blending in Horos);
// outside the overlay, and where its alpha is 0, the ramp is untouched; the result stays
// opaque. With usesImageAlpha off the overlay is opaque.
- (void)testFusionOverlayBlendsWithImageAlpha
{
    BKImageLayerRenderer *r = [self rendererOrSkip];
    if (!r) return;
    r.image = BKRampImage();
    r.viewTransform = BKOneToOne(256, 2);
    r.windowCenter = 127.5;
    r.windowWidth = 255;

    // 128 x 2 overlay: red with alpha 128, except column 0 (alpha 0 = fully see-through).
    uint8_t rgba[128 * 2 * 4];
    for (int i = 0; i < 128 * 2; i++) {
        rgba[i * 4 + 0] = 255; rgba[i * 4 + 1] = 0; rgba[i * 4 + 2] = 0;
        rgba[i * 4 + 3] = (i % 128 == 0) ? 0 : 128;
    }
    NSError *error = nil;
    BKImageLayerRenderer *o = [[BKImageLayerRenderer alloc] initWithDevice:r.device error:&error];
    XCTAssertNotNil(o, @"%@", error);
    o.image = [[BKImage alloc] initWithRGBA8Data:[NSData dataWithBytes:rgba length:sizeof(rgba)] width:128 height:2
                                    pixelSpacingX:1 pixelSpacingY:1];
    BKViewTransform t = BKViewTransformMakeFit(128, 2, 256, 2);
    t.zoom = 1;                       // 1:1, centred -> covers view columns 64..191
    o.viewTransform = t;
    o.usesImageAlpha = YES;
    o.backgroundColor = BKColorMake(0, 0, 1, 1); // must be ignored for an overlay
    r.overlay = o;

    NSData *out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:&error];
    XCTAssertNotNil(out, @"%@", error);
    uint8_t px[4];
    double a = 128.0 / 255.0;
    // Outside the overlay: plain ramp.
    BKPixel(out, 256, 10, 0, px);
    XCTAssertEqualWithAccuracy(px[0], 10, 1); XCTAssertEqualWithAccuracy(px[2], 10, 1); XCTAssertEqual(px[3], 255);
    BKPixel(out, 256, 220, 1, px);
    XCTAssertEqualWithAccuracy(px[0], 220, 1); XCTAssertEqualWithAccuracy(px[2], 220, 1);
    // Overlay column 0 (view column 64) has alpha 0: plain ramp.
    BKPixel(out, 256, 64, 0, px);
    XCTAssertEqualWithAccuracy(px[0], 64, 1); XCTAssertEqualWithAccuracy(px[1], 64, 1);
    // Inside: red mixed half and half with the grey value 100.
    BKPixel(out, 256, 100, 0, px);
    XCTAssertEqualWithAccuracy(px[0], 255 * a + 100 * (1 - a), 2);
    XCTAssertEqualWithAccuracy(px[1], 100 * (1 - a), 2);
    XCTAssertEqualWithAccuracy(px[2], 100 * (1 - a), 2);
    XCTAssertEqual(px[3], 255);

    // Alpha ignored -> opaque red inside the overlay.
    o.usesImageAlpha = NO;
    out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:NULL];
    BKPixel(out, 256, 100, 1, px);
    XCTAssertEqual(px[0], 255); XCTAssertEqual(px[1], 0); XCTAssertEqual(px[3], 255);

    // No overlay -> back to the plain ramp.
    r.overlay = nil;
    out = [r renderRGBA8WithWidth:256 height:2 scale:1 error:NULL];
    BKPixel(out, 256, 100, 0, px);
    XCTAssertEqualWithAccuracy(px[0], 100, 1); XCTAssertEqualWithAccuracy(px[1], 100, 1);
}

@end
