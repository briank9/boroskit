// BorosKitRender: the small rules of an MPR / curved-MPR slab VIEW that are not camera maths
// (plain C, no GPU code): which mouse tool a click means, the window/level drag, where a picture
// sits without its window-centre shift, where a double-clicked point lies in the patient, the
// fusion layer's opacity table, and the 16-bit / colour formats of exported slab pictures.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C99 with BorosKit's own vector types (BKVec.h), <stdint.h>, <stddef.h> and <math.h>; no
//   Objective-C, no Metal, no VTK, no OpenGL, no Apple simd, no Horos-derived (LGPL) types.
//   Compiles unchanged on Windows/Linux (check: clang -std=c99 -pedantic -Werror -fno-modules).
// - Nothing here goes to the GPU. A Vulkan build uses these functions as they are; the slab
//   pictures themselves come from the volume renderer (BKVolumeRenderer on Metal).
// - Written from the behaviour of the classic Boros 6 MPR windows (the hidden 3D view that used
//   to serve the MPR / curved-MPR slab views), described here as rules and checked with hand-
//   worked numbers in Tests/BorosKitRenderTests/BKSlabViewCoreTests.m. No code was copied from
//   VTK, Horos or elsewhere; rules that look odd but are kept on purpose are marked "classic rule".
// - Deterministic: no state, no threads, no allocation. Functions accept NULL / bad numbers and
//   then change nothing (return 0).
//
// Plain language: an MPR view shows one "window pane" (slab) of the scan. Boros 6 (2026-11-24)
// replaced the hidden 3D view behind the MPR / curved-MPR windows by a native helper. This file
// holds the helper's small decisions so the future Vulkan engine shares them exactly.

#ifndef BK_SLAB_VIEW_CORE_H
#define BK_SLAB_VIEW_CORE_H

#include "BKVec.h"     // BorosKit neutral vectors (no Apple simd: VULKAN-PORT-PLAN rule 1)
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Mouse tool of a click ------------------------------------------------------------------

// What: the app's numbers for the tools this rule can pick (the app passes its own tool ids, so
// the core does not depend on the app's enum).
typedef struct {
    int32_t zoom;
    int32_t translate;
    int32_t rotate;          // spin around the viewing direction
    int32_t windowLevel;
    int32_t camera3D;
} BKSlabViewToolIds;

// What: mouse buttons / modifier keys of an event.
enum {
    BKSlabViewButtonLeft = 0,
    BKSlabViewButtonRight = 1,
    BKSlabViewButtonOther = 2,      // middle / extra buttons
};
enum {
    BKSlabViewModControl = 1u << 0,
    BKSlabViewModShift   = 1u << 1,
    BKSlabViewModCommand = 1u << 2,
    BKSlabViewModOption  = 1u << 3,   // Alt
};

// What: the tool a mouse event uses (classic rule, in this order, each later rule wins):
//   right button = zoom (unless a context menu is up), other button = translate, else the
//   current tool; Control = rotate; Shift = zoom; Command = translate; Option = window/level;
//   Command + Option = rotate; Command + Control = 3D camera.
int32_t BKSlabViewToolForEvent(int32_t currentTool, int32_t button, int32_t contextMenuActive,
                               uint32_t modifiers, const BKSlabViewToolIds *ids);

// ---- Window / level drag (the 3D colour slab's window) ----------------------------------------

// What: one mouse-drag step of the window/level tool, from the window (*wl, *ww) before the step.
// `dx`, `dy` = the event's movement in points (y down, as AppKit reports deltas).
// petMode < 0: normal scans: wl -= trunc(dy) * ww/100, ww += trunc(dx) * ww/100 (classic rule:
//   the deltas are truncated to whole points first).
// petMode 0/1/2 (PET, or NM with mouse windowing): the three classic PET windowing styles
//   (0 = same as normal; 1 = drag sets the top of the window, the bottom stays, centre lifted by
//   `petMinimum`; 2 = vertical drag moves the top, horizontal drag the bottom (not below 0)),
//   and for 1/2 the window is kept from reaching below 0.
// The width never drops below 0.1. Returns 0 (unchanged) for bad input.
int BKSlabViewWindowLevelDrag(double *wl, double *ww, double dx, double dy, int32_t petMode, double petMinimum);

