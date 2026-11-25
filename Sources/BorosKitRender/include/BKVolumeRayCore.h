// BorosKitRender: BKVolumeRayCore - "what is under the mouse in a 3D volume picture", plain C99. Boros 6 (2026-11-18,
// 3D-off-VTK plan step V.3): the volume and endoscopy windows' 3D point tool, bone removal and double-click, without
// VTK.
//
// Original BorosKit code written for this project; contains no third-party code. The method is the plain ray walk the
// classic window used: step along the click ray through the scan, look up how opaque each scan value is in the
// window's colour / opacity table, add the opacities up, and stop where the total reaches a threshold (the bone the
// user sees). In MIP mode (maximum intensity) the brightest value on the ray is taken instead.
//
// PORTING NOTES (Vulkan / other backends): VULKAN: safe to translate directly. Pure C99 on floats / doubles, no Apple,
// GPU or LGPL types. The matrix is 16 doubles column by column (element [col * 4 + row]), like BKViewMatrix.
//
// Plain language: shoot a line from the eye through the mouse into the scan and report the first spot that looks solid.

#ifndef BK_VOLUME_RAY_CORE_H
#define BK_VOLUME_RAY_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const float *voxels;            // width * height * depth values, x fastest, then y, then slice
    int32_t width, height, depth;
    double patientToVoxel[16];      // patient mm -> voxel index (x, y, slice), column by column
} BKRayVolume;

typedef struct {
    const float *opacity;           // opacity (0..1) of `count` evenly spaced scan values from minValue to maxValue
    int32_t count;
    double minValue, maxValue;      // outside the range: the end entries
} BKRayOpacityTable;

enum { BKRayModeAccumulate = 0, BKRayModeMaximum = 1 };

typedef struct {
    double patient[3];              // the spot, patient mm
    int32_t voxel[3];               // its nearest voxel (x, y, slice)
    float value;                    // the scan value there
} BKRayHit;

// What: walks from `start` to `end` (patient mm) in steps of `stepMM`. A step is skipped when its point is outside the
// scan or "hidden": any plane (nx, ny, nz, w) of `hiddenPlanes` (count `planeCount`, may be NULL / 0) with
// n.p + w > 0 hides it (the cropping box, the clipping-range slab). Nearest-voxel values.
// Accumulate mode: opacity(value) of each step is added up; the first step where the sum reaches `threshold` (and,
// when minValue != 0, the value is at least `minValue`) is the hit.
// Maximum mode: the step with the highest value is the hit (only values >= minValue when minValue != 0).
// Returns 1 with *hit filled, or 0 when nothing qualified.
int BKVolumeRayFirstHit(const BKRayVolume *volume, const double start[3], const double end[3], double stepMM,
                        const BKRayOpacityTable *table, int32_t mode, double threshold, double minValue,
                        const float *hiddenPlanes, int32_t planeCount, BKRayHit *hit);

// What: the opacity table's value at `value` (nearest entry; clamped at the ends). 1 when the table is empty.
double BKRayOpacityAt(const BKRayOpacityTable *table, double value);

// --- Colour (RGB) scans (Boros 6, 2026-11-24, vr-colour-fusion) ---------------------------------------------------
// A colour scan: one voxel = `bytesPerVoxel` bytes (the app's colour scans: 4 bytes A, R, G, B), the colour channels
// at byte offsets redByte / greenByte / blueByte.
typedef struct {
    const uint8_t *bytes;           // width * height * depth voxels, x fastest, then y, then slice
    int32_t width, height, depth;
    int32_t bytesPerVoxel;
    int32_t redByte, greenByte, blueByte;
    double patientToVoxel[16];      // patient mm -> voxel index (x, y, slice), column by column
} BKRayColorVolume;

// What: BKVolumeRayFirstHit for a colour scan, with the same rules as the 3D picture of a colour scan
// (BKVolumeFusionCore.h): a step's opacity = the opacity table's value of its red byte + of its green byte + of its blue
// byte, capped at 1 (table over byte values, e.g. 0..255); the reported value (and the maximum-mode "brightness") is
// the grey value (R + G + B) / 3 - the same grey the app's ROI values use for colour images. Nearest voxel.
// Why: the 3D point tool, double-click and bone removal on colour scans without VTK.
int BKVolumeRayFirstHitColor(const BKRayColorVolume *volume, const double start[3], const double end[3], double stepMM,
                             const BKRayOpacityTable *table, int32_t mode, double threshold, double minValue,
                             const float *hiddenPlanes, int32_t planeCount, BKRayHit *hit);

// What: the opacity of one colour voxel under `table` (the rule above). Shared by the walk and its tests.
double BKRayColorOpacity(const BKRayOpacityTable *table, const uint8_t *voxel, int32_t redByte, int32_t greenByte,
                         int32_t blueByte);

#ifdef __cplusplus
}
#endif

#endif
