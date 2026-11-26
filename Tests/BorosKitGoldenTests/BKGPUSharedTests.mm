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
