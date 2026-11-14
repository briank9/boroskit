// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSurface: the settings block the CPU hands to the GPU for every surface
// extraction step, and the few numbers both sides must agree on.
//
// Why a macro (same trick as BKShaderTypes.h / BKMeshShaderTypes.h): the struct must
// exist twice, once in C (to fill it in) and once in the GPU program (to read it). The
// fields are written ONCE below; C expands them into a struct and the shader source
// pulls in the very same text as a string, so the two copies can never drift apart.
//
// Layout rules (so a future Vulkan backend can use the identical struct, "std430"):
//  - only 4-byte scalars and arrays of 4-byte scalars: no float3, no matrices, no bool,
//    no 8- or 16-bit types. Every field is therefore 4-byte aligned in C, Metal and
//    GLSL std430 alike, and there is no hidden padding anywhere.
//  - matrices are plain float arrays, column after column ("column-major"), exactly as
//    GLSL and simd store them.
//  - the total size is a multiple of 16 bytes (a unit test checks C == GPU size).
//  - NOTE for Vulkan: std140 (uniform buffers) would put every array element on a
//    16-byte stride and break this layout, so bind it as a std430 storage buffer (or a
//    std430 uniform via VK_EXT_scalar_block_layout). It is 336 bytes, too big for the
//    guaranteed 128-byte push-constant space, so use a small buffer, not push constants.

#ifndef BK_SURFACE_SHADER_TYPES_H
#define BK_SURFACE_SHADER_TYPES_H

#ifndef __METAL_VERSION__
#include <stdint.h>
typedef uint32_t bk_u32;
#endif

// Threads that work together on one row of the grid (one "threadgroup" in Metal,
// "workgroup" in Vulkan). Also the size of the shared-memory scan arrays. Must be even
// (two neighbouring voxels share one 32-bit word of the packed buffers).
#define BK_SURFACE_ROW_THREADS 256

// Largest Gaussian blur radius (in grid voxels) + 1: the blur weights for offsets
// 0...radius are stored, the other half is the mirror image.
#define BK_SURFACE_MAX_BLUR_WEIGHTS 32

// Largest number of triangles one grid cell can produce with our generated table
// (checked by BKSurfaceCaseTable() at start-up and by a unit test).
#define BK_SURFACE_MAX_CELL_TRIANGLES 5

// One case of the triangle table in GPU memory: 1 word triangle count + 3 edge numbers
// per triangle. The 12 edge descriptions follow the 256 cases (see BKSurfaceCore.h).
#define BK_SURFACE_CASE_STRIDE (1 + 3 * BK_SURFACE_MAX_CELL_TRIANGLES)
#define BK_SURFACE_EDGE_TABLE_OFFSET (256 * BK_SURFACE_CASE_STRIDE)
#define BK_SURFACE_TABLE_WORDS (BK_SURFACE_EDGE_TABLE_OFFSET + 12)

// Where the extraction kernels read the scan values from (BKSurfaceParams.source).
#define BK_SURFACE_SOURCE_TEXTURE 0   // straight from the volume texture (resolution 1, no smoothing)
#define BK_SURFACE_SOURCE_FIELD   1   // from the prepared 16-bit "field" buffer

// How grid points between voxels are sampled (BKSurfaceParams.sampling).
#define BK_SURFACE_SAMPLING_HARDWARE 0   // the GPU's built-in linear filter
#define BK_SURFACE_SAMPLING_MANUAL   1   // 8 reads + interpolation written out in the shader

#define BK_SURFACE_PARAM_FIELDS \
    float gridToOutput[16];      /* column-major 4x4: output point = M * (gx, gy, gz, 1) */ \
    float normalMatrix[12];      /* 3 columns of 4 floats (4th unused): turns grid-space gradients into output space (inverse-transpose) */ \
    float gridToVoxel[4];        /* x, y, z: voxel index = grid index * this (1/resolution, 1/resolution, 1); w unused */ \
    float volumeSizeInv[4];      /* 1/width, 1/height, 1/depth of the volume texture (normalised coordinates); w unused */ \
    float blurWeights[BK_SURFACE_MAX_BLUR_WEIGHTS]; /* Gaussian weights for offsets 0..blurRadius (sum of both sides = 1) */ \
    bk_u32 gridSize[4];          /* grid width, height, depth, and the row stride (width rounded up to even) */ \
    bk_u32 volumeSize[4];        /* volume texture width, height, depth; w unused */ \
    float thresholdSteps;        /* the threshold in stored 16-bit steps (0...65535 scale) */ \
    bk_u32 source;               /* BK_SURFACE_SOURCE_* */ \
    bk_u32 sampling;             /* BK_SURFACE_SAMPLING_* */ \
    bk_u32 flipWinding;          /* 1 if the output transform mirrors: swap two corners of every triangle */ \
    bk_u32 blurAxis;             /* 0 = x, 1 = y, 2 = z (blur step only) */ \
    bk_u32 blurRadius;           /* blur step only, <= BK_SURFACE_MAX_BLUR_WEIGHTS - 1 */ \
    bk_u32 reserved0; \
    bk_u32 reserved1;

#ifndef __METAL_VERSION__
typedef struct BKSurfaceParams {
    BK_SURFACE_PARAM_FIELDS
} BKSurfaceParams;
#endif

// Turns the field list into a string literal for the shader source (two levels so the
// macros inside, e.g. BK_SURFACE_MAX_BLUR_WEIGHTS, are expanded first).
#define BK_SURFACE_STRINGIFY_(...) #__VA_ARGS__
#define BK_SURFACE_STRINGIFY(...) BK_SURFACE_STRINGIFY_(__VA_ARGS__)

#endif
