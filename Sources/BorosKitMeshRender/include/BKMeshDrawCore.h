// BorosKitMeshRender: plain-C rules for face culling, textured surfaces and point sprites.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C99 with BorosKit vector types (BKVec.h; moved off Apple simd 2026-11-14) and fixed-size integers only: no Objective-C,
//   Foundation, Metal, VTK or Horos-derived (LGPL) types. A Vulkan build uses it unchanged.
// - These functions are the CPU REFERENCE of what the GPU does (the Metal shaders in
//   BKMeshShaderSource.mm follow them line for line; a GLSL port must too). The tests compare
//   the GPU pictures against them.
// - Face culling: "front-facing" = the triangle's corners run anticlockwise on screen with the
//   y axis pointing UP (the usual OpenGL / VTK rule, glFrontFace(GL_CCW)). Metal judges the
//   winding in its y-up normalised coordinates, so the renderer sets MTLWindingCounterClockwise
//   (verified by BKMeshDrawCoreTests); in Vulkan use VK_FRONT_FACE_COUNTER_CLOCKWISE together
//   with the y-flipped viewport noted in BKMeshShaderTypes.h (the flip turns the y-down
//   framebuffer back into the y-up convention used here). A mirrored placement matrix flips the
//   winding seen on screen, exactly as in OpenGL; nothing corrects for it (VTK doesn't either).
// - Texture lookup: s, t in texture units (0..1 = one copy of the picture), pixel row 0 is
//   t = 0 (like OpenGL / Metal / Vulkan: the first row in memory is at t = 0). Linear filtering
//   follows the standard texel-centre rule (u = s * width - 0.5); a GPU's own filtering may round
//   the blend weights (typically to 1/256), so comparisons need a small tolerance.
//   Wrap: repeat or clamp to the edge texel. No mipmaps (VTK's default for a vtkTexture).
// - Texture colour: the lit, clamped surface colour (straight, not premultiplied) is multiplied
//   by the texel (RGBA), then premultiplied for "over" blending. This is VTK's single-texture
//   rule (gl_FragData[0] = gl_FragData[0] * tcolor after lighting).
// - Points: squares of `pointSize` pixels centred on the projected point (what glPointSize gives
//   in the core OpenGL profile), depth-tested like surfaces. Built from two triangles per point
//   in the vertex shader, because GPU point primitives have API-dependent size limits.
// - Flags are int32_t (never bool) so they could be shared with shader structs.
// - 2026-11-25 (vulkan-engine M3): the GPU settings block BKMeshUniforms (BKMeshShaderTypes.h, now a public
//   plain-C header) is filled HERE, not in Objective-C: camera frame (via BKCameraMath), half view sizes,
//   depth range, lighting, colour, placement and normal matrix. BKMeshRenderer (Metal) calls these; a
//   Vulkan mesh pass calls the very same functions, so both engines get identical bytes.
//   Precision: the camera frame is built in double (same formula as BKCameraMath) and rounded to float once. (Before, Objective-C built it
//   in float with Apple simd, whose normalize uses Apple's own approximate 1/sqrt - not reproducible in
//   portable C; the golden harness reports the effect.)

#ifndef BK_MESH_DRAW_CORE_H
#define BK_MESH_DRAW_CORE_H

#include "BKVec.h"   // BorosKit neutral vectors (no Apple simd: VULKAN-PORT-PLAN rule 1)
#include "BKMeshShaderTypes.h"   // BKMeshUniforms, the GPU settings block (plain C since 2026-11-25)
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Which side of a triangle is not drawn (same values as BKMeshFaceCulling in BKMeshRenderer.h).
enum {
    BKMeshCullNone = 0,    // both sides drawn (default)
    BKMeshCullBack = 1,    // the back side is not drawn (VTK BackfaceCullingOn)
    BKMeshCullFront = 2,   // the front side is not drawn (VTK FrontfaceCullingOn)
};

// What: 1 when the triangle a, b, c (screen positions, x right, y UP, any common scale - e.g.
// the normalised -1..1 drawing-area coordinates) runs anticlockwise, i.e. shows its front side;
// 0 when it runs clockwise (back side) or has no area.
int32_t BKMeshTriangleIsFrontFacing(BKVec2f a, BKVec2f b, BKVec2f c);

// What: 1 when a triangle with these screen positions is NOT drawn under `cullMode`.
// Triangles without area are never drawn by GPUs anyway; here they count as culled only when
// some culling is on (with culling off the caller decides).
int32_t BKMeshTriangleIsCulled(int32_t cullMode, BKVec2f a, BKVec2f b, BKVec2f c);

// What: converts `count` texels with 1..4 unsigned 8-bit components each into RGBA8, with the
// OpenGL / VTK meaning of the components: 1 = luminance (L, L, L, 255), 2 = luminance + alpha
// (L, L, L, A), 3 = RGB (R, G, B, 255), 4 = RGBA. Returns 0 (nothing written) for other
// component counts or NULL pointers, 1 otherwise. `dst` holds 4 * count bytes.
int32_t BKMeshTextureExpandToRGBA8(const uint8_t *src, uint32_t components, size_t count, uint8_t *dst);

// Wrap modes for texture lookups.
enum {
    BKMeshTextureWrapRepeat = 0,        // the picture repeats (VTK RepeatOn, the default)
    BKMeshTextureWrapClampToEdge = 1,   // outside 0..1 the edge texel continues (VTK RepeatOff)
};

