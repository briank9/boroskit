// BorosKitMeshRender: plain-C rules for face culling, textured surfaces and point sprites.
// Original BorosKit code written for this project; contains no third-party code.
// See include/BKMeshDrawCore.h for what each function does and the porting notes.

#include "BKMeshDrawCore.h"
#include <math.h>
#include <string.h>   // memset

// Small RGBA helpers (component-wise, same order of operations as before).
static BKVec4f BKMeshV4Scale(BKVec4f a, float s) { return BKV4f(a.x * s, a.y * s, a.z * s, a.w * s); }
static BKVec4f BKMeshV4Add(BKVec4f a, BKVec4f b) { return BKV4f(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w); }
static float BKMeshClamp01(float v) { return fminf(fmaxf(v, 0.0f), 1.0f); }

int32_t BKMeshTriangleIsFrontFacing(BKVec2f a, BKVec2f b, BKVec2f c)
{
    // Twice the signed area (cross product of two edges): > 0 = anticlockwise with y up.
    float area2 = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);
    return area2 > 0.0f ? 1 : 0;
}

int32_t BKMeshTriangleIsCulled(int32_t cullMode, BKVec2f a, BKVec2f b, BKVec2f c)
{
    if (cullMode == BKMeshCullNone) return 0;
    float area2 = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);
    if (area2 == 0.0f) return 1;
    int32_t front = area2 > 0.0f;
    return cullMode == BKMeshCullBack ? !front : front;
}

int32_t BKMeshTextureExpandToRGBA8(const uint8_t *src, uint32_t components, size_t count, uint8_t *dst)
{
    if (src == NULL || dst == NULL || components < 1 || components > 4) return 0;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *s = src + i * components;
        uint8_t *d = dst + i * 4;
        switch (components) {
            case 1: d[0] = d[1] = d[2] = s[0]; d[3] = 255; break;
            case 2: d[0] = d[1] = d[2] = s[0]; d[3] = s[1]; break;
            case 3: d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255; break;
            default: d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]; break;
        }
    }
    return 1;
}

// What: a texel index made valid by the wrap rule (repeat: modulo; clamp: nearest edge).
static int32_t BKMeshWrapIndex(int32_t i, uint32_t size, int32_t wrap)
{
    int32_t n = (int32_t)size;
    if (wrap == BKMeshTextureWrapRepeat) {
        int32_t m = i % n;
        return m < 0 ? m + n : m;
    }
    return i < 0 ? 0 : (i >= n ? n - 1 : i);
}

// What: one texel as RGBA 0..1.
static BKVec4f BKMeshTexel(const uint8_t *rgba, uint32_t width, int32_t x, int32_t y)
{
    const uint8_t *p = rgba + 4 * ((size_t)y * width + (size_t)x);
    return BKV4f(p[0] / 255.0f, p[1] / 255.0f, p[2] / 255.0f, p[3] / 255.0f);
}

BKVec4f BKMeshTextureSample(const uint8_t *rgba, uint32_t width, uint32_t height,
                                float s, float t, int32_t linear, int32_t wrap)
{
    if (rgba == NULL || width == 0 || height == 0) return BKV4f(0, 0, 0, 0);
    if (wrap != BKMeshTextureWrapRepeat) {
        // Clamp to the edge: positions outside 0..1 act like the nearest edge position.
        s = fminf(fmaxf(s, 0.0f), 1.0f);
        t = fminf(fmaxf(t, 0.0f), 1.0f);
    }
    float u = s * (float)width, v = t * (float)height;
    if (!linear) {
        int32_t x = BKMeshWrapIndex((int32_t)floorf(u), width, wrap);
        int32_t y = BKMeshWrapIndex((int32_t)floorf(v), height, wrap);
        return BKMeshTexel(rgba, width, x, y);
    }
    // Texel centres sit at half-integer positions: blend the four around (u, v).
    u -= 0.5f;
    v -= 0.5f;
    float fx = floorf(u), fy = floorf(v);
    float ax = u - fx, ay = v - fy;
    int32_t x0 = BKMeshWrapIndex((int32_t)fx, width, wrap), x1 = BKMeshWrapIndex((int32_t)fx + 1, width, wrap);
    int32_t y0 = BKMeshWrapIndex((int32_t)fy, height, wrap), y1 = BKMeshWrapIndex((int32_t)fy + 1, height, wrap);
    BKVec4f top = BKMeshV4Add(BKMeshV4Scale(BKMeshTexel(rgba, width, x0, y0), 1.0f - ax), BKMeshV4Scale(BKMeshTexel(rgba, width, x1, y0), ax));
    BKVec4f bottom = BKMeshV4Add(BKMeshV4Scale(BKMeshTexel(rgba, width, x0, y1), 1.0f - ax), BKMeshV4Scale(BKMeshTexel(rgba, width, x1, y1), ax));
    return BKMeshV4Add(BKMeshV4Scale(top, 1.0f - ay), BKMeshV4Scale(bottom, ay));
}

