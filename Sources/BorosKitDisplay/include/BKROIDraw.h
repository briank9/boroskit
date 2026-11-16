// BorosKitDisplay: BKROIDraw - draws ROIs into the overlay engine's draw list (BKOverlayCore), plain C99.
// Overlay-engine plan step 6 (2026-11-16): each ROI kind gets licence-free drawing code that emits
// draw-list items directly (no OpenGL-style calls, no translation layer). Written from the RECORDED look
// of the old Horos drawing (sizes, colours, order - noted per kind); no old code copied. One kind at a
// time, each checked by the user against the old look.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99; output is the backend-neutral draw list. EVERY function in
//   this header is safe to translate directly (no Apple types, no GPU calls, no platform text): it only
//   adds lines / fills / dots / images to the list. Text pictures (labels, text boxes, text ROIs) arrive as
//   ready-made alpha masks: making them is the platform's job (Apple: Core Text / AppKit glue in the app;
//   Windows / Linux: their own rasteriser) - that glue is NOT part of this file and is not translated.
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
    int selected;             // the ROI is selected (selected or being edited)
    int drawing;              // the ROI is being drawn
    int32_t hotA, hotB;       // point being moved / under the mouse (-1: none) - drawn red
    float scale;              // image zoom before the view's matrices (the old code's "scaleValue"): some
                              // kinds size or shape themselves in that space (oval point count, arrow head)
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

// What: a rectangle ROI (old look): corners (x, y), (x, y+h), (x+w, y+h), (x+w, y) as given (a negative
// size keeps its sign); closed outline thick wide and dots of thick at the corners in the ROI colour;
// handles at the corners in light blue (0.5, 0.5, 1), size (backing + sqrt(thick)) x 3.5 x backing, when
// highlight is on and the ROI is selected or being drawn. Sizes x backing.
void BKROIDrawRect(BKOverlayList *list, const BKROIDrawContext *ctx, double x, double y, double w, double h);

// What: an oval ROI (old look): centre (cx, cy), half-sizes |rw|, |rh|; n = (int)((|rh| + |rw|) x 1.5 x
// scale) points at angles i x 360 / n degrees (angle held as a float), closed outline thick wide and a dot
// of thick at every point (and at the centre when centreDot); handles (as the rectangle) at the four
// corners of the surrounding box and at the centre.
void BKROIDrawOval(BKOverlayList *list, const BKROIDrawContext *ctx, double cx, double cy, double rw, double rh,
                   int centreDot);

// What: an arrow ROI (old look) from a (the tip) to b, in the zoomed image space (scale): t = thick / 2
// (at most 5); head size 25 x t x backing / 3; the shaft (2 t wide, dots of 2 t at both ends) starts
// (head + 13 t x backing) from the tip along the arrow and ends at b; the head is a filled triangle
// with the tip at a and its two back corners (head + 15 t x backing) away at 80 and 100 degrees off
// the arrow (+/- t x backing degrees); directions measured with the pixel shape (spacingY / spacingX;
// 1 when unknown) as the old code did. Handles (sqrt(t) x 3 x backing, hot red / selected blue) and the
// "along the line" marker (as the length ROI, with t) as the length ROI.
void BKROIDrawArrow(BKOverlayList *list, const BKROIDrawContext *ctx, BKROIPoint a, BKROIPoint b,
                    double spacingX, double spacingY, float along);

// --- Kinds added 2026-11-16 (plan step 6, second batch) -------------------------------------------------
// Per-point flags for the "all points" handle style (polygons, pencil, angles, axis, TAGT).
enum {
    BKROIPointNearMouse = 1,   // the mouse is near this point while the ROI is being drawn -> magenta
    BKROIPointSkip = 2         // no handle at this point (TAGT's first point of B and C)
};

// What: handles in the "all points" style (old look): only when highlight is on and the ROI is selected,
// being edited or being drawn; each point red (1, 0.2, 0.2) when it is hot and the ROI is selected,
// magenta (1, 0, 1) when flagged near the mouse while drawing, otherwise light blue (0.5, 0.5, 1); round,
// diameter `size` (view pixels). flags: NULL or one per point.
void BKROIDrawAllHandles(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                         const uint8_t *flags, float size);

