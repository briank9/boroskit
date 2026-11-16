// BorosKitRender: the curved-MPR (panorex) and cross-section picture generator - plain C core shared by
// the CPU reference and the GPU kernel (BKCurvedReformat.m).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. One compute thread per output pixel, a std430 parameter block
//   made of 32-bit scalars only (BKReformatParams below - no vectors, no bool, no padding surprises),
//   per-column frames in a buffer of float4 (3 per column), the scan read with exact texel reads
//   (Metal texture.read == GLSL texelFetch on a usampler3D / R16_UNORM image; no hardware filtering is
//   relied on), output = one float per pixel in a buffer. Thread group 8 x 8 (GLSL local_size_x = 8,
//   local_size_y = 8). The CPU reference BKReformatComputeRows() in BKCurvedReformatCore.c is the golden
//   output a Vulkan port must reproduce.
// - Pure C99, <stdint.h>, <math.h>; no Objective-C, Metal, Apple simd or Horos (LGPL) types.
// - Written from the definition of the picture (below). Matching the classic engine on purpose:
//   nearest = index (int)(coordinate + 0.5) (cut toward zero); cubic = Catmull-Rom (the standard
//   cubic convolution with a = -0.5) on the 4 x 4 x 4 neighbours; any neighbour outside the scan
//   counts as outOfBoundsValue; the radiograph projection is Boros' own Beer-Lambert formula
//   (CPRRadiographStrength). No code was copied.
//
// Plain language: a panorex is many thin "columns" side by side along the curve. For each column we know
// where its middle is inside the scan, which way is down the picture and which way goes through the slab.
// Each picture pixel is then found by stepping down the column, and the slab thickness is collapsed into
// one value (brightest, darkest, average, or a simulated X-ray). A cross-section picture is the same with
// straight, parallel columns.
//
// Definition: for column x (0..width-1), row y (0..height-1), slab step z (0..depth-1):
//   voxel = base[x] + row[x] * (y - rowCentre) + slab[x] * (z - slabCentre)      (voxel index space)
//   value(x, y) = projection over z of interpolate(scan, voxel)
// with rowCentre = (height-1)/2 and slabCentre = (depth-1)/2 as the curved MPR uses them.

#ifndef BK_CURVED_REFORMAT_CORE_H
#define BK_CURVED_REFORMAT_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    BKReformatNearest = 0,
    BKReformatLinear = 1,
    BKReformatCubic = 2,
} BKReformatInterpolation;

typedef enum {
    BKReformatFirstSample = 0,   // no projection: the first slab sample (callers wanting every plane draw
                                 // them one at a time with depth 1)
    BKReformatMIP = 1,
    BKReformatMinIP = 2,
    BKReformatMean = 3,
    BKReformatRadiograph = 4,
} BKReformatProjection;

// The parameter block, written ONCE as a field list so C, the Metal kernel source and a future
// GLSL/HLSL port use the identical layout (32-bit scalars only = std430/std140 safe).
#define BK_REFORMAT_PARAMS_FIELDS \
    uint32_t width;            /* output columns */ \
    uint32_t height;           /* output rows */ \
    uint32_t depth;            /* samples through the slab (>= 1) */ \
    int32_t interpolation;     /* BKReformatInterpolation */ \
    int32_t projection;        /* BKReformatProjection */ \
    float outOfBoundsValue;    /* value of any voxel outside the scan */ \
    float radiographK;         /* radiograph: strength * 0.0195 / 1000 * mm between slab samples */ \
    float valueScale;          /* GPU texel (0..1) -> value: texel * valueScale + valueOffset */ \
    float valueOffset; \
    uint32_t volumeWide;       /* scan size in voxels */ \
    uint32_t volumeHigh; \
    uint32_t volumeDeep; \
    float rowCentre;           /* (height-1)/2 */ \
    float slabCentre;          /* (depth-1)/2 */ \
    float reserved0; \
    float reserved1;

typedef struct BKReformatParams {
    BK_REFORMAT_PARAMS_FIELDS
} BKReformatParams;

// What: one column's frame, 3 x float4 in memory (w unused): the voxel position of the column's middle
// (row rowCentre, slab slabCentre), and the voxel step for one row down and one slab sample.
typedef struct {
    float base[4];
    float row[4];
    float slab[4];
} BKReformatFrame;

// What: radiographK for a slab sampled every `slabStepMm` mm (strength 0.75 = Boros' default
// CPRRadiographStrength; <= 0 means 0.75).
float BKReformatRadiographK(double strength, double slabStepMm);

// What: CPU reference - computes output rows [rowStart, rowEnd) into `out` (width * height floats,
// row-major, row 0 first) from `voxels` (volumeWide * volumeHigh * volumeDeep floats, x fastest).
// Deterministic; rows are independent, so callers may split rows across threads (one parallel_for).
// valueScale / valueOffset are ignored here (the voxels are real values).
void BKReformatComputeRows(const BKReformatParams *params, const BKReformatFrame *frames, const float *voxels,
                           uint32_t rowStart, uint32_t rowEnd, float *out);

// What: one interpolated value at voxel coordinate (x, y, z) (CPU reference of the kernel's sampling).
float BKReformatSample(const BKReformatParams *params, const float *voxels, double x, double y, double z);

#ifdef __cplusplus
}
#endif

#endif
