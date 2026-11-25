// Tests for BKVolumeFusionCore (colour scans and fusion in the 3D picture, plain C) and the colour-scan ray walk of
// BKVolumeRayCore. Boros 6 (2026-11-24, vr-colour-fusion).
//
// Original BorosKit code written for this project; contains no third-party code. The expected numbers are worked out
// by hand from the rules in BKVolumeFusionCore.h (the classic window's behaviour); a Vulkan port must give the same.

#import <XCTest/XCTest.h>
#include "BKVolumeFusionCore.h"
#include "BKVolumeRayCore.h"

@interface BKVolumeFusionCoreTests : XCTestCase
@end

@implementation BKVolumeFusionCoreTests

// The fusion slider rule: slider 128 (50 %). MIP: 2 * 128 * i / 256 = i -> i / 255. Other modes: 128 / 3 * i / 256 - 8.
- (void)testBlendOpacityTable
{
    float t[256];
    BKFusionBlendOpacityTable(128, 1, t);
    XCTAssertEqualWithAccuracy(t[0], 0.0f, 1e-7);
    XCTAssertEqualWithAccuracy(t[100], 100.0f / 255.0f, 1e-6);
    XCTAssertEqualWithAccuracy(t[255], 1.0f, 1e-6);
    BKFusionBlendOpacityTable(256, 1, t);   // doubled: capped at 255 -> 1
    XCTAssertEqualWithAccuracy(t[200], 1.0f, 1e-6);
    BKFusionBlendOpacityTable(128, 0, t);
    XCTAssertEqualWithAccuracy(t[0], 0.0f, 1e-7);                                  // -8 -> 0
    XCTAssertEqualWithAccuracy(t[40], 0.0f, 1e-7);                                 // 6.67 - 8 < 0
    XCTAssertEqualWithAccuracy(t[255], (128.0f / 3.0f * 255.0f / 256.0f - 8.0f) / 255.0f, 1e-6);
    BKFusionBlendOpacityTable(0, 0, t);
    for (int i = 0; i < 256; i++) XCTAssertEqual(t[i], 0.0f);                       // slider at 0: invisible
}

- (void)testBlendProjectionAndUnitDistance
{
    XCTAssertEqual(BKFusionBlendProjection(0), BKFusionProjectionComposite);
    XCTAssertEqual(BKFusionBlendProjection(1), BKFusionProjectionMaximum);
    XCTAssertEqual(BKFusionBlendProjection(2), BKFusionProjectionMinimum);
    XCTAssertEqual(BKFusionBlendProjection(3), BKFusionProjectionMinimum);          // classic: mean -> minimum
    XCTAssertEqualWithAccuracy(BKFusionBlendOpacityUnitDistance(4.0f), 0.25f, 1e-7);
    XCTAssertEqualWithAccuracy(BKFusionBlendOpacityUnitDistance(0.0f), 1.0f, 1e-7);
    XCTAssertEqualWithAccuracy(BKFusionTableEntryValue(-100, 154, 0), -100.0f, 1e-6);
    XCTAssertEqualWithAccuracy(BKFusionTableEntryValue(-100, 154, 254), 154.0f, 1e-4);
    XCTAssertEqualWithAccuracy(BKFusionTableEntryValue(0, 254, 127), 127.0f, 1e-4);
}

// Table lookup: 4 entries over [0, 4]: entry k sits at value k + 0.5 (texel = x * 4 - 0.5); blends linearly between.
- (void)testTableLookupPositionRule
{
    float table[16] = { 0,0,0,0,  1,1,1,1,  2,2,2,2,  3,3,3,3 };
    float out[4];
    BKFusionTableLookup(table, 4, 0, 4, 0.5f, out);  XCTAssertEqualWithAccuracy(out[0], 0.0f, 1e-6);
    BKFusionTableLookup(table, 4, 0, 4, 1.0f, out);  XCTAssertEqualWithAccuracy(out[0], 0.5f, 1e-6);
    BKFusionTableLookup(table, 4, 0, 4, 2.5f, out);  XCTAssertEqualWithAccuracy(out[3], 2.0f, 1e-6);
    BKFusionTableLookup(table, 4, 0, 4, -50.0f, out); XCTAssertEqualWithAccuracy(out[1], 0.0f, 1e-6);   // clamped
    BKFusionTableLookup(table, 4, 0, 4, 99.0f, out);  XCTAssertEqualWithAccuracy(out[2], 3.0f, 1e-6);
}

- (void)testStepOpacity
{
    XCTAssertEqual(BKFusionStepOpacity(0.0f, 2.0f), 0.0f);
    XCTAssertEqual(BKFusionStepOpacity(-1.0f, 2.0f), 0.0f);
    XCTAssertEqualWithAccuracy(BKFusionStepOpacity(0.5f, 1.0f), 0.5f, 1e-6);
    XCTAssertEqualWithAccuracy(BKFusionStepOpacity(0.5f, 2.0f), 0.75f, 1e-6);     // two unit lengths: 1 - 0.5^2
    XCTAssertEqualWithAccuracy(BKFusionStepOpacity(1.0f, 1.0f), 0.9999f, 1e-6);   // never fully opaque in one step
}

