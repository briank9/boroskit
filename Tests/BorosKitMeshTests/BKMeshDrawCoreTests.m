// Tests for face culling, textured surfaces and points (added 2026-11-14 for the ROI volume
// window). Original BorosKit code written for this project; contains no third-party code.
//
// What is checked, in plain terms:
//  - the plain-C reference rules (BKMeshDrawCore.h): which side of a triangle is the front,
//    how 1-4 component pictures become RGBA, how a texture is looked up (nearest / linear,
//    repeat / clamp, row 0 = t 0), how the texture colour is combined, how big a point is;
//  - the GPU follows those rules: back / front culling removes the right side (also with a
//    mirrored placement, as OpenGL does), a textured square shows exactly the reference texels,
//    a see-through texture makes the object see-through, points cover exactly the reference
//    squares and are hidden behind surfaces like everything else.
// GPU tests skip themselves on a machine without Metal.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitMeshRender.h"
#import "BorosKitMesh.h"
#import "BorosKitRender.h"

@interface BKMeshDrawCoreTests : XCTestCase
@end

@implementation BKMeshDrawCoreTests

#pragma mark - Helpers

// What: a renderer on the default GPU, or nil (test skipped) without one.
- (BKMeshRenderer *)renderer
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return nil; }
    NSError *error = nil;
    BKMeshRenderer *r = [[BKMeshRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(r, @"%@", error);
    return r;
}

// What: orthographic front view (looking along +y, image right = +x, image up = +z), 100 mm
// in 100 pixels, centred on the origin: patient (x, z) mm lands on pixel centre (50 + x, 50 - z).
- (void)setFrontCamera:(BKMeshRenderer *)r
{
    BKVolumeCamera *camera = [[BKVolumeCamera alloc] init];
    camera.focalPoint = N3VectorZero;
    camera.parallelScale = 50;
    [camera showStandardView:BKStandardViewAnterior];
    [r setCameraFromVolumeCamera:camera aspectRatio:1];
}

- (BKRenderResult *)render:(BKMeshRenderer *)r size:(NSUInteger)size
{
    NSError *error = nil;
    BKRenderResult *result = [r renderWithWidth:size height:size error:&error];
    XCTAssertNotNil(result, @"%@", error);
    return result;
}

// What: number of pixels with opacity above half.
static NSUInteger BKCoveredCount(BKRenderResult *result)
{
    NSUInteger n = 0;
    const uint8_t *rgba = result.rgba8Data.bytes;
    for (NSUInteger i = 0; i < result.width * result.height; i++) if (rgba[4 * i + 3] > 127) n++;
    return n;
}

// What: a square in the plane y = 0 from (-h, -h) to (h, h) in (x, z), facing the front-view
// camera (its corners anticlockwise as seen from the camera), with texture coordinates
// s = 0..1 left to right and t = 0..1 bottom to top.
static BKMeshObject *BKFacingSquare(float h, BOOL withTextureCoordinates)
{
    simd_float3 v[4] = { simd_make_float3(-h, 0, -h), simd_make_float3(h, 0, -h), simd_make_float3(h, 0, h), simd_make_float3(-h, 0, h) };
    uint32_t idx[6] = { 0, 1, 2, 0, 2, 3 };
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:v vertexCount:4 indices:idx indexCount:6 normals:NULL colors:NULL error:NULL];
    BKMeshObject *o = [[BKMeshObject alloc] initWithMesh:mesh];
    if (withTextureCoordinates) {
        simd_float2 tc[4] = { simd_make_float2(0, 0), simd_make_float2(1, 0), simd_make_float2(1, 1), simd_make_float2(0, 1) };
        [o setTextureCoordinates:tc count:4];
    }
    return o;
}

#pragma mark - Plain-C reference rules

- (void)testFacingRule
{
    BKVec2f a = BKV2f(0, 0), b = BKV2f(1, 0), c = BKV2f(0, 1);   // core types (BKVec.h)
    XCTAssertEqual(BKMeshTriangleIsFrontFacing(a, b, c), 1);    // anticlockwise, y up
    XCTAssertEqual(BKMeshTriangleIsFrontFacing(a, c, b), 0);    // clockwise
    XCTAssertEqual(BKMeshTriangleIsFrontFacing(a, a, b), 0);    // no area
    XCTAssertEqual(BKMeshTriangleIsCulled(BKMeshCullNone, a, c, b), 0);
    XCTAssertEqual(BKMeshTriangleIsCulled(BKMeshCullBack, a, b, c), 0);
    XCTAssertEqual(BKMeshTriangleIsCulled(BKMeshCullBack, a, c, b), 1);
    XCTAssertEqual(BKMeshTriangleIsCulled(BKMeshCullFront, a, b, c), 1);
    XCTAssertEqual(BKMeshTriangleIsCulled(BKMeshCullFront, a, c, b), 0);
}

