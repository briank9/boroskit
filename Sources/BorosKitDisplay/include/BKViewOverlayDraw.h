// BorosKitDisplay: BKViewOverlayDraw - the 2D views' own overlays (information text, scale bar, cross-lines,
// slice / plane lines, curves and their handles, markers) added straight to the overlay engine's draw list,
// plain C99. Overlay-engine plan step 6, second part (2026-11-16): replaces the old OpenGL-style drawing of
// those overlays (Horos code run through the soft-GL / shim translation layer).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. EVERY function in this header is plain C99 on BKVec / BKOverlayCore
//   (no Apple types, no GPU calls, no platform text): it only adds lines / fills / dots / images to the
//   backend-neutral draw list (BKOverlayCore), which a Metal or Vulkan backend draws the same way.
// - Text pictures arrive as ready-made images (BKOverlayAddImage); making them (letters -> pixels) is the
//   platform's job (Apple: AppKit glue in the app; Windows / Linux: their own rasteriser) and is NOT part of
//   this file.
// - Coordinates: the caller's drawing space ("model" space: e.g. the view in pixels from its centre, or the
//   zoomed image) mapped to view pixels (origin top-left, y down) by a 2D affine transform.
//
// Plain language: the view says how its drawing space sits on the screen; these functions put lines, dots,
// filled shapes and text pictures there, at the sizes the old drawing used (sizes are screen pixels).

#ifndef BK_VIEW_OVERLAY_DRAW_H
#define BK_VIEW_OVERLAY_DRAW_H

#include "BKOverlayCore.h"

#ifdef __cplusplus
extern "C" {
#endif

// Model space -> view pixels: view = (a x + c y + tx, b x + d y + ty).
typedef struct { double a, b, c, d, tx, ty; } BKViewXf;

// What: model point (x, y) in view pixels.
BKVec2f BKViewMap(const BKViewXf *xf, double x, double y);

// How lines are joined.
enum {
    BKViewLineStrip = 0,      // one line through all points
    BKViewLineLoop = 1,       // the same, closed
    BKViewLineSegments = 2    // separate pieces: points (0,1), (2,3), ...
};

// A pen: width in view pixels, optional dashes (view pixels, on/off), soft edge.
typedef struct {
    float width;
    const float *dashes;
    uint32_t dashCount;
    int smooth;               // 1: one-pixel soft rim (old smooth lines); 0: hard edge
    int opaque;               // 1: drawn without transparency (old code with blending off)
} BKViewPen;

// What: lines through model points xy[2 n] (x0, y0, x1, y1, ...). colors: NULL = `color`, else one per point
// (each piece fades from its first point's colour to its last's, as OpenGL's smooth shading did).
void BKViewDrawLines(BKOverlayList *list, const BKViewXf *xf, const double *xy, uint32_t n, int how,
                     const BKViewPen *pen, BKOverlayColor color, const BKOverlayColor *colors);

// What: dots of `size` view pixels at model points (round + soft edge when `round`, else square).
void BKViewDrawDots(BKOverlayList *list, const BKViewXf *xf, const double *xy, uint32_t n, float size, int round,
                    BKOverlayColor color, const BKOverlayColor *colors);

// What: a filled shape through model points: BKOverlayFillFan (as OpenGL's GL_POLYGON, right for convex
// shapes) or BKOverlayFillEvenOdd; colors (fan only) as above; opaque: without transparency.
void BKViewDrawFill(BKOverlayList *list, const BKViewXf *xf, const double *xy, uint32_t n, int rule, int smooth,
                    int opaque, BKOverlayColor color, const BKOverlayColor *colors);

// What: picture `image` (in the list, imgW x imgH pixels) drawn into the model rectangle (x, y, w, h), its
// pixel rows going down the rectangle; flipX / flipY: the drawing space is mirrored and the picture is
// mirrored back so it reads normally (StringTexture's rule). crisp: the corner is put on a whole view pixel
// and pixels are not smoothed (the classic bitmap-font look); otherwise smooth sampling unless the picture
// lands exactly 1:1 on whole pixels. Mask images take `color`; RGBA images are multiplied by it.
void BKViewDrawPicture(BKOverlayList *list, const BKViewXf *xf, int32_t image, uint32_t imgW, uint32_t imgH,
                       double x, double y, double w, double h, int flipX, int flipY, int crisp, BKOverlayColor color);

// What: the magnifying lens (overlay-engine plan step 6, 2026-11-16). A square of side `side` model units with
// its top-left corner at model (x, y) shows part of a zoomed picture, cut to shape by a mask picture.
//   zoomed: zoomSize x zoomSize pixels, 4 bytes each, row 0 = top; its red, green, blue bytes start at byte
//           `redOffset` of each pixel (0 for R,G,B,A; 1 for A,R,G,B); its own alpha byte is not used.
//   from, to: the part of the zoomed picture shown, in its pixel units: the square's left / top edge shows
//           coordinate `from`, its right / bottom edge `to` (both directions the same; may run backwards).
//   mask: maskW x maskH bytes, row 0 = top; each byte = how much of the lens shows there (0 none, 255 all);
//         it is stretched over the whole square.
//   smooth: 1 = the zoomed pixels are blended (linear), 0 = shown as hard blocks; the mask is always smooth.
// The lens is built as ONE picture with about one pixel per view pixel (so its edge stays smooth at any zoom)
// and placed with the view's transform (any rotation / mirror). Returns 1 when drawn, 0 when there was nothing
// to draw (zero size, missing pictures, or a picture too large for the list).
// Plain language: the round magnifier that follows the mouse - zoomed image inside, see-through outside.
int BKViewDrawLens(BKOverlayList *list, const BKViewXf *xf, double x, double y, double side,
                   const uint8_t *zoomed, uint32_t zoomSize, uint32_t redOffset, double from, double to,
                   const uint8_t *mask, uint32_t maskW, uint32_t maskH, int smooth);

// What: the lens's size in pixels for a square of `side` model units under `xf` (the longer of its two edges in
// view pixels, rounded up, at least 1, at most 4096) - the size of the picture BKViewDrawLens builds.
uint32_t BKViewLensPictureSize(const BKViewXf *xf, double side);

#ifdef __cplusplus
}
#endif

#endif
