// BorosKit GPU tests: the 2D golden scenes (overlay draw list, display images) shared by the Mac XCTest golden tests
// and the Vulkan / cross-backend programs. Header-only plain C. 2026-11-26, agent "vulkan-engine" (Vulkan plan 7.1 #6).
// Original BorosKit code written for this project; contains no third-party code.
//
// What:
//   - BKGoldenOverlayScene: the BKOverlayRendererTests scene (gradient polyline, dashed line, even-odd polygon,
//     round dots, RGBA image, rotated alpha mask, clipped opaque bar) PLUS a label-map overlay drawn exactly the way
//     Boros 6's segmentation overlay does it (BorosSegmentationOverlay.m: an RGBA picture of straight-alpha class
//     colours, nearest sampling, BKOverlayDrawImage with white) - the label-map hook of the 2D overlay engine.
//   - BKGoldenDisplayGrey / BKGoldenDisplayLabels: a 64 x 48 grey float image (ramp + ring) and an RGBA label
//     picture (two classes, straight alpha) for the image-layer (display) golden with a see-through overlay layer.
#ifndef BK_DISPLAY_GOLDEN_SCENE_H
#define BK_DISPLAY_GOLDEN_SCENE_H

#include <math.h>
#include <string.h>
#include "BKOverlayCore.h"

enum { BKGoldenOverlayWidth = 160, BKGoldenOverlayHeight = 120, BKGoldenDisplayW = 64, BKGoldenDisplayH = 48 };

// RGBA label picture (w x h): class 1 a disc (red, alpha 0.5), class 2 a bar (green, alpha 0.75), outline of the
// disc fully opaque yellow; the rest transparent (straight alpha, as BKLabelSliceToRGBA writes it).
static inline void BKGoldenLabelPicture(uint8_t *rgba, uint32_t w, uint32_t h)
{
    memset(rgba, 0, (size_t)w * h * 4);
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x++) {
            uint8_t *p = rgba + 4 * ((size_t)y * w + x);
            double dx = x - w * 0.4, dy = y - h * 0.5, r = sqrt(dx * dx + dy * dy), R = h * 0.3;
            if (r <= R) { p[0] = 255; p[1] = 0; p[2] = 0; p[3] = 128; }
            if (r <= R && r > R - 1.5) { p[0] = 255; p[1] = 255; p[2] = 0; p[3] = 255; }
            if (x > w * 0.65 && x < w * 0.85 && y > h * 0.2 && y < h * 0.8) { p[0] = 0; p[1] = 200; p[2] = 0; p[3] = 191; }
        }
}

static inline void BKGoldenOverlayScene(BKOverlayList *l)
{
    BKOverlayStroke s; memset(&s, 0, sizeof(s));
    s.width = 2.5f; s.join = BKOverlayJoinMiter; s.miterLimit = 10; s.smooth = 1;
    BKVec2f zig[4] = { {10, 10}, {60, 40}, {90, 12}, {150, 50} };
    BKOverlayColor cols[4] = { {1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {1, 1, 0, 0.6f} };
    BKOverlayStrokePolyline(l, zig, cols, 4, 0, &s, cols[0]);
    float dash[2] = { 6, 4 };
    BKOverlayStroke ds = s; ds.dashes = dash; ds.dashCount = 2; ds.width = 1; ds.smooth = 0;
    BKVec2f line[2] = { {5, 70}, {155, 70} };
    BKOverlayColor yellow = { 1, 1, 0, 1 };
    BKOverlayStrokePolyline(l, line, NULL, 2, 0, &ds, yellow);
    BKVec2f poly[5] = { {20, 80}, {60, 78}, {70, 110}, {40, 95}, {15, 112} };
    BKOverlayColor fillc = { 0.2f, 0.6f, 1, 0.5f };
    BKOverlayFillPolygon(l, poly, NULL, 5, BKOverlayFillEvenOdd, 1, fillc);
    BKVec2f dots[3] = { {100, 90}, {110.5f, 95.5f}, {125, 100} };
    BKOverlayColor white = { 1, 1, 1, 1 };
    BKOverlayPoints(l, dots, NULL, 3, 5, 1, 1, white);
    uint8_t px[16] = { 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 255, 64 };
    int32_t img = BKOverlayAddImage(l, 2, 2, BKOverlayImageRGBA8, px, 8);
    BKOverlayDrawImage(l, img, BKV2f(130, 80), BKV2f(10, 0), BKV2f(0, 10), 0, white);
    uint8_t mask[9] = { 0, 128, 255, 255, 128, 0, 64, 192, 32 };
    int32_t m = BKOverlayAddImage(l, 3, 3, BKOverlayImageAlpha8, mask, 3);
    BKOverlayColor tint = { 1, 0.4f, 0.1f, 1 };
    BKOverlayDrawImage(l, m, BKV2f(100, 15), BKV2f(8, 3), BKV2f(-3, 8), 0, tint);
    // Label-map overlay (segmentation): 40 x 30 label picture scaled 1.5x, nearest, white.
    uint8_t labels[40 * 30 * 4];
    BKGoldenLabelPicture(labels, 40, 30);
    int32_t lab = BKOverlayAddImage(l, 40, 30, BKOverlayImageRGBA8, labels, 40 * 4);
    BKOverlayDrawImage(l, lab, BKV2f(95.25f, 52.5f), BKV2f(1.5f, 0), BKV2f(0, 1.5f), 0, white);
    BKOverlaySetClip(l, 0, 100, 80, 20);
    BKOverlaySetIgnoreAlpha(l, 1);
    BKVec2f bar[4] = { {0, 105}, {160, 105}, {160, 118}, {0, 118} };
    BKOverlayColor half = { 0.5f, 0.5f, 0.5f, 0.3f };
    BKOverlayFillPolygon(l, bar, NULL, 4, BKOverlayFillFan, 0, half);
}

// Grey display image: a ramp -1000..1000 across x plus a ring of +600.
static inline void BKGoldenDisplayGrey(float *v)
{
    for (uint32_t y = 0; y < BKGoldenDisplayH; y++)
        for (uint32_t x = 0; x < BKGoldenDisplayW; x++) {
            double dx = x - 30.0, dy = y - 22.0, r = sqrt(dx * dx + dy * dy);
            v[y * BKGoldenDisplayW + x] = (float)(-1000.0 + 2000.0 * x / (BKGoldenDisplayW - 1) + (r > 12 && r < 16 ? 600.0 : 0.0));
        }
}

#endif
