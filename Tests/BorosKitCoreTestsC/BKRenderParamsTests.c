// BorosKit plain-C core tests: BKRenderParamsCore (the ray caster's parameter block + preset CLUT rules).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
//
// PORTING NOTES: plain C99, built by CMake on every platform (ctest core.render_params_*). On the Mac the same
// builder is exercised through BKVolumeRenderer by the golden volume renders in strict mode.
//
// What is proven (known answers worked out by hand, never from the code under test):
//   - camera frame: a front view gives right = +x, up = +z; an oblique, non-unit direction gives an orthonormal
//     frame (right x up = -forward, as the front view +x, +z looking +y) with forward along the direction; zero direction -> code 11,
//     up parallel -> code 12;
//   - perspective view size = 2 tan(fov / 2) with the aspect ratio of the output; orthographic = the given mm;
//   - crop box clamped to the voxel-centre bounds; default step = half the smallest spacing; NaN miss value ->
//     the volume's value; zero slab / clip normal -> (0, 0, 1); negative slab thickness -> 0;
//   - patient -> voxel columns / translation and fusion fields copied from the column-major matrices;
//   - the portable normalisation is deterministic and unit length to float precision;
//   - CLUT rules: 255 colour points, first at the window start, entry 254 on the window end; opacity anchors at
//     the ends only when the curve does not reach them; an existing value is replaced, not duplicated.

#include "BKCoreTest.h"
#include "BKRenderParamsCore.h"
#include <string.h>

static BKRenderSettings TestSettings(void)
{
    BKRenderSettings s;
    memset(&s, 0, sizeof s);
    s.volumeSize[0] = 64; s.volumeSize[1] = 64; s.volumeSize[2] = 48;
    // voxel = patient / spacing + 32 (x, y), / 1.25 + 24 (z): diagonal matrix, column-major.
    s.patientToVoxel[0] = 1.0; s.patientToVoxel[5] = 1.0; s.patientToVoxel[10] = 0.8; s.patientToVoxel[15] = 1.0;
    s.patientToVoxel[12] = 32.0; s.patientToVoxel[13] = 32.0; s.patientToVoxel[14] = 24.0;
    s.minPixelSpacing = 1.0;
    s.valueScale = 4000.0f; s.valueOffset = -1000.0f; s.outOfBoundsValue = -1000.0f;
    s.cameraDirection[1] = 1.0; s.cameraUp[2] = 1.0;
    s.viewWidth = 70.0; s.viewHeight = 60.0; s.fieldOfView = 30.0;
    s.cropMin[0] = -5.0; s.cropMax[0] = 100.0; s.cropMax[1] = 10.0; s.cropMax[2] = 47.0;
    s.missValue = NAN;
    s.slabNormal[2] = 0.0;   // zero normal on purpose
    return s;
}

void bk_test_render_params_frame(void)
{
    BKRenderSettings s = TestSettings();
    BKRenderParams p;
    BK_CHECK(BKRenderParamsFill(&s, 96, 80, &p) == BKRenderParamsOK);
    BK_CHECK_SAME(p.cameraRight.x, 1.0); BK_CHECK_SAME(p.cameraRight.y, 0.0); BK_CHECK_SAME(p.cameraRight.z, 0.0);
    BK_CHECK_SAME(p.cameraUp.z, 1.0); BK_CHECK_SAME(p.cameraForward.y, 1.0);
    BK_CHECK_SAME(p.viewWidth, 70.0); BK_CHECK_SAME(p.viewHeight, 60.0);

    // Oblique, non-unit direction: orthonormal, right-handed, forward along the direction.
    s.cameraDirection[0] = 110; s.cameraDirection[1] = 150; s.cameraDirection[2] = -60;
    BK_CHECK(BKRenderParamsFill(&s, 96, 80, &p) == BKRenderParamsOK);
    double len = sqrt(110.0 * 110 + 150.0 * 150 + 60.0 * 60);
    BK_CHECK_NEAR(p.cameraForward.x, 110 / len, 1e-7); BK_CHECK_NEAR(p.cameraForward.z, -60 / len, 1e-7);
    float r[3] = { p.cameraRight.x, p.cameraRight.y, p.cameraRight.z }, u[3] = { p.cameraUp.x, p.cameraUp.y, p.cameraUp.z };
    float f[3] = { p.cameraForward.x, p.cameraForward.y, p.cameraForward.z };
    BK_CHECK_NEAR(r[0] * u[0] + r[1] * u[1] + r[2] * u[2], 0.0, 1e-6);
    BK_CHECK_NEAR(r[0] * f[0] + r[1] * f[1] + r[2] * f[2], 0.0, 1e-6);
    BK_CHECK_NEAR(r[0] * r[0] + r[1] * r[1] + r[2] * r[2], 1.0, 1e-6);
    BK_CHECK_NEAR(r[1] * u[2] - r[2] * u[1], -f[0], 1e-6);  // right x up = -forward (front view: +x, +z, looking +y)
    BK_CHECK(u[2] > 0.0f);                                  // up stays on the +z side

    s.cameraDirection[0] = s.cameraDirection[1] = s.cameraDirection[2] = 0;
    BK_CHECK(BKRenderParamsFill(&s, 96, 80, &p) == BKRenderParamsZeroDirection);
    s.cameraDirection[2] = 2.0;   // parallel to up
    BK_CHECK(BKRenderParamsFill(&s, 96, 80, &p) == BKRenderParamsUpParallel);
}

