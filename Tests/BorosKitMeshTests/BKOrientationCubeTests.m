// Tests for the native orientation cube (BKOrientationCubeCore plain C + BKOrientationCube Metal).
// Original BorosKit code written for this project; contains no third-party code.
//
// What is checked, in plain terms:
//  - every hand-drawn letter is a proper drawing: its fill pieces are convex and anticlockwise,
//    lie inside the letter's outline and cover exactly the outline's area;
//  - letters are not mirrored and face outwards on every cube face (seen from outside, every
//    letter triangle runs anticlockwise on screen), the cube's own triangles face outwards;
//  - label sizes, unknown characters, long labels shrunk to fit the face;
//  - the corner camera looks at the cube from the main view's direction, only turns (ignores the
//    main camera's position / zoom) and fits the whole cube in square and tall corners;
//  - the corner rectangle of the classic top-right 10 %;
//  - on the GPU: the cube lands only inside its corner; from the front the green "A", from the
//    patient's left the blue "L", from above the red "S" are seen on a white cube.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitMeshRender.h"
#import "BorosKitMesh.h"
#import "BorosKitRender.h"
#include <math.h>

// Signed area (anticlockwise > 0).
static double BKTestArea(const BKVec2f *v, uint32_t n)
{
    double a = 0;
    for (uint32_t i = 0; i < n; i++) a += (double)v[i].x * v[(i + 1) % n].y - (double)v[(i + 1) % n].x * v[i].y;
    return 0.5 * a;
}

// Even-odd point-in-outline over all loops of a letter.
static BOOL BKTestInsideOutline(const BKOrientationGlyph *g, double x, double y)
{
    BOOL inside = NO;
    const BKVec2f *v = g->contourVertices;
    for (uint32_t c = 0; c < g->contourCount; c++) {
        uint32_t n = g->contourSizes[c];
        for (uint32_t i = 0, j = n - 1; i < n; j = i++) {
            if (((v[i].y > y) != (v[j].y > y)) &&
                (x < (v[j].x - v[i].x) * (y - v[i].y) / (v[j].y - v[i].y) + v[i].x)) inside = !inside;
        }
        v += n;
    }
    return inside;
}

static BKCameraFrame BKTestCamera(BKVec3d direction, BKVec3d up)
{
    BKCameraFrame f;
    f.direction = BKV3dNormalize(direction);
    f.up = BKV3dNormalize(up);
    f.position = BKV3dScale(f.direction, -500);   // any position: only the rotation may matter
    f.parallelScale = 120;
    f.viewAngle = 30;
    f.perspective = false;
    return f;
}

@interface BKOrientationCubeTests : XCTestCase
@end

@implementation BKOrientationCubeTests

#pragma mark - Letters

- (void)testGlyphsAreProperDrawings
{
    XCTAssertEqual(BKOrientationGlyphCount(), 6u);
    for (uint32_t gi = 0; gi < BKOrientationGlyphCount(); gi++) {
        const BKOrientationGlyph *g = BKOrientationGlyphAtIndex(gi);
        XCTAssertTrue(g != NULL);
        const BKVec2f *v = g->pieceVertices;
        for (uint32_t p = 0; p < g->pieceCount; p++) {
            uint32_t n = g->pieceSizes[p];
            XCTAssertGreaterThanOrEqual(n, 3u);
            XCTAssertGreaterThan(BKTestArea(v, n), 1e-6, @"'%c' piece %u anticlockwise", g->character, p);
            double cx = 0, cy = 0;
            for (uint32_t i = 0; i < n; i++) {
                // Convex: every turn is a left turn.
                BKVec2f a = v[i], b = v[(i + 1) % n], c = v[(i + 2) % n];
                double cross = (double)(b.x - a.x) * (c.y - b.y) - (double)(b.y - a.y) * (c.x - b.x);
                XCTAssertGreaterThan(cross, -1e-9, @"'%c' piece %u convex", g->character, p);
                XCTAssertTrue(a.x >= -1e-6 && a.x <= g->width + 1e-6 && a.y >= -1e-6 && a.y <= 1 + 1e-6);
                cx += a.x; cy += a.y;
            }
            XCTAssertTrue(BKTestInsideOutline(g, cx / n, cy / n), @"'%c' piece %u inside the outline", g->character, p);
            v += n;
        }
        double fill = BKOrientationGlyphFillArea(g), outline = BKOrientationGlyphOutlineArea(g);
        XCTAssertGreaterThan(fill, 0.2);
        XCTAssertEqualWithAccuracy(fill, outline, 1e-5, @"'%c': fill covers the outline exactly", g->character);
    }
}

