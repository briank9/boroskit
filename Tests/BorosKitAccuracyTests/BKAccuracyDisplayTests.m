// BorosKit accuracy check, part 4: the 2D display (BKViewTransform + BKImageLayerRenderer).
//
// What is checked: once an image (slice, slab, panorex) is made, the viewer places it on
// screen with zoom, pan, rotation and flips. These tests take one known image pixel and
// check that it lands on the expected screen point, with numbers worked out BY HAND
// (written next to each case), not by calling the same formula the viewer uses. Then
// the same is checked on the real GPU drawing, and that a 40 mm distance still measures
// 40 mm on screen even with non-square pixels and rotation.
//
// Conventions (from BKViewTransform.h): image pixel (i, j) has its centre at
// (i + 0.5, j + 0.5); x to the right, y DOWN, in both the image and the view.
// Rotation is clockwise on screen; flips act on the image before it is rotated.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitDisplay.h"
#import "BKPhantom.h"

@interface BKAccuracyDisplayTests : XCTestCase
@end

@implementation BKAccuracyDisplayTests

// A 200 x 100 image shown in a 400 x 300 view, no pan.
static BKViewTransform BaseTransform(CGFloat zoom)
{
    BKViewTransform t = BKViewTransformMakeFit(200, 100, 400, 300);
    t.zoom = zoom;
    return t;
}

// Known image point -> expected screen point, for each kind of move.
// The image point is (151, 21): 51 px right of and 29 px above the image centre (100, 50).
// The view centre is (200, 150).
- (void)testKnownPixelLandsOnExpectedScreenPoint
{
    CGPoint imagePoint = CGPointMake(151, 21);
    struct { NSString *name; CGFloat zoom; BOOL flipH, flipV; CGFloat rotation, panX, panY; CGPoint expected; } cases[] = {
        // Zoom 2: (51, -29) x 2 = (102, -58) from the view centre -> (302, 92).
        { @"zoom 2", 2, NO, NO, 0, 0, 0, {302, 92} },
        // Flip left-right: the point moves to the other side: (-102, -58) -> (98, 92).
        { @"zoom 2 + flip left-right", 2, YES, NO, 0, 0, 0, {98, 92} },
        // Flip top-bottom: (102, +58) -> (302, 208).
        { @"zoom 2 + flip top-bottom", 2, NO, YES, 0, 0, 0, {302, 208} },
        // Rotate 90 degrees clockwise: "right" becomes "down" and "up" becomes "right":
        // (51, -29) -> (29, 51), x 2 = (58, 102) -> (258, 252).
        { @"zoom 2 + rotate 90 clockwise", 2, NO, NO, 90, 0, 0, {258, 252} },
        // Flip first, then rotate: (-51, -29) -> rotate -> (29, -51), x 2 -> (258, 48).
        { @"zoom 2 + flip left-right + rotate 90", 2, YES, NO, 90, 0, 0, {258, 48} },
        // Rotate 180: (51, -29) -> (-51, 29), x 2 -> (98, 208).
        { @"zoom 2 + rotate 180", 2, NO, NO, 180, 0, 0, {98, 208} },
        // Zoom 1.5 and pan (10, -20): (76.5, -43.5) + pan -> (286.5, 86.5).
        { @"zoom 1.5 + pan", 1.5, NO, NO, 0, 10, -20, {286.5, 86.5} },
    };
    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        BKViewTransform t = BaseTransform(cases[c].zoom);
        t.flipHorizontal = cases[c].flipH;
        t.flipVertical = cases[c].flipV;
        t.rotationDegrees = cases[c].rotation;
        t.panX = cases[c].panX;
        t.panY = cases[c].panY;
        CGPoint v = BKViewTransformImagePointToView(t, imagePoint);
        double err = hypot(v.x - cases[c].expected.x, v.y - cases[c].expected.y);
        XCTAssertLessThan(err, 1e-9, @"%@: got %.4f,%.4f expected %.4f,%.4f", cases[c].name, v.x, v.y,
                          cases[c].expected.x, cases[c].expected.y);
        // ...and the mouse goes back to the same image point (clicks hit the right anatomy).
        CGPoint back = BKViewTransformViewPointToImage(t, v);
        XCTAssertLessThan(hypot(back.x - imagePoint.x, back.y - imagePoint.y), 1e-9, @"%@: back-conversion", cases[c].name);
        BKReport(@"2D display %@ | image point lands at %.3f,%.3f (expected %.3f,%.3f), error %.1e points",
                 cases[c].name, v.x, v.y, cases[c].expected.x, cases[c].expected.y, err);
    }
}

