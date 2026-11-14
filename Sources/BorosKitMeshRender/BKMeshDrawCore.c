// BorosKitMeshRender: plain-C rules for face culling, textured surfaces and point sprites.
// Original BorosKit code written for this project; contains no third-party code.
// See include/BKMeshDrawCore.h for what each function does and the porting notes.

#include "BKMeshDrawCore.h"
#include <math.h>

int32_t BKMeshTriangleIsFrontFacing(simd_float2 a, simd_float2 b, simd_float2 c)
{
    // Twice the signed area (cross product of two edges): > 0 = anticlockwise with y up.
    float area2 = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);
    return area2 > 0.0f ? 1 : 0;
}

int32_t BKMeshTriangleIsCulled(int32_t cullMode, simd_float2 a, simd_float2 b, simd_float2 c)
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
static simd_float4 BKMeshTexel(const uint8_t *rgba, uint32_t width, int32_t x, int32_t y)
{
    const uint8_t *p = rgba + 4 * ((size_t)y * width + (size_t)x);
    return simd_make_float4(p[0], p[1], p[2], p[3]) / 255.0f;
}

simd_float4 BKMeshTextureSample(const uint8_t *rgba, uint32_t width, uint32_t height,
                                float s, float t, int32_t linear, int32_t wrap)
{
    if (rgba == NULL || width == 0 || height == 0) return simd_make_float4(0, 0, 0, 0);
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
    simd_float4 top = BKMeshTexel(rgba, width, x0, y0) * (1.0f - ax) + BKMeshTexel(rgba, width, x1, y0) * ax;
    simd_float4 bottom = BKMeshTexel(rgba, width, x0, y1) * (1.0f - ax) + BKMeshTexel(rgba, width, x1, y1) * ax;
    return top * (1.0f - ay) + bottom * ay;
}

simd_float4 BKMeshTextureModulate(simd_float4 litColor, simd_float4 texel)
{
    simd_float4 c = simd_clamp(litColor, simd_make_float4(0, 0, 0, 0), simd_make_float4(1, 1, 1, 1)) * texel;
    return simd_make_float4(c.x * c.w, c.y * c.w, c.z * c.w, c.w);
}

void BKMeshPointSquare(float cx, float cy, float pointSize, simd_float2 *min, simd_float2 *max)
{
    float h = 0.5f * fmaxf(pointSize, 0.0f);
    if (min) *min = simd_make_float2(cx - h, cy - h);
    if (max) *max = simd_make_float2(cx + h, cy + h);
}
