// BorosKitMeshRender: BKMeshUniformFields.h - the field list of BKMeshUniforms, written ONCE.
//
// Original BorosKit code written for this project; contains no third-party code.
// Moved here 2026-11-26 by agent "vulkan-engine" (step M8) from BKMeshShaderTypes.h, unchanged.
//
// PORTING NOTES (Vulkan / other backends):
//   - This file must contain nothing but the #define below (plus the include guard), because it is read by
//     THREE compilers: C (BKMeshShaderTypes.h expands it into the C struct), Metal (BKMeshShaderSource.mm
//     pastes it in as text) and GLSL (the Vulkan shaders #include it inside a std140 uniform block).
//   - The names it uses are defined by each side: bk_mesh_float4 / bk_mesh_float4x4 / int32_t
//     (C: BKGPUTypes.h + <stdint.h>; Metal: float4 / float4x4 / int; GLSL: vec4 / mat4 / int).
//   - Layout: std140 and std430 compatible, 272 bytes (pinned in BKMeshShaderTypes.h).

#ifndef BK_MESH_UNIFORM_FIELDS_H
#define BK_MESH_UNIFORM_FIELDS_H

#define BK_MESH_UNIFORM_FIELDS \
    bk_mesh_float4x4 model;        /* object -> patient mm (the object's placement) */ \
    bk_mesh_float4x4 normalMatrix; /* turns normals with the object (inverse-transpose of model) */ \
    bk_mesh_float4 cameraPosition; /* xyz: ortho = centre of the image plane; perspective = the eye (mm) */ \
    bk_mesh_float4 cameraRight;    /* xyz: unit vector to the right of the image */ \
    bk_mesh_float4 cameraUp;       /* xyz: unit vector to the top of the image */ \
    bk_mesh_float4 cameraForward;  /* xyz: unit viewing direction */ \
    bk_mesh_float4 color;          /* rgb = object colour, a = opacity */ \
    float halfWidth;               /* ortho: half image width in mm; perspective: tan(half horizontal angle) */ \
    float halfHeight;              /* ortho: half image height in mm; perspective: tan(half vertical angle) */ \
    float nearDistance;            /* depth range (mm along the view direction) that is kept */ \
    float farDistance; \
    float ambient;                 /* lighting, same meaning as BKVolumeRenderer's */ \
    float diffuse; \
    float specular; \
    float specularPower; \
    int32_t projection;            /* BKProjection: 0 orthographic, 1 perspective */ \
    int32_t useVertexColors;       /* 1 = take the colour from the mesh's vertices */ \
    int32_t hasNormals;            /* 0 = no vertex normals: shade each triangle flat */ \
    int32_t lit;                   /* 0 = flat colour, no lighting (labels, lines) */ \
    float viewportWidth;           /* size of the drawing area in pixels (lines are sized in pixels) */ \
    float viewportHeight; \
    float lineHalfWidth;           /* lines: half the line width in pixels; points: half the point size */ \
    float paddingForAlignment;

#endif
