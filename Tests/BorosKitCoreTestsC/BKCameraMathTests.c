// BorosKit plain-C core tests: BKCameraMath (screen point -> ray, mouse move -> mm, projection).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (step M4). The same expectations as
// Tests/BorosKitRenderTests/BKCameraMathTests.m (testRightVector, testOrthoRayAndScale,
// testPerspectiveRay, testProjectPointInvertsRay, testWorldDelta).

#include "BKCoreTest.h"
#include "BKCameraMath.h"

// An orthographic camera at (0, 0, -100) looking along +z, up = +y, 100 mm high view.
static BKCameraFrame BKTestOrthoCamera(void)
{
    BKCameraFrame c;
    c.position = BKV3d(0, 0, -100);
    c.direction = BKV3d(0, 0, 1);
    c.up = BKV3d(0, 1, 0);
    c.parallelScale = 50;
    c.viewAngle = 30;
    c.perspective = false;
    return c;
}

static int BKClose3(BKVec3d a, BKVec3d b, double tol) { return BKV3dDistance(a, b) <= tol; }

// Right = direction x up; with +z view and +y up this is -x (VTK's convention).
void bk_test_camera_right_vector(void)
{
    BK_CHECK(BKClose3(BKCameraRight(BKTestOrthoCamera()), BKV3d(-1, 0, 0), 1e-12));
}

// 100 mm high on 200 points -> 0.5 mm per point; the top-left corner of a 400 x 200 view is 100 mm
// to the left (+x here) and 50 mm up; the centre of the view is the camera position.
void bk_test_camera_ortho_ray_and_scale(void)
{
    BKCameraFrame c = BKTestOrthoCamera();
    BK_CHECK_NEAR(BKCameraMillimetresPerViewPoint(c, 200, 0), 0.5, 1e-12);
    BKVec3d o, d;
    BKCameraRayThroughViewPoint(c, 400, 200, 0, 0, &o, &d);
    BK_CHECK(BKClose3(o, BKV3d(100, 50, -100), 1e-9));
    BK_CHECK(BKClose3(d, BKV3d(0, 0, 1), 1e-12));
    BKCameraRayThroughViewPoint(c, 400, 200, 200, 100, &o, &d);
    BK_CHECK(BKClose3(o, c.position, 1e-9));
}

// 90 degree vertical opening: at the top edge the ray goes 45 degrees up; at 10 mm depth the
// 200-point view is 20 mm high -> 0.1 mm per point.
void bk_test_camera_perspective_ray(void)
{
    BKCameraFrame c = BKTestOrthoCamera();
    c.perspective = true;
    c.viewAngle = 90;
    BKVec3d o, d;
    BKCameraRayThroughViewPoint(c, 200, 200, 100, 0, &o, &d);
    BK_CHECK(BKClose3(o, c.position, 1e-12));
    BK_CHECK(BKClose3(d, BKV3dNormalize(BKV3d(0, 1, 1)), 1e-9));
    BK_CHECK_NEAR(BKCameraMillimetresPerViewPoint(c, 200, 10), 0.1, 1e-9);
}

// BKCameraProjectPoint is the exact inverse of BKCameraRayThroughViewPoint; a point behind a
// perspective eye is refused.
void bk_test_camera_project_inverts_ray(void)
{
    for (int perspective = 0; perspective <= 1; perspective++) {
        BKCameraFrame c = BKTestOrthoCamera();
        c.perspective = perspective;
        c.viewAngle = 30;
        double pts[4][2] = { { 0, 0 }, { 200, 100 }, { 399, 7 }, { 13.5, 187.25 } };
        for (int i = 0; i < 4; i++)
            for (double t = 5; t < 400; t *= 3) {
                BKVec3d o, d;
                BKCameraRayThroughViewPoint(c, 400, 200, pts[i][0], pts[i][1], &o, &d);
                double x = -1, y = -1, depth = 0;
                BK_CHECK(BKCameraProjectPoint(c, 400, 200, BKV3dAddScaled(o, d, t), &x, &y, &depth));
                BK_CHECK_NEAR(x, pts[i][0], 1e-6);
                BK_CHECK_NEAR(y, pts[i][1], 1e-6);
                BK_CHECK(depth > (perspective ? 0.0 : -1e9));
            }
        if (perspective) {
            double x = 0, y = 0;
            BK_CHECK(!BKCameraProjectPoint(c, 400, 200, BKV3dAddScaled(c.position, c.direction, -10), &x, &y, NULL));
        }
    }
}

// A mouse move of 10 points right and 4 points down = 5 mm along "right", 2 mm down.
void bk_test_camera_world_delta(void)
{
    BKVec3d m = BKCameraWorldDeltaForViewDelta(BKTestOrthoCamera(), 200, 0, 10, 4);
    BK_CHECK(BKClose3(m, BKV3d(-5, -2, 0), 1e-9));
}