// A table over bytes 0..255 (2 entries): colour black -> white, opacity 0 -> 1, i.e. about byte / 255 (blended).
static void RampTable(float table[8]) { float t[8] = { 0,0,0,0, 1,1,1,1 }; for (int i = 0; i < 8; i++) table[i] = t[i]; }

// Colour scan, ramps (no colour table): a pure red voxel gives red only; a grey voxel adds three channels.
- (void)testColorVoxelStepRamps
{
    float table[8];
    RampTable(table);
    float red[3] = { 255, 0, 0 }, out[4];
    BKColorVoxelStep(red, table, 2, 0, 255, 1.0f, 0, out);
    // Byte 255 -> table position clamped to the last entry -> opacity 1 -> step 0.9999; green / blue bytes 0 -> 0.
    XCTAssertEqualWithAccuracy(out[3], 0.9999f, 1e-5);
    XCTAssertEqualWithAccuracy(out[0], 0.9999f, 1e-5);
    XCTAssertEqualWithAccuracy(out[1], 0.0f, 1e-7);
    XCTAssertEqualWithAccuracy(out[2], 0.0f, 1e-7);
    float grey[3] = { 127.5f, 127.5f, 127.5f };
    BKColorVoxelStep(grey, table, 2, 0, 255, 1.0f, 0, out);
    // Each channel: position 0.5 * 2 - 0.5 = 0.5 -> opacity 0.5; colour of that channel 0.5. Sum: opacity 1.5 -> 1,
    // premultiplied 0.5 * 0.5 = 0.25 per component (each below the opacity, no cap).
    XCTAssertEqualWithAccuracy(out[3], 1.0f, 1e-6);
    for (int k = 0; k < 3; k++) XCTAssertEqualWithAccuracy(out[k], 0.25f, 1e-6);
}

// Colour scan with a colour table: every channel takes the table's colour (here the grey ramp) at its byte.
- (void)testColorVoxelStepTableColours
{
    float table[8];
    RampTable(table);
    float v[3] = { 127.5f, 0, 0 }, out[4];
    BKColorVoxelStep(v, table, 2, 0, 255, 1.0f, 1, out);
    XCTAssertEqualWithAccuracy(out[3], 0.5f, 1e-6);          // only the red byte has opacity
    for (int k = 0; k < 3; k++) XCTAssertEqualWithAccuracy(out[k], 0.25f, 1e-6);   // 0.5 x grey 0.5 in all three
}

- (void)testMixSamples
{
    float a[4] = { 0.25f, 0, 0, 0.5f }, b[4] = { 0, 0, 0.5f, 0.5f }, none[4] = { 0, 0, 0, 0 }, out[4], back[4];
    BKFusionMixSamples(a, none, out);
    for (int k = 0; k < 4; k++) XCTAssertEqual(out[k], a[k]);         // an empty step leaves the other exactly
    BKFusionMixSamples(none, b, out);
    for (int k = 0; k < 4; k++) XCTAssertEqual(out[k], b[k]);
    BKFusionMixSamples(a, b, out);
    BKFusionMixSamples(b, a, back);
    for (int k = 0; k < 4; k++) XCTAssertEqualWithAccuracy(out[k], back[k], 1e-7);   // order does not matter
    // opacity 1 - 0.5 * 0.5 = 0.75; straight colour = (0.25, 0, 0.5) / 1.0 -> premultiplied x 0.75.
    XCTAssertEqualWithAccuracy(out[3], 0.75f, 1e-6);
    XCTAssertEqualWithAccuracy(out[0], 0.1875f, 1e-6);
    XCTAssertEqualWithAccuracy(out[1], 0.0f, 1e-7);
    XCTAssertEqualWithAccuracy(out[2], 0.375f, 1e-6);
    float under[3] = { 1, 1, 1 }, pic[3];
    BKFusionOverlay(out, under, pic);
    XCTAssertEqualWithAccuracy(pic[0], 0.1875f + 0.25f, 1e-6);
}