- (void)testGlyphLookup
{
    for (const char *c = "AILPRS"; *c; c++) XCTAssertTrue(BKOrientationGlyphFor(*c) != NULL);
    XCTAssertTrue(BKOrientationGlyphFor('l') == BKOrientationGlyphFor('L'));
    XCTAssertTrue(BKOrientationGlyphFor('X') == NULL);
    XCTAssertTrue(BKOrientationGlyphFor(' ') == NULL);
}

- (void)testLabelSizes
{
    BKOrientationLabelSize l = BKOrientationCubeLabelSize("L");
    XCTAssertEqual(l.vertexCount, 8u);
    XCTAssertEqual(l.triangleCount, 4u);
    XCTAssertEqual(l.segmentCount, 6u);
    XCTAssertEqual(l.skippedCount, 0u);
    BKOrientationLabelSize xl = BKOrientationCubeLabelSize("X L");
    XCTAssertEqual(xl.vertexCount, 8u);
    XCTAssertEqual(xl.skippedCount, 1u);
    BKOrientationLabelSize empty = BKOrientationCubeLabelSize("");
    XCTAssertEqual(empty.vertexCount + empty.triangleCount + empty.segmentCount + empty.skippedCount, 0u);
    XCTAssertEqual(BKOrientationCubeLabelSize(NULL).vertexCount, 0u);
    // Filling writes exactly what the size said.
    float v[3 * 64]; uint32_t t[3 * 64]; float s[6 * 64];
    BKOrientationLabelSize w = BKOrientationCubeFillLabel(BKCubeFaceYMinus, "AR", 0.67, 0.501, v, t, s);
    BKOrientationLabelSize ar = BKOrientationCubeLabelSize("AR");
    XCTAssertEqual(w.vertexCount, ar.vertexCount);
    XCTAssertEqual(w.triangleCount, ar.triangleCount);
    XCTAssertEqual(w.segmentCount, ar.segmentCount);
    for (uint32_t i = 0; i < 3 * w.triangleCount; i++) XCTAssertLessThan(t[i], w.vertexCount);
}

