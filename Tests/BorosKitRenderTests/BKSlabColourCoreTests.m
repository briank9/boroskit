// Tests for the colour (RGB) slab look (BKSlabColourCore.h). Boros 6 (2026-11-24, mpr-colour).
// Expected numbers worked out by hand from the rules in the header, plus a GPU check that the volume renderer's
// colour MIP windowed over [0, 255] returns the projected channel bytes the mapping expects.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"

@interface BKSlabColourCoreTests : XCTestCase
@end

@implementation BKSlabColourCoreTests

// The classic default table: linear opacity v / 255 over the bytes, grey colours (ignored without a colour table).
static void LinearTable(float *t)
{
    for (int v = 0; v < 256; v++) { t[4 * v] = t[4 * v + 1] = t[4 * v + 2] = v / 255.0f; t[4 * v + 3] = v / 255.0f; }
}

// Pure channel colours: each channel shows as v * a(v) = v^2 / 255 (the classic darker mid tones).
- (void)testChannelColours
{
    float table[1024], rgb[3];
    LinearTable(table);
    BKSlabColourOfChannels(255, 128, 0, table, 0, rgb);
    XCTAssertEqualWithAccuracy(rgb[0], 1.0f, 1e-6);
    XCTAssertEqualWithAccuracy(rgb[1], (128.0f / 255) * (128.0f / 255), 1e-6);
    XCTAssertEqualWithAccuracy(rgb[2], 0.0f, 1e-6);

    uint8_t px[8] = { 255, 128, 0, 7, 0, 0, 0, 0 }, out[8];
    XCTAssertEqual(BKSlabColourMapChannels(px, 2, table, 0, out), 1);
    XCTAssertEqual(out[0], 255);   // A
    XCTAssertEqual(out[1], 255);   // R
    XCTAssertEqual(out[2], 64);    // G: 128^2 / 255 = 64.25
    XCTAssertEqual(out[3], 0);     // B
    XCTAssertEqual(out[4], 255); XCTAssertEqual(out[5], 0); XCTAssertEqual(out[6], 0); XCTAssertEqual(out[7], 0);
    // In place.
    XCTAssertEqual(BKSlabColourMapChannels(px, 2, table, 0, px), 1);
    XCTAssertEqual(px[2], 64);
}

// A colour table: every channel adds the table's colour times its opacity; each part capped at 1.
- (void)testTableColours
{
    float table[1024], rgb[3];
    for (int v = 0; v < 256; v++) { table[4 * v] = 1; table[4 * v + 1] = 0.5f; table[4 * v + 2] = 0; table[4 * v + 3] = 0.25f; }
    BKSlabColourOfChannels(10, 20, 30, table, 1, rgb);   // 3 x 0.25 x (1, 0.5, 0)
    XCTAssertEqualWithAccuracy(rgb[0], 0.75f, 1e-6);
    XCTAssertEqualWithAccuracy(rgb[1], 0.375f, 1e-6);
    XCTAssertEqualWithAccuracy(rgb[2], 0.0f, 1e-6);
    for (int v = 0; v < 256; v++) table[4 * v + 3] = 0.6f;
    BKSlabColourOfChannels(10, 20, 30, table, 1, rgb);   // 1.8 capped at 1
    XCTAssertEqualWithAccuracy(rgb[0], 1.0f, 1e-6);
    XCTAssertEqualWithAccuracy(rgb[1], 0.9f, 1e-6);
    XCTAssertEqual(BKSlabColourMapChannels(NULL, 1, table, 1, NULL), 0);
}

// GPU: a colour scan's MIP windowed over [0, 255] gives the per-channel maxima as bytes.
- (void)testRendererChannelProjection
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return; }
    NSError *error = nil;
    BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(r, @"%@", error);
    enum { N = 16 };
    static uint8_t voxels[N * N * N * 4];
    for (int z = 0; z < N; z++) for (int y = 0; y < N; y++) for (int x = 0; x < N; x++) {
        uint8_t *v = &voxels[4 * ((z * N + y) * N + x)];
        v[0] = 255;                          // A (ignored)
        v[1] = (uint8_t)(z == 5 ? 200 : 20); // R peaks on slice 5
        v[2] = (uint8_t)(z == 9 ? 150 : 10); // G peaks on slice 9
        v[3] = 60;                           // B flat
    }
    double m[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    BKVolumeTexture *t = [[BKVolumeTexture alloc] initWithColorVoxels:voxels bytesPerVoxel:4 redByte:1 greenByte:2 blueByte:3
                                                                 width:N height:N depth:N patientToVoxel:m minPixelSpacing:1
                                                                device:device error:&error];
    XCTAssertNotNil(t, @"%@", error);
    r.volumeTexture = t;
    r.mode = BKRenderModeMIP;
    r.projection = BKProjectionOrthographic;
    r.cameraPosition = N3VectorMake(7.5, 7.5, 7.5);
    r.cameraDirection = N3VectorMake(0, 0, 1);
    r.cameraUp = N3VectorMake(0, 1, 0);
    r.viewWidth = N;
    r.viewHeight = N;
    r.sampleSpacing = 0.1;
    r.windowCenter = 127.5f;
    r.windowWidth = 255;
    BKRenderResult *res = [r renderWithWidth:N height:N error:&error];
    XCTAssertNotNil(res, @"%@", error);
    uint8_t px[4];
    [res getRGBA8:px atX:N / 2 y:N / 2];
    // Samples sit at 0.05, 0.15, ... voxels: the peak slice is met 0.05 voxels off (interpolated), so ~191 / ~143.
    XCTAssertEqualWithAccuracy(px[0], 200, 10);
    XCTAssertEqualWithAccuracy(px[1], 150, 8);
    XCTAssertGreaterThan(px[0], px[1]);
    XCTAssertEqualWithAccuracy(px[2], 60, 1);
    r.mode = BKRenderModeMinIP;
    res = [r renderWithWidth:N height:N error:&error];
    [res getRGBA8:px atX:N / 2 y:N / 2];
    XCTAssertEqualWithAccuracy(px[0], 20, 1);
    XCTAssertEqualWithAccuracy(px[1], 10, 1);
}

@end
