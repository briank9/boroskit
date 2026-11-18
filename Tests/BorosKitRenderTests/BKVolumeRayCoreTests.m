// Tests for BKVolumeRayCore (what is under the mouse in a volume).
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKVolumeRayCore.h"

@interface BKVolumeRayCoreTests : XCTestCase
@end

@implementation BKVolumeRayCoreTests

// A 10 x 10 x 10 scan of 1 mm voxels at the origin: value 0 everywhere except a "bone" block (value 1000) in
// slices 6..9. Identity placement: patient mm = voxel index.
static float gVoxels[1000];

- (void)setUp
{
    for (int z = 0; z < 10; z++)
        for (int i = 0; i < 100; i++) gVoxels[z * 100 + i] = (z >= 6) ? 1000.f : 0.f;
}

static BKRayVolume Volume(void)
{
    BKRayVolume v = { gVoxels, 10, 10, 10, {0} };
    v.patientToVoxel[0] = v.patientToVoxel[5] = v.patientToVoxel[10] = v.patientToVoxel[15] = 1;
    return v;
}

- (void)testAccumulateStopsAtBone
{
    BKRayVolume v = Volume();
    // Opacity table over 0..1000: 0 below 500, 1 from 500 up.
    float op[11] = { 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1 };
    BKRayOpacityTable t = { op, 11, 0, 1000 };
    double a[3] = { 5, 5, -5 }, b[3] = { 5, 5, 20 };
    BKRayHit hit;
    XCTAssertEqual(BKVolumeRayFirstHit(&v, a, b, 0.5, &t, BKRayModeAccumulate, 1.0, 0, NULL, 0, &hit), 1);
    XCTAssertEqual(hit.voxel[2], 6);              // first bone slice (5.5 rounds to 6)
    XCTAssertEqualWithAccuracy(hit.value, 1000.f, 0.001);
    XCTAssertEqualWithAccuracy(hit.patient[2], 5.5, 1e-9);
}

- (void)testHiddenPlaneSkipsBone
{
    BKRayVolume v = Volume();
    float op[2] = { 0, 1 };
    BKRayOpacityTable t = { op, 2, 0, 1000 };
    double a[3] = { 5, 5, -5 }, b[3] = { 5, 5, 20 };
    // Hide everything with z > 3 (plane 0,0,1,-3): the bone is cut away, nothing found.
    float plane[4] = { 0, 0, 1, -3 };
    BKRayHit hit;
    XCTAssertEqual(BKVolumeRayFirstHit(&v, a, b, 0.5, &t, BKRayModeAccumulate, 1.0, 0, plane, 1, &hit), 0);
}

- (void)testMaximumMode
{
    BKRayVolume v = Volume();
    gVoxels[8 * 100 + 5 * 10 + 5] = 3000.f;   // one brighter voxel on the ray
    double a[3] = { 5, 5, -5 }, b[3] = { 5, 5, 20 };
    BKRayHit hit;
    XCTAssertEqual(BKVolumeRayFirstHit(&v, a, b, 0.5, NULL, BKRayModeMaximum, 0, 0, NULL, 0, &hit), 1);
    XCTAssertEqual(hit.voxel[2], 8);
    XCTAssertEqualWithAccuracy(hit.value, 3000.f, 0.001);
}

- (void)testOpacityLookup
{
    float op[3] = { 0, 0.5f, 1 };
    BKRayOpacityTable t = { op, 3, 0, 100 };
    XCTAssertEqualWithAccuracy(BKRayOpacityAt(&t, -50), 0, 1e-9);
    XCTAssertEqualWithAccuracy(BKRayOpacityAt(&t, 50), 0.5, 1e-6);
    XCTAssertEqualWithAccuracy(BKRayOpacityAt(&t, 500), 1, 1e-9);
    XCTAssertEqualWithAccuracy(BKRayOpacityAt(NULL, 5), 1, 1e-9);
}

@end
