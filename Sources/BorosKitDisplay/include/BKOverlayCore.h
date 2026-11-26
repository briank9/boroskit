// BorosKitDisplay: BKOverlayCore - the 2D overlay engine's core (plain C99): everything drawn over a 2D
// image (ROIs, measurements, text pictures, cross-lines, curves, handles, brush masks) is described as
// a draw list and turned into ONE list of coloured / textured triangles that a GPU draws in one pass.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 on BKVec (no Objective-C, CoreGraphics, Metal, Apple
//   simd, LGPL types). A backend only uploads BKOverlayList's vertex array (BKOverlayVertex, 32 bytes,
//   std430-compatible: 8 floats) and its images, then draws each BKOverlayCommand (a vertex range, a
//   pipeline mode, an optional image and an optional scissor rectangle) with alpha blending. Two tiny
//   shaders (solid colour; texture x colour / mask x colour). The CPU reference rasteriser below gives
//   the expected pixels for any backend (golden checks).
// - Coordinates: VIEW pixels, origin TOP-LEFT, x right, y DOWN (device pixels, not points).
// - Colours: straight (not premultiplied) RGBA 0..1 in the vertex; the shader premultiplies. Blending:
//   source-over (premultiplied). A command can ask to ignore alpha (opaque) - old OpenGL code that drew
//   with blending off.
// - Smooth edges: a stroke / fill / point asked to be smooth gets a one-pixel "fringe" whose vertex
//   alpha goes from full to zero (analytic anti-aliasing, no multisampling needed on any GPU).
//
// Plain language: an ROI outline is a list of points joined by a line of some width; this file turns
// that line into small triangles (with an optional soft rim so it looks smooth), the same for filled
// shapes, dots, dashed lines and pictures (text pictures, brush masks). The graphics card then only
// draws triangles - which every graphics system (Metal now, Vulkan later) does the same way.

#ifndef BK_OVERLAY_CORE_H
#define BK_OVERLAY_CORE_H

#ifndef BK_GLSL   // 2026-11-26: GLSL (bk_overlay_*.vert/.frag) includes this header for BK_OVERLAY_PARAMS_FIELDS only
#include "BKVec.h"
#include "BKGPUTypes.h"   // bk_float2 + layout checks for the GPU blocks below (2026-11-25, vulkan-engine M2)
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { float r, g, b, a; } BKOverlayColor;   // straight alpha, 0..1

// One vertex (32 bytes): position (view pixels), texture coordinate (image pixels of the command's
// image, unused for solid colour), colour (straight RGBA; alpha already includes edge coverage).
typedef struct {
    float x, y;
    float u, v;
    float r, g, b, a;
} BKOverlayVertex;
BK_GPU_STATIC_ASSERT(sizeof(BKOverlayVertex) == 32, "BKOverlayVertex must stay 32 bytes (8 floats)");
BK_GPU_ASSERT_OFFSET(BKOverlayVertex, u, 8);
BK_GPU_ASSERT_OFFSET(BKOverlayVertex, r, 16);

#endif   // !BK_GLSL

// The per-command GPU constants of the two overlay shaders (24 bytes; Vulkan: push constants).
// Written ONCE as a field list (2026-11-25, vulkan-engine M2; it used to be typed twice by hand, in the
// Metal source and in C): BKOverlayRenderer.mm pastes the same text into the Metal shader, and a GLSL
// shader pastes it into a push-constant block. bk_float2 is 8-byte aligned in C, MSL and std430, so
// the offsets 0 / 8 / 16 / 20 are the same in all three.
#define BK_OVERLAY_PARAMS_FIELDS \
    bk_float2 viewSize;   /* drawing area in pixels (vertex positions are view pixels, y down) */ \
    bk_float2 imageSize;  /* the command's image in pixels (texture coordinates are image pixels); 1, 1 if none */ \
    int32_t mode;         /* BKOverlayMode...: 0 solid, 1 image x colour, 2 mask x colour */ \
    int32_t opaque;       /* 1: alpha forced to 1 (BKOverlayCommand.ignoreAlpha) */
#ifndef BK_GLSL
typedef struct BKOverlayParams { BK_OVERLAY_PARAMS_FIELDS } BKOverlayParams;
BK_GPU_STATIC_ASSERT(sizeof(BKOverlayParams) == 24, "BKOverlayParams must stay 24 bytes");
BK_GPU_ASSERT_OFFSET(BKOverlayParams, imageSize, 8);
BK_GPU_ASSERT_OFFSET(BKOverlayParams, mode, 16);
BK_GPU_ASSERT_OFFSET(BKOverlayParams, opaque, 20);

// How a command's triangles are coloured.
enum {
    BKOverlayModeSolid = 0,     // vertex colour
    BKOverlayModeImage = 1,     // image colour (RGBA8, straight alpha) x vertex colour
    BKOverlayModeMask = 2,      // vertex colour with alpha x image value (alpha 8-bit image: tinted picture)
};

// One draw call: vertices [first, first + count) as a triangle list.
typedef struct {
    uint32_t first, count;
    int32_t mode;               // BKOverlayMode...
    int32_t image;              // index into the list's images (-1: none)
    int32_t linearFilter;       // image sampling: 1 linear, 0 nearest
    int32_t ignoreAlpha;        // 1: draw opaque (alpha forced to 1)
    int32_t hasClip;            // 1: clip to the rectangle below
    int32_t clipX, clipY, clipW, clipH;   // view pixels, top-left origin
} BKOverlayCommand;

