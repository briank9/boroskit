// BorosKitRender: BKThickSlabCore - the 2D viewer's "Thick Slab" volume-rendering picture, plain C99.
// Boros 6 (2026-11-24, thickslab, 3D-off-VTK plan step 7 "leftovers"): the 2D viewer's thick slab in VR mode is
// computed here instead of in the classic ThickSlabVR view (which needed VTK for its opacity curve and lived in a
// hidden window).
//
// Original BorosKit code written for this project; contains no third-party code. The rules below were written from
// the behaviour of the classic 2D viewer (what the user sees), not from any library's source:
//  - Window: every slice value of the slab is turned into a byte 0..255 across the viewer's window (level / width):
//    t = value * s + (o + 0.5), s = 255 / (high - low), o = -low * s, as ONE fused multiply-add; t <= 0 -> 0,
//    t >= 255 -> 255, else the whole part of t; not-a-number -> 0. (This matches, bit for bit, the Apple routine the
//    classic view used, measured on 28 million values - see BKThickSlabCoreTests.)
//  - Opacity: the window's opacity menu points (x stored + 1000, y 0..1) become a 256-entry curve: straight lines
//    between the points, flat beyond the first / last point, with the classic end rules (a point (0, 0) is added
//    unless the first point sits at 0; the end point (255, 1) is added unless the last point sits at 256, then
//    (255, last opacity)); a later point at the same place replaces an earlier one. No points = straight ramp 0..1.
//  - Picture: front-to-back compositing straight down the slab's slices (no resampling, no step correction - the
//    classic look). For each pixel: remaining = 1; for each slice: o = opacity[byte], capped at remaining;
//    remaining -= o; colour += o * colourTable[byte] (fused multiply-add). Colour table = the viewer's CLUT (0..255
//    per channel) or a grey ramp. Result bytes = the same window rule over 0..255.
//  - Slice order: the classic "VR" mode (thick slab mode 4) composites from the first slice in memory to the last;
//    mode 5 ("flipped") from the last to the first (reverseSlices = 1).
//  - Fused scan (optional, the classic view's blending inputs): both scans' bytes are looked up in the SAME opacity
//    curve; when their sum exceeds what remains, both are scaled down to fit and the walk stops; colour +=
//    mainColour * o + blendColour * ob.
//  - Output: ARGB8888 bytes (alpha 255 first, then red, green, blue) - what the 2D viewer's colour display reads.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 on floats (fmaf from <math.h>; GLSL fma()), no Apple, GPU, VTK or
//   LGPL types. A compute-shader version would be one invocation per output pixel walking the slices with the same
//   body (BKThickSlabCompositePixel); the window rule needs a real fused multiply-add for bit-identical bytes.
// - Today this runs on the CPU (rows split across cores by the caller, BKThickSlabRenderRows). Rows are independent
//   and the result does not depend on the split (checked by a test). The classic picture was CPU-made too; a GPU
//   path would need the slab's float slices uploaded per picture (often 100+ MB), which costs more than it saves.
// - BKThickSlabParams is a CPU-side struct with pointers; a GPU port would bind the four 256-entry tables as one
//   std430 float4[256] buffer plus the slab as a storage buffer, and pass the scalars as push constants.
//
// Plain language: how the 2D viewer's thick slab "VR" picture is made - each slice of the slab is shaded with the
// viewer's colour table and opacity curve and stacked front to back into one coloured picture.

#ifndef BK_THICK_SLAB_CORE_H
#define BK_THICK_SLAB_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: the window's low / high ends from level and width, computed in float exactly as the viewer does
// (low = level - width / 2, high = level + width / 2).
void BKThickSlabWindowEnds(float level, float width, float *outLow, float *outHigh);

// What: one value -> byte across the window (rule in the header comment). low == high (a zero-width window, which the
// classic routine refused, leaving old bytes): value >= low -> 255, else 0.
uint8_t BKThickSlabWindowByte(float value, float low, float high);

// What: the 256-entry opacity curve (0..1) from the window's opacity points. xStored = the points' x as the window
// stores them (table position + 1000), y = opacity; count 0 = the straight ramp i / 255 ("Linear Table").
void BKThickSlabOpacityTable(const double *xStored, const double *y, int32_t count, float out[256]);

// What: a grey colour table (entry i = i), for "No CLUT".
void BKThickSlabGreyTable(float out[256]);

// What: everything one thick-slab picture needs. Tables are 256 floats each; red/green/blue are 0..255.
typedef struct BKThickSlabParams {
    int32_t width, height;      // pixels of one slice (and of the picture)
    int32_t sliceCount;         // slices in the slab (>= 1)
    int32_t reverseSlices;      // 0 = first slice in memory is in front (mode 4), 1 = last slice in front (mode 5)
    const float *source;        // sliceCount * width * height floats, slice after slice
    float windowLow, windowHigh;
    const float *opacity;       // 256
    const float *red, *green, *blue;
    // Optional fused scan (NULL = none): same layout as source, own window and colour table, same opacity curve.
    const float *blendSource;
    float blendWindowLow, blendWindowHigh;
    const float *blendRed, *blendGreen, *blendBlue;
} BKThickSlabParams;

// What: the picture's colour (0..255 floats, before the final rounding) of the pixel at `pixelIndex`
// (row * width + column).
void BKThickSlabCompositePixel(const BKThickSlabParams *p, size_t pixelIndex, float outRGB[3]);

// What: fills rows [rowBegin, rowEnd) of the ARGB8888 picture `outARGB` (width * height * 4 bytes, the whole picture;
// only the given rows are written). Rows are independent: callers may run row ranges on several threads.
// Returns 0 on success, -1 on bad input (nothing written).
int32_t BKThickSlabRenderRows(const BKThickSlabParams *p, int32_t rowBegin, int32_t rowEnd, uint8_t *outARGB);

#ifdef __cplusplus
}
#endif

#endif
