// BorosKitRender: the look of colour (RGB) scans in the MPR / curved-MPR slab modes (plain C).
// Boros 6 (2026-11-24, mpr-colour).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// What: how a slab picture of a colour scan gets its colours in thin / MIP / MinIP / mean mode, written down
// from what the classic MPR window (its hidden VTK 3D view) showed:
//  1. Each colour channel (red, green, blue byte 0..255) is projected through the slab ON ITS OWN: MIP = the
//     highest red, the highest green and the highest blue along the ray (they may come from different voxels),
//     MinIP = the lowest, mean = the average (see "Boros 6 change" below). Thin = the same with a thin slab.
//  2. Each projected channel value v is looked up in the slab helper's colour + opacity table (the window
//     wl +- ww / 2 in byte units, the opacity curve of the window, the colour table when one is chosen):
//     opacity a(v); colour = the table's colour at v when a colour table is chosen, otherwise the pure channel
//     colour (v / 255 of red for the red channel, of green for green, of blue for blue).
//  3. The three channels are added: colour = sum of a(v_c) * colour_c (each part capped at 1), laid over black
//     (the picture is opaque: alpha byte 255).
//  With the default linear opacity over 0..255 this darkens mid tones (a channel value of 128 shows as about 64)
//  - that is the classic look and is kept on purpose.
//  VR colour mode (composite) is drawn by the volume renderer itself (BKVolumeRenderer colour channels).
//  Boros 6 change: the classic engine ignored the "mean" setting for colour scans and drew its MinIP picture
//  (VTK's mean switch only reached grey scans; the mean mode used VTK's minimum-intensity blend mode). Native
//  mean is a true per-channel mean.
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C99 (<stdint.h>, <stddef.h>); no Objective-C, Metal, VTK, OpenGL, Apple simd or LGPL types.
//   Check: clang -std=c99 -pedantic -Werror -fno-modules.
// - The per-channel projection comes from the volume renderer's colour MIP / MinIP / mean picture windowed over
//   [0, 255] (so its bytes ARE the projected channel values); a Vulkan backend can run this mapping on the CPU as
//   here, or as a tiny compute pass with the 256-entry table in a buffer (same numbers).
// - Deterministic: no state, no allocation, no threads.

#ifndef BK_SLAB_COLOUR_CORE_H
#define BK_SLAB_COLOUR_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: rule 2+3 for `count` pixels. projectedRGBA: r, g, b (projected channel bytes), a (ignored) per pixel.
// table: 256 entries of r, g, b, opacity (floats 0..1) for the byte values 0..255. useTableColours: 1 = the table's
// colours (a colour table is chosen), 0 = pure channel colours. outARGB: 4 bytes per pixel, A (255), R, G, B (the
// app's colour picture layout; may be the same memory as projectedRGBA). Returns 1, or 0 for NULL input.
int BKSlabColourMapChannels(const uint8_t *projectedRGBA, size_t count, const float *table, int useTableColours,
                            uint8_t *outARGB);

// What: the colour of ONE pixel by rules 2+3 (r, g, b 0..1 written to rgbOut). For tests and the Vulkan reference.
void BKSlabColourOfChannels(uint8_t red, uint8_t green, uint8_t blue, const float *table, int useTableColours,
                            float rgbOut[3]);

#ifdef __cplusplus
}
#endif

#endif