// What: the texel colour (RGBA, 0..1) at texture position (s, t) of an RGBA8 picture of
// width x height texels (row 0 = t = 0). `linear` 1 = blend the 4 nearest texels (VTK
// InterpolateOn), 0 = nearest texel. Returns (0,0,0,0) for an empty picture.
BKVec4f BKMeshTextureSample(const uint8_t *rgba, uint32_t width, uint32_t height,
                                float s, float t, int32_t linear, int32_t wrap);

// What: the final premultiplied colour of a textured surface point: `litColor` is the lit
// surface colour (rgb) with its opacity (a), not premultiplied; it is clamped to 0..1,
// multiplied by `texel`, then premultiplied ("over" blending).
BKVec4f BKMeshTextureModulate(BKVec4f litColor, BKVec4f texel);

// What: the pixel rectangle a point of `pointSize` pixels covers when its centre projects to
// pixel position (cx, cy) (any origin; the square is centred there): min and max corners.
// Pixels whose CENTRE lies inside [min, max) are covered (the GPU's fill rule).
void BKMeshPointSquare(float cx, float cy, float pointSize, BKVec2f *min, BKVec2f *max);

// ---- GPU settings block (2026-11-25, vulkan-engine M3) -------------------------------------------------

// What: the camera the mesh pictures are drawn with (the same numbers BKMeshRenderer stores).
typedef struct {
    int32_t projection;         // 0 orthographic, 1 perspective (BKProjection)
    BKVec3d position;           // patient mm: ortho = centre of the image plane; perspective = the eye
    BKVec3d direction;          // viewing direction (any length > 0)
    BKVec3d up;                 // roughly up on the screen (any length; made perpendicular here)
    double viewWidth;           // orthographic: picture width in mm
    double viewHeight;          // orthographic: picture height in mm
    double fieldOfView;         // perspective: full VERTICAL opening angle, degrees
} BKMeshCamera;

// Results of the functions below (0 = fine). BKMeshRenderer turns them into its error messages.
enum {
    BKMeshCameraOK = 0,
    BKMeshCameraZeroDirection = 1,     // direction shorter than 1e-6
    BKMeshCameraUpParallel = 2,        // up (almost) parallel to the direction
    BKMeshCameraZeroFieldOfView = 3,   // half width / half height not > 0
};

// What: the camera's orthonormal frame - forward = unit direction, right = unit(forward x up) (the same
// formula as BKCameraMath's BKCameraRight, checked by a test), up = right x forward. Returns
// BKMeshCameraOK, or why it cannot be built (then the outputs are untouched). Any output may be NULL.
int32_t BKMeshCameraAxes(const BKMeshCamera *camera, BKVec3d *right, BKVec3d *up, BKVec3d *forward);

// What: half the picture size the vertex shader uses: orthographic = half width / height in mm;
// perspective = tan(half vertical angle) and that times the drawing area's aspect (width / height).
// Same float maths the renderer always used.
void BKMeshCameraHalfSize(const BKMeshCamera *camera, float areaWidth, float areaHeight,
                          float *halfWidth, float *halfHeight);

// What: the depth range (mm along the viewing direction) that encloses everything drawn, from the
// nearest / farthest object corner: 1 mm + 1 % of the depth extent of margin on both sides; in
// perspective the far distance stays >= 0.001 and the near one >= far / 10000 (nothing behind the eye).
// Why: a tight range keeps the depth test precise.
void BKMeshDepthRange(float nearest, float farthest, int32_t perspective, float *nearDistance, float *farDistance);

// What (2026-11-26, vulkan-engine M9): the depth extent of an axis-aligned box (patient mm) along the
// viewing direction: each of its 8 corners' distance z = dot(corner - camera, forward) widens
// [*nearest, *farthest] (start them at +inf / -inf). Returns the box centre's distance (the drawing
// order of see-through objects: farthest first). Float maths in the exact order the renderer always used
// ((x + y) + z sums, Foundation MIN / MAX comparisons), so Metal and a Vulkan pass agree bit for bit.
float BKMeshBoxDepthExtent(BKVec3f lo, BKVec3f hi, BKVec3f camera, BKVec3f forward, float *nearest, float *farthest);

// Lighting terms (same meaning as BKVolumeRenderer's).
typedef struct { float ambient, diffuse, specular, specularPower; } BKMeshLighting;

// What: zeroes `u` and fills the part shared by every object of a frame: camera frame, half sizes,
// depth range, lighting, projection, drawing-area size; lit = 1. Returns BKMeshCameraOK or the problem
// (then `u` is zeroed only).
int32_t BKMeshUniformsFill(BKMeshUniforms *u, const BKMeshCamera *camera, float areaWidth, float areaHeight,
                           float nearDistance, float farDistance, BKMeshLighting lighting);

// What: one object's placement. `model` = 16 floats, column-major (object -> patient mm). With
// `withNormalMatrix` = 1 the normal matrix is the inverse-transpose of the model's 3x3 part (computed in
// double; a singular 3x3 part is used as it is), otherwise identity (lines, points).
void BKMeshUniformsSetModel(BKMeshUniforms *u, const float model[16], int32_t withNormalMatrix);

// What: object colour (rgb) and opacity; the opacity is clamped to 0..1 exactly as the Objective-C
// MIN(MAX(opacity, 0), 1) did (so a NaN opacity becomes 1). The colour is stored as given.
void BKMeshUniformsSetColor(BKMeshUniforms *u, float r, float g, float b, float opacity);

#ifdef __cplusplus
}
#endif

#endif