// Polygon-like kinds.
enum { BKROIPolyClosed = 0, BKROIPolyOpen = 1, BKROIPolyAngle = 2 };
// What: a closed polygon / pencil (BKROIPolyClosed), open polygon (BKROIPolyOpen) or 3-point angle
// (BKROIPolyAngle), old look: the outline through `curve` (the smoothed points the ROI shows; closed for
// BKROIPolyClosed unless being drawn) thick wide (x 2 while drawing); open polygon with `closeHint`: a faint
// closing line (opacity / 4) from the last curve point to the first; angle with 3 points: the arc at point
// 1 (BKAngleCore, radius at most 40 % of the shorter arm, preferred 25 x backing, in the zoomed image space);
// dots of the line width at every curve point; "all points" handles at the ROI's points, size
// (backing + sqrt(thick)) x 3.5 x backing; and - drawn always - a magenta (1, 0, 1) dot of that size on the
// point under the mouse (ctx->hotB). Sizes x backing.
void BKROIDrawPolygon(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *curve, uint32_t nCurve,
                      const BKROIPoint *pts, uint32_t n, int kind, int closeHint, const uint8_t *flags);

// What: a dynamic angle (old look): a line through the first four points (at most), thick wide (x 2 while
// drawing), whose colour fades to 10 % opacity at points 1 and 2 (the two lines join faintly); with four
// points the arc where the lines (or their extensions) cross, in the full colour, and thin dotted
// extensions (1 x backing wide, dashes of 4 x backing, 70 % opacity) from each line to the crossing;
// "all points" handles of (backing + sqrt(thick)) x 3.5 x backing. Sizes x backing.
void BKROIDrawDynamicAngle(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                           const uint8_t *flags);

// What: an axis ROI (old look): a closed outline through the first four points (at most), thick wide
// (x 2 while drawing); "all points" handles of (backing + sqrt(thick)) x 3.5 x backing; with four points,
// in the zoomed image space: a blue (0, 0, 1) line through the middles of sides 0-1 and 2-3, from 125 above
// the first middle to 125 below the second, and a red (1, 0, 0) line through the middles of sides 3-0 and
// 1-2, from 125 left of the first to 125 right of the second (both the outline's width); then the four
// points filled in the ROI colour at 25 % opacity (no soft edge).
void BKROIDrawAxis(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                   const uint8_t *flags);

// A text picture that is already in the list (BKOverlayAddImage, an alpha mask) and the size it is drawn
// at, in view pixels (the platform's text rasteriser makes it: Core Text on Apple).
typedef struct {
    int32_t image;            // index in the list, -1: none
    float width, height;      // drawn size, view pixels
} BKROIDrawLabel;

// What: a TAGT ROI (six points: B = 0-1, C = 2-3, A = 4-5), old look: the three lines thick wide; handles
// (all-points style, size thick x 2 x backing) except at points 0 and 2; the labels B, C, A next to points
// 1, 3, 5: picture's top-left at the point, turning with the image (flipX / flipY: the view mirrors the
// image, the picture is mirrored back so it reads normally), a black shadow one zoomed-image unit right and
// down, then yellow (1, 1, 0).
void BKROIDrawTAGT(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                   const uint8_t *flags, const BKROIDrawLabel labels[3], int flipX, int flipY);

// What: a 2D point ROI (old look): a 200-point circle of radius 8 in the zoomed image space (its height
// times spacingX / spacingY when both are known), 1 x backing wide, in the ROI colour; then a dot of
// (1 + sqrt(thick)) x 3.5 x backing at the centre - light blue (0.5, 0.5, 1, opacity) when highlight is on
// and the ROI is selected / edited / being drawn, else the ROI colour.
void BKROIDraw2DPoint(BKOverlayList *list, const BKROIDrawContext *ctx, BKROIPoint centre, double spacingX, double spacingY);

