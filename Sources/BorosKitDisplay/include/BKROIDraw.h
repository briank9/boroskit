// BorosKitDisplay: BKROIDraw - draws ROIs into the overlay engine's draw list (BKOverlayCore), plain C99.
// Overlay-engine plan step 6 (2026-11-16): each ROI kind gets licence-free drawing code that emits
// draw-list items directly (no OpenGL-style calls, no translation layer). Written from the RECORDED look
// of the old Horos drawing (sizes, colours, order - noted per kind); no old code copied. One kind at a
// time, each checked by the user against the old look.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99; output is the backend-neutral draw list.
// - Coordinates: ROI points in image pixels; BKROIDrawTransform maps them to view pixels (y down), the
//   space of the draw list. Sizes (line widths, dot sizes) are in view pixels.
//
// Plain language: the app says where the image is on screen (the transform), the ROI's colour, line
// thickness and selection state; this file adds the ROI's lines, dots and handles to the frame's list.

#ifndef BK_ROI_DRAW_H
#define BK_ROI_DRAW_H

#include "BKOverlayCore.h"
#include "BKROICore.h"

#ifdef __cplusplus
extern "C" {
#endif

// Image pixels -> view pixels: view = (a x + c y + tx, b x + d y + ty).
typedef struct { double a, b, c, d, tx, ty; } BKROIDrawTransform;

// What the drawing needs to know about the ROI and the view.
typedef struct {
    BKROIDrawTransform xf;
    BKOverlayColor color;     // the ROI's colour and opacity
    float thick;              // the ROI's line thickness setting
    float backing;            // screen pixels per point (2 on Retina)
    int highlight;            // the view shows selection handles
    int selected;             // the ROI is selected (or being drawn / edited)
    int32_t hotA, hotB;       // point being moved / under the mouse (-1: none) - drawn red
} BKROIDrawContext;

// What: the view position of image point p.
BKVec2f BKROIDrawMap(const BKROIDrawContext *ctx, BKROIPoint p);

// Building blocks (view sizes in pixels; anti-aliased like the old smooth lines and round points).
// What: a line through image points (closed: back to the first).
void BKROIDrawLine(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                   int closed, float width, BKOverlayColor color);
// What: round dots of diameter `size` at image points.
void BKROIDrawDots(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                   float size, BKOverlayColor color);
// What: selection handles (old look): when highlight is on, the hot points red (1, 0.2, 0.2) and - if
// the ROI is selected - the others light blue (0.5, 0.5, 1), round, diameter `size`.
void BKROIDrawHandles(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                      float size);

// What: a length ROI (old look, recorded 2026-11-16):
// - if cobbHighlight: first a yellow (1, 1, 0, 50 %) line, 3 x thick wide (the first of two or more
//   length ROIs on the image when the Cobb angle is shown);
// - the line through the points, thick wide, in the ROI colour, and dots of thick at each point;
// - handles of sqrt(thick) x 3 (the old code used this size for every line kind);
// - if 0 <= along: a red (1, 0, 0) marker at that fraction of the way from point 0 to point 1, size
//   (backing + sqrt(thick)) x 3.5 (the old code's "mouse position" marker on the line).
// Sizes x backing. Points: the ROI's points (usually 2).
void BKROIDrawLength(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                     int cobbHighlight, float along);

#ifdef __cplusplus
}
#endif

#endif
