// Mac (XCTest) runner of the GPU tests shared by every backend (Vulkan plan phase 2, 2026-11-26, agent "vulkan-engine").
// Original BorosKit code written for this project; contains no third-party code.
//
// What: compiles Tests/BorosKitGPUShared (the same C++ the Vulkan programs run) into this target and runs it on a
// MetalDevice: the triangle, the golden bone meshes through BKMeshPass in STRICT mode (bit-identical to the Metal
// references), front / back faces, and a smoke run of the feature scene (lines, points, textures, see-through,
// wireframe, culling). The Metal-vs-Vulkan comparison of that scene runs in CMake (bk_gpu_cross).

#import <XCTest/XCTest.h>
#include "../BorosKitGPUShared/BKGPUSharedTests.cpp"
#include "../BorosKitGPUShared/BKGPUTestMetal.mm"

@interface BKGPUSharedTests : XCTestCase
@end

@implementation BKGPUSharedTests {
    std::unique_ptr<boroskit::gpu::Device> _device;
}

- (void)setUp
{
    _device = bkshared::MakeTestMetalDevice();
}

- (BOOL)haveDevice
{
    if (_device) return YES;
    NSLog(@"BKGPUSharedTests: no Metal GPU - skipped");
    return NO;
}

- (NSString *)referencesFolder
{
    return [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"References"];
}

- (void)testTriangle
{
    if ([self haveDevice]) XCTAssertEqual(bkshared::TestTriangle(*_device), 0);
}

- (void)testGoldenMeshesThroughMeshPassStrict
{
    if ([self haveDevice]) XCTAssertEqual(bkshared::TestGoldenMeshes(*_device, self.referencesFolder.fileSystemRepresentation, nullptr, "metal", true), 0);
}

- (void)testWinding
{
    if ([self haveDevice]) XCTAssertEqual(bkshared::TestWinding(*_device), 0);
}

- (void)testComputePrefixSum
{
    if ([self haveDevice]) XCTAssertEqual(bkshared::TestComputeScan(*_device), 0);
}

// 2026-11-26: recorded references for lines, points, textured meshes and the whole scene (strict when
// BK_GOLDEN_STRICT=1; recorded with BK_GOLDEN_RECORD=1 - this Metal run is the reference).
- (void)testGoldenFeatures
{
    if (![self haveDevice]) return;
    const char *rec = getenv("BK_GOLDEN_RECORD"), *strict = getenv("BK_GOLDEN_STRICT");
    bool record = rec && rec[0] == '1', isStrict = strict && strict[0] == '1';
    XCTAssertEqual(bkshared::TestGoldenFeatures(*_device, [self referencesFolder].fileSystemRepresentation, nullptr, "metal",
                                                isStrict, record), 0);
}

// 2026-11-26: BKSurfacePass straight on the MetalDevice (the same code the Vulkan program runs).
- (void)testSurfacePass
{
    if (![self haveDevice]) return;
    const char *strict = getenv("BK_GOLDEN_STRICT");
    XCTAssertEqual(bkshared::TestSurfacePass(*_device, [self referencesFolder].fileSystemRepresentation, "metal",
                                             strict && strict[0] == '1'), 0);
}

// 2026-11-26 (7.1 #4): BKRaycastPass straight on the MetalDevice (the code the Vulkan program runs). Since the
// portable-normalise switch the parameter blocks equal BKVolumeRenderer's, so the hardware-filtered run is strict
// with BK_GOLDEN_STRICT=1.
- (void)testRaycastPass
{
    if (![self haveDevice]) return;
    const char *strict = getenv("BK_GOLDEN_STRICT");
    XCTAssertEqual(bkshared::TestRaycastPass(*_device, [self referencesFolder].fileSystemRepresentation, nullptr, "metal",
                                             strict && strict[0] == '1'), 0);
}

- (void)testFeatureSceneRenders
{
    if (![self haveDevice]) return;
    std::vector<uint8_t> rgba;
    std::vector<float> distance;
    XCTAssertTrue(bkshared::RenderFeatureScene(*_device, &rgba, &distance));
    size_t drawn = 0;
    for (size_t i = 3; i < rgba.size(); i += 4) drawn += rgba[i] != 0;
    XCTAssertGreaterThan(drawn, (size_t)2000, @"the feature scene should cover a good part of the picture");
}

@end
