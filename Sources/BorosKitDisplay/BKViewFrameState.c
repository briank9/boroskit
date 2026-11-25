// BorosKitDisplay: BKViewFrameState - see BKViewFrameState.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.
// Boros 6 (2026-11-24, gl-2d-final): overlay-engine plan step 8, decoupling round 3.

#include "BKViewFrameState.h"
#include <string.h>

void BKViewFrameStateReset(BKViewFrameState *s)
{
    if (!s) return;
    memset(s, 0, sizeof *s);
    BKViewMatricesReset(&s->m);
    BKViewPenStateReset(&s->pen);
    s->blendSrc = BKViewBlendOne;
    s->blendDst = BKViewBlendZero;
    s->pen.premultiplied = 1;          // source factor One (only matters once blending is switched on)
}

void BKViewFrameStateCarryOver(BKViewFrameState *s)
{
    if (!s) return;
    BKViewMatricesKeepTops(&s->m);
    s->savedTop = 0;
}

void BKViewFrameStateSetSwitch(BKViewFrameState *s, BKViewSwitch sw, int32_t on)
{
    if (!s) return;
    int32_t v = on ? 1 : 0;
    switch (sw) {
        case BKViewSwitchBlend: s->pen.blend = v; break;
        case BKViewSwitchSmoothLines: s->pen.smoothLines = v; break;
        case BKViewSwitchRoundPoints: s->pen.roundPoints = v; break;
        case BKViewSwitchSmoothFills: s->pen.smoothFills = v; break;
        case BKViewSwitchDashes: s->pen.dashed = v; break;
        case BKViewSwitchClip: s->clipOn = v; break;
        default: break;
    }
}

int32_t BKViewFrameStateSwitch(const BKViewFrameState *s, BKViewSwitch sw)
{
    if (!s) return 0;
    switch (sw) {
        case BKViewSwitchBlend: return s->pen.blend;
        case BKViewSwitchSmoothLines: return s->pen.smoothLines;
        case BKViewSwitchRoundPoints: return s->pen.roundPoints;
        case BKViewSwitchSmoothFills: return s->pen.smoothFills;
        case BKViewSwitchDashes: return s->pen.dashed;
        case BKViewSwitchClip: return s->clipOn;
        default: return 0;
    }
}

void BKViewFrameStateSetBlend(BKViewFrameState *s, BKViewBlendFactor src, BKViewBlendFactor dst)
{
    if (!s) return;
    s->blendSrc = (int32_t)src;
    s->blendDst = (int32_t)dst;
    s->pen.premultiplied = (src == BKViewBlendOne) ? 1 : 0;
}

int32_t BKViewFrameStateBlendIsPlain(const BKViewFrameState *s)
{
    if (!s) return 0;
    if (!s->pen.blend) return 1;
    return s->blendDst == BKViewBlendOneMinusSrcAlpha &&
           (s->blendSrc == BKViewBlendSrcAlpha || s->blendSrc == BKViewBlendOne);
}

int32_t BKViewFrameStateSave(BKViewFrameState *s, uint32_t groups)
{
    if (!s || s->savedTop >= BK_VIEW_SAVE_DEPTH) return 0;
    BKViewFrameSaved *o = &s->saved[s->savedTop++];
    o->groups = groups;
    o->pen = s->pen;
    memcpy(o->viewport, s->viewport, sizeof o->viewport);
    memcpy(o->clip, s->clip, sizeof o->clip);
    o->clipOn = s->clipOn;
    o->blendSrc = s->blendSrc;
    o->blendDst = s->blendDst;
    o->matrixMode = s->m.mode;
    return 1;
}

int32_t BKViewFrameStateRestore(BKViewFrameState *s)
{
    if (!s || s->savedTop <= 0) return 0;
    const BKViewFrameSaved *o = &s->saved[--s->savedTop];
    uint32_t g = o->groups;
    if (g & BKViewSaveSwitches) {
        s->pen.blend = o->pen.blend; s->pen.smoothLines = o->pen.smoothLines;
        s->pen.roundPoints = o->pen.roundPoints; s->pen.smoothFills = o->pen.smoothFills;
        s->pen.dashed = o->pen.dashed; s->clipOn = o->clipOn;
    }
    if (g & BKViewSaveColor)
        memcpy(s->pen.color, o->pen.color, sizeof s->pen.color);
    if (g & BKViewSaveLines) {
        s->pen.lineWidth = o->pen.lineWidth;
        s->pen.dashPattern = o->pen.dashPattern; s->pen.dashRepeat = o->pen.dashRepeat;
        s->pen.smoothLines = o->pen.smoothLines; s->pen.dashed = o->pen.dashed;
    }
    if (g & BKViewSavePoints) {
        s->pen.pointSize = o->pen.pointSize;
        s->pen.roundPoints = o->pen.roundPoints;
    }
    if (g & BKViewSaveFills)
        s->pen.smoothFills = o->pen.smoothFills;
    if (g & BKViewSaveBlend) {
        s->pen.blend = o->pen.blend;
        s->blendSrc = o->blendSrc; s->blendDst = o->blendDst;
        s->pen.premultiplied = o->pen.premultiplied;
    }
    if (g & BKViewSaveViewport)
        memcpy(s->viewport, o->viewport, sizeof s->viewport);
    if (g & BKViewSaveClip) {
        memcpy(s->clip, o->clip, sizeof s->clip);
        s->clipOn = o->clipOn;
    }
    if (g & BKViewSaveMatrixMode)
        BKViewMatricesSetMode(&s->m, o->matrixMode);
    return 1;
}

int32_t BKViewFrameStateTo2D(const BKViewFrameState *s, int32_t width, int32_t height,
                             BKViewXf *xf, double *zx, double *zy)
{
    if (!s || !xf) return 0;
    if (width && s->viewport[2] != width) return 0;
    if (height && s->viewport[3] != height) return 0;
    return BKViewMatricesTo2D(&s->m, s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3], xf, zx, zy) ? 1 : 0;
}
