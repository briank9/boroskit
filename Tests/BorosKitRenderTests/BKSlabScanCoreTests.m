// Tests for the slab scan placement rules (BKSlabScanCore.h). Boros 6 (2026-11-24, mpr-colour).
// Expected numbers worked out by hand from the rules in the header.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import "BKSlabScanCore.h"

@interface BKSlabScanCoreTests : XCTestCase
@end

@implementation BKSlabScanCoreTests

static BKSlabScanInput AxialInput(double sx, double sy, double interval, double thickness)
{
    BKSlabScanInput in = { { 10, 20, 30 }, { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, sx, sy, interval, thickness };
    return in;
}

static void AssertVec(BKVec3d a, double x, double y, double z, double tol)
{
    XCTAssertEqualWithAccuracy(a.x, x, tol);
    XCTAssertEqualWithAccuracy(a.y, y, tol);
    XCTAssertEqualWithAccuracy(a.z, z, tol);
}

// A normal axial scan: voxel (i, j, k) at origin + (0.5 i, 0.4 j, 2 k); the matrix maps back.
- (void)testNormalScan
{
    BKSlabScanInput in = AxialInput(0.5, 0.4, 2, 3);
    BKSlabScan s;
    XCTAssertEqual(BKSlabScanMake(&in, &s), 1);
    XCTAssertEqual(s.flags, 0u);
    AssertVec(s.spacing, 0.5, 0.4, 2, 0);
    XCTAssertEqual(s.sliceStep, 2);
    XCTAssertEqual(s.minSpacing, 0.4);
    AssertVec(BKSlabScanVoxelToPatient(&s, BKV3d(2, 5, 3)), 11, 22, 36, 1e-12);
    AssertVec(BKSlabScanPatientToVoxel(&s, BKV3d(11, 22, 36)), 2, 5, 3, 1e-12);
    // Translation column of patient -> voxel: -origin / spacing.
    XCTAssertEqualWithAccuracy(s.patientToVoxel[12], -20, 1e-12);
    XCTAssertEqualWithAccuracy(s.patientToVoxel[13], -50, 1e-12);
    XCTAssertEqualWithAccuracy(s.patientToVoxel[14], -15, 1e-12);
}

// Slices running backwards: same voxel positions, the slice axis reversed, spacing positive.
- (void)testNegativeInterval
{
    BKSlabScanInput in = AxialInput(1, 1, -2.5, 2.5);
    BKSlabScan s;
    XCTAssertEqual(BKSlabScanMake(&in, &s), 1);
    XCTAssertEqual(s.flags, (uint32_t)BKSlabScanSlicesBackwards);
    AssertVec(s.axes[2], 0, 0, -1, 0);
    AssertVec(s.spacing, 1, 1, 2.5, 0);
    XCTAssertEqual(s.sliceStep, -2.5);
    XCTAssertEqual(s.minSpacing, 1);
    // Slice 4 lies 10 mm BELOW the first one.
    AssertVec(BKSlabScanVoxelToPatient(&s, BKV3d(0, 0, 4)), 10, 20, 20, 1e-12);
    // origin + k * spacing.z * axes[2] gives the same point.
    BKVec3d p = BKV3dAddScaled(s.origin, s.axes[2], 4 * s.spacing.z);
    AssertVec(p, 10, 20, 20, 1e-12);
    AssertVec(BKSlabScanPatientToVoxel(&s, BKV3d(10, 20, 20)), 0, 0, 4, 1e-12);
}

// Missing numbers: pixel spacing -> 1 mm; interval 0 -> slice thickness; both 0 -> average pixel spacing.
- (void)testSubstitutions
{
    BKSlabScan s;
    BKSlabScanInput a = AxialInput(0, -1, 2, 0);
    XCTAssertEqual(BKSlabScanMake(&a, &s), 1);
    XCTAssertEqual(s.flags, (uint32_t)BKSlabScanUsedDefaultPixelSpacing);
    AssertVec(s.spacing, 1, 1, 2, 0);

    BKSlabScanInput b = AxialInput(0.5, 0.5, 0, 1.25);
    XCTAssertEqual(BKSlabScanMake(&b, &s), 1);
    XCTAssertEqual(s.flags, (uint32_t)BKSlabScanUsedSliceThickness);
    XCTAssertEqual(s.sliceStep, 1.25);

    BKSlabScanInput c = AxialInput(0.5, 0.3, 0, 0);
    XCTAssertEqual(BKSlabScanMake(&c, &s), 1);
    XCTAssertEqual(s.flags, (uint32_t)BKSlabScanUsedAverageSpacing);
    XCTAssertEqualWithAccuracy(s.sliceStep, 0.4, 1e-15);
    XCTAssertEqualWithAccuracy(s.minSpacing, 0.3, 1e-15);

    BKSlabScanInput d = AxialInput(NAN, 0.5, NAN, -0.75);   // not-a-number spacing, interval -> thickness (sign kept)
    XCTAssertEqual(BKSlabScanMake(&d, &s), 1);
    XCTAssertEqual(s.flags, (uint32_t)(BKSlabScanUsedDefaultPixelSpacing | BKSlabScanUsedSliceThickness | BKSlabScanSlicesBackwards));
    XCTAssertEqual(s.sliceStep, -0.75);
}

// Degenerate orientation -> identity; an oblique (rotated) one is kept.
- (void)testOrientation
{
    BKSlabScan s;
    BKSlabScanInput in = AxialInput(1, 1, 1, 1);
    for (int i = 0; i < 9; i++) in.cosines[i] = 0;
    XCTAssertEqual(BKSlabScanMake(&in, &s), 1);
    XCTAssertEqual(s.flags, (uint32_t)BKSlabScanUsedIdentityOrientation);
    AssertVec(s.axes[0], 1, 0, 0, 0);

    // Rotated 90 degrees around z: rows run along +y, columns along -x.
    double r[9] = { 0, 1, 0, -1, 0, 0, 0, 0, 1 };
    for (int i = 0; i < 9; i++) in.cosines[i] = r[i];
    in.pixelSpacingX = 2;
    XCTAssertEqual(BKSlabScanMake(&in, &s), 1);
    XCTAssertEqual(s.flags, 0u);
    AssertVec(BKSlabScanVoxelToPatient(&s, BKV3d(1, 1, 1)), 10 - 1, 20 + 2, 31, 1e-12);
    AssertVec(BKSlabScanPatientToVoxel(&s, BKV3d(9, 22, 31)), 1, 1, 1, 1e-12);
}

// Volumic check: at least 3 slices, all the same size.
- (void)testVolumic
{
    int32_t w[4] = { 512, 512, 512, 512 }, h[4] = { 512, 512, 512, 512 };
    XCTAssertEqual(BKSlabScanCheckVolumic(4, w, h), BKSlabScanVolumic);
    XCTAssertEqual(BKSlabScanCheckVolumic(3, NULL, NULL), BKSlabScanVolumic);
    XCTAssertEqual(BKSlabScanCheckVolumic(2, w, h), BKSlabScanTooFewSlices);
    XCTAssertEqual(BKSlabScanCheckVolumic(1, w, h), BKSlabScanTooFewSlices);
    h[3] = 256;
    XCTAssertEqual(BKSlabScanCheckVolumic(4, w, h), BKSlabScanUnequalSlices);
    w[0] = 0;
    XCTAssertEqual(BKSlabScanCheckVolumic(4, w, h), BKSlabScanEmptySlices);
    XCTAssertEqual(BKSlabScanMake(NULL, NULL), 0);
}

@end