- (void)testRayBoxIntervalAndUnion
{
    double t0, t1;
    BKVec3d lo = BKV3d(0, 0, 0), hi = BKV3d(9, 9, 9);
    XCTAssertEqual(BKFusionRayBoxInterval(BKV3d(5, 5, -10), BKV3d(0, 0, 1), lo, hi, -INFINITY, INFINITY, &t0, &t1), 1);
    XCTAssertEqualWithAccuracy(t0, 10.0, 1e-12);
    XCTAssertEqualWithAccuracy(t1, 19.0, 1e-12);
    // Perspective ray starting inside: from t = 0.
    XCTAssertEqual(BKFusionRayBoxInterval(BKV3d(5, 5, 5), BKV3d(0, 0, 1), lo, hi, 0, INFINITY, &t0, &t1), 1);
    XCTAssertEqualWithAccuracy(t0, 0.0, 1e-12);
    XCTAssertEqualWithAccuracy(t1, 4.0, 1e-12);
    // Parallel to z, outside the box's x range: a miss.
    XCTAssertEqual(BKFusionRayBoxInterval(BKV3d(20, 5, -10), BKV3d(0, 0, 1), lo, hi, -INFINITY, INFINITY, &t0, &t1), 0);
    // Union of two stretches (first scan 10..19, fused scan 4..30) and of only one.
    XCTAssertEqual(BKFusionUnionInterval(1, 10, 19, 1, 4, 30, &t0, &t1), 1);
    XCTAssertEqual(t0, 4.0); XCTAssertEqual(t1, 30.0);
    XCTAssertEqual(BKFusionUnionInterval(0, 10, 19, 1, 4, 30, &t0, &t1), 1);
    XCTAssertEqual(t0, 4.0); XCTAssertEqual(t1, 30.0);
    XCTAssertEqual(BKFusionUnionInterval(0, 0, 0, 0, 0, 0, &t0, &t1), 0);
}

- (void)testWindowDrag
{
    float wl, ww;
    // Ordinary: level 100, width 200 -> adapter 2; down 3 points, right 5: level 94, width 210. Fractions cut off.
    BKFusionWindowDrag(100, 200, 5.7, 3.2, 0, 0, 0, &wl, &ww);
    XCTAssertEqualWithAccuracy(wl, 94.0f, 1e-5);
    XCTAssertEqualWithAccuracy(ww, 210.0f, 1e-5);
    BKFusionWindowDrag(100, 1, -500, 0, 0, 0, 0, &wl, &ww);
    XCTAssertEqualWithAccuracy(ww, 0.1f, 1e-6);           // never below 0.1
    // PET mode 1: bottom 0 kept, top moves up by 10 x adapter 1 (width 100): width 110, level 55 + 0.
    BKFusionWindowDrag(50, 100, 0, -10, 1, 1, 0, &wl, &ww);
    XCTAssertEqualWithAccuracy(ww, 110.0f, 1e-5);
    XCTAssertEqualWithAccuracy(wl, 55.0f, 1e-5);
    // PET mode 2: bottom 0 + 4, top 100 - (-6) -> window 4..106.
    BKFusionWindowDrag(50, 100, 4, -6, 1, 2, 0, &wl, &ww);
    XCTAssertEqualWithAccuracy(ww, 102.0f, 1e-5);
    XCTAssertEqualWithAccuracy(wl, 55.0f, 1e-5);
}

// Colour scan ray walk: a 10 x 10 x 10 scan (A, R, G, B bytes), empty except slices 6..9 (R 90, G 30, B 0).
- (void)testColorRayWalk
{
    static uint8_t bytes[1000 * 4];
    memset(bytes, 0, sizeof bytes);
    for (int z = 6; z < 10; z++)
        for (int i = 0; i < 100; i++) { uint8_t *v = bytes + 4 * (z * 100 + i); v[0] = 255; v[1] = 90; v[2] = 30; v[3] = 0; }
    BKRayColorVolume vol = { bytes, 10, 10, 10, 4, 1, 2, 3, {0} };
    vol.patientToVoxel[0] = vol.patientToVoxel[5] = vol.patientToVoxel[10] = vol.patientToVoxel[15] = 1;
    // Opacity over bytes 0..255: 0 below 64, 0.5 from 64 up (nearest entry of 5 at 0, 64, 128, 191, 255).
    float op[5] = { 0, 0.5f, 0.5f, 0.5f, 0.5f };
    BKRayOpacityTable t = { op, 5, 0, 255 };
    // One voxel: red 90 -> entry 1 (0.5), green 30 / blue 0 -> entry 0 (0): 0.5 per step, so 2 steps reach 1.
    XCTAssertEqualWithAccuracy(BKRayColorOpacity(&t, bytes + 4 * 600, 1, 2, 3), 0.5, 1e-12);
    double a[3] = { 5, 5, -5 }, b[3] = { 5, 5, 20 };
    BKRayHit hit;
    XCTAssertEqual(BKVolumeRayFirstHitColor(&vol, a, b, 1.0, &t, BKRayModeAccumulate, 1.0, 0, NULL, 0, &hit), 1);
    XCTAssertEqual(hit.voxel[2], 7);                                   // slice 6 (0.5) + slice 7 (0.5) = 1
    XCTAssertEqualWithAccuracy(hit.value, 40.0f, 1e-5);                // (90 + 30 + 0) / 3
    XCTAssertEqual(BKVolumeRayFirstHitColor(&vol, a, b, 1.0, &t, BKRayModeMaximum, 1.0, 0, NULL, 0, &hit), 1);
    XCTAssertEqualWithAccuracy(hit.value, 40.0f, 1e-5);
    // All transparent: nothing.
    float zero[1] = { 0 };
    BKRayOpacityTable none = { zero, 1, 0, 255 };
    XCTAssertEqual(BKVolumeRayFirstHitColor(&vol, a, b, 1.0, &none, BKRayModeAccumulate, 1.0, 0, NULL, 0, &hit), 0);
}

@end
