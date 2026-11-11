// Tests for BKVolumeView (the on-screen 3D view): interaction methods drive the
// scene's camera and window/level and bracket an interaction, which ends by itself
// after idleDelay. No window is needed; GPU-less machines skip.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitDisplay.h"
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

@interface BKVolumeViewTests : XCTestCase
@end

@implementation BKVolumeViewTests

// What: a 16^3 volume of 1 mm voxels (values do not matter here).
- (CPRVolumeData *)smallVolume
{
    float *bytes = calloc(16 * 16 * 16, sizeof(float));
    double orientation[9] = {1,0,0, 0,1,0, 0,0,1};
    return [[CPRVolumeData alloc] initWithFloatBytesNoCopy:bytes pixelsWide:16 pixelsHigh:16 pixelsDeep:16
                                                     origin:N3VectorZero orientation:orientation
                                                   spacingX:1 spacingY:1 spacingZ:1 freeWhenDone:YES];
}

// What: moves change the camera / WL, start an interaction, and the idle timer ends it.
- (void)testInteractionDrivesSceneAndEndsWhenIdle
{
    if (!MTLCreateSystemDefaultDevice()) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeView *view = [[BKVolumeView alloc] initWithFrame:CGRectMake(0, 0, 400, 300)];
    XCTAssertNotNil(view.scene);
    NSError *error = nil;
    XCTAssertTrue([view setVolumeData:[self smallVolume] error:&error], @"%@", error);
    view.idleDelay = 0.05;

    // Reset view = Horos' left view, fitted to the volume.
    N3Vector d0 = view.scene.camera.direction;
    XCTAssertEqualWithAccuracy(d0.x, -1.0, 1e-9);

    [view rotateByViewDelta:CGSizeMake(40, 0)];
    XCTAssertTrue(view.scene.interacting);
    XCTAssertLessThan(N3VectorDotProduct(view.scene.camera.direction, d0), 0.999);

    CGFloat ps = view.scene.camera.parallelScale;
    [view zoomByFactor:2];
    XCTAssertEqualWithAccuracy(view.scene.camera.parallelScale, ps / 2, 1e-9);

    view.scene.windowWidth = 400; view.scene.windowCenter = 40;
    [view adjustWindowLevelByDeltaX:0 deltaY:10];
    XCTAssertEqualWithAccuracy(view.scene.windowCenter, 0, 1e-4);   // 40 - 10 * 4

    // No more moves: the interaction ends by itself (full quality next frame).
    XCTestExpectation *idle = [self expectationWithDescription:@"idle"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertFalse(view.scene.interacting);
        [idle fulfill];
    });
    [self waitForExpectations:@[idle] timeout:2];

    // Explicit brackets are not ended by the idle timer.
    [view beginInteraction];
    [view rotateByViewDelta:CGSizeMake(5, 5)];
    XCTestExpectation *still = [self expectationWithDescription:@"still"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertTrue(view.scene.interacting);
        [still fulfill];
    });
    [self waitForExpectations:@[still] timeout:2];
    [view endInteraction];
    XCTAssertFalse(view.scene.interacting);

    // Standard view keeps the zoom.
    ps = view.scene.camera.parallelScale;
    [view showStandardView:BKStandardViewAnterior];
    XCTAssertEqualWithAccuracy(view.scene.camera.direction.y, 1.0, 1e-9);
    XCTAssertEqualWithAccuracy(view.scene.camera.parallelScale, ps, 1e-9);
}

@end