- (void)testTextureExpandRule
{
    uint8_t out[8];
    const uint8_t grey[2] = { 10, 20 };
    XCTAssertEqual(BKMeshTextureExpandToRGBA8(grey, 1, 2, out), 1);
    const uint8_t expect1[8] = { 10, 10, 10, 255, 20, 20, 20, 255 };
    XCTAssertEqual(memcmp(out, expect1, 8), 0);
    const uint8_t greyAlpha[2] = { 30, 40 };
    BKMeshTextureExpandToRGBA8(greyAlpha, 2, 1, out);
    XCTAssertTrue(out[0] == 30 && out[1] == 30 && out[2] == 30 && out[3] == 40);
    const uint8_t rgb[3] = { 1, 2, 3 };
    BKMeshTextureExpandToRGBA8(rgb, 3, 1, out);
    XCTAssertTrue(out[0] == 1 && out[1] == 2 && out[2] == 3 && out[3] == 255);
    const uint8_t rgba[4] = { 4, 5, 6, 7 };
    BKMeshTextureExpandToRGBA8(rgba, 4, 1, out);
    XCTAssertTrue(out[0] == 4 && out[1] == 5 && out[2] == 6 && out[3] == 7);
    XCTAssertEqual(BKMeshTextureExpandToRGBA8(rgba, 5, 1, out), 0);
    XCTAssertEqual(BKMeshTextureExpandToRGBA8(NULL, 3, 1, out), 0);
}

- (void)testTextureSampleRule
{
    // 2 x 2 picture: row 0 (t = 0): black, red; row 1: green, blue.
    const uint8_t px[16] = { 0, 0, 0, 255,   255, 0, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255 };
    // Nearest: the texel the position falls into; row 0 is at small t.
    BKVec4f c = BKMeshTextureSample(px, 2, 2, 0.75f, 0.25f, 0, BKMeshTextureWrapRepeat);
    XCTAssertEqualWithAccuracy(c.x, 1, 1e-6);   // red
    c = BKMeshTextureSample(px, 2, 2, 0.25f, 0.75f, 0, BKMeshTextureWrapRepeat);
    XCTAssertEqualWithAccuracy(c.y, 1, 1e-6);   // green
    // Repeat: s = 1.25 is s = 0.25.
    c = BKMeshTextureSample(px, 2, 2, 1.25f, 0.25f, 0, BKMeshTextureWrapRepeat);
    XCTAssertEqualWithAccuracy(c.x, 0, 1e-6);   // black
    // Clamp: s = 1.25 is the right edge.
    c = BKMeshTextureSample(px, 2, 2, 1.25f, 0.25f, 0, BKMeshTextureWrapClampToEdge);
    XCTAssertEqualWithAccuracy(c.x, 1, 1e-6);   // red
    // Linear at a texel centre = that texel; halfway between two centres = the average.
    c = BKMeshTextureSample(px, 2, 2, 0.75f, 0.25f, 1, BKMeshTextureWrapClampToEdge);
    XCTAssertEqualWithAccuracy(c.x, 1, 1e-6);
    c = BKMeshTextureSample(px, 2, 2, 0.5f, 0.25f, 1, BKMeshTextureWrapClampToEdge);
    XCTAssertEqualWithAccuracy(c.x, 0.5, 1e-6);
    // Linear with repeat at s = 0 blends the left and the right column.
    c = BKMeshTextureSample(px, 2, 2, 0.0f, 0.25f, 1, BKMeshTextureWrapRepeat);
    XCTAssertEqualWithAccuracy(c.x, 0.5, 1e-6);
    // Modulate: clamped lit colour times texel, premultiplied.
    BKVec4f m = BKMeshTextureModulate(BKV4f(2.0f, 0.5f, 1.0f, 0.5f), BKV4f(0.5f, 1.0f, 1.0f, 0.5f));
    XCTAssertEqualWithAccuracy(m.w, 0.25, 1e-6);
    XCTAssertEqualWithAccuracy(m.x, 0.5 * 0.25, 1e-6);
    XCTAssertEqualWithAccuracy(m.y, 0.5 * 0.25, 1e-6);
    // Point square.
    BKVec2f lo, hi;
    BKMeshPointSquare(10, 20, 4, &lo, &hi);
    XCTAssertTrue(lo.x == 8 && lo.y == 18 && hi.x == 12 && hi.y == 22);
}

