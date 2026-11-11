//  CPREngineTests.m
//  BorosKit
//
//  Smoke tests for the CPR (curved planar reformation) engine copied from Horos.
//  They build a small synthetic CT-like volume whose voxel values encode their own
//  position, ask the engine for a straight and a curved (panorex-style) slice, and
//  check that the output has the requested size and that sampled values land where
//  the geometry says they should. Runs on macOS and iOS.
//  The test target is compiled with ARC (SwiftPM default); the engine uses manual
//  retain/release internally, which is fine to call from ARC code.

#import <XCTest/XCTest.h>
#import "CPRVolumeData.h"
#import "CPRGenerator.h"
#import "CPRGeneratorRequest.h"
#import "CPRUnsignedInt16ImageRep.h"
#import "N3BezierPath.h"

static const NSUInteger kSize = 64; // 64 x 64 x 64 voxels, 1 mm spacing

@interface CPREngineTests : XCTestCase
@end

@implementation CPREngineTests

// Builds a kSize^3 volume at the origin with 1 mm voxels and identity orientation,
// where each voxel's value is computed by valueAt(x, y, z). Uses the BorosKit raw
// initializer (the replacement for the DCMPix-based one).
- (CPRVolumeData *)volumeWithValue:(float (^)(NSUInteger x, NSUInteger y, NSUInteger z))valueAt
{
    float *bytes = malloc(sizeof(float) * kSize * kSize * kSize);
    for (NSUInteger z = 0; z < kSize; z++)
        for (NSUInteger y = 0; y < kSize; y++)
            for (NSUInteger x = 0; x < kSize; x++)
                bytes[(z * kSize + y) * kSize + x] = valueAt(x, y, z);

    double orientation[9] = {1,0,0, 0,1,0, 0,0,1};
    return [[CPRVolumeData alloc] initWithFloatBytesNoCopy:bytes pixelsWide:kSize pixelsHigh:kSize pixelsDeep:kSize
                                                     origin:N3VectorZero orientation:orientation
                                                   spacingX:1 spacingY:1 spacingZ:1 freeWhenDone:YES];
}

// Reads one output pixel from a generated (single-slice) volume.
static float PixelAt(CPRVolumeData *v, NSUInteger x, NSUInteger y)
{
    float f = NAN;
    [v getFloat:&f atPixelCoordinateX:x y:y z:0];
    return f;
}

// The raw initializer must give the same geometry the DCMPix path gave:
// 1 mm spacing, identity orientation, origin at 0.
- (void)testVolumeGeometry
{
    CPRVolumeData *v = [self volumeWithValue:^float(NSUInteger x, NSUInteger y, NSUInteger z) { return 0; }];
    XCTAssertEqualWithAccuracy(v.pixelSpacingX, 1.0, 1e-6);
    XCTAssertEqualWithAccuracy(v.pixelSpacingZ, 1.0, 1e-6);
    XCTAssertEqualWithAccuracy(v.originX, 0.0, 1e-6);
    XCTAssertTrue(v.rectilinear);
}

// Straight CPR along the x axis through a volume where value == x (mm).
// Every column of the output should equal the x position of that point on the line,
// so values rise left to right and are constant down each column.
- (void)testStraightenedSlice
{
    CPRVolumeData *volume = [self volumeWithValue:^float(NSUInteger x, NSUInteger y, NSUInteger z) { return (float)x; }];

    N3MutableBezierPath *path = [N3MutableBezierPath bezierPath];
    [path moveToVector:N3VectorMake(8, 32, 32)];
    [path lineToVector:N3VectorMake(56, 32, 32)];

    CPRStraightenedGeneratorRequest *request = [[CPRStraightenedGeneratorRequest alloc] init];
    request.pixelsWide = 97;
    request.pixelsHigh = 21;
    request.bezierPath = path;
    request.initialNormal = N3VectorMake(0, 0, 1);
    request.interpolationMode = CPRInterpolationModeCubic;

    CPRVolumeData *out = [CPRGenerator synchronousRequestVolume:request volumeData:volume];
    XCTAssertNotNil(out);
    XCTAssertEqual(out.pixelsWide, (NSUInteger)97);
    XCTAssertEqual(out.pixelsHigh, (NSUInteger)21);
    XCTAssertEqual(out.pixelsDeep, (NSUInteger)1);

    float left = PixelAt(out, 0, 10), mid = PixelAt(out, 48, 10), right = PixelAt(out, 96, 10);
    XCTAssertEqualWithAccuracy(left, 8.0, 0.75);
    XCTAssertEqualWithAccuracy(mid, 32.0, 0.75);
    XCTAssertEqualWithAccuracy(right, 56.0, 0.75);
    // constant down a column (the normal is along z, value depends only on x)
    XCTAssertEqualWithAccuracy(PixelAt(out, 48, 0), mid, 1e-3);
    XCTAssertEqualWithAccuracy(PixelAt(out, 48, 20), mid, 1e-3);

    // the 16-bit export path the panorex export uses must also work
    CPRUnsignedInt16ImageRep *rep = [out unsignedInt16ImageRepForSliceAtIndex:0];
    XCTAssertEqual(rep.pixelsWide, (NSUInteger)97);
    XCTAssertEqual(rep.pixelsHigh, (NSUInteger)21);
    XCTAssertTrue(rep.unsignedInt16Data != NULL);
}

// Curved, panorex-style ("stretched") CPR: a U-shaped arch in the axial plane
// (z = 32), unrolled with z as the up direction, through a volume where value == z.
// Each output row should therefore hold one constant height, the middle row ~32,
// and the top and bottom rows should differ by about the output height in mm.
- (void)testCurvedPanorexSlice
{
    CPRVolumeData *volume = [self volumeWithValue:^float(NSUInteger x, NSUInteger y, NSUInteger z) { return (float)z; }];

    N3MutableBezierPath *arch = [N3MutableBezierPath bezierPath];
    [arch moveToVector:N3VectorMake(12, 50, 32)];
    [arch curveToVector:N3VectorMake(52, 50, 32) controlVector1:N3VectorMake(12, 6, 32) controlVector2:N3VectorMake(52, 6, 32)];

    CPRStretchedGeneratorRequest *request = [[CPRStretchedGeneratorRequest alloc] init];
    request.pixelsWide = 120;
    request.pixelsHigh = 41;
    request.bezierPath = arch;
    request.projectionNormal = N3VectorMake(0, 0, 1);
    request.midHeightPoint = N3VectorMake(32, 32, 32);
    request.interpolationMode = CPRInterpolationModeCubic;

    CPRVolumeData *out = [CPRGenerator synchronousRequestVolume:request volumeData:volume];
    XCTAssertNotNil(out);
    XCTAssertEqual(out.pixelsWide, (NSUInteger)120);
    XCTAssertEqual(out.pixelsHigh, (NSUInteger)41);

    float midRow = PixelAt(out, 60, 20);
    XCTAssertEqualWithAccuracy(midRow, 32.0, 0.75);
    // a row is one height: same value at both ends and the middle of the arch
    XCTAssertEqualWithAccuracy(PixelAt(out, 5, 20), midRow, 1e-2);
    XCTAssertEqualWithAccuracy(PixelAt(out, 114, 20), midRow, 1e-2);

    // rows are spaced evenly along z: top and bottom are symmetric around the middle
    float top = PixelAt(out, 60, 0), bottom = PixelAt(out, 60, 40);
    XCTAssertEqualWithAccuracy(top + bottom, 2 * midRow, 0.75);
    XCTAssertGreaterThan(fabsf(top - bottom), 5.0);
}

@end
