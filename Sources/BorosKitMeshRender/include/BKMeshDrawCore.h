// BorosKitMeshRender: plain-C rules for face culling, textured surfaces and point sprites.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C with <simd/simd.h> vector types and fixed-size integers only: no Objective-C,
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

#ifndef BK_MESH_DRAW_CORE_H
#define BK_MESH_DRAW_CORE_H

#include <simd/simd.h>
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
int32_t BKMeshTriangleIsFrontFacing(simd_float2 a, simd_float2 b, simd_float2 c);

// What: 1 when a triangle with these screen positions is NOT drawn under `cullMode`.
// Triangles without area are never drawn by GPUs anyway; here they count as culled only when
// some culling is on (with culling off the caller decides).
int32_t BKMeshTriangleIsCulled(int32_t cullMode, simd_float2 a, simd_float2 b, simd_float2 c);

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
simd_float4 BKMeshTextureSample(const uint8_t *rgba, uint32_t width, uint32_t height,
                                float s, float t, int32_t linear, int32_t wrap);

// What: the final premultiplied colour of a textured surface point: `litColor` is the lit
// surface colour (rgb) with its opacity (a), not premultiplied; it is clamped to 0..1,
// multiplied by `texel`, then premultiplied ("over" blending).
simd_float4 BKMeshTextureModulate(simd_float4 litColor, simd_float4 texel);

// What: the pixel rectangle a point of `pointSize` pixels covers when its centre projects to
// pixel position (cx, cy) (any origin; the square is centred there): min and max corners.
// Pixels whose CENTRE lies inside [min, max) are covered (the GPU's fill rule).
void BKMeshPointSquare(float cx, float cy, float pointSize, simd_float2 *min, simd_float2 *max);

#ifdef __cplusplus
}
#endif

#endif