// An image used by the list (copied in). kind: 4 bytes per pixel RGBA (straight alpha) or 1 byte (mask).
enum { BKOverlayImageRGBA8 = 0, BKOverlayImageAlpha8 = 1 };
typedef struct {
    uint32_t width, height;
    int32_t kind;
    uint8_t *pixels;            // width x height x (4 or 1) bytes, row 0 = top, owned by the list
} BKOverlayImage;

// Line style.
enum { BKOverlayCapButt = 0, BKOverlayCapSquare = 1, BKOverlayCapRound = 2 };
enum { BKOverlayJoinMiter = 0, BKOverlayJoinBevel = 1, BKOverlayJoinRound = 2 };
typedef struct {
    float width;                // view pixels (minimum 1/64)
    int32_t cap, join;
    float miterLimit;           // ratio, as Core Graphics / SVG (default 10); a sharper corner is bevelled
    const float *dashes;        // on / off lengths in view pixels (NULL or count 0: solid)
    uint32_t dashCount;
    float dashPhase;            // distance into the dash pattern at the first point
    int32_t smooth;             // 1: one-pixel soft rim (anti-aliasing)
} BKOverlayStroke;

// The draw list (opaque; growable arrays, reused frame after frame with BKOverlayListReset).
typedef struct BKOverlayList BKOverlayList;

BKOverlayList *BKOverlayListCreate(void);
void BKOverlayListFree(BKOverlayList *list);
// Empties the list (keeps its memory for the next frame).
void BKOverlayListReset(BKOverlayList *list);

// Results for a backend.
const BKOverlayVertex *BKOverlayListVertices(const BKOverlayList *list, uint32_t *count);
const BKOverlayCommand *BKOverlayListCommands(const BKOverlayList *list, uint32_t *count);
const BKOverlayImage *BKOverlayListImages(const BKOverlayList *list, uint32_t *count);
// 0 when everything so far was added correctly; otherwise the first problem (out of memory = 1,
// bad argument = 2); the list stays usable (the bad item is skipped).
int BKOverlayListError(const BKOverlayList *list);

// --- State for the following items -------------------------------------------------------------
// Clip rectangle (view pixels) for following items; w or h <= 0 clears it.
void BKOverlaySetClip(BKOverlayList *list, int32_t x, int32_t y, int32_t w, int32_t h);
// Draw following items opaque (alpha ignored), as old code that drew without blending.
void BKOverlaySetIgnoreAlpha(BKOverlayList *list, int ignoreAlpha);

// --- Items -------------------------------------------------------------------------------------
// Stroked line through `count` points (closed: back to the first). colors: NULL = `color` everywhere,
// else one colour per point; each segment then fades from its start point's colour to its end point's
// (as OpenGL's smooth shading did).
void BKOverlayStrokePolyline(BKOverlayList *list, const BKVec2f *points, const BKOverlayColor *colors,
                             uint32_t count, int closed, const BKOverlayStroke *stroke, BKOverlayColor color);
// Separate segments: points (0,1), (2,3), ... (as OpenGL GL_LINES).
void BKOverlayStrokeSegments(BKOverlayList *list, const BKVec2f *points, const BKOverlayColor *colors,
                             uint32_t count, const BKOverlayStroke *stroke, BKOverlayColor color);
// Filled polygon. rule: BKOverlayFillFan = triangles from the first point (what OpenGL's GL_POLYGON
// does - right for convex shapes, and what the old code relied on); BKOverlayFillEvenOdd = the area
// inside by the even-odd rule (concave and self-crossing shapes; triangulated by a scan-band method).
// colors: NULL or one per point (fan rule only; even-odd uses `color`).
enum { BKOverlayFillFan = 0, BKOverlayFillEvenOdd = 1 };
void BKOverlayFillPolygon(BKOverlayList *list, const BKVec2f *points, const BKOverlayColor *colors,
                          uint32_t count, int rule, int smooth, BKOverlayColor color);
// Ready-made triangles (OpenGL GL_TRIANGLES / strips / quads already split by the caller), one colour
// per point or `color`.
void BKOverlayFillTriangles(BKOverlayList *list, const BKVec2f *points, const BKOverlayColor *colors,
                            uint32_t count, BKOverlayColor color);
// Dots of `size` view pixels centred on the points: round (smooth: soft rim) or square.
void BKOverlayPoints(BKOverlayList *list, const BKVec2f *points, const BKOverlayColor *colors,
                     uint32_t count, float size, int round, int smooth, BKOverlayColor color);
// Adds an image (pixels copied, row 0 = top); returns its index, or -1.
int32_t BKOverlayAddImage(BKOverlayList *list, uint32_t width, uint32_t height, int32_t kind,
                          const uint8_t *pixels, size_t bytesPerRow);
// Draws image `image` so that its pixel (u, v) (v down) lands on view point origin + u*uAxis + v*vAxis
// (any rotation / scale / mirror). Mask images are drawn in `color`; RGBA images are multiplied by it.
void BKOverlayDrawImage(BKOverlayList *list, int32_t image, BKVec2f origin, BKVec2f uAxis, BKVec2f vAxis,
                        int linearFilter, BKOverlayColor color);

// --- CPU reference rasteriser (tests, golden checks for any GPU backend) -------------------------
// Draws the whole list into `rgba` (width x height x 4 floats, premultiplied, row 0 = top), which holds
// the background already. Pixel centres at (x + 0.5, y + 0.5); a pixel is covered by a triangle when its
// centre is inside (top-left rule for shared edges); colours interpolate across the triangle; images are
// sampled nearest or bilinear at the interpolated texture coordinate; source-over blending.
void BKOverlayRasterize(const BKOverlayList *list, float *rgba, uint32_t width, uint32_t height);

#ifdef __cplusplus
}
#endif

#endif   // !BK_GLSL
#endif