// Letters face outwards and read correctly (not mirrored) from outside on every face, lie just
// in front of the face, are centred and 0.67 high.
- (void)testLettersReadCorrectlyFromOutside
{
    for (int32_t f = 0; f < BKCubeFaceCount; f++) {
        BKVec3d n, u, r;
        BKOrientationCubeFaceFrame(f, &n, &u, &r);
        XCTAssertEqualWithAccuracy(BKV3dDot(n, u), 0, 1e-12);
        XCTAssertEqualWithAccuracy(BKV3dLength(r), 1, 1e-12);
        const char *label = BKOrientationCubeDefaultLabel(f);
        BKOrientationLabelSize size = BKOrientationCubeLabelSize(label);
        float v[3 * 64]; uint32_t t[3 * 64];
        BKOrientationCubeFillLabel(f, label, BK_ORIENTATION_CUBE_TEXT_SCALE, BK_ORIENTATION_CUBE_TEXT_OFFSET, v, t, NULL);
        // Viewer outside the face looking at it, with the face's "up" up.
        BKCameraFrame cam = BKTestCamera(BKV3dNeg(n), u);
        cam.position = BKV3dScale(n, 10);
        cam.parallelScale = 1;
        double minU = 1e9, maxU = -1e9, minR = 1e9, maxR = -1e9;
        for (uint32_t i = 0; i < size.vertexCount; i++) {
            BKVec3d p = BKV3d(v[3 * i], v[3 * i + 1], v[3 * i + 2]);
            XCTAssertEqualWithAccuracy(BKV3dDot(p, n), BK_ORIENTATION_CUBE_TEXT_OFFSET, 1e-6);
            minU = fmin(minU, BKV3dDot(p, u)); maxU = fmax(maxU, BKV3dDot(p, u));
            minR = fmin(minR, BKV3dDot(p, r)); maxR = fmax(maxR, BKV3dDot(p, r));
        }
        XCTAssertEqualWithAccuracy(maxU - minU, BK_ORIENTATION_CUBE_TEXT_SCALE, 1e-5, @"face %d letter height", f);
        XCTAssertEqualWithAccuracy(minU + maxU, 0, 1e-5);
        XCTAssertEqualWithAccuracy(minR + maxR, 0, 1e-5, @"face %d letter centred", f);
        for (uint32_t k = 0; k < size.triangleCount; k++) {
            double sx[3], sy[3];
            for (int c = 0; c < 3; c++) {
                uint32_t i = t[3 * k + c];
                XCTAssertTrue(BKCameraProjectPoint(cam, 100, 100, BKV3d(v[3 * i], v[3 * i + 1], v[3 * i + 2]), &sx[c], &sy[c], NULL));
                sy[c] = -sy[c];   // screen y down -> up
            }
            double area2 = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0]);
            XCTAssertGreaterThan(area2, 0, @"face %d triangle %u anticlockwise (not mirrored) from outside", f, k);
        }
    }
    // Classic directions: on the patient's left face (seen from the left) the viewer's right is
    // posterior (+y), so the L's foot points to the patient's back.
    BKVec3d n, u, r;
    BKOrientationCubeFaceFrame(BKCubeFaceXPlus, &n, &u, &r);
    XCTAssertEqualWithAccuracy(r.y, 1, 1e-12);
    BKOrientationCubeFaceFrame(BKCubeFaceYMinus, &n, &u, &r);   // front: viewer's right = patient's left (+x)
    XCTAssertEqualWithAccuracy(r.x, 1, 1e-12);
    BKOrientationCubeFaceFrame(BKCubeFaceZPlus, &n, &u, &r);    // top: "up" = patient's left, as the classic cube
    XCTAssertEqualWithAccuracy(u.x, 1, 1e-12);
}

- (void)testLongLabelShrinksToFitTheFace
{
    float v[3 * 128];
    BKOrientationLabelSize size = BKOrientationCubeFillLabel(BKCubeFaceYMinus, "LLLL", 0.67, 0.501, v, NULL, NULL);
    double minX = 1e9, maxX = -1e9;
    for (uint32_t i = 0; i < size.vertexCount; i++) { minX = fmin(minX, v[3 * i]); maxX = fmax(maxX, v[3 * i]); }
    XCTAssertLessThanOrEqual(maxX - minX, BK_ORIENTATION_CUBE_MAX_TEXT_WIDTH + 1e-5);
    XCTAssertGreaterThan(maxX - minX, 0.85);
}

#pragma mark - Cube, camera, corner