- (void)testTextureObjectAndTexturedFlag
{
    const uint8_t rgb[6] = { 1, 2, 3, 4, 5, 6 };
    BKMeshTexture *t = [[BKMeshTexture alloc] initWithPixels:rgb components:3 width:2 height:1];
    XCTAssertNotNil(t);
    XCTAssertTrue(t.opaque);
    XCTAssertTrue(t.interpolate && t.repeat);
    XCTAssertEqual(t.rgba8Data.length, 8u);
    const uint8_t ga[2] = { 9, 100 };
    XCTAssertFalse([[BKMeshTexture alloc] initWithPixels:ga components:2 width:1 height:1].opaque);
    XCTAssertNil([[BKMeshTexture alloc] initWithPixels:rgb components:0 width:2 height:1]);
    XCTAssertNil([[BKMeshTexture alloc] initWithPixels:rgb components:3 width:0 height:1]);

    BKMeshObject *o = BKFacingSquare(10, NO);
    o.texture = t;
    XCTAssertFalse(o.textured);                 // no coordinates: drawn untextured (VTK's rule)
    simd_float2 three[3] = {};
    [o setTextureCoordinates:three count:3];
    XCTAssertFalse(o.textured);                 // wrong count
    o = BKFacingSquare(10, YES);
    o.texture = t;
    XCTAssertTrue(o.textured);
    [o setTextureCoordinates:NULL count:0];
    XCTAssertFalse(o.textured);
}

#pragma mark - Face culling on the GPU

// A box whose sides face outward, front view: without culling and with back culling the
// nearest (front) side is seen (ray distance -10 mm); with front culling the inside of the far
// side is seen (+10 mm). The picture covers the same 20 x 20 pixels in all three cases.
- (void)testBoxCulling
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    [self setFrontCamera:r];
    BKMeshObject *box = [[BKMeshObject alloc] initWithMesh:[BKMesh boxMeshWithMin:simd_make_float3(-10, -10, -10) max:simd_make_float3(10, 10, 10)]];
    r.objects = @[box];
    BKMeshFaceCulling modes[3] = { BKMeshFaceCullingNone, BKMeshFaceCullingBack, BKMeshFaceCullingFront };
    float expected[3] = { -10, -10, 10 };
    for (int i = 0; i < 3; i++) {
        box.faceCulling = modes[i];
        BKRenderResult *res = [self render:r size:100];
        XCTAssertEqual(BKCoveredCount(res), 400u, @"mode %d", i);
        XCTAssertEqualWithAccuracy([res valueAtX:50 y:50], expected[i], 0.01, @"mode %d", i);
    }
    // A mirrored placement turns the box inside out on screen (as in OpenGL): back culling now
    // shows the far side.
    box.faceCulling = BKMeshFaceCullingBack;
    simd_float4x4 mirror = matrix_identity_float4x4;
    mirror.columns[0].x = -1;
    box.transform = mirror;
    XCTAssertEqualWithAccuracy([[self render:r size:100] valueAtX:50 y:50], 10, 0.01);
}

// One square facing the camera, then the same square turned round: each culling mode removes
// exactly what the plain-C rule (BKMeshTriangleIsCulled) says, from both projections.
- (void)testCullingMatchesReferenceRule
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    for (int perspective = 0; perspective < 2; perspective++) {
        BKVolumeCamera *camera = [[BKVolumeCamera alloc] init];
        camera.focalPoint = N3VectorZero;
        camera.parallelScale = 50;
        camera.distance = 200;
        camera.projection = perspective ? BKProjectionPerspective : BKProjectionOrthographic;
        [camera showStandardView:BKStandardViewAnterior];
        [r setCameraFromVolumeCamera:camera aspectRatio:1];
        for (int turned = 0; turned < 2; turned++) {
            BKMeshObject *square = BKFacingSquare(10, NO);
            if (turned) {   // rotate 180 degrees about z: the back side faces the camera
                simd_float4x4 m = matrix_identity_float4x4;
                m.columns[0].x = -1; m.columns[1].y = -1;
                square.transform = m;
            }
            r.objects = @[square];
            // Screen positions of the first triangle (x right = +x mm, y up = +z mm; the turn
            // mirrors x on screen).
            float sx = turned ? -1 : 1;
            BKVec2f a = BKV2f(-10 * sx, -10), b = BKV2f(10 * sx, -10), c = BKV2f(10 * sx, 10);
            int32_t cullModes[3] = { BKMeshCullNone, BKMeshCullBack, BKMeshCullFront };
            for (int m = 0; m < 3; m++) {
                square.faceCulling = (BKMeshFaceCulling)cullModes[m];
                BOOL drawn = BKCoveredCount([self render:r size:100]) > 0;
                XCTAssertEqual(drawn, !BKMeshTriangleIsCulled(cullModes[m], a, b, c),
                               @"perspective %d turned %d cull %d", perspective, turned, cullModes[m]);
            }
        }
    }
}

