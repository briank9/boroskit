// Tests for the curved-MPR height cut-off (BKHeightBandCore + its use in BKCurvedReformatCore / the GPU kernel).
//
// Original BorosKit code written for this project; contains no third-party code.
// Boros 6 (2026-11-25, cpr-cutoff). What is checked: the column height function and the picture helpers
// against hand-computed values; that the CPU reference skips samples outside the band for every projection
// (and is bit-identical to before when the cut-off is off); and that the GPU kernel matches the CPU reference
// with the cut-off on (the comparison a Vulkan port must pass).

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BKCurvedReformat.h"
#import "BKHeightBandCore.h"
#import "BKVolumeTexture.h"
#include <unistd.h>

@interface BKHeightBandCoreTests : XCTestCase
@end

static const uint32_t kBN = 20;   // phantom size

// What: phantom whose value is the voxel's z index * 100 - 1000 (so the value tells which height a sample
// came from), with x / y adding a little ramp so MIP / MinIP / mean are distinguishable.
static float *BKBandPhantom(void)
{
    float *v = malloc(sizeof(float) * kBN * kBN * kBN);
    for (uint32_t z = 0; z < kBN; z++)
        for (uint32_t y = 0; y < kBN; y++)
            for (uint32_t x = 0; x < kBN; x++)
                v[x + kBN * (y + kBN * z)] = (float)(100 * z) - 1000.0f + 0.5f * (float)x;
    return v;
}

static BKReformatParams BKBandParams(uint32_t w, uint32_t h, uint32_t d, BKReformatProjection proj)
{
    BKReformatParams p;
    memset(&p, 0, sizeof(p));
    p.width = w; p.height = h; p.depth = d;
    p.interpolation = BKReformatNearest; p.projection = proj;
    p.outOfBoundsValue = -2000.0f;
    p.radiographK = BKReformatRadiographK(0.75, 1.0);
    p.volumeWide = p.volumeHigh = p.volumeDeep = kBN;
    p.rowCentre = (h - 1) / 2.0f;
    p.slabCentre = (d - 1) / 2.0f;
    p.bandOutsideValue = -3000.0f;
    return p;
}

@implementation BKHeightBandCoreTests

- (void)testColumnHeightFunction
{
    // Axis +z (given with length 2: normalised), origin z = 5; column middle at z = 8, rows step 0.5 mm in z,
    // slab steps along x (no height change).
    BKVec3f fn = BKHeightBandColumn(BKV3d(0, 0, 2), BKV3d(1, 2, 5), BKV3d(4, 4, 8), BKV3d(0, 0, 0.5), BKV3d(1, 0, 0));
    XCTAssertEqualWithAccuracy(fn.x, 3.0, 1e-6);
    XCTAssertEqualWithAccuracy(fn.y, 0.5, 1e-6);
    XCTAssertEqualWithAccuracy(fn.z, 0.0, 1e-6);
    XCTAssertEqualWithAccuracy(BKHeightBandColumnHeight(fn, -4, 7), 1.0, 1e-6);
    // Tilted slab: the slab step changes the height too.
    fn = BKHeightBandColumn(BKV3d(0, 0, 1), BKV3d(0, 0, 0), BKV3d(0, 0, 0), BKV3d(0, 1, 0), BKV3d(0, 0.6, 0.8));
    XCTAssertEqualWithAccuracy(fn.z, 0.8, 1e-6);
    // Zero axis: height 0 everywhere (no NaN).
    fn = BKHeightBandColumn(BKV3d(0, 0, 0), BKV3d(0, 0, 0), BKV3d(1, 1, 1), BKV3d(0, 1, 0), BKV3d(1, 0, 0));
    XCTAssertEqual(fn.x, 0); XCTAssertEqual(fn.y, 0); XCTAssertEqual(fn.z, 0);
    // Inside test includes both ends.
    XCTAssertTrue(BKHeightBandInside(-2, 3, -2));
    XCTAssertTrue(BKHeightBandInside(-2, 3, 3));
    XCTAssertFalse(BKHeightBandInside(-2, 3, 3.001f));
}

- (void)testNormalize
{
    double lo = 10, hi = -10;
    BKHeightBandNormalize(&lo, &hi, 1);
    XCTAssertEqual(lo, -10); XCTAssertEqual(hi, 10);
    lo = 4.8; hi = 5.0;
    BKHeightBandNormalize(&lo, &hi, 2);
    XCTAssertEqualWithAccuracy(lo, 3.9, 1e-9); XCTAssertEqualWithAccuracy(hi, 5.9, 1e-9);
    lo = NAN; hi = INFINITY;
    BKHeightBandNormalize(&lo, &hi, 1);
    XCTAssertEqual(lo, -20); XCTAssertEqual(hi, 20);
}

