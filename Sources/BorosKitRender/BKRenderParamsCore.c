// BorosKitRender: BKRenderParamsCore implementation (see include/BKRenderParamsCore.h).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan step 7.1 #4a): moved operation for operation from
// BKVolumeRenderer.m (-fillParams:, -fillBlendParams:) and BKTransferFunction.m (CLUT rules), so the GPU receives
// exactly the same numbers as before. Compiled with -ffp-contract=off like every BorosKit core (no hidden fma).

#include "BKRenderParamsCore.h"
#include "BKVolumeFusionCore.h"   // BKFusionBlendProjection

#include <math.h>
#include <string.h>

static const double kBKPi = 3.14159265358979323846;   // the value of M_PI (not every C library defines M_PI)

void BKRenderNormalize3fPortable(float v[3])
{
    double x = v[0], y = v[1], z = v[2];
    double len = sqrt(x * x + y * y + z * z);
    v[0] = (float)(x / len);
    v[1] = (float)(y / len);
    v[2] = (float)(z / len);
}

// What: |v| in float with the order of simd_precise_length (x*x + y*y + z*z, then sqrtf), so the "too short?"
// tests decide exactly as before.
static float BKLength3f(const float v[3])
{
    return sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

// What: a x b with the operand order of simd_cross ((a.zxy * b - a * b.zxy).zxy).
static void BKCross3f(const float a[3], const float b[3], float out[3])
{
    float r0 = a[1] * b[2] - a[2] * b[1];
    float r1 = a[2] * b[0] - a[0] * b[2];
    float r2 = a[0] * b[1] - a[1] * b[0];
    out[0] = r0; out[1] = r1; out[2] = r2;
}

static void BKToFloat3(const double d[3], float out[3])
{
    out[0] = (float)d[0]; out[1] = (float)d[1]; out[2] = (float)d[2];
}

static bk_float4 BKF4(const float v[3])
{
    return bk_make_float4(v[0], v[1], v[2], 0.0f);
}

// What: a unit normal from a double normal, or (0, 0, 1) when it is (nearly) zero (slab / clip plane rule).
static bk_float4 BKUnitNormalOrZ(const double n[3], BKRenderNormalize3f normalize3f)
{
    float v[3];
    BKToFloat3(n, v);
    if (BKLength3f(v) > 1e-6f) {
        normalize3f(v);
        return BKF4(v);
    }
    return bk_make_float4(0.0f, 0.0f, 1.0f, 0.0f);
}

// What: clamp like simd_clamp (min(max(x, lo), hi)).
static float BKClampf(float x, float lo, float hi)
{
    return fminf(fmaxf(x, lo), hi);
}

int BKRenderParamsFill(const BKRenderSettings *s, uint32_t width, uint32_t height, BKRenderParams *p)
{
    memset(p, 0, sizeof(*p));
    BKRenderNormalize3f normalize3f = s->normalize3f ? s->normalize3f : BKRenderNormalize3fPortable;
    const double *m = s->patientToVoxel;

    // patient -> voxel: columns of the 3x3 part + translation (column 3).
    for (int c = 0; c < 3; c++)
        p->patientToVoxelColumns[c] = bk_make_float4((float)m[c * 4 + 0], (float)m[c * 4 + 1], (float)m[c * 4 + 2], 0.0f);
    p->patientToVoxelTranslation = bk_make_float4((float)m[12], (float)m[13], (float)m[14], 0.0f);
    float volumeSize[3] = { (float)s->volumeSize[0], (float)s->volumeSize[1], (float)s->volumeSize[2] };
    p->volumeSize = BKF4(volumeSize);

    // Ray-cast region: crop box intersected with the volume's voxel-centre bounds.
    float boxMin[3], boxMax[3];
    for (int a = 0; a < 3; a++) {
        float volMax = volumeSize[a] - 1.0f;
        boxMin[a] = BKClampf((float)s->cropMin[a], 0.0f, volMax);
        boxMax[a] = BKClampf((float)s->cropMax[a], 0.0f, volMax);
    }
    p->boxMin = BKF4(boxMin);
    p->boxMax = BKF4(boxMax);

    // Orthonormal camera frame (right, up, forward) from direction + up.
    float forward[3], up[3], right[3];
    BKToFloat3(s->cameraDirection, forward);
    BKToFloat3(s->cameraUp, up);
    if (BKLength3f(forward) < 1e-6f) return BKRenderParamsZeroDirection;
    normalize3f(forward);
    BKCross3f(forward, up, right);
    if (BKLength3f(right) < 1e-6f) return BKRenderParamsUpParallel;
    normalize3f(right);
    BKCross3f(right, forward, up);
    float position[3];
    BKToFloat3(s->cameraPosition, position);
    p->cameraPosition = BKF4(position);
    p->cameraRight = BKF4(right);
    p->cameraUp = BKF4(up);
    p->cameraForward = BKF4(forward);

    if (s->projection == 1) {   // perspective
        float vfov = (float)s->fieldOfView * (float)kBKPi / 180.0f;
        p->viewHeight = 2.0f * tanf(0.5f * vfov);
        p->viewWidth = p->viewHeight * (float)width / (float)height;
    } else {
        p->viewWidth = (float)s->viewWidth;
        p->viewHeight = (float)s->viewHeight;
    }

    float slabPoint[3], clipPoint[3];
    BKToFloat3(s->slabPoint, slabPoint);
    p->slabPoint = BKF4(slabPoint);
    p->slabNormal = BKUnitNormalOrZ(s->slabNormal, normalize3f);
    p->slabThickness = (float)(s->slabThickness < 0.0 ? 0.0 : s->slabThickness);   // = MAX(t, 0.0) incl. NaN
    p->useSlab = s->slabEnabled ? 1 : 0;

    BKToFloat3(s->clipPoint, clipPoint);
    p->clipPoint = BKF4(clipPoint);
    p->clipNormal = BKUnitNormalOrZ(s->clipNormal, normalize3f);
    p->useClip = s->clipPlaneEnabled ? 1 : 0;

    uint32_t planes = s->clipPlaneCount < BK_MAX_CLIP_PLANES ? s->clipPlaneCount : BK_MAX_CLIP_PLANES;
    for (uint32_t i = 0; i < planes; i++)
        p->clipPlanes[i] = bk_make_float4(s->clipPlanes[4 * i], s->clipPlanes[4 * i + 1], s->clipPlanes[4 * i + 2], s->clipPlanes[4 * i + 3]);
    p->clipPlaneCount = (int32_t)planes;

    p->stepSize = s->sampleSpacing > 0 ? (float)s->sampleSpacing : (float)(0.5 * s->minPixelSpacing);
    if (!(p->stepSize > 0)) p->stepSize = 0.5f;
    p->opacityUnitDistance = s->opacityUnitDistance > 0 ? s->opacityUnitDistance : 1.0f;
    p->valueScale = s->valueScale;
    p->valueOffset = s->valueOffset;
    p->tfMin = s->tfMin;
    p->tfMax = s->tfMax;
    p->windowCenter = s->windowCenter;
    p->windowWidth = s->windowWidth;
    p->outOfBoundsValue = isnan(s->missValue) ? s->outOfBoundsValue : s->missValue;
    p->ambient = s->ambient;
    p->diffuse = s->diffuse;
    p->specular = s->specular;
    p->specularPower = s->specularPower;
    p->width = width;
    p->height = height;
    p->mode = s->mode;
    p->projection = s->projection;
    p->shading = s->shading ? 1 : 0;
    p->manualFiltering = s->manualFiltering ? 1 : 0;
    p->useGeometry = s->useGeometry ? 1 : 0;

    // Colour scans + fusion (was -fillBlendParams:).
    p->colorVolume = s->colorVolume ? 1 : 0;
    p->colorUsesTable = s->colorUsesTable ? 1 : 0;
    p->blendOpacityUnitDistance = s->blendOpacityUnitDistance > 0 ? s->blendOpacityUnitDistance : 1.0f;
    p->blendProjection = BKFusionBlendProjection(s->mode);
    if (!s->useBlend) { p->useBlend = 0; return BKRenderParamsOK; }
    const double *b = s->blendPatientToVoxel;
    for (int c = 0; c < 3; c++)
        p->blendPatientToVoxelColumns[c] = bk_make_float4((float)b[c * 4 + 0], (float)b[c * 4 + 1], (float)b[c * 4 + 2], 0.0f);
    p->blendPatientToVoxelTranslation = bk_make_float4((float)b[12], (float)b[13], (float)b[14], 0.0f);
    p->blendVolumeSize = bk_make_float4((float)s->blendVolumeSize[0], (float)s->blendVolumeSize[1], (float)s->blendVolumeSize[2], 0.0f);
    p->blendValueScale = s->blendValueScale;
    p->blendValueOffset = s->blendValueOffset;
    p->blendTfMin = s->blendTfMin;
    p->blendTfMax = s->blendTfMax;
    p->blendColorVolume = s->blendColorVolume ? 1 : 0;
    p->useBlend = 1;
    return BKRenderParamsOK;
}

size_t BKRenderTFInsertPoint(BKRenderTFPoint *points, size_t count, size_t capacity, BKRenderTFPoint point)
{
    size_t i = 0;
    while (i < count && points[i].value < point.value) i++;
    if (i < count && points[i].value == point.value) {
        points[i] = point;
        return count;
    }
    if (count >= capacity) return count;
    memmove(points + i + 1, points + i, (count - i) * sizeof(BKRenderTFPoint));
    points[i] = point;
    return count + 1;
}

void BKRenderTFFromCLUT(const uint8_t red[256], const uint8_t green[256], const uint8_t blue[256],
                        float windowCenter, float windowWidth, const double *opacityXY, size_t count,
                        BKRenderTFPoint *color, size_t *colorCount, BKRenderTFPoint *opacity, size_t *opacityCount)
{
    float start = windowCenter - windowWidth / 2.0f;
    float end = windowCenter + windowWidth / 2.0f;
    size_t nc = 0, no = 0;
    // Colour: the FIRST 255 entries (0..254) spaced (end - start) / 254 apart (entry 255 is never used).
    for (int i = 0; i < 255; i++) {
        float value = start + (end - start) * (float)i / 254.0f;
        BKRenderTFPoint pt = { value, { red[i] / 255.0f, green[i] / 255.0f, blue[i] / 255.0f } };
        nc = BKRenderTFInsertPoint(color, nc, 255, pt);
    }
    // Opacity: same rules as -[VRView setOpacity:].
    size_t capacity = count + 2;
    if (count == 0 || opacityXY[0] != 0) {
        BKRenderTFPoint pt = { start, { 0.0f, 0.0f, 0.0f } };
        no = BKRenderTFInsertPoint(opacity, no, capacity, pt);
    }
    for (size_t i = 0; i < count; i++) {
        BKRenderTFPoint pt = { start + (float)(opacityXY[2 * i] / 256.0) * (end - start), { (float)opacityXY[2 * i + 1], 0.0f, 0.0f } };
        no = BKRenderTFInsertPoint(opacity, no, capacity, pt);
    }
    if (count == 0 || opacityXY[2 * (count - 1)] != 256) {
        BKRenderTFPoint pt = { end, { 1.0f, 0.0f, 0.0f } };
        no = BKRenderTFInsertPoint(opacity, no, capacity, pt);
    }
    *colorCount = nc;
    *opacityCount = no;
}
