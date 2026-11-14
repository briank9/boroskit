// Tests for BKCropBox (the native cropping box object): visibility, the drawable objects
// (outline, handles at a constant screen size, highlights, slab cut, world scale), drags making
// it crop, the 6 clip planes, and reset.
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import "BKCropBox.h"
#import "BKMeshRenderer.h"

@interface BKCropBoxTests : XCTestCase
@end

// What: orthographic camera looking down -z at (100, 50); 0.5 mm per point in a 200-point view.
static BKCameraFrame BKCropBoxTestCamera(void)
{
    BKCameraFrame f;
    f.position = simd_make_double3(100, 50, 200);
    f.direction = simd_make_double3(0, 0, -1);
    f.up = simd_make_double3(0, 1, 0);
    f.parallelScale = 50;
    f.viewAngle = 30;
    f.perspective = false;
    return f;
}

@implementation BKCropBoxTests

// What: a new box around x 80..120, y 40..60, z 25..35, minimum edge 2 mm.
- (BKCropBox *)makeBox
{
    BKOrientedBox b = BKBoxMakeAxisAligned(simd_make_double3(80, 40, 25), simd_make_double3(120, 60, 35));
    return [[BKCropBox alloc] initWithDefaultBox:b minimumEdge:2.0];
}

// Hidden: nothing drawn, nothing grabbed, nothing cropped. Shown: 12 edges and 7 handles, each
// handle 5 points = 2.5 mm big, all multiplied by worldScale.
- (void)testDrawingFollowsVisibilityAndScale
{
    BKCropBox *box = [self makeBox];
    BKCameraFrame cam = BKCropBoxTestCamera();
    XCTAssertEqual(box.drawObjects.count, 9u);
    [box updateDrawingWithCamera:cam viewHeight:200 cutPlanes:NULL count:0];
    for (id o in box.drawObjects) XCTAssertFalse([o isVisible]);
    XCTAssertFalse([box beginDragAtViewX:140 yDown:100 button:BKCropButtonLeft shift:NO camera:cam viewWidth:200 viewHeight:200 cutPlanes:NULL count:0]);
    simd_float4 planes[6];
    XCTAssertEqual([box getClipPlanes:planes], 0u);

    box.visible = YES;
    box.worldScale = 2.0;
    [box updateDrawingWithCamera:cam viewHeight:200 cutPlanes:NULL count:0];
    BKLineObject *outline = box.drawObjects[0];
    XCTAssertTrue(outline.visible);
    XCTAssertEqual(outline.segmentCount, 12u);
    XCTAssertEqualWithAccuracy(outline.transform.columns[0].x, 2.0f, 1e-6f);
    for (int h = 0; h < 7; h++) {
        BKMeshObject *handle = box.drawObjects[1 + h];
        XCTAssertTrue(handle.visible);
        XCTAssertEqualWithAccuracy(handle.transform.columns[0].x, 5.0f, 1e-5f);   // 2.5 mm x worldScale 2
    }
    BKMeshObject *plusX = box.drawObjects[1 + BKBoxFacePlusX];
    XCTAssertEqualWithAccuracy(plusX.transform.columns[3].x, 240.0f, 1e-4f);    // x = 120 mm x 2
    XCTAssertFalse([box.drawObjects[8] isVisible]);                               // no highlighted face
}

// Grabbing the +X handle: red handle, yellow face shown; dragging makes the box crop (6 planes
// cutting outside it); mouse-up removes the highlights; reset crops nothing again.
- (void)testDragCropsAndHighlights
{
    BKCropBox *box = [self makeBox];
    BKCameraFrame cam = BKCropBoxTestCamera();
    box.visible = YES;
    XCTAssertTrue([box beginDragAtViewX:140 yDown:100 button:BKCropButtonLeft shift:NO camera:cam viewWidth:200 viewHeight:200 cutPlanes:NULL count:0]);
    XCTAssertTrue(box.dragging);
    XCTAssertEqualObjects(box.dragDescription, @"face move");
    [box updateDrawingWithCamera:cam viewHeight:200 cutPlanes:NULL count:0];
    BKMeshObject *plusX = box.drawObjects[1 + BKBoxFacePlusX];
    BKMeshObject *minusX = box.drawObjects[1 + BKBoxFaceMinusX];
    XCTAssertTrue(simd_equal(plusX.color, box.selectedHandleColor));
    XCTAssertTrue(simd_equal(minusX.color, box.handleColor));
    BKMeshObject *face = box.drawObjects[8];
    XCTAssertTrue(face.visible);
    XCTAssertEqual(face.mesh.triangleCount, 2u);
    XCTAssertEqualWithAccuracy(face.opacity, 0.25f, 1e-6f);

    XCTAssertFalse(box.cropsVolume);
    XCTAssertTrue([box continueDragByViewX:-20 yDown:0 camera:cam viewHeight:200]);   // +X face 10 mm in
    XCTAssertTrue(box.cropsVolume);
    simd_float4 planes[6];
    XCTAssertEqual([box getClipPlanes:planes], 6u);
    // +X plane: normal +x, cut where x - 110 > 0.
    XCTAssertEqualWithAccuracy(planes[BKBoxFacePlusX].x, 1.0f, 1e-6f);
    XCTAssertEqualWithAccuracy(planes[BKBoxFacePlusX].w, -110.0f, 1e-4f);

    [box endDrag];
    XCTAssertFalse(box.dragging);
    XCTAssertNil(box.dragDescription);
    [box updateDrawingWithCamera:cam viewHeight:200 cutPlanes:NULL count:0];
    XCTAssertTrue(simd_equal(plusX.color, box.handleColor));
    XCTAssertFalse(face.visible);

    [box resetToDefaultBox];
    XCTAssertFalse(box.cropsVolume);
    XCTAssertEqual([box getClipPlanes:planes], 0u);
    XCTAssertEqualWithAccuracy(box.box.halfSize[0], 20.0, 1e-12);
}

// A slab keeping z <= 32 hides the +Z handle and shortens the uprights; hiding keeps the crop.
- (void)testSlabCutAndHideKeepsCrop
{
    BKCropBox *box = [self makeBox];
    BKCameraFrame cam = BKCropBoxTestCamera();
    box.visible = YES;
    simd_float4 slab = simd_make_float4(0, 0, 1, -32);
    [box updateDrawingWithCamera:cam viewHeight:200 cutPlanes:&slab count:1];
    XCTAssertFalse([box.drawObjects[1 + BKBoxFacePlusZ] isVisible]);
    XCTAssertTrue([box.drawObjects[1 + BKBoxFaceMinusZ] isVisible]);
    BKLineObject *outline = box.drawObjects[0];
    XCTAssertEqual(outline.segmentCount, 8u);

    BKOrientedBox turned = box.box;
    BKBoxRotate(&turned, simd_make_double3(0, 0, 1), 0.3);
    [box setBox:turned cropsVolume:YES];
    box.visible = NO;
    [box updateDrawingWithCamera:cam viewHeight:200 cutPlanes:NULL count:0];
    for (id o in box.drawObjects) XCTAssertFalse([o isVisible]);
    simd_float4 planes[6];
    XCTAssertEqual([box getClipPlanes:planes], 6u);
}

@end