- (void)testPictureLineAndClip
{
    // Height = (py - 50) * 0.2 mm on a 100 x 100 picture (rows downwards = positive heights).
    BKHeightBandPictureFn fn = { -10.0, 0.0, 0.2 };
    double seg[4];
    XCTAssertEqual(BKHeightBandLineInRect(fn, 4.0, 100, 100, seg), 1);   // py = 70
    XCTAssertEqualWithAccuracy(seg[1], 70, 1e-9);
    XCTAssertEqualWithAccuracy(seg[3], 70, 1e-9);
    XCTAssertEqualWithAccuracy(fabs(seg[2] - seg[0]), 100, 1e-9);
    XCTAssertEqual(BKHeightBandLineInRect(fn, 30.0, 100, 100, seg), 0);  // beyond the picture
    BKHeightBandPictureFn flat = { 1.0, 0.0, 0.0 };
    XCTAssertEqual(BKHeightBandLineInRect(flat, 1.0, 100, 100, seg), 0); // no height change: no line

    double poly[10];
    uint32_t n = BKHeightBandClipRect(fn, 4.0, 1, 100, 100, poly);   // the part below the picture's row 70
    XCTAssertEqual(n, 4u);
    double minY = 1e9, maxY = -1e9;
    for (uint32_t i = 0; i < n; i++) { minY = fmin(minY, poly[2 * i + 1]); maxY = fmax(maxY, poly[2 * i + 1]); }
    XCTAssertEqualWithAccuracy(minY, 70, 1e-9);
    XCTAssertEqualWithAccuracy(maxY, 100, 1e-9);
    XCTAssertEqual(BKHeightBandClipRect(fn, 30.0, 1, 100, 100, poly), 0u);   // nothing above 30 mm
    XCTAssertEqual(BKHeightBandClipRect(fn, 30.0, 0, 100, 100, poly), 4u);   // everything below it

    // Tilted line through two corners' neighbourhood: a triangle and a pentagon.
    BKHeightBandPictureFn tilt = { 0.0, 1.0, 1.0 };   // height = px + py
    n = BKHeightBandClipRect(tilt, 50.0, 0, 100, 100, poly);   // px + py < 50: triangle at (0,0)
    XCTAssertEqual(n, 3u);
    n = BKHeightBandClipRect(tilt, 50.0, 1, 100, 100, poly);   // the rest: pentagon
    XCTAssertEqual(n, 5u);
    XCTAssertEqual(BKHeightBandLineInRect(tilt, 50.0, 100, 100, seg), 1);
    XCTAssertEqualWithAccuracy(seg[0] + seg[1], 50, 1e-9);
    XCTAssertEqualWithAccuracy(seg[2] + seg[3], 50, 1e-9);
}

// What: a straight column going down in z: rows step 1 voxel in z, slab along x. Heights = z - 10 (mm).
static void BKBandFrames(BKReformatFrame *frames, uint32_t W, uint32_t H, int tiltedSlab)
{
    for (uint32_t i = 0; i < W; i++) {
        BKReformatFrame f = { { 3.0f + (float)i * 0.5f, 9.0f, (H - 1) / 2.0f + 0.25f, 0 }, { 0, 0, 1, 0 },
                              { 1, 0, tiltedSlab ? 0.5f : 0.0f, 0 } };
        // height(ry, rz) = z - 10 = (base z + ry + 0.5 rz) - 10
        BKVec3f fn = BKHeightBandColumn(BKV3d(0, 0, 1), BKV3d(0, 0, 10), BKV3d(f.base[0], f.base[1], f.base[2]),
                                        BKV3d(0, 0, 1), BKV3d(1, 0, tiltedSlab ? 0.5 : 0));
        f.base[3] = fn.x; f.row[3] = fn.y; f.slab[3] = fn.z;
        frames[i] = f;
    }
}

