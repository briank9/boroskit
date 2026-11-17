// Tests for BKViewMatrix (the 2D views' positioning stacks), plan step 8c.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKViewMatrix.h"

@interface BKViewMatrixTests : XCTestCase
@end

@implementation BKViewMatrixTests

// A typical 2D view set-up: scale to clip space (y flipped), rotate 90 degrees, move. A point must land where
// hand maths puts it, and BKViewMatricesTo2D must give the same placement.
- (void)testTypicalViewSetUp
{
    BKViewMatrices m;
    BKViewMatricesReset(&m);
    const double W = 200, H = 100;
    BKViewMatricesScale(&m, 2.0 / W, -2.0 / H, 1);      // view pixels from the centre, y down -> clip space
    BKViewMatricesRotate(&m, 90, 0, 0, 1);              // then turned 90 degrees
    BKViewMatricesTranslate(&m, 10, 0, 0);              // drawing space moved 10 to the right first
    BKViewXf xf; double zx = 7, zy = 7;
    XCTAssertEqual(BKViewMatricesTo2D(&m, 0, 0, (int32_t)W, (int32_t)H, &xf, &zx, &zy), 1);
    // Point (0, 0): moved to (10, 0), turned 90 degrees -> (0, 10), centre-relative y down -> view (100, 60).
    BKVec2f p = BKViewMap(&xf, 0, 0);
    XCTAssertEqualWithAccuracy(p.x, 100.0f, 1e-4);
    XCTAssertEqualWithAccuracy(p.y, 60.0f, 1e-4);
    XCTAssertEqualWithAccuracy(zx, 0.0, 1e-12);
    XCTAssertEqualWithAccuracy(zy, 0.0, 1e-12);
}

// Push / pop, stack limits, modes, keep-tops, not-2D cases.
- (void)testStacksAndLimits
{
    BKViewMatrices m;
    BKViewMatricesReset(&m);
    BKViewMatricesScale(&m, 2, 2, 1);
    XCTAssertEqual(BKViewMatricesPush(&m), 1);
    BKViewMatricesTranslate(&m, 5, 0, 0);
    XCTAssertEqualWithAccuracy(BKViewMatricesTop(&m, BKMatrixModelView)[12], 10.0, 1e-12);
    XCTAssertEqual(BKViewMatricesPop(&m), 1);
    XCTAssertEqualWithAccuracy(BKViewMatricesTop(&m, BKMatrixModelView)[12], 0.0, 1e-12);
    XCTAssertEqual(BKViewMatricesPop(&m), 0);                       // only one matrix left
    for (int i = 1; i < BK_VIEW_MV_DEPTH; i++) XCTAssertEqual(BKViewMatricesPush(&m), 1);
    XCTAssertEqual(BKViewMatricesPush(&m), 0);                      // full
    BKViewMatricesKeepTops(&m);
    XCTAssertEqual(m.mvTop, 0);
    XCTAssertEqualWithAccuracy(BKViewMatricesTop(&m, BKMatrixModelView)[0], 2.0, 1e-12);

    // Projection mode: changes only the projection; a non-identity projection is not plain 2D.
    BKViewMatricesSetMode(&m, BKMatrixProjection);
    BKViewMatricesScale(&m, 1, 1, 0.5);
    XCTAssertEqualWithAccuracy(BKViewMatricesTop(&m, BKMatrixModelView)[10], 1.0, 1e-12);
    BKViewXf xf;
    XCTAssertEqual(BKViewMatricesTo2D(&m, 0, 0, 10, 10, &xf, NULL, NULL), 0);
    BKViewMatricesIdentity(&m);
    XCTAssertEqual(BKViewMatricesTo2D(&m, 0, 0, 10, 10, &xf, NULL, NULL), 1);
    XCTAssertEqual(BKViewMatricesTo2D(&m, 1, 0, 10, 10, &xf, NULL, NULL), 0);   // viewport not at 0, 0
    // Perspective in the model-view: not plain 2D.
    BKViewMatricesSetMode(&m, BKMatrixModelView);
    double persp[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0.5, 0,0,0,1 };
    BKViewMatricesMultiply(&m, persp);
    XCTAssertEqual(BKViewMatricesTo2D(&m, 0, 0, 10, 10, &xf, NULL, NULL), 0);
    // Zero rotation axis: nothing changes.
    BKViewMatricesReset(&m);
    BKViewMatricesRotate(&m, 45, 0, 0, 0);
    XCTAssertEqual(BKViewMatricesTop(&m, BKMatrixModelView)[0], 1.0);
}

@end
