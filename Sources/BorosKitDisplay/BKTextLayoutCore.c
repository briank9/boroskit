// BorosKitDisplay: text label placement in plain C.
// Original BorosKit code written for this project; contains no third-party code.
// See include/BKTextLayoutCore.h for the rules and the porting notes.

#include "BKTextLayoutCore.h"
#include <stddef.h>

BKVec2f BKTextLayoutAnchorPoint(const BKTextLayoutItem *item, float viewWidth, float viewHeight)
{
    if (item == NULL) return BKV2f(0, 0);
    return BKV2f(item->anchor.x * viewWidth + item->offset.x, item->anchor.y * viewHeight + item->offset.y);
}

float BKTextLayoutBlockHeight(const BKTextLayoutItem *item, uint32_t lineCount)
{
    if (item == NULL || lineCount == 0) return 0;
    float spacing = item->lineSpacing > 0 ? item->lineSpacing : 1.0f;
    return item->lineHeight + (float)(lineCount - 1) * item->lineHeight * spacing;
}

uint32_t BKTextLayoutLines(const BKTextLayoutItem *item, float viewWidth, float viewHeight,
                           const float *lineWidths, uint32_t lineCount, BKVec2f *outTopLeft)
{
    if (item == NULL || lineWidths == NULL || outTopLeft == NULL) return 0;
    BKVec2f a = BKTextLayoutAnchorPoint(item, viewWidth, viewHeight);
    float spacing = item->lineSpacing > 0 ? item->lineSpacing : 1.0f;
    float step = item->lineHeight * spacing;
    float block = BKTextLayoutBlockHeight(item, lineCount);
    // Top of the block: the anchor is its top, middle or bottom.
    float top = a.y;
    if (item->vertical == BKTextLayoutMiddle) top = a.y - 0.5f * block;
    else if (item->vertical == BKTextLayoutBottom) top = a.y - block;
    for (uint32_t i = 0; i < lineCount; i++) {
        float w = lineWidths[i] > 0 ? lineWidths[i] : 0;
        float x = a.x;
        if (item->horizontal == BKTextLayoutCenter) x = a.x - 0.5f * w;
        else if (item->horizontal == BKTextLayoutRight) x = a.x - w;
        outTopLeft[i] = BKV2f(x, top + (float)i * step);
    }
    return lineCount;
}

void BKTextLayoutCornerAnchor(int32_t corner, BKVec2f *anchor, int32_t *horizontal, int32_t *vertical)
{
    if (corner < 0 || corner > 8) corner = BKTextCornerTopLeft;
    int32_t column = corner % 3, row = corner / 3;   // 0 left/top, 1 centre, 2 right/bottom
    if (anchor) *anchor = BKV2f(0.5f * (float)column, 0.5f * (float)row);
    if (horizontal) *horizontal = column == 0 ? BKTextLayoutLeft : (column == 1 ? BKTextLayoutCenter : BKTextLayoutRight);
    if (vertical) *vertical = row == 0 ? BKTextLayoutTop : (row == 1 ? BKTextLayoutMiddle : BKTextLayoutBottom);
}
