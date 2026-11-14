// BorosKitDisplay: BKTextLayoutCore - where the lines of an on-screen text label go (plain C,
// positions only; no fonts, no drawing).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C99 with BorosKit's own vector type BKVec2f (BKVec.h); no Objective-C, CoreGraphics,
//   CoreText, VTK, Apple simd or LGPL types. Compiles unchanged on Windows/Linux.
// - The drawing layer measures each line with its own font system (Core Text on Apple; on
//   Windows/Linux whatever 2D text route is chosen, VULKAN-PORT-PLAN R11) and hands in the
//   line widths and the line height; this core returns each line's top-left corner. So the
//   placement rules are written once and every platform puts the text in the same spot.
// - Deterministic, no allocation.
//
// Plain language: the 3D window writes a few labels over the picture - the WL/WW values top left,
// the orientation letters at the middle of each edge, the turn angles bottom right. Each label
// is pinned to a point of the view (a fraction of its width / height, plus a few points of
// offset) and is left / centre / right aligned there, and its block of lines is top / middle /
// bottom aligned. These are the same rules VTK's text actors used (and the VTK -> Metal mirror
// copied): lines step down by lineHeight x lineSpacing, every line aligned on its own.
//
// Units: view points, origin TOP-LEFT, x right, y DOWN.

#ifndef BK_TEXT_LAYOUT_CORE_H
#define BK_TEXT_LAYOUT_CORE_H

#include "BKVec.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Horizontal alignment of every line at the anchor (same numbers as BKTextHorizontalAlignment).
enum { BKTextLayoutLeft = 0, BKTextLayoutCenter = 1, BKTextLayoutRight = 2 };
// Vertical alignment of the whole block of lines at the anchor.
enum { BKTextLayoutTop = 0, BKTextLayoutMiddle = 1, BKTextLayoutBottom = 2 };

// Nine named spots of a view, for convenience (BKTextLayoutCornerAnchor).
enum {
    BKTextCornerTopLeft = 0, BKTextCornerTop = 1, BKTextCornerTopRight = 2,
    BKTextCornerLeft = 3, BKTextCornerCenter = 4, BKTextCornerRight = 5,
    BKTextCornerBottomLeft = 6, BKTextCornerBottom = 7, BKTextCornerBottomRight = 8
};

typedef struct {
    BKVec2f anchor;        // fraction of the view: (0, 0) top-left, (1, 1) bottom-right
    BKVec2f offset;        // view points added to the anchor (x right, y down)
    int32_t horizontal;    // BKTextLayoutLeft / Center / Right
    int32_t vertical;      // BKTextLayoutTop / Middle / Bottom (the block)
    float lineHeight;      // one line's height (font ascent + descent), points
    float lineSpacing;     // distance between line tops, in lineHeights (VTK's default 1.1); <= 0 -> 1
} BKTextLayoutItem;

// What: the anchor point in view points of a view viewWidth x viewHeight (anchor fraction x size
// + offset).
BKVec2f BKTextLayoutAnchorPoint(const BKTextLayoutItem *item, float viewWidth, float viewHeight);

// What: height of a block of lineCount lines: lineHeight + (lineCount - 1) x lineHeight x spacing.
float BKTextLayoutBlockHeight(const BKTextLayoutItem *item, uint32_t lineCount);

// What: top-left corner (view points, y down) of each of the lineCount lines whose measured
// widths (points) are lineWidths[i]; written to outTopLeft[i]. Empty lines (width 0) keep their
// row. Returns lineCount (0 when item / arrays are NULL).
uint32_t BKTextLayoutLines(const BKTextLayoutItem *item, float viewWidth, float viewHeight,
                           const float *lineWidths, uint32_t lineCount, BKVec2f *outTopLeft);

// What: the anchor fraction and alignments that pin a label to one of the nine named spots
// (e.g. BKTextCornerTopRight -> anchor (1, 0), right, top). Any output may be NULL.
void BKTextLayoutCornerAnchor(int32_t corner, BKVec2f *anchor, int32_t *horizontal, int32_t *vertical);

#ifdef __cplusplus
}
#endif

#endif
