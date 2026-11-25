// BorosKitRender: BKVolumeFusionCore - colour (RGB) scans and fusion (a second scan blended over the first) in the
// 3D volume picture, plain C99. Boros 6 (2026-11-24, vr-colour-fusion, 3D-off-VTK plan steps 4 + 5): the volume and
// endoscopy windows draw colour scans and fused series without VTK.
//
// Original BorosKit code written for this project; contains no third-party code. The rules below were written from
// the behaviour of the classic Boros volume window (what the user sees), not from any library's source:
//  - Colour scans: each of the three colour channels (red, green, blue byte 0..255) is looked up separately in the
//    window's opacity table; the channel's colour is a pure red / green / blue ramp (no colour table chosen) or the
//    colour table's colour at that byte (a colour table chosen). The three contributions are ADDED (premultiplied
//    colour and opacity), the opacity capped at 1 - the classic window's "three independent components" look.
//  - Fusion: the fused scan has its own placement, window, colour table and an opacity ramp set by the window's
//    fusion slider (BKFusionBlendOpacityTable). In 3D mode both scans are sampled at the same points of each ray and
//    mixed there (BKFusionMixSamples), so the fused scan is in front of / behind the first scan exactly where it is in
//    the patient. In MIP / MinIP / mean the fused scan's own projection is laid over the first scan's grey picture.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 on floats / doubles (BKVec3d from BorosKitVec), no Apple, GPU, VTK
//   or LGPL types. The GPU shader (BKShaderSource.mm, bk_trace_ext and helpers) mirrors these functions line by line
//   - a Vulkan compute shader must do the same; the XCTests (BKVolumeFusionCoreTests) are the reference numbers.
// - Colour volume texture: RGBA8_UNORM 3D, linear filtering (mandatory format feature in Vulkan, no fallback needed;
//   the manual-filtering switch still reads 8 texels by hand for identical numbers on every GPU).
// - The fused scan needs a second 3D texture and a second 4096 x 1 RGBA32F table (bindings 5 and 6 of the ray-cast
//   kernels); both are plain sampled images.
//
// Plain language: how a colour scan and a second, overlaid scan are turned into colours along each ray of the 3D
// picture, and the fusion slider's opacity rule.

#ifndef BK_VOLUME_FUSION_CORE_H
#define BK_VOLUME_FUSION_CORE_H

#include <stdint.h>
#include "BKVec.h"

