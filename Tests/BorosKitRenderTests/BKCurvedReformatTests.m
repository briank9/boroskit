// Tests for the curved-MPR / cross-section generator (BKCurvedReformatCore + BKCurvedReformat).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// What is checked: the CPU reference against hand-computed values (each rule of the definition), and the
// GPU kernel against the CPU reference for every interpolation and projection (the same comparison a
// Vulkan port must pass). Integer-valued phantom voxels, so the GPU's 16-bit scan copy is exact.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BKCurvedReformat.h"
#import "BKVolumeTexture.h"
#include <unistd.h>

@interface BKCurvedReformatTests : XCTestCase
@end

static const uint32_t kN = 24;   // phantom size (kN^3 voxels)

// What: phantom value v = x + 10 y + 100 z - 1000 (a straight ramp: linear AND cubic interpolation
// reproduce it exactly away from the edges), with a bright 5x5x5 block (3000) at 15..19 to test projections.
static float *BKNewPhantom(void)
{
    float *v = malloc(sizeof(float) * kN * kN * kN);
    for (uint32_t z = 0; z < kN; z++)
        for (uint32_t y = 0; y < kN; y++)
            for (uint32_t x = 0; x < kN; x++) {
                BOOL block = x >= 15 && x < 20 && y >= 15 && y < 20 && z >= 15 && z < 20;
                v[x + kN * (y + kN * z)] = block ? 3000.0f : (float)(x + 10 * y + 100 * z) - 1000.0f;
            }
    return v;
}

static BKReformatParams BKParams(uint32_t w, uint32_t h, uint32_t d, BKReformatInterpolation interp, BKReformatProjection proj)
{
    BKReformatParams p;
    memset(&p, 0, sizeof(p));
    p.width = w; p.height = h; p.depth = d;
    p.interpolation = interp; p.projection = proj;
    p.outOfBoundsValue = -2000.0f;
    p.radiographK = BKReformatRadiographK(0.75, 0.5);
    p.volumeWide = p.volumeHigh = p.volumeDeep = kN;
    p.rowCentre = (h - 1) / 2.0f;
    p.slabCentre = (d - 1) / 2.0f;
    return p;
}

static BKReformatFrame BKFrame(float bx, float by, float bz, float rx, float ry, float rz, float sx, float sy, float sz)
{
    BKReformatFrame f = { { bx, by, bz, 0 }, { rx, ry, rz, 0 }, { sx, sy, sz, 0 } };
    return f;
}

@implementation BKCurvedReformatTests

- (void)testCPUReferenceRules
{
    float *v = BKNewPhantom();
    BKReformatParams p = BKParams(1, 1, 1, BKReformatLinear, BKReformatMIP);
    // Linear and cubic reproduce the ramp exactly inside the scan.
    XCTAssertEqualWithAccuracy(BKReformatSample(&p, v, 5.25, 6.5, 7.75), 5.25 + 65 + 775 - 1000, 1e-3);
    p.interpolation = BKReformatCubic;
    XCTAssertEqualWithAccuracy(BKReformatSample(&p, v, 5.25, 6.5, 7.75), 5.25 + 65 + 775 - 1000, 1e-3);
    // Nearest: (int)(c + 0.5) cut toward zero -> -0.9 reads voxel 0 (classic rule); 3.5 reads 4.
    p.interpolation = BKReformatNearest;
    XCTAssertEqualWithAccuracy(BKReformatSample(&p, v, -0.9, 2.2, 3.5), 0 + 20 + 400 - 1000, 0);
    XCTAssertEqualWithAccuracy(BKReformatSample(&p, v, -1.6, 2.2, 3.5), -2000, 0);   // outside
    // Projections along x through the block row y = z = 17 (slab of 24 samples from x = 0 to 23).
    BKReformatFrame f = BKFrame(11.5, 17, 17, 0, 1, 0, 1, 0, 0);
    float out;
    p = BKParams(1, 1, 24, BKReformatNearest, BKReformatMIP);
    BKReformatComputeRows(&p, &f, v, 0, 1, &out);
    XCTAssertEqualWithAccuracy(out, 3000, 0);
    p.projection = BKReformatMinIP;
    BKReformatComputeRows(&p, &f, v, 0, 1, &out);
    XCTAssertEqualWithAccuracy(out, 0 + 170 + 1700 - 1000, 0);
    p.projection = BKReformatMean;
    BKReformatComputeRows(&p, &f, v, 0, 1, &out);
    double sum = 0;
    for (int x = 0; x < 24; x++) sum += (x >= 15 && x < 20) ? 3000 : x + 170 + 1700 - 1000;
    XCTAssertEqualWithAccuracy(out, sum / 24.0, 1e-2);
    p.projection = BKReformatRadiograph;
    BKReformatComputeRows(&p, &f, v, 0, 1, &out);
    double mu = 0;
    for (int x = 0; x < 24; x++) mu += (((x >= 15 && x < 20) ? 3000 : x + 170 + 1700 - 1000) + 1000) * p.radiographK;
    XCTAssertEqualWithAccuracy(out, 3000 - 4000 * exp(-mu), 1e-2);
    free(v);
}

