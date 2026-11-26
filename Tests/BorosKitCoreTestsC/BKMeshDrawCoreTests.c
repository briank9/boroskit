// BorosKit plain-C core tests: BKMeshDrawCore (culling / texture / point rules and, since M3, the
// GPU settings block BKMeshUniforms).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (step M4). The first three tests carry the same
// expectations as Tests/BorosKitMeshTests/BKMeshDrawCoreTests.m (testFacingRule,
// testTextureExpandRule, testTextureSampleRule); the others test the new uniform builder.

#include "BKCoreTest.h"
#include "BKMeshDrawCore.h"
#include "BKCameraMath.h"
#include <string.h>

void bk_test_mesh_facing_rule(void)
{
    BKVec2f a = BKV2f(0, 0), b = BKV2f(1, 0), c = BKV2f(0, 1);
    BK_CHECK(BKMeshTriangleIsFrontFacing(a, b, c) == 1);    // anticlockwise, y up
    BK_CHECK(BKMeshTriangleIsFrontFacing(a, c, b) == 0);    // clockwise
    BK_CHECK(BKMeshTriangleIsFrontFacing(a, a, b) == 0);    // no area
    BK_CHECK(BKMeshTriangleIsCulled(BKMeshCullNone, a, c, b) == 0);
    BK_CHECK(BKMeshTriangleIsCulled(BKMeshCullBack, a, b, c) == 0);
    BK_CHECK(BKMeshTriangleIsCulled(BKMeshCullBack, a, c, b) == 1);
    BK_CHECK(BKMeshTriangleIsCulled(BKMeshCullFront, a, b, c) == 1);
    BK_CHECK(BKMeshTriangleIsCulled(BKMeshCullFront, a, c, b) == 0);
}

void bk_test_mesh_texture_expand_rule(void)
{
    uint8_t out[8];
    const uint8_t grey[2] = { 10, 20 };
    BK_CHECK(BKMeshTextureExpandToRGBA8(grey, 1, 2, out) == 1);
    const uint8_t expect1[8] = { 10, 10, 10, 255, 20, 20, 20, 255 };
    BK_CHECK(memcmp(out, expect1, 8) == 0);
    const uint8_t greyAlpha[2] = { 30, 40 };
    BKMeshTextureExpandToRGBA8(greyAlpha, 2, 1, out);
    BK_CHECK(out[0] == 30 && out[1] == 30 && out[2] == 30 && out[3] == 40);
    const uint8_t rgb[3] = { 1, 2, 3 };
    BKMeshTextureExpandToRGBA8(rgb, 3, 1, out);
    BK_CHECK(out[0] == 1 && out[1] == 2 && out[2] == 3 && out[3] == 255);
    const uint8_t rgba[4] = { 4, 5, 6, 7 };
    BKMeshTextureExpandToRGBA8(rgba, 4, 1, out);
    BK_CHECK(out[0] == 4 && out[1] == 5 && out[2] == 6 && out[3] == 7);
    BK_CHECK(BKMeshTextureExpandToRGBA8(rgba, 5, 1, out) == 0);
    BK_CHECK(BKMeshTextureExpandToRGBA8(NULL, 3, 1, out) == 0);
}