#ifdef __cplusplus
extern "C" {
#endif

// What the fused scan does along the ray for each render mode of the first scan.
enum {
    BKFusionProjectionComposite = 0,   // 3D: sampled and mixed with the first scan at every step
    BKFusionProjectionMaximum   = 1,   // MIP: its brightest value, laid over the picture
    BKFusionProjectionMinimum   = 2,   // MinIP and mean: its darkest value, laid over the picture (classic rule)
};

// What: the fused scan's projection for the first scan's render mode (0 3D, 1 MIP, 2 MinIP, 3 mean). The classic
// window switched the fused scan to minimum intensity for both MinIP and mean (it had no mean mode for the fused
// scan); kept so the pictures look the same.
int32_t BKFusionBlendProjection(int32_t mainMode);

// What: the fused scan's 256 opacities (0..1) across its window, from the fusion slider value `blendFactor`
// (0..256, the window's slider; 128 = 50 %), as the classic window built them:
//   MIP:        opacity[i] = clamp(2 * f * i / 256, 0, 255) / 255
//   other modes: opacity[i] = clamp(f / 3 * i / 256 - 8, 0, 255) / 255
// `maximumIntensity` = 1 for the MIP rule (the first scan in MIP mode), 0 otherwise.
void BKFusionBlendOpacityTable(float blendFactor, int32_t maximumIntensity, float out[256]);

// What: the opacity unit distance (mm) for the fused scan in 3D mode. The classic window applied the fused scan's
// opacities per "VTK world unit" (pixel spacing / super-sampling mm) while the first scan's opacities were divided by
// the super-sampling factor; BorosKit applies the first scan's opacities per millimetre. To keep the classic balance
// between the two scans the fused scan's opacities apply per 1 / superSampling mm. superSampling <= 0 -> 1 mm.
float BKFusionBlendOpacityUnitDistance(float superSampling);

// What: the value at which the classic fusion table entry `index` (0..254) sits: low + (high - low) * index / 254
// (the classic tables use their first 255 entries spread over the window, the last entry on the window's end).
float BKFusionTableEntryValue(float low, float high, int32_t index);

// What: one lookup in a baked colour / opacity table (`entries` RGBA floats spread over [tableMin, tableMax]), with
// the same position rule and linear blend between the two nearest entries as the GPU: texel = x * entries - 0.5,
// clamped to the first / last entry, x = (value - tableMin) / (tableMax - tableMin).
void BKFusionTableLookup(const float *rgba, int32_t entries, float tableMin, float tableMax, float value, float out[4]);

// What: the opacity of one step along the ray from a table opacity (VTK-free form of the usual correction for the
// step length): 0 when tableOpacity <= 0, else 1 - (1 - min(tableOpacity, 0.9999)) ^ exponent, exponent = step
// length / opacity unit distance.
float BKFusionStepOpacity(float tableOpacity, float exponent);

// What: one step of a colour scan along the ray. rgb = the step's red, green, blue (0..255, interpolated), table =
// the window's baked colour / opacity table (see BKFusionTableLookup), exponent = see BKFusionStepOpacity.
// useTableColours = 0: each channel is a pure ramp (red byte r -> colour (r/255, 0, 0), etc.); 1: each channel takes
// the table's colour at its byte. out = premultiplied RGB + opacity of the step: the three channels' (opacity,
// opacity x colour) ADDED, the opacity capped at 1 and each colour component capped at the opacity.
void BKColorVoxelStep(const float rgb[3], const float *table, int32_t entries, float tableMin, float tableMax,
                      float exponent, int32_t useTableColours, float out[4]);

// What: two steps at the same spot (premultiplied RGB + opacity each, e.g. the first and the fused scan) mixed into
// one: opacity = 1 - (1 - a1)(1 - a2) (light gets through only where both let it through); colour = the opacity-
// weighted average of the two colours. Order does not matter; a step with opacity 0 leaves the other unchanged.
void BKFusionMixSamples(const float a[4], const float b[4], float out[4]);

// What: MIP / MinIP / mean with fusion: the fused scan's projected step (premultiplied RGB + opacity) laid over the
// first scan's picture colour `under` (RGB 0..1): out = over.rgb + (1 - over.a) * under.
void BKFusionOverlay(const float over[4], const float under[3], float out[3]);

// What: the part of the ray origin + t * dir inside the box [lo, hi] (all in one space, e.g. voxel indices): writes
// *t0 <= *t1 and returns 1, or returns 0 when the ray misses. A direction component of 0 means "no limit along that
// axis" when the origin is inside the box's range on that axis, else a miss. tMin / tMax: the ray's own limits
// (e.g. 0 / +infinity for a perspective ray, -infinity / +infinity for a parallel one).
int BKFusionRayBoxInterval(BKVec3d origin, BKVec3d dir, BKVec3d lo, BKVec3d hi, double tMin, double tMax,
                           double *t0, double *t1);

// What: the stretch of the ray that covers both intervals (the first scan's and the fused scan's): the union of the
// ones that exist (has* = 1). Returns 0 when neither exists.
int BKFusionUnionInterval(int hasA, double a0, double a1, int hasB, double b0, double b1, double *t0, double *t1);

// What: the fused scan's window after one mouse-drag event of the "fused window / level" tool (classic tWLBlended),
// from the window before the event. dx = horizontal move (view points, right positive), dyDown = vertical move (down
// positive); both counted in whole points like the classic window. Ordinary scans: level -= dy * width / 100,
// width += dx * width / 100. PET (and NM with "mouseWindowingNM"): petMode 0 the same; petMode 1 moves only the top
// of the window (bottom kept, level = half the width + petMinimum, never below half the width); petMode 2 moves
// bottom with dx and top with dy (bottom never below 0). The width never goes below 0.1.
void BKFusionWindowDrag(float startLevel, float startWidth, double dx, double dyDown, int32_t isPET, int32_t petMode,
                        float petMinimum, float *level, float *width);

#ifdef __cplusplus
}
#endif

#endif