- (void)testCPUReferenceSkipsOutsideSamples
{
    float *v = BKBandPhantom();
    const uint32_t W = 4, H = 18, D = 5;
    BKReformatFrame frames[4];
    BKBandFrames(frames, W, H, 0);
    float off[W * H], on[W * H];
    for (int proj = 0; proj <= 4; proj++) {
        BKReformatParams p = BKBandParams(W, H, proj == 0 ? 1 : D, (BKReformatProjection)proj);
        // Off: bit-identical whatever the w components / limits hold.
        BKReformatComputeRows(&p, frames, v, 0, H, off);
        BKReformatFrame plain[4];
        memcpy(plain, frames, sizeof(plain));
        for (uint32_t i = 0; i < W; i++) plain[i].base[3] = plain[i].row[3] = plain[i].slab[3] = 0;
        p.bandLow = 1; p.bandHigh = 2;   // ignored while bandEnabled = 0
        BKReformatComputeRows(&p, plain, v, 0, H, on);
        XCTAssertEqual(memcmp(off, on, sizeof(off)), 0, @"projection %d", proj);
        // On: band [-3.5, 4.5] mm -> rows whose z is 6.75..14.25 are kept (z = row + 0.25 + 0 at ry...).
        p.bandEnabled = 1; p.bandLow = -3.5f; p.bandHigh = 4.5f;
        BKReformatComputeRows(&p, frames, v, 0, H, on);
        for (uint32_t y = 0; y < H; y++) {
            double z = (double)frames[0].base[2] + ((double)y - p.rowCentre);
            BOOL inside = (z - 10) >= -3.5 && (z - 10) <= 4.5;
            for (uint32_t x = 0; x < W; x++) {
                float got = on[y * W + x];
                if (inside) XCTAssertEqual(got, off[y * W + x], @"projection %d row %u inside the band changed", proj, y);
                else XCTAssertEqual(got, -3000.0f, @"projection %d row %u should be cut off", proj, y);
            }
        }
    }
    free(v);
}

// What: a slab tilted against the band (each pixel's slab crosses a limit): only the samples inside count.
- (void)testTiltedSlabProjectionUsesInsideSamplesOnly
{
    float *v = BKBandPhantom();
    const uint32_t W = 1, H = 1, D = 9;
    BKReformatFrame frames[1];
    BKBandFrames(frames, W, H, 1);   // base z = 0.25, slab rises 0.5 z per sample
    frames[0].base[2] = 10.25f;      // middle at z = 10.25 -> height 0.25
    frames[0].base[3] = 0.25f;
    BKReformatParams p = BKBandParams(W, H, D, BKReformatMIP);
    p.bandEnabled = 1; p.bandLow = -1.1f; p.bandHigh = 0.9f;   // samples rz = -2, -1, 0, 1 (heights -0.75 .. 0.75)
    float out;
    BKReformatComputeRows(&p, frames, v, 0, 1, &out);
    // Nearest sampling: (int)(z + 0.5). rz = 1 -> z = 10.75 -> voxel 11; x = 3 + 1 = 4.
    XCTAssertEqual(out, 100.0f * 11 - 1000.0f + 0.5f * 4);
    p.projection = BKReformatMinIP;
    BKReformatComputeRows(&p, frames, v, 0, 1, &out);
    // rz = -2 -> z = 9.25 -> voxel 9; x = 1.
    XCTAssertEqual(out, 100.0f * 9 - 1000.0f + 0.5f * 1);
    p.projection = BKReformatMean;
    BKReformatComputeRows(&p, frames, v, 0, 1, &out);
    double sum = 0;
    int zs[4] = { 9, 10, 10, 11 }, xs[4] = { 1, 2, 3, 4 };   // rz = -2 .. 1: z 9.25 9.75 10.25 10.75 -> 9 10 10 11
    for (int k = 0; k < 4; k++) sum += 100.0 * zs[k] - 1000.0 + 0.5 * xs[k];
    XCTAssertEqualWithAccuracy(out, sum / 4.0, 1e-3);
    p.projection = BKReformatRadiograph;
    BKReformatComputeRows(&p, frames, v, 0, 1, &out);
    double mu = 0;
    for (int k = 0; k < 4; k++) mu += ((100.0 * zs[k] - 1000.0 + 0.5 * xs[k]) + 1000.0) * p.radiographK;
    XCTAssertEqualWithAccuracy(out, 3000 - 4000 * exp(-mu), 1e-2);
    free(v);
}

