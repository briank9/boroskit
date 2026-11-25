// BorosKitRender: colour (RGB) scans in the MPR / curved-MPR slab modes (plain C).
// See include/BKSlabColourCore.h for the rules and the porting notes.
// Boros 6 (2026-11-24, mpr-colour).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKSlabColourCore.h"

void BKSlabColourOfChannels(uint8_t red, uint8_t green, uint8_t blue, const float *table, int useTableColours,
                            float rgbOut[3])
{
    if (rgbOut == NULL) return;
    rgbOut[0] = rgbOut[1] = rgbOut[2] = 0;
    if (table == NULL) return;
    uint8_t v[3] = { red, green, blue };
    for (int c = 0; c < 3; c++) {
        const float *e = &table[4 * v[c]];
        float a = e[3];
        if (!(a > 0)) continue;
        if (a > 1) a = 1;
        if (useTableColours) {
            rgbOut[0] += a * e[0];
            rgbOut[1] += a * e[1];
            rgbOut[2] += a * e[2];
        } else {
            rgbOut[c] += a * ((float)v[c] / 255.0f);
        }
    }
    for (int c = 0; c < 3; c++) {
        if (!(rgbOut[c] > 0)) rgbOut[c] = 0;
        if (rgbOut[c] > 1) rgbOut[c] = 1;   // each part capped at 1 (classic)
    }
}

int BKSlabColourMapChannels(const uint8_t *projectedRGBA, size_t count, const float *table, int useTableColours,
                            uint8_t *outARGB)
{
    if (projectedRGBA == NULL || table == NULL || outARGB == NULL) return 0;
    for (size_t i = 0; i < count; i++) {
        float rgb[3];
        BKSlabColourOfChannels(projectedRGBA[4 * i], projectedRGBA[4 * i + 1], projectedRGBA[4 * i + 2], table,
                               useTableColours, rgb);
        outARGB[4 * i] = 255;
        outARGB[4 * i + 1] = (uint8_t)(rgb[0] * 255.0f + 0.5f);
        outARGB[4 * i + 2] = (uint8_t)(rgb[1] * 255.0f + 0.5f);
        outARGB[4 * i + 3] = (uint8_t)(rgb[2] * 255.0f + 0.5f);
    }
    return 1;
}