void bk_test_render_params_fields(void)
{
    BKRenderSettings s = TestSettings();
    s.projection = 1;
    s.slabThickness = -3.0;
    BKRenderParams p;
    BK_CHECK(BKRenderParamsFill(&s, 96, 80, &p) == BKRenderParamsOK);
    double h = 2.0 * tan(0.5 * 30.0 * 3.14159265358979323846 / 180.0);
    BK_CHECK_NEAR(p.viewHeight, h, 1e-6);
    BK_CHECK_NEAR(p.viewWidth, h * 96.0 / 80.0, 1e-6);
    BK_CHECK_SAME(p.boxMin.x, 0.0); BK_CHECK_SAME(p.boxMax.x, 63.0);   // clamped to the voxel-centre bounds
    BK_CHECK_SAME(p.boxMax.y, 10.0); BK_CHECK_SAME(p.boxMax.z, 47.0);
    BK_CHECK_SAME(p.stepSize, 0.5);                                     // half the smallest spacing
    BK_CHECK_SAME(p.outOfBoundsValue, -1000.0);                         // NaN miss value
    BK_CHECK_SAME(p.slabNormal.z, 1.0); BK_CHECK_SAME(p.clipNormal.z, 1.0);   // zero normals -> (0, 0, 1)
    BK_CHECK_SAME(p.slabThickness, 0.0);
    BK_CHECK_SAME(p.opacityUnitDistance, 1.0); BK_CHECK_SAME(p.blendOpacityUnitDistance, 1.0);
    BK_CHECK_SAME(p.patientToVoxelColumns[2].z, 0.8f); BK_CHECK_SAME(p.patientToVoxelTranslation.z, 24.0);
    BK_CHECK_SAME(p.volumeSize.z, 48.0);
    BK_CHECK(p.width == 96 && p.height == 80 && p.useBlend == 0 && p.skipEmptySpace == 0 && p.valuesOnly == 0);

    s.useBlend = 1;
    s.blendVolumeSize[0] = 10; s.blendVolumeSize[1] = 11; s.blendVolumeSize[2] = 12;
    s.blendPatientToVoxel[0] = 0.5; s.blendPatientToVoxel[14] = 3.0;
    s.blendTfMin = -5; s.blendTfMax = 7;
    s.missValue = 42.0f;
    BK_CHECK(BKRenderParamsFill(&s, 8, 8, &p) == BKRenderParamsOK);
    BK_CHECK(p.useBlend == 1);
    BK_CHECK_SAME(p.blendVolumeSize.y, 11.0); BK_CHECK_SAME(p.blendPatientToVoxelColumns[0].x, 0.5);
    BK_CHECK_SAME(p.blendPatientToVoxelTranslation.z, 3.0); BK_CHECK_SAME(p.blendTfMax, 7.0);
    BK_CHECK_SAME(p.outOfBoundsValue, 42.0);

    // Portable normalisation: unit length, deterministic.
    float a[3] = { 0.3f, 0.2f, 0.93f }, b[3] = { 0.3f, 0.2f, 0.93f };
    BKRenderNormalize3fPortable(a);
    BKRenderNormalize3fPortable(b);
    BK_CHECK(memcmp(a, b, sizeof a) == 0);
    BK_CHECK_NEAR(a[0] * a[0] + a[1] * a[1] + a[2] * a[2], 1.0, 1e-6);
}

void bk_test_render_params_clut(void)
{
    uint8_t ramp[256];
    for (int i = 0; i < 256; i++) ramp[i] = (uint8_t)i;
    BKRenderTFPoint color[255], opacity[8];
    size_t nc = 0, no = 0;
    // Window 40 / 400: start -160, end 240.
    BKRenderTFFromCLUT(ramp, ramp, ramp, 40.0f, 400.0f, NULL, 0, color, &nc, opacity, &no);
    BK_CHECK(nc == 255 && no == 2);
    BK_CHECK_SAME(color[0].value, -160.0); BK_CHECK_SAME(color[254].value, 240.0);
    BK_CHECK_SAME(color[254].c[0], 254.0f / 255.0f);
    BK_CHECK_SAME(opacity[0].value, -160.0); BK_CHECK_SAME(opacity[0].c[0], 0.0);
    BK_CHECK_SAME(opacity[1].value, 240.0); BK_CHECK_SAME(opacity[1].c[0], 1.0);

    // A curve that starts at x = 0 and ends at x = 256: no anchors; a middle point at x = 128 -> value 40.
    const double xy[6] = { 0, 0.25, 128, 0.5, 256, 0.75 };
    BKRenderTFFromCLUT(ramp, ramp, ramp, 40.0f, 400.0f, xy, 3, color, &nc, opacity, &no);
    BK_CHECK(no == 3);
    BK_CHECK_SAME(opacity[0].c[0], 0.25); BK_CHECK_SAME(opacity[1].value, 40.0); BK_CHECK_SAME(opacity[2].c[0], 0.75);

    // Insert: sorted, and a point at an existing value replaces it.
    BKRenderTFPoint pts[4];
    size_t n = 0;
    BKRenderTFPoint p1 = { 5, { 1, 0, 0 } }, p2 = { 1, { 2, 0, 0 } }, p3 = { 5, { 3, 0, 0 } };
    n = BKRenderTFInsertPoint(pts, n, 4, p1);
    n = BKRenderTFInsertPoint(pts, n, 4, p2);
    n = BKRenderTFInsertPoint(pts, n, 4, p3);
    BK_CHECK(n == 2);
    BK_CHECK_SAME(pts[0].value, 1.0); BK_CHECK_SAME(pts[1].c[0], 3.0);
}