// Non-square pixels (0.3 mm wide, 0.5 mm tall, as in a reformatted image): two points
// 40 mm apart vertically (80 pixels) and two 40 mm apart horizontally (133.33 pixels)
// must both measure 40 mm on screen, also when the image is rotated 30 degrees and zoomed.
// Why: on-screen distances (scale bar, a ruler drawn in view units) use mm per view point.
- (void)testDistancesStayTrueOnScreenWithNonSquarePixels
{
    BKViewTransform t = BaseTransform(1.7);
    t.pixelSpacingX = 0.3;
    t.pixelSpacingY = 0.5;
    t.rotationDegrees = 30;
    t.panX = 13;
    double mmPerPoint = BKViewTransformMillimetresPerViewPoint(t);
    struct { CGPoint a, b; NSString *name; } pairs[] = {
        { {50.5, 10.5}, {50.5, 90.5}, @"vertical 40 mm (80 px of 0.5 mm)" },
        { {20.5, 50.5}, {20.5 + 40.0 / 0.3, 50.5}, @"horizontal 40 mm (133.3 px of 0.3 mm)" },
        // 24 mm across and 32 mm down = 40 mm diagonally (3-4-5 triangle).
        { {30, 20}, {30 + 24.0 / 0.3, 20 + 32.0 / 0.5}, @"diagonal 40 mm" },
    };
    for (size_t k = 0; k < 3; k++) {
        CGPoint va = BKViewTransformImagePointToView(t, pairs[k].a), vb = BKViewTransformImagePointToView(t, pairs[k].b);
        double mm = hypot(va.x - vb.x, va.y - vb.y) * mmPerPoint;
        XCTAssertEqualWithAccuracy(mm, 40.0, 1e-9, @"%@", pairs[k].name);
        BKReport(@"2D display non-square pixels, rotated 30deg | %@ measures %.6f mm on screen", pairs[k].name, mm);
    }
}

// The same moves on the real GPU drawing: a bright 2 x 2 pixel marker (centred on image
// point (151, 21), right side of the image) must appear centred on the hand-computed screen
// point, and nowhere else. If the GPU drawing and the math ever disagreed, overlays and
// measurements would sit off the anatomy.
- (void)testGPUImageMatchesHandComputedScreenPoints
{
    if (!MTLCreateSystemDefaultDevice()) { XCTSkip(@"No Metal GPU available"); return; }
    NSError *error = nil;
    BKImageLayerRenderer *r = [[BKImageLayerRenderer alloc] initWithDevice:nil error:&error];
    XCTAssertNotNil(r, @"%@", error);
    float *pixels = calloc(200 * 100, sizeof(float));
    for (int y = 20; y <= 21; y++)
        for (int x = 150; x <= 151; x++) pixels[y * 200 + x] = 1000;
    r.image = [[BKImage alloc] initWithFloatPixels:pixels width:200 height:100 pixelSpacingX:1 pixelSpacingY:1];
    free(pixels);
    r.windowCenter = 500;
    r.windowWidth = 1000;
    r.interpolation = BKImageInterpolationNearest;
    r.backgroundColor = BKColorMake(0, 0, 0, 1);

    struct { NSString *name; BOOL flipH; CGFloat rotation; CGPoint expected; } cases[] = {
        { @"zoom 2", NO, 0, {302, 92} },
        { @"zoom 2 + flip left-right", YES, 0, {98, 92} },
        { @"zoom 2 + rotate 90 clockwise", NO, 90, {258, 252} },
        { @"zoom 2 + flip left-right + rotate 90", YES, 90, {258, 48} },
    };
    for (size_t c = 0; c < 4; c++) {
        BKViewTransform t = BaseTransform(2);
        t.flipHorizontal = cases[c].flipH;
        t.rotationDegrees = cases[c].rotation;
        r.viewTransform = t;
        NSData *out = [r renderRGBA8WithWidth:400 height:300 scale:1 error:&error];
        XCTAssertNotNil(out, @"%@", error);
        // Weighted centre of the bright output pixels; output pixel (x, y) covers the view
        // square [x, x+1) x [y, y+1), so its centre is (x + 0.5, y + 0.5).
        const uint8_t *p = out.bytes;
        double sw = 0, sx = 0, sy = 0;
        NSUInteger bright = 0;
        for (NSUInteger y = 0; y < 300; y++)
            for (NSUInteger x = 0; x < 400; x++) {
                double w = p[4 * (y * 400 + x)];
                if (w <= 0) continue;
                sw += w; sx += w * (x + 0.5); sy += w * (y + 0.5);
                if (w > 128) bright++;
            }
        double cx = sx / sw, cy = sy / sw;
        double err = hypot(cx - cases[c].expected.x, cy - cases[c].expected.y);
        XCTAssertLessThanOrEqual(err, 0.25, @"%@: marker drawn at %.2f,%.2f, expected %.2f,%.2f",
                                 cases[c].name, cx, cy, cases[c].expected.x, cases[c].expected.y);
        // 2 x 2 image pixels at zoom 2 = 4 x 4 = 16 screen pixels, no more (nothing elsewhere).
        XCTAssertEqual(bright, 16u, @"%@: marker size on screen", cases[c].name);
        BKReport(@"2D display GPU %@ | marker drawn at %.2f,%.2f (expected %.2f,%.2f), error %.3f points, %lu bright pixels",
                 cases[c].name, cx, cy, cases[c].expected.x, cases[c].expected.y, err, (unsigned long)bright);
    }
}

@end