void bk_test_mesh_texture_sample_rule(void)
{
    // 2 x 2 picture: row 0 (t = 0): black, red; row 1: green, blue.
    const uint8_t px[16] = { 0, 0, 0, 255,   255, 0, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255 };
    BKVec4f c = BKMeshTextureSample(px, 2, 2, 0.75f, 0.25f, 0, BKMeshTextureWrapRepeat);
    BK_CHECK_NEAR(c.x, 1, 1e-6);   // red
    c = BKMeshTextureSample(px, 2, 2, 0.25f, 0.75f, 0, BKMeshTextureWrapRepeat);
    BK_CHECK_NEAR(c.y, 1, 1e-6);   // green
    c = BKMeshTextureSample(px, 2, 2, 1.25f, 0.25f, 0, BKMeshTextureWrapRepeat);
    BK_CHECK_NEAR(c.x, 0, 1e-6);   // repeat: s = 1.25 is s = 0.25 (black)
    c = BKMeshTextureSample(px, 2, 2, 1.25f, 0.25f, 0, BKMeshTextureWrapClampToEdge);
    BK_CHECK_NEAR(c.x, 1, 1e-6);   // clamp: the right edge (red)
    c = BKMeshTextureSample(px, 2, 2, 0.75f, 0.25f, 1, BKMeshTextureWrapClampToEdge);
    BK_CHECK_NEAR(c.x, 1, 1e-6);   // linear at a texel centre = that texel
    c = BKMeshTextureSample(px, 2, 2, 0.5f, 0.25f, 1, BKMeshTextureWrapClampToEdge);
    BK_CHECK_NEAR(c.x, 0.5, 1e-6); // halfway = the average
    c = BKMeshTextureSample(px, 2, 2, 0.0f, 0.25f, 1, BKMeshTextureWrapRepeat);
    BK_CHECK_NEAR(c.x, 0.5, 1e-6); // repeat at s = 0 blends left and right column
    BKVec4f m = BKMeshTextureModulate(BKV4f(2.0f, 0.5f, 1.0f, 0.5f), BKV4f(0.5f, 1.0f, 1.0f, 0.5f));
    BK_CHECK_NEAR(m.w, 0.25, 1e-6);
    BK_CHECK_NEAR(m.x, 0.5 * 0.25, 1e-6);
    BK_CHECK_NEAR(m.y, 0.5 * 0.25, 1e-6);
    BKVec2f lo, hi;
    BKMeshPointSquare(10, 20, 4, &lo, &hi);
    BK_CHECK(lo.x == 8 && lo.y == 18 && hi.x == 12 && hi.y == 22);
}

// The two golden mesh-render cameras (kBKGoldenMeshRenderCases) and an awkward one.
static BKMeshCamera BKTestMeshCamera(int which)
{
    BKMeshCamera c;
    memset(&c, 0, sizeof c);
    if (which == 0) {          // meshrender_bone_ortho: front view, 70 x 70 mm
        c.projection = 0;
        c.position = BKV3d(0, 0, 0); c.direction = BKV3d(0, 1, 0); c.up = BKV3d(0, 0, 1);
        c.viewWidth = 70; c.viewHeight = 70; c.fieldOfView = 30;
    } else if (which == 1) {   // meshrender_bone_persp_seethrough: oblique perspective, 30 degrees
        c.projection = 1;
        c.position = BKV3d(-110, -150, 60); c.direction = BKV3d(110, 150, -60); c.up = BKV3d(0, 0, 1);
        c.fieldOfView = 30;
    } else {                   // not unit, up not perpendicular
        c.projection = 0;
        c.position = BKV3d(1, 2, 3); c.direction = BKV3d(-0.3, 2.5, 0.7); c.up = BKV3d(0.2, -0.1, 3.0);
        c.viewWidth = 12.5; c.viewHeight = 7.25;
    }
    return c;
}

// BKMeshCameraAxes: orthonormal, and right is BIT FOR BIT BKCameraMath's BKCameraRight (the formula is
// written out in BKMeshDrawCore.c because a C file there cannot include BorosKitRender under SwiftPM).
void bk_test_mesh_camera_axes(void)
{
    for (int which = 0; which < 3; which++) {
        BKMeshCamera c = BKTestMeshCamera(which);
        BKVec3d r, u, f;
        BK_CHECK(BKMeshCameraAxes(&c, &r, &u, &f) == BKMeshCameraOK);
        BKCameraFrame frame;
        frame.position = c.position;
        frame.direction = BKV3dNormalize(c.direction);
        frame.up = c.up;
        frame.parallelScale = 0.5 * c.viewHeight;
        frame.viewAngle = c.fieldOfView;
        frame.perspective = c.projection == 1;
        BKVec3d cr = BKCameraRight(frame);
        BK_CHECK_SAME(r.x, cr.x);
        BK_CHECK_SAME(r.y, cr.y);
        BK_CHECK_SAME(r.z, cr.z);
        BK_CHECK_NEAR(BKV3dLength(r), 1, 1e-15);
        BK_CHECK_NEAR(BKV3dLength(u), 1, 1e-15);
        BK_CHECK_NEAR(BKV3dLength(f), 1, 1e-15);
        BK_CHECK_NEAR(BKV3dDot(r, u), 0, 1e-15);
        BK_CHECK_NEAR(BKV3dDot(r, f), 0, 1e-15);
        BK_CHECK_NEAR(BKV3dDot(u, f), 0, 1e-15);
        BK_CHECK(BKV3dDot(u, c.up) > 0);          // up stays on the side of the given up
    }
    // Front view: forward +y, up +z -> right = +x.
    BKMeshCamera c = BKTestMeshCamera(0);
    BKVec3d r, u, f;
    BKMeshCameraAxes(&c, &r, &u, &f);
    BK_CHECK(r.x == 1 && r.y == 0 && r.z == 0 && u.z == 1 && f.y == 1);
    // Refusals (outputs untouched).
    c.direction = BKV3d(0, 0, 0);
    r = BKV3d(7, 7, 7);
    BK_CHECK(BKMeshCameraAxes(&c, &r, NULL, NULL) == BKMeshCameraZeroDirection);
    BK_CHECK(r.x == 7);
    c.direction = BKV3d(0, 0, 2);
    BK_CHECK(BKMeshCameraAxes(&c, NULL, NULL, NULL) == BKMeshCameraUpParallel);
    c.direction = BKV3d(0, NAN, 1);
    BK_CHECK(BKMeshCameraAxes(&c, NULL, NULL, NULL) == BKMeshCameraZeroDirection);
}