BKVec4f BKMeshTextureModulate(BKVec4f litColor, BKVec4f texel)
{
    BKVec4f c = BKV4f(BKMeshClamp01(litColor.x) * texel.x, BKMeshClamp01(litColor.y) * texel.y,
                      BKMeshClamp01(litColor.z) * texel.z, BKMeshClamp01(litColor.w) * texel.w);
    return BKV4f(c.x * c.w, c.y * c.w, c.z * c.w, c.w);
}

void BKMeshPointSquare(float cx, float cy, float pointSize, BKVec2f *min, BKVec2f *max)
{
    float h = 0.5f * fmaxf(pointSize, 0.0f);
    if (min) *min = BKV2f(cx - h, cy - h);
    if (max) *max = BKV2f(cx + h, cy + h);
}

// ---- GPU settings block (2026-11-25, agent "vulkan-engine", step M3) -----------------------------------
// What: everything BKMeshUniforms holds, filled in plain C (see the header). Why: the Objective-C renderer
// used to compute the camera frame, view sizes, depth range and normal matrix itself with Apple simd; a
// Vulkan engine could not reuse that and its copy would drift. Now Metal and Vulkan call these functions.
// Written from the maths (orthonormal frame by cross products; inverse-transpose by cofactors).


// pi as a literal (M_PI is not part of strict C99); (float) of it is the same value M_PI gave.
#define BK_MESH_PI 3.14159265358979323846

int32_t BKMeshCameraAxes(const BKMeshCamera *camera, BKVec3d *right, BKVec3d *up, BKVec3d *forward)
{
    // Same two checks (and thresholds) as the renderer had: a zero direction, and an up vector that is
    // parallel to the direction (their cross product, before normalising, nearly zero). Written as
    // "not >=" so a NaN camera is refused too (the old float code let it through and drew nothing useful).
    double dirLength = BKV3dLength(camera->direction);
    if (!(dirLength >= 1e-6)) return BKMeshCameraZeroDirection;
    BKVec3d f = BKV3dDiv(camera->direction, dirLength);
    if (!(BKV3dLength(BKV3dCross(f, camera->up)) >= 1e-6)) return BKMeshCameraUpParallel;
    // right = unit(forward x up): exactly BKCameraMath's BKCameraRight (same operations, same order; the
    // plain-C core tests check the two give identical bits). It is not called directly because a C file of
    // this SwiftPM target cannot include BorosKitRender's headers: with modules on, that imports the whole
    // Objective-C BorosKitRender module, which a C file cannot load.
    BKVec3d r = BKV3dNormalize(BKV3dCross(f, camera->up));
    if (right) *right = r;
    if (up) *up = BKV3dCross(r, f);     // unit: r and f are unit and perpendicular
    if (forward) *forward = f;
    return BKMeshCameraOK;
}

void BKMeshCameraHalfSize(const BKMeshCamera *camera, float areaWidth, float areaHeight,
                          float *halfWidth, float *halfHeight)
{
    float hw, hh;
    if (camera->projection == 1) {
        // Vertical angle given, horizontal follows the drawing area (as in the volume renderer).
        hh = tanf(0.5f * (float)camera->fieldOfView * (float)BK_MESH_PI / 180.0f);
        hw = hh * (areaWidth / areaHeight);
    } else {
        hw = 0.5f * (float)camera->viewWidth;
        hh = 0.5f * (float)camera->viewHeight;
    }
    if (halfWidth) *halfWidth = hw;
    if (halfHeight) *halfHeight = hh;
}

void BKMeshDepthRange(float nearest, float farthest, int32_t perspective, float *nearDistance, float *farDistance)
{
    // Comparisons written like Foundation's MAX(a, b) = a < b ? b : a, which the renderer used before.
    float extent = farthest - nearest;
    float margin = 1.0f + 0.01f * (extent < 0.0f ? 0.0f : extent);
    float n = nearest - margin, f = farthest + margin;
    if (perspective) {
        if (f < 1e-3f) f = 1e-3f;
        if (n < f * 1e-4f) n = f * 1e-4f;
    }
    *nearDistance = n;
    *farDistance = f;
}

