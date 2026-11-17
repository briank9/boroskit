// BorosKitDisplay: BKViewPenState - see BKViewPenState.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKViewPenState.h"
#include <string.h>

void BKViewPenStateReset(BKViewPenState *s)
{
    if (!s) return;
    memset(s, 0, sizeof *s);
    s->color[0] = s->color[1] = s->color[2] = s->color[3] = 1;
    s->lineWidth = 1; s->pointSize = 1;
    s->dashPattern = 0xFFFF; s->dashRepeat = 1;
}

uint32_t BKViewPenStateDashes(const BKViewPenState *s, float *dashes, uint32_t max)
{
    if (!s || !dashes || max < 2 || !s->dashed) return 0;
    uint32_t pattern = s->dashPattern & 0xFFFF;
    if (pattern == 0 || pattern == 0xFFFF) return 0;
    int repeat = s->dashRepeat >= 1 ? s->dashRepeat : 1;
    int start = 0;
    while (start < 16 && ((pattern >> start) & 1) == 0) start++;
    // Runs of equal bits from the first drawn bit, round the 16 bits once: drawn, gap, drawn, ...
    uint32_t n = 0;
    int bit = 1, run = 0;
    for (int k = 0; k < 16; k++) {
        int b = (int)((pattern >> ((start + k) % 16)) & 1);
        if (b == bit) run++;
        else {
            if (n < max) dashes[n++] = (float)(run * repeat);
            bit = b; run = 1;
        }
    }
    if (n < max) dashes[n++] = (float)(run * repeat);
    if (n % 2) { if (n < max) dashes[n++] = 0; else n--; }
    return n;
}

BKViewPen BKViewPenStatePen(const BKViewPenState *s, float width, float *dashStore)
{
    BKViewPen p;
    memset(&p, 0, sizeof p);
    p.width = width;
    if (!s) return p;
    uint32_t n = dashStore ? BKViewPenStateDashes(s, dashStore, 32) : 0;
    p.dashes = n ? dashStore : NULL;
    p.dashCount = n;
    p.smooth = s->smoothLines ? 1 : 0;
    p.opaque = s->blend ? 0 : 1;
    return p;
}
