// BorosKitSegmentation XCTests (2026-11-26, agent "segmentation").
// Original BorosKit code written for this project; contains no third-party code.
//
// What: (1) runs the shared plain-C checks (BKSegmentationCTests.c = ctest core.seg_*); (2) the GPU class surface
// (BKLabelSurface): without smoothing it must give exactly the CPU reference mesh (same vertex / triangle counts,
// positions within float rounding) in patient mm; with the default smoothing a ball phantom gives a closed surface
// whose enclosed volume is within 3 % of the voxel volume and whose centre is the ball's centre.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BKSegmentationCore.h"
#import "BKLabelSurface.h"
#import "BKSurfaceExtractor.h"
#import "BKSurfaceCore.h"
#import "BKMesh.h"

extern int bk_test_checks, bk_test_failures;
void bk_test_seg_round_trip(void);
void bk_test_seg_damaged_files(void);
void bk_test_seg_counts_volumes(void);
void bk_test_seg_slices_planes(void);
void bk_test_seg_overlay_picture(void);
void bk_test_seg_mask_surface(void);

@interface BKSegmentationTests : XCTestCase
@end

@implementation BKSegmentationTests

- (void)runC:(void (*)(void))test name:(NSString *)name
{
    int before = bk_test_failures, checks = bk_test_checks;
    test();
    XCTAssertEqual(bk_test_failures, before, @"%@: %d of %d checks failed (see the FAIL lines above)", name,
                   bk_test_failures - before, bk_test_checks - checks);
}

- (void)testRoundTrip { [self runC:bk_test_seg_round_trip name:@"round trip"]; }
- (void)testDamagedFiles { [self runC:bk_test_seg_damaged_files name:@"damaged files"]; }
- (void)testCountsVolumes { [self runC:bk_test_seg_counts_volumes name:@"counts / volumes"]; }
- (void)testSlicesPlanes { [self runC:bk_test_seg_slices_planes name:@"slices / planes"]; }
- (void)testOverlayPicture { [self runC:bk_test_seg_overlay_picture name:@"overlay picture"]; }
- (void)testMaskSurface { [self runC:bk_test_seg_mask_surface name:@"mask surface"]; }

// A ball of class 9 (radius 5.9 mm: not exactly on voxel centres, whose distance ties would round one-sided) in a 0.4 mm grid with a tilted slice direction, + class 2 (a small box).
static BKLabelVolume *BallVolume(double centre[3])
{
    BKLabelGrid g;
    memset(&g, 0, sizeof g);
    g.dims[0] = 48; g.dims[1] = 44; g.dims[2] = 40;
    g.spacing[0] = 0.4; g.spacing[1] = 0.4; g.spacing[2] = 0.4;
    g.origin[0] = -50; g.origin[1] = 20; g.origin[2] = 100;
    g.axes[0] = 1; g.axes[4] = 1; g.axes[8] = 1;
    BKLabelVolume *v = BKLabelVolumeCreate(&g);
    uint16_t *L = BKLabelVolumeVoxels(v);
    BKLabelGridVoxelToPatient(&g, 24, 22, 20, centre);
    for (uint32_t k = 0; k < 40; k++)
        for (uint32_t j = 0; j < 44; j++)
            for (uint32_t i = 0; i < 48; i++) {
                double p[3];
                BKLabelGridVoxelToPatient(&g, i, j, k, p);
                double dx = p[0] - centre[0], dy = p[1] - centre[1], dz = p[2] - centre[2];
                if (dx * dx + dy * dy + dz * dz <= 5.9 * 5.9) L[(k * 44 + j) * 48 + i] = 9;
                else if (i < 4 && j < 5 && k < 3) L[(k * 44 + j) * 48 + i] = 2;
            }
    return v;
}