// What: a text ROI (old look): its text picture (text.width x text.height view pixels), upright (it does not
// turn with the image). The old code placed the picture's corner at centre - (boxW / 2, boxH / (2 ratio))
// (boxW / boxH: the ROI's box size, which the old code kept in points while the picture is in pixels, so on
// Retina the picture reaches right / down of the box; kept as it was) in a space the view mirrors (flipX /
// flipY), ratio = spacingX / spacingY (1 when unknown). First a black shadow one pixel right and down (in
// that space), opacity = the ROI's, then the ROI colour; handles (light blue, 6 x backing) at the box
// corners around the centre when highlight is on and the ROI is selected / edited / being drawn.
void BKROIDrawTextROI(BKOverlayList *list, const BKROIDrawContext *ctx, BKROIDrawLabel text, BKVec2f centre,
                      float boxW, float boxH, double ratio, int flipX, int flipY);

// What: the outline mask of a brush (8-bit mask, w x h): a (w + 2) x (h + 2) mask (one pixel of margin on
// every side) that is 255 where a pixel is NOT in the mask but one of its 8 neighbours (or itself) is - the
// ring just outside the brush region. dst must hold (w + 2) x (h + 2) bytes. Returns 0 on bad input.
int BKROIMaskOutline(const uint8_t *mask, uint32_t w, uint32_t h, uint8_t *dst);

// What: a brush ROI (old look): the mask (w x h, 8-bit, row 0 at image row upLeftY) laid on the image with
// its top-left corner at image point (upLeftX, upLeftY), one mask pixel per image pixel, in the ROI colour
// and opacity (linear: smooth sampling, else nearest); before it, when `outline` is given ((w + 2) x
// (h + 2) bytes, BKROIMaskOutline), the outline in black one pixel further out; when outline is NULL and
// highlight is on and the ROI is selected / edited / being drawn, light-blue handles of handleSize view
// pixels at the mask's four corners.
void BKROIDrawBrush(BKOverlayList *list, const BKROIDrawContext *ctx, const uint8_t *mask, uint32_t w, uint32_t h,
                    double upLeftX, double upLeftY, int linear, const uint8_t *outline, float handleSize);

// What: a layer (picture) ROI (old look): RGBA picture `image` (already in the list, imgW x imgH pixels)
// with its corners (0,0), (imgW,0), (0,imgH) on image points p1, p2, p4 (smooth sampling); with
// `handles`: light-blue dots of 8 x backing at p1, p2, p3, p4.
void BKROIDrawLayer(BKOverlayList *list, const BKROIDrawContext *ctx, int32_t image, uint32_t imgW, uint32_t imgH,
                    BKROIPoint p1, BKROIPoint p2, BKROIPoint p3, BKROIPoint p4, int handles);

// What: an ROI's measurement text box (old look). Coordinates in "box space": pixels with the origin at the
// view's centre, y down (the old code's space); view = box x scale + offset. When `connector`: a curve
// (quadratic, 31 points) from the box's left middle via (anchor.x - 30, anchor.y) to the anchor, first
// 3 x backing wide in dark red (0.3, 0, 0) - black when the ROI is asleep - then 1 x backing wide in white,
// both opaque and without soft edges (the old code drew them with blending off). No box background (the
// old background added nothing: transparent). Then each text line (up to 6, empty ones skipped): picture's
// top-left at (whole(textX - 2 x backing), whole(textY + line x lineHeight - height)) (whole: dropping the
// fraction, towards zero), black shadow one pixel right and down, then the ROI colour, opaque.
typedef struct {
    float scale, offsetX, offsetY;           // box space -> view pixels
    float boxX, boxY, boxW, boxH;            // the box (drawRect)
    float anchorX, anchorY;                  // the point the connector ends on
    int connector, asleep;
    float textX, textY, lineHeight;          // first line's text point; line spacing
    BKROIDrawLabel lines[6];                 // image -1 for an empty line
} BKROIDrawTextBox;
void BKROIDrawTextBoxItems(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIDrawTextBox *box);

#ifdef __cplusplus
}
#endif

#endif
