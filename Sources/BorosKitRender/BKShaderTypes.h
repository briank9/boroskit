// BorosKitRender: the parameter block that the CPU hands to the GPU for every render.
//
// Why a macro: the same struct must exist twice, once in Objective-C (to fill it in)
// and once in the Metal shader (to read it). If the two copies ever drift apart, the
// GPU silently reads garbage. So the fields are written ONCE in BK_RENDER_PARAMS_FIELDS
// below; the Objective-C side expands it into a C struct, and the shader source pulls
// the very same text in as a string (see BKShaderSource.mm). A unit test also checks
// that the GPU and CPU agree on the struct size.
//
// Type names: bk_float3 / bk_float3x3 map to simd_float3 / simd_float3x3 on the CPU and
// to float3 / float3x3 in Metal. Both have identical size (16 / 48 bytes) and
// alignment (16), so the layouts match field for field.

#ifndef BK_SHADER_TYPES_H
#define BK_SHADER_TYPES_H

#include <simd/simd.h>
#include <stdint.h>
#include "BKClipPlanes.h"   // BK_MAX_CLIP_PLANES (shared with the plain-C plane math)

typedef simd_float3   bk_float3;
typedef simd_float4   bk_float4;   // 16 bytes / 16-byte alignment on both sides, like float3
typedef simd_float3x3 bk_float3x3;

// Field list (order matters: 16-byte vectors first, then 4-byte scalars, so there is
// no hidden padding that one compiler might lay out differently from the other).
#define BK_RENDER_PARAMS_FIELDS \
    bk_float3x3 patientToVoxel;   /* linear part of the patient(mm) -> voxel index transform */ \
    bk_float3 patientToVoxelTranslation; /* translation part of the same transform */ \
    bk_float3 volumeSize;         /* voxel counts (w, h, d) as floats */ \
    bk_float3 boxMin;             /* region to ray-cast, voxel space (volume bounds intersected with crop box) */ \
    bk_float3 boxMax; \
    bk_float3 cameraPosition;     /* ortho: centre of the image plane; perspective: the eye. Patient mm */ \
    bk_float3 cameraRight;        /* unit vector pointing to the right of the image */ \
    bk_float3 cameraUp;           /* unit vector pointing to the top of the image */ \
    bk_float3 cameraForward;      /* unit viewing direction */ \
    bk_float3 slabPoint;          /* a point on the slab's centre plane (patient mm) */ \
    bk_float3 slabNormal;         /* unit normal of the slab's centre plane */ \
    bk_float3 clipPoint;          /* a point on the clipping ("scissors") plane, patient mm */ \
    bk_float3 clipNormal;         /* unit normal; the side it points to is cut away */ \
    bk_float3 brickGrid;          /* empty-space skipping: number of bricks along x, y, z */ \
    bk_float4 clipPlanes[BK_MAX_CLIP_PLANES]; /* extra clip planes (e.g. a rotated crop box): (nx,ny,nz,w), patient mm; cut where dot(n,x)+w > 0 (see BKClipPlanesPack) */ \
    float viewWidth;              /* ortho: image width in mm; perspective: 2*tan(hfov/2) */ \
    float viewHeight;             /* ortho: image height in mm; perspective: 2*tan(vfov/2) */ \
    float stepSize;               /* requested distance between samples along a ray, mm */ \
    float opacityUnitDistance;    /* distance (mm) over which a transfer-function opacity applies */ \
    float valueScale;             /* stored texel (0..1) -> real value: v = texel*valueScale + valueOffset */ \
    float valueOffset; \
    float tfMin;                  /* value mapped to the first transfer-function entry */ \
    float tfMax;                  /* value mapped to the last transfer-function entry */ \
    float windowCenter;           /* grayscale window for MIP / MinIP / average output */ \
    float windowWidth; \
    float slabThickness;          /* mm; 0 = single plane (classic MPR slice) */ \
    float outOfBoundsValue;       /* value reported where a ray misses the volume */ \
    float ambient;                /* shading terms for composite (VR) mode */ \
    float diffuse; \
    float specular; \
    float specularPower; \
    uint32_t width;               /* output image size in pixels */ \
    uint32_t height; \
    int32_t mode;                 /* BKRenderMode */ \
    int32_t projection;           /* BKProjection */ \
    int32_t useSlab;              /* 1 = limit rays to the slab */ \
    int32_t shading;              /* 1 = gradient shading in composite mode */ \
    int32_t useClip;              /* 1 = cut away the half-space in front of the clipping plane */ \
    int32_t skipEmptySpace;       /* 1 = jump over bricks that cannot change the picture (see BK_BRICK_SIZE) */ \
    int32_t clipPlaneCount;       /* number of valid entries in clipPlanes (0..BK_MAX_CLIP_PLANES) */

// Empty-space skipping (plain language): the volume is divided into small cubes
// ("bricks") of BK_BRICK_SIZE voxels per side. For every brick the lowest and highest
// stored value is remembered once per volume. A ray that enters a brick which cannot
// show anything (all its values are fully transparent in 3D mode, or cannot beat the
// brightest value found so far in MIP) jumps straight to where it leaves the brick,
// and then carries on sampling at exactly the same spots it would have used anyway.
// So the picture is the same, it is just found faster. 8 is a good size: small enough
// to fit tightly around bone and teeth, large enough that jumping saves real work.
#define BK_BRICK_SIZE 8

// Number of entries in the transfer-function lookup table (shared with the shader so
// the "is this brick see-through?" test reads the table exactly as the ray does).
#define BK_TRANSFER_FUNCTION_ENTRIES 4096

typedef struct BKRenderParams {
    BK_RENDER_PARAMS_FIELDS
} BKRenderParams;

// Turns the field list above into a string literal for the shader source.
// Two levels are needed so the macro is expanded before it is stringified.
#define BK_STRINGIFY_(...) #__VA_ARGS__
#define BK_STRINGIFY(...) BK_STRINGIFY_(__VA_ARGS__)

#endif