- (void)testBoxFacesOutwards
{
    float p[72], nrm[72]; uint32_t t[36];
    BKOrientationCubeFillBox(p, nrm, t);
    for (int k = 0; k < 12; k++) {
        BKVec3d a = BKV3d(p[3 * t[3 * k]], p[3 * t[3 * k] + 1], p[3 * t[3 * k] + 2]);
        BKVec3d b = BKV3d(p[3 * t[3 * k + 1]], p[3 * t[3 * k + 1] + 1], p[3 * t[3 * k + 1] + 2]);
        BKVec3d c = BKV3d(p[3 * t[3 * k + 2]], p[3 * t[3 * k + 2] + 1], p[3 * t[3 * k + 2] + 2]);
        BKVec3d normal = BKV3d(nrm[3 * t[3 * k]], nrm[3 * t[3 * k] + 1], nrm[3 * t[3 * k] + 2]);
        BKVec3d cross = BKV3dCross(BKV3dSub(b, a), BKV3dSub(c, a));
        XCTAssertEqualWithAccuracy(BKV3dDot(cross, normal), 1.0, 1e-6, @"triangle %d outward, area 0.5", k);
        XCTAssertEqualWithAccuracy(BKV3dDot(a, normal), 0.5, 1e-6);
    }
}

- (void)testCornerCameraTurnsOnlyAndFitsTheCube
{
    // Main camera: front view, far away, zoomed - the cube camera ignores all but the rotation.
    BKCameraFrame main = BKTestCamera(BKV3d(0, 1, 0), BKV3d(0, 0.3, 1));   // up not perpendicular on purpose
    main.position = BKV3d(123, -900, 45);
    BKCameraFrame c;
    XCTAssertTrue(BKOrientationCubeCamera(main, 1.0, &c));
    XCTAssertTrue(c.perspective);
    XCTAssertEqualWithAccuracy(c.viewAngle, 30, 1e-12);
    XCTAssertEqualWithAccuracy(c.direction.y, 1, 1e-12);
    XCTAssertEqualWithAccuracy(c.up.z, 1, 1e-12);
    XCTAssertEqualWithAccuracy(BKV3dDot(c.up, c.direction), 0, 1e-12);
    double d = BKOrientationCubeBoundingRadius() / sin(15.0 * M_PI / 180.0);
    XCTAssertEqualWithAccuracy(c.position.y, -d, 1e-9);
    XCTAssertEqualWithAccuracy(c.position.x, 0, 1e-12);
    for (int tall = 0; tall < 2; tall++) {
        double aspect = tall ? 0.5 : 1.0, w = 100 * aspect, h = 100;
        // Seen from an oblique direction, every corner of the cube lies inside the corner view.
        BKCameraFrame oblique = BKTestCamera(BKV3d(1, 2, -1.5), BKV3d(0, 0, 1));
        XCTAssertTrue(BKOrientationCubeCamera(oblique, aspect, &c));
        for (int i = 0; i < 8; i++) {
            BKVec3d corner = BKV3d((i & 1) ? 0.5 : -0.5, (i & 2) ? 0.5 : -0.5, (i & 4) ? 0.5 : -0.5);
            double x, y;
            XCTAssertTrue(BKCameraProjectPoint(c, w, h, corner, &x, &y, NULL));
            XCTAssertTrue(x > 0 && x < w && y > 0 && y < h, @"corner %d inside (aspect %.1f): %.1f %.1f", i, aspect, x, y);
        }
    }
    BKCameraFrame bad = BKTestCamera(BKV3d(0, 0, 1), BKV3d(0, 0, 1));   // up parallel to the direction
    XCTAssertFalse(BKOrientationCubeCamera(bad, 1, &c));
}

- (void)testClassicCornerRectangle
{
    double vp[4];
    BKOrientationCubeClassicViewport(vp);
    BKOrientationRect r;
    XCTAssertTrue(BKOrientationCubeCornerRect(1000, 800, vp, &r));
    XCTAssertEqual(r.x, 900); XCTAssertEqual(r.y, 0); XCTAssertEqual(r.width, 100); XCTAssertEqual(r.height, 80);
    double empty[4] = { 0.5, 0.5, 0.5, 0.9 };
    XCTAssertFalse(BKOrientationCubeCornerRect(1000, 800, empty, &r));
}

