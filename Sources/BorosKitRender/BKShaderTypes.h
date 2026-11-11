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

typedef simd_float3   bk_float3;
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
    int32_t shading;              /* 1 = gradient shading in composite mode */

typedef struct BKRenderParams {
    BK_RENDER_PARAMS_FIELDS
} BKRenderParams;

// Turns the field list above into a string literal for the shader source.
// Two levels are needed so the macro is expanded before it is stringified.
#define BK_STRINGIFY_(...) #__VA_ARGS__
#define BK_STRINGIFY(...) BK_STRINGIFY_(__VA_ARGS__)

#endif