void bk_test_mesh_uniforms_fill(void)
{
    BKMeshLighting light = { 0.1f, 0.7f, 0.2f, 10.0f };
    BKMeshUniforms u;
    // Orthographic: half sizes are half the view in mm; vectors w = 1 (point) / 0 (directions).
    BKMeshCamera c = BKTestMeshCamera(0);
    BK_CHECK(BKMeshUniformsFill(&u, &c, 96, 96, 5, 200, light) == BKMeshCameraOK);
    BK_CHECK(u.halfWidth == 35 && u.halfHeight == 35);
    BK_CHECK(u.cameraPosition.w == 1 && u.cameraRight.w == 0 && u.cameraUp.w == 0 && u.cameraForward.w == 0);
    BK_CHECK(u.cameraRight.x == 1 && u.cameraUp.z == 1 && u.cameraForward.y == 1);
    BK_CHECK(u.nearDistance == 5 && u.farDistance == 200);
    BK_CHECK(u.ambient == 0.1f && u.diffuse == 0.7f && u.specular == 0.2f && u.specularPower == 10.0f);
    BK_CHECK(u.projection == 0 && u.lit == 1 && u.viewportWidth == 96 && u.viewportHeight == 96);
    BK_CHECK(u.useVertexColors == 0 && u.hasNormals == 0 && u.lineHalfWidth == 0 && u.paddingForAlignment == 0);
    // Perspective: tan(15 degrees) high, times the aspect wide.
    c = BKTestMeshCamera(1);
    BK_CHECK(BKMeshUniformsFill(&u, &c, 96, 80, 1, 400, light) == BKMeshCameraOK);
    BK_CHECK_NEAR(u.halfHeight, 0.26794919243112270, 1e-7);
    BK_CHECK_NEAR(u.halfWidth, 0.26794919243112270 * 96.0 / 80.0, 1e-7);
    BK_CHECK(u.projection == 1);
    // The float vectors are the double frame rounded once.
    BKVec3d r, up, f;
    BKMeshCameraAxes(&c, &r, &up, &f);
    BK_CHECK(u.cameraRight.x == (float)r.x && u.cameraUp.y == (float)up.y && u.cameraForward.z == (float)f.z);
    // Zero field of view: refused, block left zeroed.
    c.fieldOfView = 0;
    BK_CHECK(BKMeshUniformsFill(&u, &c, 96, 80, 1, 400, light) == BKMeshCameraZeroFieldOfView);
    BK_CHECK(u.lit == 0 && u.halfHeight == 0);
    c = BKTestMeshCamera(0);
    c.viewHeight = 0;
    BK_CHECK(BKMeshUniformsFill(&u, &c, 96, 96, 1, 2, light) == BKMeshCameraZeroFieldOfView);
}

