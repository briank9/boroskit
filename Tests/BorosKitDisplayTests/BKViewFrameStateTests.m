// Tests for BKViewFrameState (a 2D view's drawing state for one frame), overlay-engine step 8 round 3.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKViewFrameState.h"

@interface BKViewFrameStateTests : XCTestCase
@end

@implementation BKViewFrameStateTests

- (void)testDefaultsAndSwitches
{
    BKViewFrameState s;
    BKViewFrameStateReset(&s);
    XCTAssertEqual(s.m.mode, (int32_t)BKMatrixModelView);
    XCTAssertEqual(s.pen.lineWidth, 1.0f);
    XCTAssertEqual(s.blendSrc, (int32_t)BKViewBlendOne);
    XCTAssertEqual(s.blendDst, (int32_t)BKViewBlendZero);
    for (int k = 0; k < BKViewSwitchCount; k++) XCTAssertEqual(BKViewFrameStateSwitch(&s, (BKViewSwitch)k), 0);

    BKViewFrameStateSetSwitch(&s, BKViewSwitchBlend, 1);
    BKViewFrameStateSetSwitch(&s, BKViewSwitchSmoothLines, 7);   // any non-zero = on
    BKViewFrameStateSetSwitch(&s, BKViewSwitchClip, 1);
    XCTAssertEqual(s.pen.blend, 1); XCTAssertEqual(s.pen.smoothLines, 1); XCTAssertEqual(s.clipOn, 1);
    XCTAssertEqual(BKViewFrameStateSwitch(&s, BKViewSwitchSmoothLines), 1);

    // Blend rule: One / Zero with blending on is not the plain "paint with transparency" rule.
    XCTAssertEqual(BKViewFrameStateBlendIsPlain(&s), 0);
    BKViewFrameStateSetBlend(&s, BKViewBlendSrcAlpha, BKViewBlendOneMinusSrcAlpha);
    XCTAssertEqual(BKViewFrameStateBlendIsPlain(&s), 1);
    XCTAssertEqual(s.pen.premultiplied, 0);
    BKViewFrameStateSetBlend(&s, BKViewBlendOne, BKViewBlendOneMinusSrcAlpha);
    XCTAssertEqual(BKViewFrameStateBlendIsPlain(&s), 1);
    XCTAssertEqual(s.pen.premultiplied, 1);
    BKViewFrameStateSetBlend(&s, BKViewBlendOne, BKViewBlendOne);   // additive (fusion)
    XCTAssertEqual(BKViewFrameStateBlendIsPlain(&s), 0);
    BKViewFrameStateSetSwitch(&s, BKViewSwitchBlend, 0);            // ... but blending off is plain
    XCTAssertEqual(BKViewFrameStateBlendIsPlain(&s), 1);
}

- (void)testSaveRestoreGroups
{
    BKViewFrameState s;
    BKViewFrameStateReset(&s);
    s.pen.color[0] = 0.25f; s.pen.lineWidth = 3; s.pen.pointSize = 5;
    s.viewport[2] = 100; s.viewport[3] = 50;
    XCTAssertEqual(BKViewFrameStateSave(&s, BKViewSaveColor | BKViewSaveLines), 1);
    s.pen.color[0] = 0.75f; s.pen.lineWidth = 9; s.pen.pointSize = 11; s.viewport[2] = 7;
    BKViewFrameStateSetSwitch(&s, BKViewSwitchSmoothLines, 1);
    XCTAssertEqual(BKViewFrameStateRestore(&s), 1);
    XCTAssertEqual(s.pen.color[0], 0.25f);      // saved group: back
    XCTAssertEqual(s.pen.lineWidth, 3.0f);      // saved group: back
    XCTAssertEqual(s.pen.smoothLines, 0);       // line group includes line smoothing
    XCTAssertEqual(s.pen.pointSize, 11.0f);     // not saved: kept
    XCTAssertEqual(s.viewport[2], 7);           // not saved: kept
    XCTAssertEqual(BKViewFrameStateRestore(&s), 0);   // empty

    // Matrix mode and blend groups; overflow refused.
    BKViewMatricesSetMode(&s.m, BKMatrixProjection);
    BKViewFrameStateSetBlend(&s, BKViewBlendSrcAlpha, BKViewBlendOneMinusSrcAlpha);
    XCTAssertEqual(BKViewFrameStateSave(&s, BKViewSaveAll), 1);
    BKViewMatricesSetMode(&s.m, BKMatrixModelView);
    BKViewFrameStateSetBlend(&s, BKViewBlendOne, BKViewBlendOne);
    XCTAssertEqual(BKViewFrameStateRestore(&s), 1);
    XCTAssertEqual(s.m.mode, (int32_t)BKMatrixProjection);
    XCTAssertEqual(s.blendSrc, (int32_t)BKViewBlendSrcAlpha);
    XCTAssertEqual(s.pen.premultiplied, 0);
    for (int i = 0; i < BK_VIEW_SAVE_DEPTH; i++) XCTAssertEqual(BKViewFrameStateSave(&s, BKViewSaveAll), 1);
    XCTAssertEqual(BKViewFrameStateSave(&s, BKViewSaveAll), 0);
    BKViewFrameStateCarryOver(&s);
    XCTAssertEqual(s.savedTop, 0);
}

- (void)testTo2DMatchesMatrices
{
    BKViewFrameState s;
    BKViewFrameStateReset(&s);
    s.viewport[2] = 200; s.viewport[3] = 100;
    BKViewMatricesScale(&s.m, 2.0 / 200, -2.0 / 100, 1);
    BKViewMatricesTranslate(&s.m, -100, -50, 0);
    BKViewXf a, b;
    XCTAssertEqual(BKViewFrameStateTo2D(&s, 200, 100, &a, NULL, NULL), 1);
    XCTAssertEqual(BKViewMatricesTo2D(&s.m, 0, 0, 200, 100, &b, NULL, NULL), 1);
    XCTAssertEqual(memcmp(&a, &b, sizeof a), 0);
    // The view's pixel (0, 0) top-left maps to (0, 0).
    BKVec2f p = BKViewMap(&a, 0, 0);
    XCTAssertEqualWithAccuracy(p.x, 0.0, 1e-6); XCTAssertEqualWithAccuracy(p.y, 0.0, 1e-6);
    XCTAssertEqual(BKViewFrameStateTo2D(&s, 201, 100, &a, NULL, NULL), 0);   // overlay of another size
    XCTAssertEqual(BKViewFrameStateTo2D(&s, 0, 0, &a, NULL, NULL), 1);       // size not checked
    s.viewport[0] = 1;
    XCTAssertEqual(BKViewFrameStateTo2D(&s, 0, 0, &a, NULL, NULL), 0);       // must start at 0, 0
    // Carry-over keeps the current matrices.
    s.viewport[0] = 0;
    BKViewMatricesPush(&s.m);
    BKViewMatricesScale(&s.m, 3, 3, 1);
    BKViewFrameStateCarryOver(&s);
    XCTAssertEqual(s.m.mvTop, 0);
    XCTAssertEqualWithAccuracy(BKViewMatricesTop(&s.m, BKMatrixModelView)[0], 3 * 2.0 / 200, 1e-12);
}

@end
