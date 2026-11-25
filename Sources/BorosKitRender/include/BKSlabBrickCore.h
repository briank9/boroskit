// BorosKitRender: slab pictures of scans too big for one GPU 3D texture - "bricks" (plain C).
// Boros 6 (2026-11-24, mpr-colour).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// What: a scan with more voxels on one side than the GPU's largest 3D texture (Metal: 2048 on every Apple GPU;
// Vulkan: maxImageDimension3D, which the specification only guarantees to be 256) is cut into bricks. Each brick
// is its own 3D texture holding a box of the scan plus a 2-voxel MARGIN of its neighbours. Every slab picture is
// then drawn brick by brick at FULL resolution and the brick pictures are put together on the CPU:
//  - MIP / MinIP: the highest / lowest value over the bricks the pixel's ray actually crosses;
//  - mean: the bricks' means weighted by the length of the ray inside each brick (inside the slab);
//  - VR colour (composite): front-to-back "over" in an order that is correct for every ray (see the rule below);
//  - colour (RGB) scans in MIP / MinIP / mean: the same per channel.
// A pixel whose ray crosses no brick gets the scan's outside value (as the single-texture picture).
//
// RULES (checked in Tests/BorosKitRenderTests/BKSlabBrickCoreTests.m):
//  1. Brick plan per axis: an axis of d voxels that fits (d <= maxSide) is one brick. Otherwise it gets
//     n = ceil((d - 1) / (maxSide - 1 - 2 * margin)) bricks; brick b's CORE runs from voxel s_b to s_(b+1) with
//     s_b = round(b * (d - 1) / n) (neighbouring cores share their boundary plane, so together they cover the
//     scan's whole voxel-centre box [0, d - 1] with no gap and no overlap); its TEXTURE holds voxels
//     s_b - margin .. s_(b+1) + margin (clamped to the scan), never more than maxSide. The bricks of the three
//     axes are combined (x fastest, then y, then z).
//  2. The margin: rays are clipped to the core box, but trilinear filtering (1 voxel) and the shading gradient
//     (central differences, 1 more voxel) read neighbours - margin 2 makes every sample inside a core identical
//     to the same sample in one big texture.
//  3. Ray weight of a brick for picture pixel (x, y): the length (mm) of the pixel's ray inside the brick's core
//     box AND inside the slab [-thickness / 2, +thickness / 2] around the picture plane (for thickness 0: 1 if
//     the pixel's point lies in the core box, else 0). Weight 0 = the brick does not count for that pixel.
//  4. Visiting order for VR colour: sort the bricks by their grid index along each axis, taken in the direction
//     the rays travel along that axis (reversed for a negative direction component), z major, then y, then x.
//     All rays of a slab picture are parallel, so along every ray the bricks it crosses come in that order.
//  5. "Over": colour = colour + (1 - alpha) * brickColour, alpha = alpha + (1 - alpha) * brickAlpha
//     (premultiplied colours, as the renderer writes them).
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C99 (BKVec.h, <stdint.h>, <stddef.h>, <math.h>); no Objective-C, Metal, VTK, OpenGL, Apple simd or
//   LGPL types. Check: clang -std=c99 -pedantic -Werror -fno-modules.
// - VULKAN: read VkPhysicalDeviceLimits.maxImageDimension3D and pass it as maxSide (also honour
//   maxImageDimension3D for the margin: maxSide must be > 1 + 2 * margin). Each brick is an ordinary sampled 3D
//   image; the ray-cast kernel is unchanged - only its box (crop min / max = the core box in brick voxels) and
//   its patient -> voxel matrix (BKSlabBrickPatientToVoxel) change per brick. No bindless / descriptor arrays are
//   needed: one dispatch per brick, combined here on the CPU.
// - The combination could later move to a compute pass (same rules); the CPU version is the reference.
// - Deterministic: no state, no threads; the result does not depend on how the caller splits the work.

#ifndef BK_SLAB_BRICK_CORE_H
#define BK_SLAB_BRICK_CORE_H

#include "BKVec.h"
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: the margin the slab renderer uses (rule 2).
#define BK_SLAB_BRICK_MARGIN 2
// What: the most bricks the plan makes along one axis (BKSlabBrickPlan returns 0 beyond it).
#define BK_SLAB_BRICK_MAX_PER_AXIS 63