- (BKSurfaceExtractor *)extractor
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) return nil;
    NSError *error = nil;
    BKSurfaceExtractor *x = [[BKSurfaceExtractor alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(x, @"%@", error);
    return x;
}

- (void)testGPUSurfaceEqualsCPUReference
{
    BKSurfaceExtractor *x = [self extractor];
    if (x == nil) { NSLog(@"no Metal GPU: GPU surface test skipped"); return; }
    double c[3];
    BKLabelVolume *v = BallVolume(c);
    BKLabelSurfaceOptions *raw = [[BKLabelSurfaceOptions alloc] init];
    raw.maskSmoothing = 0;
    raw.meshSmoothingIterations = 0;
    NSError *error = nil;
    BKMesh *gpu = [[[BKLabelSurface alloc] initWithExtractor:x] meshForLabelVolume:v value:2 options:raw error:&error];
    XCTAssertNotNil(gpu, @"%@", error);
    // CPU reference on the same padded box (margin 2 with smoothing 0).
    int64_t bmin[3];
    uint32_t bdim[3];
    XCTAssertEqual(BKLabelMaskBox(v, 2, 2, bmin, bdim), 1);
    float *mask = malloc(sizeof(float) * bdim[0] * bdim[1] * bdim[2]);
    BKLabelMaskFillFloat(v, 2, bmin, bdim, mask);
    double toPatient[16];
    BKLabelMaskBoxToPatient(BKLabelVolumeGetGrid(v), bmin, toPatient);
    BKSurfaceMeshData ref;
    memset(&ref, 0, sizeof ref);
    XCTAssertEqual(BKSurfaceReferenceExtract(mask, bdim[0], bdim[1], bdim[2], 0.5f, toPatient, &ref), BKSurfaceStatusOK);
    XCTAssertEqual(gpu.vertexCount, (NSUInteger)ref.vertexCount);
    XCTAssertEqual(gpu.triangleCount, (NSUInteger)ref.triangleCount);
    float worst = 0;
    for (NSUInteger n = 0; n < MIN(gpu.vertexCount, (NSUInteger)ref.vertexCount); n++)
        for (int a = 0; a < 3; a++) worst = MAX(worst, fabsf(gpu.vertices[n][a] - ref.positions[4 * n + a]));
    XCTAssertLessThan(worst, 1e-4f, @"GPU and CPU reference vertices differ by %g mm", worst);
    XCTAssertTrue(gpu.watertight);
    BKSurfaceMeshDataFree(&ref);
    free(mask);
    // A class without voxels gives nil + an error, never an empty mesh.
    XCTAssertNil([[[BKLabelSurface alloc] initWithExtractor:x] meshForLabelVolume:v value:77 options:raw error:&error]);
    BKLabelVolumeFree(v);
}

- (void)testSmoothedBallVolumeAndCentre
{
    BKSurfaceExtractor *x = [self extractor];
    if (x == nil) { NSLog(@"no Metal GPU: GPU surface test skipped"); return; }
    double c[3];
    BKLabelVolume *v = BallVolume(c);
    uint64_t *counts = calloc(65536, sizeof(uint64_t));
    BKLabelVolumeCount(v, counts);
    double voxelVolume = BKLabelGridVolumeOfCount(BKLabelVolumeGetGrid(v), counts[9]);
    free(counts);
    NSError *error = nil;
    BKMesh *mesh = [[[BKLabelSurface alloc] initWithExtractor:x] meshForLabelVolume:v value:9 options:nil error:&error];
    XCTAssertNotNil(mesh, @"%@", error);
    XCTAssertTrue(mesh.watertight);
    double meshVolume = fabs(mesh.enclosedVolume);
    XCTAssertEqualWithAccuracy(meshVolume / voxelVolume, 1.0, 0.03, @"mesh %.2f mm3 vs voxels %.2f mm3", meshVolume, voxelVolume);
    simd_float3 lo = mesh.boundsMin, hi = mesh.boundsMax;
    for (int a = 0; a < 3; a++) XCTAssertEqualWithAccuracy((lo[a] + hi[a]) / 2, c[a], 0.05);
    BKLabelVolumeFree(v);
}

@end