void bk_test_mesh_uniforms_model_and_colour(void)
{
    BKMeshUniforms u;
    memset(&u, 0, sizeof u);
    // Scale (2, 4, 0.5) + translation: normal matrix = inverse-transpose = scale (1/2, 1/4, 2).
    const float scaled[16] = { 2, 0, 0, 0,   0, 4, 0, 0,   0, 0, 0.5f, 0,   10, 20, 30, 1 };
    BKMeshUniformsSetModel(&u, scaled, 1);
    BK_CHECK(u.model.columns[3].x == 10 && u.model.columns[3].z == 30 && u.model.columns[3].w == 1);
    BK_CHECK(u.normalMatrix.columns[0].x == 0.5f && u.normalMatrix.columns[1].y == 0.25f && u.normalMatrix.columns[2].z == 2.0f);
    BK_CHECK(u.normalMatrix.columns[0].y == 0 && u.normalMatrix.columns[2].w == 0 && u.normalMatrix.columns[3].w == 1);
    // A rotation (90 degrees about z) is its own inverse-transpose.
    const float rot[16] = { 0, 1, 0, 0,   -1, 0, 0, 0,   0, 0, 1, 0,   0, 0, 0, 1 };
    BKMeshUniformsSetModel(&u, rot, 1);
    BK_CHECK(u.normalMatrix.columns[0].y == 1 && u.normalMatrix.columns[1].x == -1 && u.normalMatrix.columns[2].z == 1);
    // A shear: N * M^T = identity (N = inverse-transpose).
    const float shear[16] = { 1, 0, 0, 0,   0.5f, 1, 0, 0,   0.25f, -0.75f, 2, 0,   0, 0, 0, 1 };
    BKMeshUniformsSetModel(&u, shear, 1);
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) {
            // (N M^T)(i, j) = sum_k N(i, k) * M(j, k); N(i, k) = column k, component i.
            double sum = 0;
            for (int k = 0; k < 3; k++) {
                const float *nk = (const float *)&u.normalMatrix.columns[k];
                sum += (double)nk[i] * (double)shear[k * 4 + j];
            }
            BK_CHECK_NEAR(sum, i == j ? 1 : 0, 1e-6);
        }
    // Singular 3x3 part: used as it is. Lines / points: identity whatever the placement.
    const float flat[16] = { 1, 0, 0, 0,   0, 1, 0, 0,   0, 0, 0, 0,   0, 0, 0, 1 };
    BKMeshUniformsSetModel(&u, flat, 1);
    BK_CHECK(u.normalMatrix.columns[2].z == 0 && u.normalMatrix.columns[0].x == 1);
    BKMeshUniformsSetModel(&u, scaled, 0);
    BK_CHECK(u.normalMatrix.columns[0].x == 1 && u.normalMatrix.columns[1].y == 1 && u.normalMatrix.columns[2].z == 1);
    // Colour: opacity clamped like MIN(MAX(o, 0), 1); NaN -> 1 (what that expression gives).
    BKMeshUniformsSetColor(&u, 0.25f, 0.5f, 2.0f, 0.4f);
    BK_CHECK(u.color.x == 0.25f && u.color.z == 2.0f && u.color.w == 0.4f);
    BKMeshUniformsSetColor(&u, 0, 0, 0, -3);
    BK_CHECK(u.color.w == 0);
    BKMeshUniformsSetColor(&u, 0, 0, 0, 7);
    BK_CHECK(u.color.w == 1);
    BKMeshUniformsSetColor(&u, 0, 0, 0, NAN);
    BK_CHECK(u.color.w == 1);
}

void bk_test_mesh_depth_range(void)
{
    float n, f;
    BKMeshDepthRange(10, 110, 0, &n, &f);           // margin 1 + 1 % of 100 = 2
    BK_CHECK(n == 8 && f == 112);
    BKMeshDepthRange(-50, 10, 1, &n, &f);           // perspective: nothing behind the eye
    BK_CHECK_NEAR(f, 11.6, 1e-5);
    BK_CHECK_NEAR(n, 11.6 * 1e-4, 1e-8);
    BKMeshDepthRange(-50, -40, 1, &n, &f);          // all behind: far clamped to 0.001
    BK_CHECK(f == 1e-3f);
    BK_CHECK_NEAR(n, 1e-7, 1e-12);
    BKMeshDepthRange(INFINITY, -INFINITY, 0, &n, &f);   // nothing drawn: not finite (caller skips)
    BK_CHECK(!isfinite(n) && !isfinite(f));
}