int32_t BKMeshUniformsFill(BKMeshUniforms *u, const BKMeshCamera *camera, float areaWidth, float areaHeight,
                           float nearDistance, float farDistance, BKMeshLighting lighting)
{
    memset(u, 0, sizeof *u);
    BKVec3d r, up, f;
    int32_t status = BKMeshCameraAxes(camera, &r, &up, &f);
    if (status != BKMeshCameraOK) return status;
    // Vectors go to the GPU as float4 with w = 1 for the point and 0 for directions (rounded once here).
    u->cameraPosition = bk_make_float4((float)camera->position.x, (float)camera->position.y, (float)camera->position.z, 1.0f);
    u->cameraRight = bk_make_float4((float)r.x, (float)r.y, (float)r.z, 0.0f);
    u->cameraUp = bk_make_float4((float)up.x, (float)up.y, (float)up.z, 0.0f);
    u->cameraForward = bk_make_float4((float)f.x, (float)f.y, (float)f.z, 0.0f);
    BKMeshCameraHalfSize(camera, areaWidth, areaHeight, &u->halfWidth, &u->halfHeight);
    if (!(u->halfWidth > 0) || !(u->halfHeight > 0)) {
        memset(u, 0, sizeof *u);
        return BKMeshCameraZeroFieldOfView;
    }
    u->nearDistance = nearDistance;
    u->farDistance = farDistance;
    u->ambient = lighting.ambient;
    u->diffuse = lighting.diffuse;
    u->specular = lighting.specular;
    u->specularPower = lighting.specularPower;
    u->projection = camera->projection;
    u->lit = 1;
    u->viewportWidth = areaWidth;
    u->viewportHeight = areaHeight;
    return BKMeshCameraOK;
}

void BKMeshUniformsSetModel(BKMeshUniforms *u, const float model[16], int32_t withNormalMatrix)
{
    for (int c = 0; c < 4; c++)
        u->model.columns[c] = bk_make_float4(model[c * 4 + 0], model[c * 4 + 1], model[c * 4 + 2], model[c * 4 + 3]);
    // a(r, c) = row r, column c of the model's 3x3 (linear) part.
#define BK_A(r, c) ((double)model[(c) * 4 + (r)])
    double n[3][3] = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };   // n[r][c]
    if (withNormalMatrix) {
        // Inverse-transpose = cofactor matrix / determinant (adjugate rule written out).
        double cof[3][3];
        cof[0][0] =   BK_A(1, 1) * BK_A(2, 2) - BK_A(1, 2) * BK_A(2, 1);
        cof[0][1] = -(BK_A(1, 0) * BK_A(2, 2) - BK_A(1, 2) * BK_A(2, 0));
        cof[0][2] =   BK_A(1, 0) * BK_A(2, 1) - BK_A(1, 1) * BK_A(2, 0);
        cof[1][0] = -(BK_A(0, 1) * BK_A(2, 2) - BK_A(0, 2) * BK_A(2, 1));
        cof[1][1] =   BK_A(0, 0) * BK_A(2, 2) - BK_A(0, 2) * BK_A(2, 0);
        cof[1][2] = -(BK_A(0, 0) * BK_A(2, 1) - BK_A(0, 1) * BK_A(2, 0));
        cof[2][0] =   BK_A(0, 1) * BK_A(1, 2) - BK_A(0, 2) * BK_A(1, 1);
        cof[2][1] = -(BK_A(0, 0) * BK_A(1, 2) - BK_A(0, 2) * BK_A(1, 0));
        cof[2][2] =   BK_A(0, 0) * BK_A(1, 1) - BK_A(0, 1) * BK_A(1, 0);
        double det = BK_A(0, 0) * cof[0][0] + BK_A(0, 1) * cof[0][1] + BK_A(0, 2) * cof[0][2];
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++)
                n[r][c] = det != 0 ? cof[r][c] / det : BK_A(r, c);   // singular: the 3x3 part as it is
    }
#undef BK_A
    for (int c = 0; c < 3; c++)
        u->normalMatrix.columns[c] = bk_make_float4((float)n[0][c], (float)n[1][c], (float)n[2][c], 0.0f);
    u->normalMatrix.columns[3] = bk_make_float4(0.0f, 0.0f, 0.0f, 1.0f);
}

void BKMeshUniformsSetColor(BKMeshUniforms *u, float r, float g, float b, float opacity)
{
    // MIN(MAX(o, 0), 1) with Foundation's definitions: MAX(a, b) = a < b ? b : a, MIN(a, b) = a < b ? a : b.
    float o = opacity < 0.0f ? 0.0f : opacity;
    o = o < 1.0f ? o : 1.0f;
    u->color = bk_make_float4(r, g, b, o);
}
