// Tests for slab pictures of scans bigger than one GPU texture (BKSlabBrickCore.h). Boros 6 (2026-11-24,
// mpr-colour). CPU rules with hand-worked numbers, then GPU checks: a scan cut into 27 small bricks gives the same
// MIP / MinIP / mean / VR colour slab pictures as the same scan in one texture.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"

@interface BKSlabBrickCoreTests : XCTestCase
@end

@implementation BKSlabBrickCoreTests

#pragma mark - CPU rules

// A scan that fits is one brick covering everything, without margins.
- (void)testPlanThatFits
{
    int32_t dims[3] = { 512, 512, 300 }, grid[3];
    BKSlabBrick b[4];
    XCTAssertEqual(BKSlabBrickPlan(dims, 2048, BK_SLAB_BRICK_MARGIN, b, 4, grid), 1);
    XCTAssertEqual(grid[0], 1); XCTAssertEqual(grid[2], 1);
    for (int a = 0; a < 3; a++) {
        XCTAssertEqual(b[0].coreLo[a], 0); XCTAssertEqual(b[0].coreHi[a], dims[a] - 1);
        XCTAssertEqual(b[0].texLo[a], 0);  XCTAssertEqual(b[0].texHi[a], dims[a] - 1);
    }
}

// 5000 voxels along z, textures of 2048: n = ceil(4999 / 2043) = 3, splits 0, 1666, 3333, 4999.
- (void)testPlanSplitsOneAxis
{
    int32_t dims[3] = { 600, 500, 5000 }, grid[3];
    BKSlabBrick b[8];
    XCTAssertEqual(BKSlabBrickPlan(dims, 2048, 2, b, 8, grid), 3);
    XCTAssertEqual(grid[0], 1); XCTAssertEqual(grid[1], 1); XCTAssertEqual(grid[2], 3);
    XCTAssertEqual(b[0].coreLo[2], 0);    XCTAssertEqual(b[0].coreHi[2], 1666);
    XCTAssertEqual(b[1].coreLo[2], 1666); XCTAssertEqual(b[1].coreHi[2], 3333);
    XCTAssertEqual(b[2].coreLo[2], 3333); XCTAssertEqual(b[2].coreHi[2], 4999);
    XCTAssertEqual(b[0].texLo[2], 0);     XCTAssertEqual(b[0].texHi[2], 1668);
    XCTAssertEqual(b[1].texLo[2], 1664);  XCTAssertEqual(b[1].texHi[2], 3335);
    XCTAssertEqual(b[2].texLo[2], 3331);  XCTAssertEqual(b[2].texHi[2], 4999);
    for (int i = 0; i < 3; i++) {
        XCTAssertLessThanOrEqual(b[i].texHi[2] - b[i].texLo[2] + 1, 2048);
        XCTAssertEqual(b[i].texLo[0], 0); XCTAssertEqual(b[i].texHi[0], 599);   // axes that fit: no margin
    }
}

// The Vulkan minimum (256): every texture fits, the cores tile the scan exactly.
- (void)testPlanVulkanMinimum
{
    int32_t dims[3] = { 512, 700, 257 }, grid[3];
    int32_t count = BKSlabBrickPlan(dims, 256, 2, NULL, 0, grid);
    XCTAssertEqual(grid[0], 3); XCTAssertEqual(grid[1], 3); XCTAssertEqual(grid[2], 2);
    XCTAssertEqual(count, 18);
    BKSlabBrick b[18];
    XCTAssertEqual(BKSlabBrickPlan(dims, 256, 2, b, 18, NULL), 18);
    for (int i = 0; i < count; i++)
        for (int a = 0; a < 3; a++) {
            XCTAssertLessThanOrEqual(b[i].texHi[a] - b[i].texLo[a] + 1, 256);
            XCTAssertLessThanOrEqual(b[i].texLo[a], b[i].coreLo[a]);
            XCTAssertGreaterThanOrEqual(b[i].texHi[a], b[i].coreHi[a]);
        }
    // x fastest: brick 1 is the second along x and starts where brick 0 ends.
    XCTAssertEqual(b[1].grid[0], 1);
    XCTAssertEqual(b[1].coreLo[0], b[0].coreHi[0]);
    XCTAssertEqual(b[17].coreHi[0], 511); XCTAssertEqual(b[17].coreHi[1], 699); XCTAssertEqual(b[17].coreHi[2], 256);
    // Bad input.
    XCTAssertEqual(BKSlabBrickPlan(dims, 5, 2, NULL, 0, NULL), 0);
    int32_t zero[3] = { 0, 10, 10 };
    XCTAssertEqual(BKSlabBrickPlan(zero, 256, 2, NULL, 0, NULL), 0);
}