- (void)testGPUMatchesCPUReference
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) return;
    NSError *error = nil;
    BKCurvedReformat *gen = [[BKCurvedReformat alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(gen, @"%@", error);
    float *v = BKNewPhantom();
    double identity[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    BKVolumeTexture *tex = [[BKVolumeTexture alloc] initWithFloatVoxels:v width:kN height:kN depth:kN patientToVoxel:identity
                                                        minPixelSpacing:1 outOfBoundsValue:-2000 device:device error:&error];
    XCTAssertNotNil(tex, @"%@", error);
    // A curved set of 40 columns (a quarter circle around the block), 30 rows, slab 9 samples, reaching
    // outside the scan at the edges.
    const uint32_t W = 40, H = 30, D = 9;
    BKReformatFrame *frames = malloc(sizeof(BKReformatFrame) * W);
    for (uint32_t i = 0; i < W; i++) {
        double a = M_PI_2 * i / (W - 1);
        double cx = 12 + 10 * cos(a), cy = 12 + 10 * sin(a);
        frames[i] = BKFrame((float)cx, (float)cy, 13.3f, 0, 0, 0.7f, (float)cos(a) * 0.5f, (float)sin(a) * 0.5f, 0);
    }
    size_t page = (size_t)getpagesize(), bytes = W * H * sizeof(float), rounded = (bytes + page - 1) / page * page;
    float *gpu = NULL, *cpu = malloc(bytes);
    XCTAssertEqual(posix_memalign((void **)&gpu, page, rounded), 0);
    for (int interp = 0; interp < 3; interp++)
        for (int proj = 1; proj <= 4; proj++) {
            BKReformatParams p = BKParams(W, H, D, (BKReformatInterpolation)interp, (BKReformatProjection)proj);
            [BKCurvedReformat computeOnCPUParams:p frames:frames voxels:v into:cpu];
            XCTAssertTrue([gen renderParams:p frames:frames volume:tex into:gpu capacity:rounded error:&error], @"%@", error);
            double worst = 0;
            for (size_t k = 0; k < W * H; k++) worst = fmax(worst, fabs(gpu[k] - cpu[k]));
            // float vs double positions + 16-bit texel scaling: well below 0.1 HU.
            XCTAssertLessThan(worst, 0.1, @"interpolation %d projection %d: largest difference %.4f", interp, proj, worst);
        }
    // Unaligned destination (copied) and render-ahead give the same picture.
    BKReformatParams p = BKParams(W, H, D, BKReformatCubic, BKReformatMean);
    float *copied = malloc(bytes + 4);
    XCTAssertTrue([gen renderParams:p frames:frames volume:tex into:copied + 1 capacity:bytes error:&error]);
    id<MTLCommandBuffer> cb = [gen commitParams:p frames:frames volume:tex into:gpu capacity:rounded error:&error];
    XCTAssertNotNil(cb, @"%@", error);
    [cb waitUntilCompleted];
    XCTAssertEqual(memcmp(copied + 1, gpu, bytes), 0);
    free(copied); free(gpu); free(cpu); free(frames); free(v);
}

@end
