// Mac (XCTest) accuracy phantoms for BKMesh area / volume (precision follow-up, 2026-11-26, agent "vulkan-engine").
// Original BorosKit code written for this project; contains no third-party code.
// REQ-MESH-AREA / REQ-MESH-VOLUME (PRECISION-AUDIT.md): exact answers for a box. The same numbers are checked
// in the CMake build through the C++ core (ctest mesh_accuracy_box), which BKMesh now calls.

#import <XCTest/XCTest.h>
#import "BorosKitMesh.h"

@interface BKMeshAccuracyTests : XCTestCase
@end

@implementation BKMeshAccuracyTests

- (void)testBoxAreaAndVolumeAreExact
{
    BKMesh *box = [BKMesh boxMeshWithMin:simd_make_float3(-1, -1.5f, -2) max:simd_make_float3(1, 1.5f, 2)];   // 2 x 3 x 4 mm
    XCTAssertEqual(box.enclosedVolume, 24.0);
    XCTAssertEqual(box.surfaceArea, 52.0);
    BKMesh *far = [BKMesh boxMeshWithMin:simd_make_float3(100.25f, 200.5f, -300.75f) max:simd_make_float3(102.25f, 203.5f, -296.75f)];
    XCTAssertEqualWithAccuracy(far.enclosedVolume, 24.0, 24e-9);
    XCTAssertEqualWithAccuracy(far.surfaceArea, 52.0, 52e-12);
}

@end