#pragma mark - GPU

// Counts pixels by colour class in a picture; NO when anything was drawn outside `corner`.
static void BKTestCount(BKRenderResult *res, CGRect corner, NSUInteger *white, NSUInteger *red, NSUInteger *green,
                        NSUInteger *blue, NSUInteger *outside)
{
    *white = *red = *green = *blue = *outside = 0;
    const uint8_t *px = res.rgba8Data.bytes;
    for (NSUInteger y = 0; y < res.height; y++)
        for (NSUInteger x = 0; x < res.width; x++) {
            const uint8_t *p = px + 4 * (y * res.width + x);
            BOOL in = CGRectContainsPoint(corner, CGPointMake(x + 0.5, y + 0.5));
            if (!in) { if (p[3]) (*outside)++; continue; }
            if (p[3] < 250) continue;
            if (p[0] > 200 && p[1] > 200 && p[2] > 200) (*white)++;
            else if (p[0] > 200 && p[1] < 60 && p[2] < 60) (*red)++;
            else if (p[1] > 200 && p[0] < 60 && p[2] < 60) (*green)++;
            else if (p[2] > 200 && p[0] < 60 && p[1] < 60) (*blue)++;
        }
}

- (void)testCubeDrawsInItsCornerWithTheRightLetters
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return; }
    NSError *error = nil;
    BKOrientationCube *cube = [[BKOrientationCube alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(cube, @"%@", error);
    XCTAssertEqual(cube.skippedCharacterCount, 0u);
    XCTAssertEqual(cube.meshObjects.count, 7u);
    CGRect corner = CGRectMake(120, 0, 80, 80);
    struct { BKVec3d dir, up; int expect; } views[] = {
        { {0, 1, 0}, {0, 0, 1}, 1 },    // front: green A
        { {-1, 0, 0}, {0, 0, 1}, 2 },   // from the patient's left: blue L
        { {0, 0, -1}, {1, 0, 0}, 0 },   // from above: red S
    };
    for (int v = 0; v < 3; v++) {
        BKRenderResult *res = [cube renderWithWidth:200 height:150 viewport:corner
                                         mainCamera:BKTestCamera(views[v].dir, views[v].up) error:&error];
        XCTAssertNotNil(res, @"%@", error);
        NSUInteger white, red, green, blue, outside;
        BKTestCount(res, corner, &white, &red, &green, &blue, &outside);
        XCTAssertEqual(outside, 0u, @"view %d: nothing outside the corner", v);
        XCTAssertGreaterThan(white, 400u, @"view %d: white cube face", v);
        NSUInteger letter = views[v].expect == 0 ? red : (views[v].expect == 1 ? green : blue);
        NSUInteger others = (views[v].expect == 0 ? 0 : red) + (views[v].expect == 1 ? 0 : green) + (views[v].expect == 2 ? 0 : blue);
        XCTAssertGreaterThan(letter, 150u, @"view %d: the face's letter in its colour", v);
        XCTAssertLessThan(others, 20u, @"view %d: no other letter seen face-on", v);
    }
    // System-font letters (default since 2026-11-14): every character can be drawn, none skipped.
    XCTAssertTrue(cube.usesSystemFont);
    [cube setLabels:@[@"L", @"R", @"P", @"A", @"H", @"F"]];
    XCTAssertEqual(cube.skippedCharacterCount, 0u);
    // Hand-drawn core letters: unknown characters are counted (the app logs them).
    cube.usesSystemFont = NO;
    [cube setLabels:@[@"L", @"R", @"P", @"A", @"H", @"F"]];
    XCTAssertEqual(cube.skippedCharacterCount, 2u);
    cube.usesSystemFont = YES;
    // nil restores L R P A S I.
    [cube setLabels:nil];
    XCTAssertEqualObjects(cube.labels, (@[@"L", @"R", @"P", @"A", @"S", @"I"]));
}

@end