- (void)testGPUMatchesCPUWithCutoff
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) return;
    NSError *error = nil;
    BKCurvedReformat *gen = [[BKCurvedReformat alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(gen, @"%@", error);
    float *v = BKBandPhantom();
    double identity[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    BKVolumeTexture *tex = [[BKVolumeTexture alloc] initWithFloatVoxels:v width:kBN height:kBN depth:kBN patientToVoxel:identity
                                                        minPixelSpacing:1 outOfBoundsValue:-2000 device:device error:&error];
    XCTAssertNotNil(tex, @"%@", error);
    // 24 columns on an arc, 26 rows going up in z with a slight tilt, slab of 7 samples tilted against the band.
    const uint32_t W = 24, H = 26, D = 7;
    BKReformatFrame *frames = malloc(sizeof(BKReformatFrame) * W);
    for (uint32_t i = 0; i < W; i++) {
        double a = M_PI_2 * i / (W - 1);
        BKVec3d mid = BKV3d(10 + 6 * cos(a), 10 + 6 * sin(a), 9.37), row = BKV3d(0.05, 0, 0.61), slab = BKV3d(cos(a) * 0.5, sin(a) * 0.5, 0.13);
        BKReformatFrame f = { { (float)mid.x, (float)mid.y, (float)mid.z, 0 }, { (float)row.x, (float)row.y, (float)row.z, 0 },
                              { (float)slab.x, (float)slab.y, (float)slab.z, 0 } };
        BKVec3f fn = BKHeightBandColumn(BKV3d(0, 0.1, 1), BKV3d(0, 0, 9.0), mid, row, slab);
        f.base[3] = fn.x; f.row[3] = fn.y; f.slab[3] = fn.z;
        frames[i] = f;
    }
    size_t page = (size_t)getpagesize(), bytes = W * H * sizeof(float), rounded = (bytes + page - 1) / page * page;
    float *gpu = NULL, *cpu = malloc(bytes);
    XCTAssertEqual(posix_memalign((void **)&gpu, page, rounded), 0);
    for (int interp = 0; interp < 3; interp++)
        for (int proj = 0; proj <= 4; proj++) {
            BKReformatParams p = BKBandParams(W, H, proj == 0 ? 1 : D, (BKReformatProjection)proj);
            p.interpolation = (BKReformatInterpolation)interp;
            p.bandEnabled = 1; p.bandLow = -3.013f; p.bandHigh = 4.021f;   // off exact sample heights
            [BKCurvedReformat computeOnCPUParams:p frames:frames voxels:v into:cpu];
            XCTAssertTrue([gen renderParams:p frames:frames volume:tex into:gpu capacity:rounded error:&error], @"%@", error);
            double worst = 0;
            size_t cut = 0;
            for (size_t k = 0; k < W * H; k++) {
                worst = fmax(worst, fabs(gpu[k] - cpu[k]));
                if (cpu[k] == -3000.0f) cut++;
            }
            XCTAssertLessThan(worst, 0.1, @"interpolation %d projection %d: largest difference %.4f", interp, proj, worst);
            XCTAssertGreaterThan(cut, (size_t)0, @"some pixels must be cut off");
            XCTAssertLessThan(cut, (size_t)(W * H), @"some pixels must stay");
        }
    free(gpu); free(cpu); free(frames); free(v);
}

// Boros 6 (2026-11-25, cpr-cutoff-2): the rows an export picture needs to cover exactly the band.
- (void)testBandRows
{
    // 3 columns, rows 0.5 mm apart, height 0 at the row centre (picture 41 rows, centre 20).
    BKReformatFrame f[3];
    memset(f, 0, sizeof(f));
    for (int i = 0; i < 3; i++) { f[i].row[3] = 0.5f; }
    int32_t first = 99;
    // Band -3 .. +5 mm -> ry -6 .. +10 -> rows 14 .. 30 (17 rows), beyond nothing.
    XCTAssertEqual(BKReformatBandRows(f, 3, 41, 20, 0, -3, 5, &first), 17u);
    XCTAssertEqual(first, 14);
    // Wider than the picture: rows outside 0..40 are allowed (the export is re-made to the band).
    XCTAssertEqual(BKReformatBandRows(f, 3, 41, 20, 0, -20, 20, &first), 81u);
    XCTAssertEqual(first, -20);
    // Downward rows (row step negative): same rows mirrored.
    for (int i = 0; i < 3; i++) f[i].row[3] = -0.5f;
    XCTAssertEqual(BKReformatBandRows(f, 3, 41, 20, 0, -3, 5, &first), 17u);
    XCTAssertEqual(first, 10);
    // Tilted band across the columns (h0 differs): the union of the columns' rows.
    for (int i = 0; i < 3; i++) { f[i].row[3] = 1.0f; f[i].base[3] = (float)i; }
    XCTAssertEqual(BKReformatBandRows(f, 3, 41, 20, 0, 0, 2, &first), 5u);   // rows 18..22
    XCTAssertEqual(first, 18);
    // A tilted slab widens each row's reach by |slab w| * slabCentre.
    for (int i = 0; i < 3; i++) { f[i].base[3] = 0; f[i].slab[3] = 0.25f; }
    XCTAssertEqual(BKReformatBandRows(f, 3, 41, 20, 4, 0, 2, &first), 5u);   // band widened by 1 mm: -1 .. 3
    XCTAssertEqual(first, 19);
    // Band outside every column's reach of a flat column: nothing.
    for (int i = 0; i < 3; i++) { f[i].row[3] = 0; f[i].slab[3] = 0; f[i].base[3] = 7; }
    XCTAssertEqual(BKReformatBandRows(f, 3, 41, 20, 0, 0, 2, &first), 0u);
    // Flat column inside the band: all rows.
    XCTAssertEqual(BKReformatBandRows(f, 3, 41, 20, 0, 0, 10, &first), 41u);
    XCTAssertEqual(first, 0);
}

@end