#pragma mark - Textures on the GPU

// What: renders a facing square that fills the 64 x 64 picture exactly (64 mm, 1 mm per pixel),
// unlit and white, with `texture`; checks every pixel against the reference lookup at that
// pixel's centre (s left to right, t bottom to top). Returns the largest difference (0..255).
- (int)largestDifferenceForTexture:(BKMeshTexture *)texture renderer:(BKMeshRenderer *)r
{
    BKVolumeCamera *camera = [[BKVolumeCamera alloc] init];
    camera.focalPoint = N3VectorZero;
    camera.parallelScale = 32;
    [camera showStandardView:BKStandardViewAnterior];
    [r setCameraFromVolumeCamera:camera aspectRatio:1];
    BKMeshObject *square = BKFacingSquare(32, YES);
    square.color = simd_make_float3(1, 1, 1);
    square.lit = NO;
    square.texture = texture;
    r.objects = @[square];
    BKRenderResult *res = [self render:r size:64];
    int worst = 0;
    for (NSUInteger y = 0; y < 64; y++)
        for (NSUInteger x = 0; x < 64; x++) {
            float s = (x + 0.5f) / 64.0f, t = 1.0f - (y + 0.5f) / 64.0f;
            BKVec4f texel = BKMeshTextureSample(texture.rgba8Data.bytes, (uint32_t)texture.width, (uint32_t)texture.height, s, t,
                                                    texture.interpolate, texture.repeat ? BKMeshTextureWrapRepeat : BKMeshTextureWrapClampToEdge);
            BKVec4f e = BKMeshTextureModulate(BKV4f(1, 1, 1, 1), texel);
            float expect[4] = { e.x * 255.0f, e.y * 255.0f, e.z * 255.0f, e.w * 255.0f };
            uint8_t px[4];
            [res getRGBA8:px atX:x y:y];
            for (int k = 0; k < 4; k++) worst = MAX(worst, abs((int)px[k] - (int)lroundf(expect[k])));
        }
    return worst;
}

// A 4 x 4 RGB checker-like picture on a square: nearest and linear lookups, repeat and clamp,
// all match the plain-C reference (linear within the GPU's blend-weight rounding).
- (void)testTexturedSquareMatchesReference
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    uint8_t px[4 * 4 * 3];
    for (int i = 0; i < 16; i++) {
        px[3 * i] = (uint8_t)(i * 16);
        px[3 * i + 1] = (uint8_t)((i % 4) * 80);
        px[3 * i + 2] = (uint8_t)((i / 4) * 80);
    }
    BKMeshTexture *texture = [[BKMeshTexture alloc] initWithPixels:px components:3 width:4 height:4];
    for (int interpolate = 0; interpolate < 2; interpolate++)
        for (int repeat = 0; repeat < 2; repeat++) {
            texture.interpolate = interpolate;
            texture.repeat = repeat;
            int worst = [self largestDifferenceForTexture:texture renderer:r];
            XCTAssertLessThanOrEqual(worst, interpolate ? 2 : 0, @"interpolate %d repeat %d", interpolate, repeat);
        }
    // Row 0 is at t = 0, i.e. the BOTTOM of this square: the bottom-left pixel shows texel 0.
    texture.interpolate = NO;
    [self largestDifferenceForTexture:texture renderer:r];
    BKRenderResult *res = [self render:r size:64];
    uint8_t c[4];
    [res getRGBA8:c atX:1 y:62];
    XCTAssertEqual(c[0], 0);
    XCTAssertEqual(c[2], 0);
    [res getRGBA8:c atX:1 y:1];      // top-left: texel 12 (row 3, column 0)
    XCTAssertEqual(c[0], 12 * 16);
    XCTAssertEqual(c[2], 240);
}

