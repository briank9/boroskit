// BorosKitVec: BKVec - BorosKit's own small vector types for the plain-C cores.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// What: 2/3/4-component vectors (double and float) as plain C structs, with the handful of
// operations the cores need (add, subtract, scale, dot, cross, length, normalize ...), all
// `static inline`, header only.
// Why (VULKAN-PORT-PLAN.md rule 1 / step R1, section 14): the plain-C cores (camera maths, box
// widget, crop box, mesh draw rules) must compile unchanged on Windows and Linux for the Vulkan
// engine. Apple's <simd/simd.h> does not exist there, and Horos' N3 types are LGPL. Standard C99
// only (math.h); no compiler vector extensions, so MSVC, GCC and clang all accept it.
// Apple glue (Objective-C / Metal) converts at the boundary with BKVecSimd.h.
//
// Layout: plain structs of doubles / floats, no padding tricks. These are CPU-side types; GPU
// structs keep their own std430 rules (bk_float4 etc. in the *ShaderTypes.h headers).

#ifndef BK_VEC_H
#define BK_VEC_H

#include <math.h>
#include <stddef.h>   // NULL, size_t (came in through simd before)

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { double x, y, z; } BKVec3d;
typedef struct { float x, y; } BKVec2f;
typedef struct { float x, y, z; } BKVec3f;
typedef struct { float x, y, z, w; } BKVec4f;

// --- BKVec3d ------------------------------------------------------------------------------------
static inline BKVec3d BKV3d(double x, double y, double z) { BKVec3d v = { x, y, z }; return v; }
static inline BKVec3d BKV3dAdd(BKVec3d a, BKVec3d b) { return BKV3d(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline BKVec3d BKV3dSub(BKVec3d a, BKVec3d b) { return BKV3d(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline BKVec3d BKV3dScale(BKVec3d a, double s) { return BKV3d(a.x * s, a.y * s, a.z * s); }
static inline BKVec3d BKV3dDiv(BKVec3d a, double s) { return BKV3d(a.x / s, a.y / s, a.z / s); }
static inline BKVec3d BKV3dNeg(BKVec3d a) { return BKV3d(-a.x, -a.y, -a.z); }
// a + b * s (the most common pattern: a point moved along a direction)
static inline BKVec3d BKV3dAddScaled(BKVec3d a, BKVec3d b, double s) { return BKV3d(a.x + b.x * s, a.y + b.y * s, a.z + b.z * s); }
static inline BKVec3d BKV3dMul(BKVec3d a, BKVec3d b) { return BKV3d(a.x * b.x, a.y * b.y, a.z * b.z); }
static inline double BKV3dDot(BKVec3d a, BKVec3d b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline BKVec3d BKV3dCross(BKVec3d a, BKVec3d b)
{
    return BKV3d(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}
static inline double BKV3dLength(BKVec3d a) { return sqrt(BKV3dDot(a, a)); }
static inline double BKV3dDistance(BKVec3d a, BKVec3d b) { return BKV3dLength(BKV3dSub(a, b)); }
// Unit vector; a zero vector gives NaNs (like simd_normalize). Use a "safe" variant where that matters.
static inline BKVec3d BKV3dNormalize(BKVec3d a) { return BKV3dDiv(a, BKV3dLength(a)); }
static inline BKVec3d BKV3dMin(BKVec3d a, BKVec3d b) { return BKV3d(fmin(a.x, b.x), fmin(a.y, b.y), fmin(a.z, b.z)); }
static inline BKVec3d BKV3dMax(BKVec3d a, BKVec3d b) { return BKV3d(fmax(a.x, b.x), fmax(a.y, b.y), fmax(a.z, b.z)); }
static inline double BKV3dComponent(BKVec3d a, int i) { return i == 0 ? a.x : (i == 1 ? a.y : a.z); }
static inline void BKV3dSetComponent(BKVec3d *a, int i, double value) { if (i == 0) a->x = value; else if (i == 1) a->y = value; else a->z = value; }

// --- BKVec3f / BKVec2f / BKVec4f ------------------------------------------------------------------
static inline BKVec2f BKV2f(float x, float y) { BKVec2f v = { x, y }; return v; }
static inline BKVec3f BKV3f(float x, float y, float z) { BKVec3f v = { x, y, z }; return v; }
static inline BKVec4f BKV4f(float x, float y, float z, float w) { BKVec4f v = { x, y, z, w }; return v; }
static inline BKVec3f BKV3fAdd(BKVec3f a, BKVec3f b) { return BKV3f(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline BKVec3f BKV3fSub(BKVec3f a, BKVec3f b) { return BKV3f(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline BKVec3f BKV3fScale(BKVec3f a, float s) { return BKV3f(a.x * s, a.y * s, a.z * s); }
static inline float BKV3fDot(BKVec3f a, BKVec3f b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline BKVec3f BKV3fCross(BKVec3f a, BKVec3f b)
{
    return BKV3f(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}
static inline BKVec3f BKV3fDiv(BKVec3f a, float s) { return BKV3f(a.x / s, a.y / s, a.z / s); }
static inline float BKV3fLength(BKVec3f a) { return sqrtf(BKV3fDot(a, a)); }
static inline BKVec3f BKV3fFromD(BKVec3d a) { return BKV3f((float)a.x, (float)a.y, (float)a.z); }
static inline BKVec3d BKV3dFromF(BKVec3f a) { return BKV3d(a.x, a.y, a.z); }

#ifdef __cplusplus
}
#endif

#endif