// ---- Picture placement ----------------------------------------------------------------------

// What: the patient position of picture pixel (0, 0) WITHOUT the window-centre shift, from the
// position WITH it (what BKSlabGeometryCompute returns): origin + right * (wcX * resolution) +
// down * (wcY * resolution), where (wcX, wcY) is the window centre in frame points as the classic
// -windowCenter getter returns it (BKSlabCameraGetWindowCenterPoint). Classic rule: the frame-point
// offset is applied with the render resolution (mm per render pixel), as the classic engine did.
// The DICOM export of a slab picture stored this position.
BKVec3d BKSlabViewOriginWithoutWindowCenter(BKVec3d originWithShift, BKVec3d right, BKVec3d down,
                                            double windowCenterX, double windowCenterY, double resolution);

// What: the patient position (mm) of a double-clicked point of a slab view, classic rule:
// origin(without window-centre shift, middle of the slab) + down * ((frameHeight - y) * r)
// + right * (x * r), with (x, y) the click in render pixels measured from the bottom-left and
// frameHeight the view's frame height (classic: the frame height in points, not pixels - kept).
BKVec3d BKSlabViewClickPosition(BKVec3d originWithoutShift, BKVec3d right, BKVec3d down,
                                double x, double y, double frameHeight, double resolution);

// ---- Fusion layer ---------------------------------------------------------------------------

// What: the 256-entry opacity table of the fusion (blending) layer for a blending factor `factor`
// (0...256, the classic default 128), classic rule: maximum-intensity mode: a = 2 * factor,
// opacity[i] = clamp(a * i / 256, 0, 255) / 255; other modes: a = factor / 3,
// opacity[i] = clamp(a * i / 256 - 8, 0, 255) / 255. Returns 0 for bad input.
int BKSlabViewBlendingOpacityTable(double factor, int32_t maximumIntensity, float out[256]);

// ---- Export formats ---------------------------------------------------------------------------

// What: how a grey slab picture is stored as 16-bit DICOM pixels, from the scan's lowest value
// (classic rule): lowest < -1024 -> signed, no offset; lowest >= 0 -> unsigned, no offset;
// otherwise unsigned with offset -1024 (stored = value + 1024).
typedef struct {
    int32_t isSigned;      // 1 = int16 pixels, 0 = uint16 pixels
    int32_t offset;        // value subtracted before storing (0 or -1024)
} BKSlabViewExportFormat;
BKSlabViewExportFormat BKSlabViewExportFormatForMinimum(double volumeMinimum);

// What: converts `count` slab values to the 16-bit pixels of `format`:
// stored = (value - offset) / slope, rounded to nearest (ties to even), clamped to the type's
// range (NaN -> 0). `out` holds `count` 16-bit words (int16 bits when format.isSigned).
// slope <= 0 or not finite counts as 1. Returns 0 for bad input.
int BKSlabViewValuesTo16Bit(const float *values, size_t count, BKSlabViewExportFormat format,
                            double slope, uint16_t *out);

// What: an RGBA8 picture with colour already laid over black (BKVolumeRenderer's composite
// output) -> the classic ARGB8 slab picture layout (A = 255 opaque, then R, G, B), `count` pixels.
// `in` and `out` may be the same memory. Returns 0 for bad input.
int BKSlabViewRGBAToOpaqueARGB(const uint8_t *in, size_t count, uint8_t *out);

// What: an ARGB8 picture -> packed RGB8 (3 bytes per pixel, alpha dropped), for the colour DICOM
// export. `in` and `out` may be the same memory (out is never ahead of in). Returns 0 for bad input.
int BKSlabViewARGBToRGB(const uint8_t *in, size_t count, uint8_t *out);

#ifdef __cplusplus
}
#endif

#endif