// A grey + alpha picture: the object becomes see-through (drawn in the see-through pass, so it
// does not stop the ray-distance output) and its colour is premultiplied like the reference.
- (void)testSeeThroughTexture
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    const uint8_t ga[2] = { 200, 128 };
    BKMeshTexture *texture = [[BKMeshTexture alloc] initWithPixels:ga components:2 width:1 height:1];
    XCTAssertLessThanOrEqual([self largestDifferenceForTexture:texture renderer:r], 1);
    BKRenderResult *res = [self render:r size:64];
    XCTAssertTrue(isinf([res valueAtX:32 y:32]));   // see-through: no ray distance
    // Untextured (no texture set) the same square is solid.
    ((BKMeshObject *)r.objects.firstObject).texture = nil;
    XCTAssertEqualWithAccuracy([[self render:r size:64] valueAtX:32 y:32], 0, 0.01);
}

#pragma mark - Points on the GPU

// Points of 3 and 4 pixels cover exactly the pixels whose centres lie in the reference square;
// a point behind a solid box is hidden, one in front is drawn over it; points write the ray
// distance like lines.
- (void)testPointsCoverReferenceSquares
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    [self setFrontCamera:r];
    for (int size = 3; size <= 4; size++) {
        // (10.25, 0, 20.25) mm -> pixel position (60.25, 29.75); (-20.25, 0, -10.25) -> (29.75, 60.25).
        // (Quarter-pixel positions: no square edge falls exactly on a pixel centre.)
        simd_float3 p[2] = { simd_make_float3(10.25f, 0, 20.25f), simd_make_float3(-20.25f, 0, -10.25f) };
        BKPointObject *points = [[BKPointObject alloc] initWithPoints:p count:2];
        points.pointSize = size;
        points.color = simd_make_float3(1, 0, 0);
        r.pointObjects = @[points];
        r.objects = @[];
        BKRenderResult *res = [self render:r size:100];
        NSUInteger expectedCount = 0;
        float centres[2][2] = { { 60.25f, 29.75f }, { 29.75f, 60.25f } };
        for (int k = 0; k < 2; k++) {
            BKVec2f lo, hi;
            BKMeshPointSquare(centres[k][0], centres[k][1], size, &lo, &hi);
            for (int y = 0; y < 100; y++)
                for (int x = 0; x < 100; x++) {
                    BOOL inside = (x + 0.5f) >= lo.x && (x + 0.5f) < hi.x && (y + 0.5f) >= lo.y && (y + 0.5f) < hi.y;
                    if (!inside) continue;
                    expectedCount++;
                    uint8_t c[4];
                    [res getRGBA8:c atX:x y:y];
                    XCTAssertEqual(c[0], 255, @"size %d point %d pixel %d,%d", size, k, x, y);
                }
        }
        XCTAssertEqual(BKCoveredCount(res), expectedCount, @"size %d", size);
        XCTAssertEqual(expectedCount, (NSUInteger)(2 * size * size));
        XCTAssertEqualWithAccuracy([res valueAtX:60 y:29], 0, 0.01);   // ray distance of the point
    }
    // Hidden behind / drawn in front of a solid box (front view looks along +y).
    BKMeshObject *box = [[BKMeshObject alloc] initWithMesh:[BKMesh boxMeshWithMin:simd_make_float3(-30, -10, -30) max:simd_make_float3(30, 10, 30)]];
    box.color = simd_make_float3(0, 0, 1);
    box.lit = NO;
    r.objects = @[box];
    simd_float3 behind = simd_make_float3(0, 20, 0);
    BKPointObject *point = [[BKPointObject alloc] initWithPoints:&behind count:1];
    point.pointSize = 5;
    point.color = simd_make_float3(1, 0, 0);
    r.pointObjects = @[point];
    uint8_t c[4];
    [[self render:r size:100] getRGBA8:c atX:50 y:50];
    XCTAssertEqual(c[0], 0);
    XCTAssertEqual(c[2], 255);
    simd_float3 front = simd_make_float3(0, -20, 0);
    [point setPoints:&front count:1];
    [[self render:r size:100] getRGBA8:c atX:50 y:50];
    XCTAssertEqual(c[0], 255);
    XCTAssertEqual(c[2], 0);
}

@end