// The brick's matrix and core box.
- (void)testBrickTransformAndBox
{
    BKSlabBrick b = { { 100, 0, 50 }, { 200, 9, 80 }, { 98, 0, 48 }, { 202, 9, 82 }, { 1, 0, 1 } };
    double m[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -5, -6, -7, 1 }, out[16];
    BKSlabBrickPatientToVoxel(m, &b, out);
    XCTAssertEqual(out[12], -103); XCTAssertEqual(out[13], -6); XCTAssertEqual(out[14], -55);
    XCTAssertEqual(out[0], 1);
    double lo[3], hi[3];
    BKSlabBrickCoreBoxInTexture(&b, lo, hi);
    XCTAssertEqual(lo[0], 2); XCTAssertEqual(hi[0], 102);
    XCTAssertEqual(lo[1], 0); XCTAssertEqual(hi[1], 9);
    XCTAssertEqual(lo[2], 2); XCTAssertEqual(hi[2], 32);
}

// Ray weights: identity scan, picture in the plane z = 5 looking along +z (right = +x, down = -y... the ray is
// cross(right, down)). Core box x 0..10, y 0..10, z 3..8, slab 4 mm thick: z 3..7 -> 4 mm inside where x, y inside.
- (void)testRayWeights
{
    double m[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    BKSlabBrick b = { { 0, 0, 3 }, { 10, 10, 8 }, { 0, 0, 1 }, { 10, 10, 10 }, { 0, 0, 0 } };
    float w[4 * 3];
    // right = (1,0,0), down = (0,-1,0): ray = cross = (0,0,-1); pixel (x, y) at (8 + 2x, 2 - 2y, 5).
    double largest = BKSlabBrickRayWeights(m, &b, BKV3d(8, 2, 5), BKV3d(1, 0, 0), BKV3d(0, -1, 0), 2, 4, 4, 3, w);
    XCTAssertEqualWithAccuracy(largest, 4, 1e-6);
    XCTAssertEqualWithAccuracy(w[0], 4, 1e-6);         // (8, 2): inside
    XCTAssertEqualWithAccuracy(w[1], 4, 1e-6);         // (10, 2): on the face, still inside
    XCTAssertEqualWithAccuracy(w[2], 0, 1e-6);         // (12, 2): outside
    XCTAssertEqualWithAccuracy(w[4 + 0], 4, 1e-6);     // (8, 0)
    XCTAssertEqualWithAccuracy(w[8 + 0], 0, 1e-6);     // (8, -2): outside in y
    // Slab partly outside the core: picture at z = 2, slab 4 mm: z 0..4 -> only 3..4 inside = 1 mm.
    BKSlabBrickRayWeights(m, &b, BKV3d(8, 2, 2), BKV3d(1, 0, 0), BKV3d(0, -1, 0), 2, 4, 1, 1, w);
    XCTAssertEqualWithAccuracy(w[0], 1, 1e-6);
    // Thickness 0: inside / outside of the point.
    BKSlabBrickRayWeights(m, &b, BKV3d(8, 2, 3), BKV3d(1, 0, 0), BKV3d(0, -1, 0), 2, 0, 3, 1, w);
    XCTAssertEqual(w[0], 1); XCTAssertEqual(w[1], 1); XCTAssertEqual(w[2], 0);
    XCTAssertEqual(BKSlabBrickRayWeights(m, &b, BKV3d(0, 0, 0), BKV3d(0, 0, 0), BKV3d(0, -1, 0), 2, 4, 1, 1, w), -1);
}

// Visiting order: z major, each axis in the ray's direction.
- (void)testVisitOrder
{
    int32_t dims[3] = { 30, 30, 30 };
    BKSlabBrick b[8];
    XCTAssertEqual(BKSlabBrickPlan(dims, 20, 2, b, 8, NULL), 8);
    int32_t order[8];
    XCTAssertEqual(BKSlabBrickVisitOrder(b, 8, BKV3d(0.3, 0.2, 1), order), 1);
    int32_t expectForward[8] = { 0, 1, 2, 3, 4, 5, 6, 7 };
    for (int i = 0; i < 8; i++) XCTAssertEqual(order[i], expectForward[i]);
    XCTAssertEqual(BKSlabBrickVisitOrder(b, 8, BKV3d(-0.3, 0.2, -1), order), 1);
    // z reversed (bricks 4..7 first), x reversed inside each row.
    int32_t expectBack[8] = { 5, 4, 7, 6, 1, 0, 3, 2 };
    for (int i = 0; i < 8; i++) XCTAssertEqual(order[i], expectBack[i]);
}

// Putting values together: MIP / MinIP only over bricks that count, mean weighted, outside where none counts.
- (void)testCombineValues
{
    float acc[3], ws[3], out[3];
    float v1[3] = { 5, -100, 7 }, w1[3] = { 2, 0, 1 };
    float v2[3] = { 9, -200, 3 }, w2[3] = { 1, 0, 3 };
    BKSlabBrickBeginValues(1, 3, acc, ws);
    BKSlabBrickAddValues(1, v1, w1, 3, acc, ws);
    BKSlabBrickAddValues(1, v2, w2, 3, acc, ws);
    BKSlabBrickFinishValues(1, acc, ws, 3, -1000, out);
    XCTAssertEqual(out[0], 9); XCTAssertEqual(out[1], -1000); XCTAssertEqual(out[2], 7);
    BKSlabBrickBeginValues(2, 3, acc, ws);
    BKSlabBrickAddValues(2, v1, w1, 3, acc, ws);
    BKSlabBrickAddValues(2, v2, w2, 3, acc, ws);
    BKSlabBrickFinishValues(2, acc, ws, 3, -1000, out);
    XCTAssertEqual(out[0], 5); XCTAssertEqual(out[1], -1000); XCTAssertEqual(out[2], 3);   // -100 / -200 do not count
    BKSlabBrickBeginValues(3, 3, acc, ws);
    BKSlabBrickAddValues(3, v1, w1, 3, acc, ws);
    BKSlabBrickAddValues(3, v2, w2, 3, acc, ws);
    BKSlabBrickFinishValues(3, acc, ws, 3, -1000, out);
    XCTAssertEqualWithAccuracy(out[0], (5 * 2 + 9 * 1) / 3.0, 1e-6);
    XCTAssertEqualWithAccuracy(out[2], (7 * 1 + 3 * 3) / 4.0, 1e-6);
}

- (void)testCombineChannelsAndOver
{
    float acc[6], ws[2];
    uint8_t a[8] = { 10, 200, 30, 255, 0, 0, 0, 255 }, b[8] = { 50, 100, 20, 255, 9, 9, 9, 255 }, out[8];
    float wa[2] = { 1, 0 }, wb[2] = { 3, 0 };
    BKSlabBrickBeginChannels(1, 2, acc, ws);
    BKSlabBrickAddChannels(1, a, wa, 2, acc, ws);
    BKSlabBrickAddChannels(1, b, wb, 2, acc, ws);
    BKSlabBrickFinishChannels(1, acc, ws, 2, out);
    XCTAssertEqual(out[0], 50); XCTAssertEqual(out[1], 200); XCTAssertEqual(out[2], 30); XCTAssertEqual(out[3], 255);
    XCTAssertEqual(out[4], 0); XCTAssertEqual(out[5], 0); XCTAssertEqual(out[6], 0);        // no brick counted
    BKSlabBrickBeginChannels(3, 2, acc, ws);
    BKSlabBrickAddChannels(3, a, wa, 2, acc, ws);
    BKSlabBrickAddChannels(3, b, wb, 2, acc, ws);
    BKSlabBrickFinishChannels(3, acc, ws, 2, out);
    XCTAssertEqual(out[0], 40); XCTAssertEqual(out[1], 125); XCTAssertEqual(out[2], 23);   // (10 + 150) / 4 ...

    // Over: front half-transparent red over opaque green -> red 0.5, green 0.5, alpha 1.
    float acc4[4];
    uint8_t front[4] = { 128, 0, 0, 128 }, back[4] = { 0, 255, 0, 255 }, res[4];
    BKSlabBrickBeginOver(1, acc4);
    BKSlabBrickAddOver(front, 1, acc4);
    BKSlabBrickAddOver(back, 1, acc4);
    BKSlabBrickFinishOver(acc4, 1, res);
    XCTAssertEqual(res[0], 128); XCTAssertEqualWithAccuracy(res[1], 127, 1); XCTAssertEqual(res[2], 0); XCTAssertEqual(res[3], 255);
}

#pragma mark - GPU: bricked pictures = one-texture pictures

static const int kN = 40;

// The test scan: a smooth field (linear ramp + a soft bright blob) - smooth so pictures sampled at slightly
// different ray positions agree closely; a colour version has different blobs per channel.
static float Field(int x, int y, int z)
{
    double dx = x - 22.0, dy = y - 17.0, dz = z - 20.0;
    return (float)(-500.0 + 10.0 * z + 1200.0 * exp(-(dx * dx + dy * dy + dz * dz) / 60.0));
}

typedef struct { BKVec3d pixel0, right, down; double spacing, thickness; int32_t w, h; } TestPicture;

// The renderer set up for one slab picture, the way the app's slab renderer glue does it.
static void Configure(BKVolumeRenderer *r, BKVolumeTexture *t, BKRenderMode mode, TestPicture p, const double *lo, const double *hi)
{
    BKVec3d right = BKV3dNormalize(p.right), down = BKV3dNormalize(p.down);
    BKVec3d dir = BKV3dNormalize(BKV3dCross(right, down));
    BKVec3d centre = BKV3dAdd(p.pixel0, BKV3dAdd(BKV3dScale(right, 0.5 * (p.w - 1) * p.spacing), BKV3dScale(down, 0.5 * (p.h - 1) * p.spacing)));
    r.volumeTexture = t;
    r.mode = mode;
    r.projection = BKProjectionOrthographic;
    r.cameraPosition = N3VectorMake(centre.x, centre.y, centre.z);
    r.cameraDirection = N3VectorMake(dir.x, dir.y, dir.z);
    r.cameraUp = N3VectorMake(-down.x, -down.y, -down.z);
    r.viewWidth = p.w * p.spacing;
    r.viewHeight = p.h * p.spacing;
    r.sampleSpacing = 0.25;
    r.slabEnabled = YES;
    r.slabPlane = N3PlaneMake(N3VectorMake(p.pixel0.x, p.pixel0.y, p.pixel0.z), N3VectorMake(dir.x, dir.y, dir.z));
    r.slabThickness = p.thickness;
    r.cropMin = lo ? N3VectorMake(lo[0], lo[1], lo[2]) : N3VectorMake(0, 0, 0);
    r.cropMax = hi ? N3VectorMake(hi[0], hi[1], hi[2]) : N3VectorMake(t.pixelsWide - 1, t.pixelsHigh - 1, t.pixelsDeep - 1);
    r.missValue = -2000;
    r.skipsEmptySpace = NO;
}

static TestPicture ObliquePicture(void)
{
    // An oblique plane through the scan: right / down tilted against every axis, 1 mm pixels, 6 mm slab.
    TestPicture p;
    p.right = BKV3dNormalize(BKV3d(0.9, 0.3, 0.2));
    p.down = BKV3dNormalize(BKV3dCross(BKV3d(0.2, -0.4, 0.9), p.right));
    p.spacing = 1;
    p.thickness = 6;
    p.w = 48; p.h = 48;
    BKVec3d centre = BKV3d(19.5, 19.5, 19.5);
    p.pixel0 = BKV3dSub(centre, BKV3dAdd(BKV3dScale(p.right, 23.5), BKV3dScale(p.down, 23.5)));
    return p;
}

- (void)testBrickedPicturesMatchOneTexture
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return; }
    NSError *error = nil;
    BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(r, @"%@", error);

    float *voxels = malloc(sizeof(float) * kN * kN * kN);
    for (int z = 0; z < kN; z++) for (int y = 0; y < kN; y++) for (int x = 0; x < kN; x++)
        voxels[(z * kN + y) * kN + x] = Field(x, y, z);
    BKSlabScanInput in = { { 0, 0, 0 }, { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, 1, 1, 1, 1 };
    BKSlabScan scan;
    XCTAssertEqual(BKSlabScanMake(&in, &scan), 1);
    BKVolumeTexture *whole = [[BKVolumeTexture alloc] initWithFloatVoxels:voxels width:kN height:kN depth:kN
                                                           patientToVoxel:scan.patientToVoxel minPixelSpacing:1
                                                         outOfBoundsValue:-2000 device:device error:&error];
    XCTAssertNotNil(whole, @"%@", error);

    // 18-voxel textures: ceil(39 / (18 - 1 - 4)) = 3 bricks per axis = 27.
    int32_t dims[3] = { kN, kN, kN };
    BKSlabBrick bricks[27];
    XCTAssertEqual(BKSlabBrickPlan(dims, 18, BK_SLAB_BRICK_MARGIN, bricks, 27, NULL), 27);
    NSMutableArray *textures = [NSMutableArray array];
    for (int i = 0; i < 27; i++) {
        BKSlabBrick *b = &bricks[i];
        int bw = b->texHi[0] - b->texLo[0] + 1, bh = b->texHi[1] - b->texLo[1] + 1, bd = b->texHi[2] - b->texLo[2] + 1;
        float *sub = malloc(sizeof(float) * bw * bh * bd);
        for (int z = 0; z < bd; z++) for (int y = 0; y < bh; y++)
            memcpy(&sub[(z * bh + y) * bw], &voxels[((z + b->texLo[2]) * kN + (y + b->texLo[1])) * kN + b->texLo[0]], sizeof(float) * bw);
        double m[16];
        BKSlabBrickPatientToVoxel(scan.patientToVoxel, b, m);
        BKVolumeTexture *t = [[BKVolumeTexture alloc] initWithFloatVoxels:sub width:bw height:bh depth:bd patientToVoxel:m
                                                          minPixelSpacing:1 outOfBoundsValue:-2000 device:device error:&error];
        free(sub);
        XCTAssertNotNil(t, @"%@", error);
        [textures addObject:t];
    }
    TestPicture p = ObliquePicture();
    size_t count = (size_t)p.w * p.h;
    float *acc = malloc(sizeof(float) * count), *ws = malloc(sizeof(float) * count), *wt = malloc(sizeof(float) * count);
    float *bricked = malloc(sizeof(float) * count);

    BKRenderMode modes[3] = { BKRenderModeMIP, BKRenderModeMinIP, BKRenderModeAverage };
    // HU. The pictures differ only by WHERE along each ray the samples sit (each brick spaces its own samples over
    // its piece of the ray). MIP peaks lie in the blob's flat centre (tiny differences); MinIP minima lie at the slab
    // faces on the blob's flank, up to ~130 HU per mm steep, and a short brick piece samples nearer the face than
    // the one-texture ray (whose first sample sits up to half a step = 0.125 mm inside) - measured 7.6 HU.
    double tolerance[3] = { 2.0, 12.0, 4.0 };
    for (int m = 0; m < 3; m++) {
        int32_t mode = m + 1;
        Configure(r, whole, modes[m], p, NULL, NULL);
        BKRenderResult *one = [r renderWithWidth:p.w height:p.h error:&error];
        XCTAssertNotNil(one, @"%@", error);
        BKSlabBrickBeginValues(mode, count, acc, ws);
        int used = 0;
        for (int i = 0; i < 27; i++) {
            if (BKSlabBrickRayWeights(scan.patientToVoxel, &bricks[i], p.pixel0, p.right, p.down, p.spacing, p.thickness, p.w, p.h, wt) <= 0)
                continue;
            used++;
            double lo[3], hi[3];
            BKSlabBrickCoreBoxInTexture(&bricks[i], lo, hi);
            Configure(r, textures[i], modes[m], p, lo, hi);
            BKRenderResult *part = [r renderWithWidth:p.w height:p.h error:&error];
            XCTAssertNotNil(part, @"%@", error);
            BKSlabBrickAddValues(mode, part.floatData.bytes, wt, count, acc, ws);
        }
        XCTAssertGreaterThan(used, 3);
        BKSlabBrickFinishValues(mode, acc, ws, count, -2000, bricked);
        const float *ref = one.floatData.bytes;
        double worst = 0;
        int outsideMismatch = 0;
        for (size_t i = 0; i < count; i++) {
            if ((ref[i] == -2000) != (bricked[i] == -2000)) { outsideMismatch++; continue; }
            worst = fmax(worst, fabs(ref[i] - bricked[i]));
        }
        XCTAssertLessThanOrEqual(outsideMismatch, (int)(count / 100), @"mode %d: pixels outside in one picture only", mode);
        XCTAssertLessThan(worst, tolerance[m], @"mode %d: largest difference %.3f", mode, worst);
    }

    // VR colour (composite): bricks in visiting order, "over".
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    [tf addColorPointAtValue:-500 red:0.2f green:0.4f blue:1];
    [tf addColorPointAtValue:800 red:1 green:0.9f blue:0.6f];
    [tf addOpacityPointAtValue:0 opacity:0];
    [tf addOpacityPointAtValue:700 opacity:0.15f];
    r.transferFunction = tf;
    r.shadingEnabled = YES;
    Configure(r, whole, BKRenderModeComposite, p, NULL, NULL);
    BKRenderResult *one = [r renderWithWidth:p.w height:p.h error:&error];
    XCTAssertNotNil(one, @"%@", error);
    BKVec3d dir = BKV3dNormalize(BKV3dCross(p.right, p.down));
    int32_t order[27];
    XCTAssertEqual(BKSlabBrickVisitOrder(bricks, 27, dir, order), 1);   // identity scan: voxel direction = view direction
    float *acc4 = malloc(sizeof(float) * count * 4);
    uint8_t *mixed = malloc(count * 4);
    BKSlabBrickBeginOver(count, acc4);
    for (int k = 0; k < 27; k++) {
        int i = order[k];
        if (BKSlabBrickRayWeights(scan.patientToVoxel, &bricks[i], p.pixel0, p.right, p.down, p.spacing, p.thickness, p.w, p.h, wt) <= 0)
            continue;
        double lo[3], hi[3];
        BKSlabBrickCoreBoxInTexture(&bricks[i], lo, hi);
        Configure(r, textures[i], BKRenderModeComposite, p, lo, hi);
        BKRenderResult *part = [r renderWithWidth:p.w height:p.h error:&error];
        XCTAssertNotNil(part, @"%@", error);
        BKSlabBrickAddOver(part.rgba8Data.bytes, count, acc4);
    }
    BKSlabBrickFinishOver(acc4, count, mixed);
    const uint8_t *ref8 = one.rgba8Data.bytes;
    int worst8 = 0;
    for (size_t i = 0; i < count * 4; i++) worst8 = MAX(worst8, abs((int)ref8[i] - (int)mixed[i]));
    XCTAssertLessThanOrEqual(worst8, 6, @"VR colour: largest channel difference %d", worst8);

    free(acc4); free(mixed);
    free(acc); free(ws); free(wt); free(bricked); free(voxels);
}

@end
