// Copyright (c) 2026 Serdal Kocak. All rights reserved.
//
// BorosKitSurface: the backend-neutral "brain" of surface extraction, in plain C.
//
// What it is: everything about building a bone / soft-tissue surface from a scan that
// does NOT depend on the graphics chip's programming interface:
//   - the marching-cubes triangle table, GENERATED here from first principles (no
//     table copied from anywhere; see BKSurfaceCore.c for the derivation);
//   - the plan: grid size for a given resolution, blur weights, buffer sizes, memory
//     checks and the numbers handed to the GPU (BKSurfaceParams);
//   - the "row prefix sum" between the two GPU passes;
//   - a slow but simple CPU reference extractor that produces exactly the same mesh as
//     the GPU (same vertex order, same triangles), used by the tests to prove the GPU
//     result right, and by a future Vulkan backend to prove ITS result right.
//
// Why plain C: the Metal backend (BKSurfaceExtractor.m) and a future Vulkan backend
// share this file unchanged. No Foundation, Metal or Apple-only types are used here.
//
// Conventions shared by all functions:
//   - "grid": the points where the scan is sampled for the surface. Grid point (gx,gy,gz)
//     sits at voxel index (gx/resolution, gy/resolution, gz): resolution thins the grid
//     in X and Y only (like the old Horos/VTK "resolution" setting), Z stays native.
//   - "inside" = value >= threshold (bone is brighter than its surroundings).
//   - matrices are 4x4, column-major (element row r, column c at m[c*4 + r]), and act on
//     column vectors: out = M * (x, y, z, 1).
//   - each grid point "owns" the three edges leaving it toward +x, +y and +z; a surface
//     vertex lies on an owned edge where the value crosses the threshold. Vertices are
//     numbered row by row (rows ordered y fastest, then z), within a row by x, and at
//     one grid point in edge order x, y, z. GPU and CPU reference follow this exactly.

#ifndef BK_SURFACE_CORE_H
#define BK_SURFACE_CORE_H

#include <stdint.h>
#include <stddef.h>
#include "BKSurfaceShaderTypes.h"

