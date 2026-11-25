// BorosKitRender: the small rules of an MPR / curved-MPR slab view (plain C).
// See include/BKSlabViewCore.h for what each function does, the rules and the porting notes.
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKSlabViewCore.h"
#include <math.h>

int32_t BKSlabViewToolForEvent(int32_t currentTool, int32_t button, int32_t contextMenuActive,
                               uint32_t modifiers, const BKSlabViewToolIds *ids)
{
    if (ids == NULL) return currentTool;
    int32_t tool = currentTool;
    if (button == BKSlabViewButtonRight && !contextMenuActive) tool = ids->zoom;
    else if (button == BKSlabViewButtonOther) tool = ids->translate;
    if (modifiers & BKSlabViewModControl) tool = ids->rotate;
    if (modifiers & BKSlabViewModShift) tool = ids->zoom;
    if (modifiers & BKSlabViewModCommand) tool = ids->translate;
    if (modifiers & BKSlabViewModOption) tool = ids->windowLevel;
    if ((modifiers & BKSlabViewModCommand) && (modifiers & BKSlabViewModOption)) tool = ids->rotate;
    if ((modifiers & BKSlabViewModCommand) && (modifiers & BKSlabViewModControl)) tool = ids->camera3D;
    return tool;
}

int BKSlabViewWindowLevelDrag(double *wl, double *ww, double dx, double dy, int32_t petMode, double petMinimum)
{
    if (wl == NULL || ww == NULL || !isfinite(*wl) || !isfinite(*ww) || !isfinite(dx) || !isfinite(dy) ||
        !isfinite(petMinimum))
        return 0;
    double startWL = *wl, startWW = *ww;
    double startMin = startWL - startWW / 2, startMax = startWL + startWW / 2;
    double adapter = startWW / 100.0;
    double nwl = startWL, nww = startWW;
    if (petMode == 1) {
        double endLevel = startMax + (-dy) * adapter;
        nwl = (endLevel - startMin) / 2 + petMinimum;
        nww = endLevel - startMin;
        if (nww < 0.1) nww = 0.1;
        if (nwl - nww / 2 < 0) nwl = nww / 2;
    } else if (petMode == 2) {
        double endLevel = startMax - dy * adapter;
        double startLevel = startMin + dx * adapter;
        if (startLevel < 0) startLevel = 0;
        nwl = startLevel + (endLevel - startLevel) / 2;
        nww = endLevel - startLevel;
        if (nww < 0.1) nww = 0.1;
        if (nwl - nww / 2 < 0) nwl = nww / 2;
    } else {
        // Normal scans and PET style 0: the deltas are truncated to whole points first (classic rule).
        nwl = startWL - (double)(long)dy * adapter;
        nww = startWW + (double)(long)dx * adapter;
    }
    if (nww < 0.1) nww = 0.1;
    *wl = nwl;
    *ww = nww;
    return 1;
}

BKVec3d BKSlabViewOriginWithoutWindowCenter(BKVec3d originWithShift, BKVec3d right, BKVec3d down,
                                            double windowCenterX, double windowCenterY, double resolution)
{
    return BKV3dAdd(originWithShift, BKV3dAdd(BKV3dScale(right, windowCenterX * resolution),
                                              BKV3dScale(down, windowCenterY * resolution)));
}

BKVec3d BKSlabViewClickPosition(BKVec3d originWithoutShift, BKVec3d right, BKVec3d down,
                                double x, double y, double frameHeight, double resolution)
{
    return BKV3dAdd(originWithoutShift, BKV3dAdd(BKV3dScale(down, (frameHeight - y) * resolution),
                                                 BKV3dScale(right, x * resolution)));
}

int BKSlabViewBlendingOpacityTable(double factor, int32_t maximumIntensity, float out[256])
{
    if (out == NULL || !isfinite(factor)) return 0;
    double a = maximumIntensity ? factor * 2 : factor / 3;
    for (int i = 0; i < 256; i++) {
        double v = (a * (double)i) / 256.0;
        if (!maximumIntensity) v -= 8.0;
        if (v > 255) v = 255;
        if (v < 0) v = 0;
        out[i] = (float)(v / 255.0);
    }
    return 1;
}

BKSlabViewExportFormat BKSlabViewExportFormatForMinimum(double volumeMinimum)
{
    BKSlabViewExportFormat f;
    if (volumeMinimum < -1024) { f.isSigned = 1; f.offset = 0; }
    else if (volumeMinimum >= 0) { f.isSigned = 0; f.offset = 0; }
    else { f.isSigned = 0; f.offset = -1024; }
    return f;
}

int BKSlabViewValuesTo16Bit(const float *values, size_t count, BKSlabViewExportFormat format,
                            double slope, uint16_t *out)
{
    if (values == NULL || out == NULL) return 0;
    if (!(slope > 0) || !isfinite(slope)) slope = 1;
    double lo = format.isSigned ? -32768.0 : 0.0, hi = format.isSigned ? 32767.0 : 65535.0;
    for (size_t i = 0; i < count; i++) {
        double s = ((double)values[i] - (double)format.offset) / slope;
        if (s != s) s = 0;            // NaN
        if (s < lo) s = lo;
        if (s > hi) s = hi;
        double r = nearbyint(s);      // default rounding mode: nearest, ties to even
        if (format.isSigned) {
            int16_t v = (int16_t)r;
            out[i] = (uint16_t)v;
        } else {
            out[i] = (uint16_t)r;
        }
    }
    return 1;
}

int BKSlabViewRGBAToOpaqueARGB(const uint8_t *in, size_t count, uint8_t *out)
{
    if (in == NULL || out == NULL) return 0;
    for (size_t i = 0; i < count; i++) {
        uint8_t r = in[4 * i], g = in[4 * i + 1], b = in[4 * i + 2];
        out[4 * i] = 255;
        out[4 * i + 1] = r;
        out[4 * i + 2] = g;
        out[4 * i + 3] = b;
    }
    return 1;
}

int BKSlabViewARGBToRGB(const uint8_t *in, size_t count, uint8_t *out)
{
    if (in == NULL || out == NULL) return 0;
    for (size_t i = 0; i < count; i++) {
        uint8_t r = in[4 * i + 1], g = in[4 * i + 2], b = in[4 * i + 3];
        out[3 * i] = r;
        out[3 * i + 1] = g;
        out[3 * i + 2] = b;
    }
    return 1;
}
