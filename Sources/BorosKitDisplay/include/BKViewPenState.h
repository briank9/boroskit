// BorosKitDisplay: BKViewPenState - the 2D views' current drawing settings (colour, line width, dot size,
// smoothing, blending, dash pattern), plain C99. Overlay-engine plan step 8d (2026-11-16): takes over what the
// app's soft-GL layer kept, so the views' drawing takes its pen from BorosKit only.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99; no Apple, GPU or LGPL types.
// - The dash pattern is kept the way the classic drawing code sets it (a 16-bit on/off pattern, each bit
//   `repeat` pixels long, read from bit 0); BKViewPenStateDashes turns it into on/off lengths for BKViewPen.
//
// Plain language: what colour and what kind of pen the view is drawing with right now.

#ifndef BK_VIEW_PEN_STATE_H
#define BK_VIEW_PEN_STATE_H

#include <stdint.h>
#include "BKViewOverlayDraw.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float color[4];               // current colour (r, g, b, a; 0..1)
    float lineWidth, pointSize;   // view pixels
    int32_t smoothLines;          // 1: soft line edges
    int32_t roundPoints;          // 1: round, soft dots (else square)
    int32_t smoothFills;          // 1: soft edges on filled shapes
    int32_t blend;                // 1: drawn with transparency (0: opaque)
    int32_t premultiplied;        // 1: colours already multiplied by alpha (blend source "one")
    int32_t dashed;               // 1: the dash pattern below applies
    uint32_t dashPattern;         // 16 bits, 1 = drawn; bit 0 first
    int32_t dashRepeat;           // pixels per bit (>= 1)
} BKViewPenState;

// What: the classic defaults - white, width 1, size 1, nothing smoothed, no blending, solid lines.
void BKViewPenStateReset(BKViewPenState *s);

// What: the dash pattern as on / off lengths in view pixels, starting with a dash (the pattern is rotated to
// its first drawn bit), written to dashes[0 .. max-1]; returns how many (always even; 0 = solid line - not
// dashed, an all-drawn pattern or an empty one).
uint32_t BKViewPenStateDashes(const BKViewPenState *s, float *dashes, uint32_t max);

// What: a BKViewPen of `width` view pixels with this state's smoothing, blending and dashes (dashes stored in
// `dashStore`, room for 32 floats, which must live as long as the pen is used).
BKViewPen BKViewPenStatePen(const BKViewPenState *s, float width, float *dashStore);

#ifdef __cplusplus
}
#endif

#endif
