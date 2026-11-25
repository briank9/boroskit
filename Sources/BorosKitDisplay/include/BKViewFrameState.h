// BorosKitDisplay: BKViewFrameState - everything a 2D view's drawing "remembers" while it draws one frame:
// its positioning (BKViewMatrices), its pen (BKViewPenState), the viewport, the clip box, the blend rule and a
// small save / restore stack. Plain C99. Overlay-engine plan step 8, decoupling round 3 (2026-11-24,
// gl-2d-final): the native (Metal) 2D frames keep their drawing state HERE, in BorosKit, instead of in the
// app's soft-GL layer; the app's remaining soft-GL adapter (only for older view classes and plug-ins that
// still call OpenGL-style functions) reads and writes this same state.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 (int32_t / float / double); no Apple, GPU or LGPL types,
//   no allocation. Nothing here talks to a GPU: the state only decides WHERE and HOW the overlay engine
//   (BKOverlayCore / BKViewOverlayDraw / BKROIDraw) places and paints what the views draw.
// - The save groups are the drawing state groups the views' code saves and restores around a block (colour,
//   line pen, dot pen, fill smoothing, blending, all switches, viewport, clip box, matrix mode); a backend
//   never sees them.
// - BKViewFrameStateTo2D gives the 2D affine BKViewXf (drawing space -> view pixels, top-left origin, y down)
//   that every BorosKit 2D drawing function takes; a Vulkan overlay renderer uses the same draw list.
//
// Plain language: the view says "zoom here, use this colour, this line width, clip to this box"; this file
// remembers it for the frame, and can put an earlier setting back when the view asks.
#ifndef BK_VIEW_FRAME_STATE_H
#define BK_VIEW_FRAME_STATE_H

#include <stdint.h>
#include "BKViewMatrix.h"
#include "BKViewPenState.h"

#ifdef __cplusplus
extern "C" {
#endif

// The on / off switches of the pen (stored in BKViewPenState) and the clip box.
typedef enum {
    BKViewSwitchBlend = 0,      // paint with transparency (pen.blend)
    BKViewSwitchSmoothLines,    // soft line edges (pen.smoothLines)
    BKViewSwitchRoundPoints,    // round, soft dots (pen.roundPoints)
    BKViewSwitchSmoothFills,    // soft edges on filled shapes (pen.smoothFills)
    BKViewSwitchDashes,         // dash pattern applies (pen.dashed)
    BKViewSwitchClip,           // clip to the clip box (clipOn)
    BKViewSwitchCount
} BKViewSwitch;

// Blend factors, as the views name them (the classic code's source / destination factors).
typedef enum {
    BKViewBlendZero = 0,
    BKViewBlendOne,
    BKViewBlendSrcAlpha,
    BKViewBlendOneMinusSrcAlpha,
    BKViewBlendOther            // anything else (the engine cannot paint it the classic way)
} BKViewBlendFactor;

// Save groups for BKViewFrameStateSave (any combination).
enum {
    BKViewSaveColor      = 1u << 0,   // pen colour
    BKViewSaveLines      = 1u << 1,   // line width, dash pattern, line smoothing + dashes switches
    BKViewSavePoints     = 1u << 2,   // dot size, round-dots switch
    BKViewSaveFills      = 1u << 3,   // fill smoothing switch
    BKViewSaveBlend      = 1u << 4,   // blend switch + factors
    BKViewSaveSwitches   = 1u << 5,   // every switch (BKViewSwitch*)
    BKViewSaveViewport   = 1u << 6,   // viewport
    BKViewSaveClip       = 1u << 7,   // clip box + clip switch
    BKViewSaveMatrixMode = 1u << 8,   // which matrix stack is current
    BKViewSaveAll        = 0x1FFu
};

#define BK_VIEW_SAVE_DEPTH 16

// One saved copy (everything except the matrices, which have their own stacks).
typedef struct {
    uint32_t groups;
    BKViewPenState pen;
    int32_t viewport[4];
    int32_t clip[4];
    int32_t clipOn;
    int32_t blendSrc, blendDst;       // BKViewBlendFactor
    int32_t matrixMode;               // BKMatrixModelView / Projection / Texture
} BKViewFrameSaved;

typedef struct {
    BKViewMatrices m;                 // positioning stacks (BKViewMatrix)
    BKViewPenState pen;               // colour, widths, smoothing, blending, dashes (BKViewPenState)
    int32_t viewport[4];              // x, y, width, height in view pixels (bottom-left origin, as the views set it)
    int32_t clip[4];                  // clip box x, y, width, height (bottom-left origin)
    int32_t clipOn;                   // 1: drawing is clipped to `clip`
    int32_t blendSrc, blendDst;       // BKViewBlendFactor (pen.premultiplied follows blendSrc == One)
    BKViewFrameSaved saved[BK_VIEW_SAVE_DEPTH];
    int32_t savedTop;                 // number of saved copies
} BKViewFrameState;

// What: the starting state of a view that never drew natively: identity matrices (model-view current), the
// pen defaults (BKViewPenStateReset), viewport and clip box 0, every switch off, blend factors One / Zero,
// nothing saved.
void BKViewFrameStateReset(BKViewFrameState *s);

// What: prepares the state a view carries into its next frame: each matrix stack keeps only its top matrix,
// the save stack is emptied (a frame may not restore what an earlier frame saved).
void BKViewFrameStateCarryOver(BKViewFrameState *s);

// What: switch `sw` on (1) or off (0) / its current value (0 for an unknown switch).
void BKViewFrameStateSetSwitch(BKViewFrameState *s, BKViewSwitch sw, int32_t on);
int32_t BKViewFrameStateSwitch(const BKViewFrameState *s, BKViewSwitch sw);

// What: the blend factors (pen.premultiplied = source is One).
void BKViewFrameStateSetBlend(BKViewFrameState *s, BKViewBlendFactor src, BKViewBlendFactor dst);

// What: 1 when what is drawn now can be painted by the overlay engine as the classic code painted it:
// blending off, or the normal "paint with transparency" rule (destination OneMinusSrcAlpha, source SrcAlpha
// or One = colours already premultiplied).
int32_t BKViewFrameStateBlendIsPlain(const BKViewFrameState *s);

// What: saves the `groups` (BKViewSave*) / puts the last saved copy back (only its groups). Return 1, or 0
// when the stack is full / empty (nothing changed; the caller decides, the views treat it as "cannot draw").
int32_t BKViewFrameStateSave(BKViewFrameState *s, uint32_t groups);
int32_t BKViewFrameStateRestore(BKViewFrameState *s);

// What: the current drawing space as a 2D placement on the current viewport (BKViewMatricesTo2D): 1 and *xf
// (and *zx / *zy, may be NULL) filled, or 0 when the matrices are not plain 2D or the viewport does not start
// at 0, 0. When `width` / `height` are not 0 the viewport must also be exactly that size (the overlay's).
int32_t BKViewFrameStateTo2D(const BKViewFrameState *s, int32_t width, int32_t height,
                             BKViewXf *xf, double *zx, double *zy);

#ifdef __cplusplus
}
#endif

#endif
