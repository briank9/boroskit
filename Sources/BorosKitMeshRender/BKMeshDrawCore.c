// BorosKitMeshRender: plain-C rules for face culling, textured surfaces and point sprites.
// Original BorosKit code written for this project; contains no third-party code.
// See include/BKMeshDrawCore.h for what each function does and the porting notes.

#include "BKMeshDrawCore.h"
#include <math.h>

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