// What: one brick (voxel indices of the whole scan, inclusive).
typedef struct {
    int32_t coreLo[3], coreHi[3];   // the part of the scan this brick draws
    int32_t texLo[3], texHi[3];     // the voxels its texture holds (core + margin)
    int32_t grid[3];                // its position in the brick grid
} BKSlabBrick;

// What: the brick plan of a scan of dims[0] x dims[1] x dims[2] voxels for textures of at most maxSide voxels per
// side (rule 1). Writes up to `capacity` bricks to `out` (may be NULL to only count) and returns how many the plan
// has; 0 for bad input (a side < 1, maxSide <= 1 + 2 * margin, margin < 0). gridCounts (may be NULL) gets the
// number of bricks along each axis.
int32_t BKSlabBrickPlan(const int32_t dims[3], int32_t maxSide, int32_t margin, BKSlabBrick *out, int32_t capacity,
                        int32_t gridCounts[3]);

// What: the patient-mm -> voxel matrix of a brick's texture from the whole scan's (column by column, voxel =
// M * (x, y, z, 1)): the same matrix moved by the brick's first texture voxel.
void BKSlabBrickPatientToVoxel(const double scanPatientToVoxel[16], const BKSlabBrick *brick, double out[16]);

// What: the brick's core box in its own texture's voxel indices (the ray-cast box / crop box of that brick).
void BKSlabBrickCoreBoxInTexture(const BKSlabBrick *brick, double lo[3], double hi[3]);

// What: rule 3 for a whole picture: weights[y * width + x] = the ray weight of `brick` for pixel (x, y). The
// picture: pixel (x, y) at pixel0 + right * (x * spacing) + down * (y * spacing) (patient mm; right / down are
// made unit length), rays along cross(right, down), slab `thickness` mm around that plane. Returns the largest
// weight (0 = the brick does not touch the picture at all, the caller may skip it), or -1 for bad input.
double BKSlabBrickRayWeights(const double scanPatientToVoxel[16], const BKSlabBrick *brick, BKVec3d pixel0,
                             BKVec3d right, BKVec3d down, double spacing, double thickness,
                             int32_t width, int32_t height, float *weights);

// What: rule 4 - order[0..count-1] = the brick numbers in visiting order for rays travelling along
// voxelDirection (the view direction in the scan's voxel axes). Returns 1, or 0 for bad input.
int BKSlabBrickVisitOrder(const BKSlabBrick *bricks, int32_t count, BKVec3d voxelDirection, int32_t *order);

// ---- Putting the brick pictures together -------------------------------------------------------------------
// mode: 1 MIP, 2 MinIP, 3 mean (the slab modes). The accumulators are float arrays of `count` pixels (colour:
// 3 floats per pixel) plus one weight per pixel, started with BKSlabBrickBegin*.

// What: starts the value accumulators (count pixels).
void BKSlabBrickBeginValues(int32_t mode, size_t count, float *acc, float *weightSum);
// What: adds one brick's picture values (count floats) with its ray weights.
void BKSlabBrickAddValues(int32_t mode, const float *values, const float *weights, size_t count, float *acc, float *weightSum);
// What: the finished picture: out[i] = the combined value, or `outside` where no brick counted.
void BKSlabBrickFinishValues(int32_t mode, const float *acc, const float *weightSum, size_t count, float outside, float *out);

// What: the same per colour channel; the brick pictures are RGBA8 (r, g, b, a bytes per pixel; a is ignored),
// the result RGBA8 with a = 255 (0, 0, 0 where no brick counted).
void BKSlabBrickBeginChannels(int32_t mode, size_t count, float *acc3, float *weightSum);
void BKSlabBrickAddChannels(int32_t mode, const uint8_t *rgba, const float *weights, size_t count, float *acc3, float *weightSum);
void BKSlabBrickFinishChannels(int32_t mode, const float *acc3, const float *weightSum, size_t count, uint8_t *outRGBA);

// What: VR colour (rule 5): acc4 (4 floats per pixel, premultiplied r, g, b, alpha 0..1) starts at 0; add the brick
// pictures (premultiplied RGBA8) in visiting order; finish = RGBA8 (premultiplied, alpha in a).
void BKSlabBrickBeginOver(size_t count, float *acc4);
void BKSlabBrickAddOver(const uint8_t *rgba, size_t count, float *acc4);
void BKSlabBrickFinishOver(const float *acc4, size_t count, uint8_t *outRGBA);

#ifdef __cplusplus
}
#endif

#endif