#ifdef __cplusplus
extern "C" {
#endif

// ---- Status codes (BKSurfaceExtractor turns them into NSError codes 1:1) ------------
typedef enum {
    BKSurfaceStatusOK = 0,
    BKSurfaceStatusInvalidInput = 1,     // bad sizes, resolution, smoothing, NaN threshold, singular transform
    BKSurfaceStatusTooLarge = 2,         // grid or result too big for the GPU buffers / memory budget
    BKSurfaceStatusOutOfMemory = 3,      // an allocation failed
    BKSurfaceStatusGPUFailed = 4,        // the GPU reported an error (backend sets this)
} BKSurfaceStatus;

// A short plain-language explanation of a status (static text, never NULL).
const char *BKSurfaceStatusMessage(BKSurfaceStatus status);

// ---- Marching-cubes table --------------------------------------------------------------
// Cube corner numbering: corner c sits at offset (c & 1, (c >> 1) & 1, (c >> 2) & 1) from
// the cell's first grid point. A cell's "case" has bit c set when corner c is inside.
//
// Edge numbering: edges 0-3 run along x, 4-7 along y, 8-11 along z. Edge 4*axis + j
// starts at the j-th corner (in increasing number) whose bit `axis` is 0.
typedef struct {
    uint8_t corner0, corner1;   // the edge's two corners (corner1 = corner0 + step along axis)
    uint8_t axis;               // 0 = x, 1 = y, 2 = z
    uint8_t dx, dy, dz;         // offset of the grid point that OWNS the edge (= corner0's offset)
} BKSurfaceEdge;

// The 12 cube edges (static data, derived from the numbering above).
const BKSurfaceEdge *BKSurfaceEdges(void);

// One of the 256 cases: up to BK_SURFACE_MAX_CELL_TRIANGLES triangles, each given by the
// three cube edges its corners lie on. Triangles are wound anticlockwise seen from
// OUTSIDE (from the low-value side) in grid coordinates.
typedef struct {
    uint8_t triangleCount;
    uint8_t edges[BK_SURFACE_MAX_CELL_TRIANGLES * 3];
} BKSurfaceCase;

// The generated table (built once on first use; thread-safe to call). Index = case.
const BKSurfaceCase *BKSurfaceCaseTable(void);

// The table in the layout the GPU reads (BK_SURFACE_TABLE_WORDS uint32 words, see
// BKSurfaceShaderTypes.h): per case the count then 3*MAX edge numbers, then the 12 edge
// descriptions packed as dx | dy<<8 | dz<<16 | axis<<24.
void BKSurfaceFillGPUTable(uint32_t words[BK_SURFACE_TABLE_WORDS]);

// ---- Planning ------------------------------------------------------------------------------
typedef struct {
    uint32_t volumeWidth, volumeHeight, volumeDepth;   // voxels of the scan
    float resolution;            // (0, 1]: grid spacing in X and Y = 1/resolution voxels
    float smoothingSigma;        // Gaussian pre-blur, in voxels of the ORIGINAL scan; 0 = off; max 10
    double voxelToOutput[16];    // voxel index -> output coordinates (usually patient mm)
    uint32_t sampling;           // BK_SURFACE_SAMPLING_*
    uint64_t maxBufferBytes;     // largest single GPU buffer allowed (0 = no limit)
    uint64_t memoryBudgetBytes;  // all temporaries together must fit in this (0 = no limit)
} BKSurfacePlanRequest;

typedef struct {
    uint32_t gridWidth, gridHeight, gridDepth;
    uint32_t rowStride;          // gridWidth rounded up to even (two 16-bit values per 32-bit word)
    uint32_t rowCount;           // gridHeight * gridDepth: one GPU threadgroup per row
    int usesField;               // 1: a 16-bit field buffer is prepared (resolution < 1 or smoothing)
    int blurs;                   // 1: smoothing passes run (needs a second field buffer)
    uint32_t blurRadius[3];      // per axis, 0 = that axis is not blurred
    float blurWeights[3][BK_SURFACE_MAX_BLUR_WEIGHTS];
    uint64_t fieldBytes;         // one 16-bit field buffer (0 when !usesField)
    uint64_t packedBytes;        // the per-grid-point 16-bit "edge mask + vertex prefix" buffer
    uint64_t rowTableBytes;      // one per-row uint32 table (two are used: vertices, triangles)
    uint64_t peakTemporaryBytes; // largest amount of temporary GPU memory alive at once (before the output)
    BKSurfaceParams params;      // ready for the GPU except thresholdSteps / blur fields
} BKSurfacePlan;

// Checks the request and fills the plan. Never allocates.
BKSurfaceStatus BKSurfacePlanMake(const BKSurfacePlanRequest *request, BKSurfacePlan *plan);

// Real-value threshold (e.g. HU) -> stored 16-bit steps, for a volume whose real value
// is texel(0..1) * valueScale + valueOffset. Returns NaN for an invalid input.
float BKSurfaceThresholdToSteps(float threshold, float valueScale, float valueOffset);

// Fills params.blurAxis/blurRadius/blurWeights for one blur step along `axis`.
void BKSurfacePlanSetBlurAxis(const BKSurfacePlan *plan, uint32_t axis, BKSurfaceParams *params);

// Grid -> output transform, its normal matrix and whether it mirrors, from a voxel ->
// output matrix and the grid -> voxel scale. Returns 0 if the matrix is singular.
// gridToOutput: column-major 4x4; normalMatrix: 3 columns of 4 (see BKSurfaceParams).
int BKSurfaceGridTransform(const double voxelToOutput[16], const double gridToVoxel[3],
                           float gridToOutput[16], float normalMatrix[12], uint32_t *mirrors);

// ---- Between the GPU passes --------------------------------------------------------------
// Turns per-row counts into per-row starting positions IN PLACE (exclusive prefix sum)
// and returns the total. Fails (returns UINT64_MAX) if the total does not fit in 32 bits,
// because vertex numbers and index positions are 32-bit on the GPU.
uint64_t BKSurfaceExclusiveScan(uint32_t *values, size_t count);

// Bytes of the output buffers for a mesh: vertices + normals (16 bytes each: x, y, z +
// one unused float, which is also the memory layout of simd_float3) + 3 uint32 per triangle.
uint64_t BKSurfaceOutputBytes(uint64_t vertexCount, uint64_t triangleCount);

// ---- CPU reference -------------------------------------------------------------------------
// A mesh as plain arrays (allocated with malloc; free with BKSurfaceMeshDataFree).
typedef struct {
    float *positions;      // 4 floats per vertex (x, y, z, unused)
    float *normals;        // 4 floats per vertex, unit length (0 if the gradient vanished)
    uint32_t *indices;     // 3 per triangle
    uint64_t vertexCount, triangleCount;
} BKSurfaceMeshData;

void BKSurfaceMeshDataFree(BKSurfaceMeshData *mesh);

// The reference extractor: marching cubes on a grid of values (index x + w*(y + h*z)),
// same table, same edge ownership, same vertex numbering, same interpolation and
// gradient normals as the GPU kernels, in double precision, one thread. Output is in
// gridToOutput coordinates (voxelToOutput composed with no resampling: pass the voxel
// -> output matrix if the grid IS the voxel grid). Use it on small grids only.
BKSurfaceStatus BKSurfaceReferenceExtract(const float *values, uint32_t width, uint32_t height, uint32_t depth,
                                          float threshold, const double gridToOutput[16],
                                          BKSurfaceMeshData *out);

#ifdef __cplusplus
}
#endif

#endif
