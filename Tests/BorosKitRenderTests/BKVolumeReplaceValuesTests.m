// Tests for -[BKVolumeScene replaceVolumeValues:error:] (2026-11-14).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// Plain terms: after the 3D window's scissors cut (or bone removal / undo) the scan's VALUES change
// in memory. The scene must upload them and keep everything else: the user's camera (turned and
// zoomed), and must show the new values. A scan of a different size is opened fully instead.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

@interface BKVolumeReplaceValuesTests : XCTestCase
@end

@implementation BKVolumeReplaceValuesTests

// A cube of n^3 voxels (1 mm, origin -n/2) filled by `fill(x, y, z)`.
static CPRVolumeData *BKCube(NSUInteger n, float (^fill)(NSUInteger, NSUInteger, NSUInteger))
{
    float *v = malloc(sizeof(float) * n * n * n);
    for (NSUInteger z = 0; z < n; z++)
        for (NSUInteger y = 0; y < n; y++)
            for (NSUInteger x = 0; x < n; x++) v[(z * n + y) * n + x] = fill(x, y, z);
    double o[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    double h = -(double)n / 2;
    return [[CPRVolumeData alloc] initWithFloatBytesNoCopy:v pixelsWide:n pixelsHigh:n pixelsDeep:n
                                                    origin:N3VectorMake(h, h, h) orientation:o
                                                  spacingX:1 spacingY:1 spacingZ:1 freeWhenDone:YES];
}

- (void)testValuesReplacedViewKept
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) return;
    NSError *error = nil;
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(scene, @"%@", error);
    scene.mode = BKRenderModeMIP;
    scene.windowCenter = 500;
    scene.windowWidth = 1000;
    XCTAssertTrue([scene setVolumeData:BKCube(32, ^float(NSUInteger x, NSUInteger y, NSUInteger z) { return 1000; }) error:&error], @"%@", error);

    // The user turns and zooms.
    [scene.camera showStandardView:BKStandardViewAnterior];
    [scene.camera zoomByFactor:2.5];
    BKVolumeCamera *before = [scene.camera copy];
    BKRenderResult *full = [scene renderFullQualityWithWidth:32 height:32 missValue:NAN error:&error];

    // "Scissors": everything set to air.
    XCTAssertTrue([scene replaceVolumeValues:BKCube(32, ^float(NSUInteger x, NSUInteger y, NSUInteger z) { return -1000; }) error:&error], @"%@", error);
    XCTAssertEqualWithAccuracy(scene.camera.parallelScale, before.parallelScale, 1e-9, @"zoom kept");
    XCTAssertEqualWithAccuracy(scene.camera.direction.y, before.direction.y, 1e-9, @"view direction kept");
    XCTAssertEqualWithAccuracy(scene.camera.focalPoint.x, before.focalPoint.x, 1e-9, @"centre kept");
    XCTAssertEqualWithAccuracy(scene.windowCenter, 500, 1e-6, @"window kept");
    BKRenderResult *cut = [scene renderFullQualityWithWidth:32 height:32 missValue:NAN error:&error];
    XCTAssertGreaterThan([full valueAtX:16 y:16], 900.0f);
    XCTAssertLessThan([cut valueAtX:16 y:16], -900.0f, @"the new values are shown");

    // A different size is a new scan: opened fully (camera fitted again).
    XCTAssertTrue([scene replaceVolumeValues:BKCube(16, ^float(NSUInteger x, NSUInteger y, NSUInteger z) { return 0; }) error:&error], @"%@", error);
    XCTAssertEqual(scene.volumeTexture.pixelsWide, 16u);
    XCTAssertNotEqualWithAccuracy(scene.camera.parallelScale, before.parallelScale, 1e-6);
}

@end
