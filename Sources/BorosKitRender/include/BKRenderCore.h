// BorosKitRender: BKRenderCore (plain C, the backend-neutral maths of the volume renderer)
// Original BorosKit code written for this project; contains no third-party code.
//
// What it is: the parts of volume rendering that do not depend on the graphics API:
//   - the transfer function (colour/opacity points -> value lookup, baking the 4096-entry
//     table the GPU reads, smallest/largest point);
//   - the running count of "not see-through" table entries used by empty-space skipping;
//   - the brick grid size for empty-space skipping;
//   - how a volume's real values are stored as 16-bit steps (scale/offset choice, the
//     rounding of each voxel, the "whole numbers?" check).
// Why plain C: the Metal classes (BKTransferFunction.m, BKVolumeRenderer.m,
// BKVolumeTexture.m) call these, and a future Vulkan backend calls the very same code, so
// both feed the GPU identical tables and identical 16-bit volumes.
//
// ---- PORTING NOTES (future Vulkan backend) -------------------------------------------
//  - C99 + libc only (math.h). No Foundation, Metal, simd or N3 types.
//  - Floating-point contraction: these functions are compiled by Apple clang with its
//    default (-ffp-contract=on, i.e. a*b+c inside one expression may become a fused
//    multiply-add on arm64). The golden references were made that way. A Windows/Linux
//    build should use the same setting with a compiler that honours it (clang), or the
//    baked table may differ in the last bit; the golden numbers file shows it at once.
//  - BKRenderQuantizeToSteps rounds to nearest with ties to even (rintf in the default
//    rounding mode), which is what Accelerate's vDSP_vfixru16 does on Apple machines; a
//    unit test checks the two agree, including exact .5 cases.
// ---------------------------------------------------------------------------------------

#ifndef BK_RENDER_CORE_H
#define BK_RENDER_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Transfer function -------------------------------------------------------------------
// One control point: a value (e.g. HU) and up to 3 components (r, g, b for colour points;
// only c[0] = opacity for opacity points). Lists are sorted by value, no duplicates.
typedef struct {
    float value;
    float c[3];
} BKRenderTFPoint;

// What: piecewise-linear lookup in a sorted point list, clamped to the first/last point
// outside the defined range; writes `components` floats to out. Nothing is written for an
// empty list (the caller's default stays).
void BKRenderTFEvaluate(const BKRenderTFPoint *points, size_t count, float value, float *out, int components);

// What: colour (r, g, b) and opacity at `value`; white and fully opaque where a list is empty.
void BKRenderTFGetRGBA(const BKRenderTFPoint *color, size_t colorCount,
                       const BKRenderTFPoint *opacity, size_t opacityCount, float value, float rgba[4]);

// What: smallest / largest value used by any point (0 when there are no points at all).
float BKRenderTFMinimumValue(const BKRenderTFPoint *color, size_t colorCount,
                             const BKRenderTFPoint *opacity, size_t opacityCount);
float BKRenderTFMaximumValue(const BKRenderTFPoint *color, size_t colorCount,
                             const BKRenderTFPoint *opacity, size_t opacityCount);

// What: samples the function at `count` evenly spaced values from the minimum to the
// maximum value (both included) into rgba (4 floats per entry). Why: the GPU reads this
// table (BK_TRANSFER_FUNCTION_ENTRIES entries) instead of the point lists.
void BKRenderTFBake(const BKRenderTFPoint *color, size_t colorCount,
                    const BKRenderTFPoint *opacity, size_t opacityCount, float *rgba, size_t count);

// What: counts[k] = how many of the first k table entries have opacity > 0 (counts has
// entries + 1 elements). Why: "is any entry between a and b visible?" becomes one
// subtraction on the GPU (empty-space skipping).
void BKRenderAlphaPrefixCount(const float *rgba, size_t entries, uint32_t *counts);

// ---- Empty-space skipping ----------------------------------------------------------------
// What: number of bricks (BK_BRICK_SIZE voxels per side; a partial brick counts) along
// x, y and z for a volume of the given size.
void BKRenderBrickGrid(uint32_t width, uint32_t height, uint32_t depth, uint32_t brickSize, uint32_t grid[3]);

// ---- 16-bit volume storage ---------------------------------------------------------------
// How real values are stored: real = steps / 65535 * valueScale + valueOffset.
typedef struct {
    float valueOffset;   // = the volume's lowest value
    float valueScale;    // = step * 65535
    float step;          // real-value size of one 16-bit step
    int lossless;        // 1 when rounding gives every voxel back exactly (whole numbers, range <= 65535)
} BKRenderQuantization;

// What: picks the storage for a volume whose values run from lo to hi; `integral` = 1
// when every voxel is a whole number. The range is always spread over all 65,536 steps
// (see BKVolumeTexture.h for why).
BKRenderQuantization BKRenderQuantizationForRange(float lo, float hi, int integral);

// What: 1 if every value is a whole number (stops at the first that is not).
int BKRenderAllIntegral(const float *values, size_t count);

// What: converts real values to 16-bit steps: (v - lo) / step, clamped to 0...65535 and
// rounded to nearest (ties to even). The arithmetic is (v + (-lo)) * (1 / step) in float,
// exactly as the Metal upload does it.
void BKRenderQuantizeToSteps(const float *values, size_t count, BKRenderQuantization q, uint16_t *steps);

#ifdef __cplusplus
}
#endif

#endif
