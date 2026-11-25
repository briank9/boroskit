// BorosKitRender: where every voxel of a scan lies, for the MPR / curved-MPR slab pictures (plain C).
// Boros 6 (2026-11-24, mpr-colour).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// What: from the first slice of a series (size, image origin, row / column / slice-normal direction cosines,
// pixel spacing, slice interval, slice thickness) this core makes the scan's placement in patient millimetres:
//  - the effective voxel sizes (the classic substitution rules for missing numbers, see below);
//  - three axes + POSITIVE voxel sizes describing the same voxel positions even when the slices run backwards
//    (negative slice interval): the slice axis is then the reversed slice normal;
//  - the patient-mm -> voxel-index matrix the GPU volume texture needs (column by column, voxel = M * (x, y, z, 1));
//  - the smallest voxel size (the volume renderer's default sample step is half of it).
// And: whether a slice list can be a volume at all (at least 3 slices, all the same size) - the rule the 2D
// viewer's MPR / curved-MPR menu items apply before opening the window ("MPR requires volumic data.").
//
// Why: until 2026-11-24 the MPR / curved-MPR windows sent such scans to the classic VTK helper (negative interval,
// missing spacing) or used the Horos-derived (LGPL) CPRVolumeData class to place the scan on the GPU. The native
// slab helper now handles every case itself, with these rules written down once for Metal and the Vulkan engine.
//
// RULES (each one checked in Tests/BorosKitRenderTests/BKSlabScanCoreTests.m):
//  1. Pixel spacing x or y not a positive finite number -> 1 mm for that axis (the classic 3D engine used a data
//     spacing of 1 x 1 for such scans). Flag BKSlabScanUsedDefaultPixelSpacing.
//  2. Slice step = the slice interval; when it is 0 (or not finite): the slice thickness (classic rule, "slice
//     interval = slice thickness"); when that is 0 too: the average of the two pixel spacings (the rule the GPU
//     upload always had). The SIGN is kept: negative = each next slice lies against the slice normal. Flags
//     BKSlabScanUsedSliceThickness / BKSlabScanUsedAverageSpacing / BKSlabScanSlicesBackwards.
//  3. Direction cosines that are not finite or do not span 3D (|det| < 1e-6) -> the identity orientation (the
//     rule of the old GPU upload for "curved or bogus" orientations). Flag BKSlabScanUsedIdentityOrientation.
//  4. Voxel (i, j, k) lies at origin + i * sx * row + j * sy * column + k * step * normal (DICOM image plane).
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C99 on doubles with BorosKit's own vector types (BKVec.h); no Objective-C, Metal, VTK, OpenGL, Apple
//   simd or Horos-derived (LGPL) types. Check: clang -std=c99 -pedantic -Werror -fno-modules.
// - The matrix layout (column by column, column vectors, translation in elements 12..14) is that of a std430
//   mat4 / a Vulkan shader's column-major matrix; the Vulkan volume upload uses it unchanged.
// - Deterministic: no state, no allocation, no threads.

#ifndef BK_SLAB_SCAN_CORE_H
#define BK_SLAB_SCAN_CORE_H

#include "BKVec.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: the first slice's numbers as the app stores them (DCMPix).
typedef struct {
    double origin[3];          // patient mm of voxel (0, 0) of the first slice
    double cosines[9];         // row direction, column direction, slice normal
    double pixelSpacingX;      // mm between columns
    double pixelSpacingY;      // mm between rows
    double sliceInterval;      // mm from one slice to the next (signed; 0 = unknown)
    double sliceThickness;     // mm (used when the interval is 0)
} BKSlabScanInput;

// What: which substitution rules were used (bit flags, for the app's log line).
enum {
    BKSlabScanUsedDefaultPixelSpacing  = 1u << 0,
    BKSlabScanUsedSliceThickness       = 1u << 1,
    BKSlabScanUsedAverageSpacing       = 1u << 2,
    BKSlabScanSlicesBackwards          = 1u << 3,
    BKSlabScanUsedIdentityOrientation  = 1u << 4,
};

// What: the scan's placement (see the rules above).
typedef struct {
    BKVec3d origin;            // patient mm of voxel (0, 0, 0)
    BKVec3d axes[3];           // unit-ish directions of increasing i, j, k (axes[2] reversed for backwards slices)
    BKVec3d spacing;           // POSITIVE mm per voxel along axes[0..2]
    double sliceStep;          // signed mm per slice along the slice normal (rule 2)
    double minSpacing;         // smallest of spacing.x, spacing.y, spacing.z
    double patientToVoxel[16]; // column by column: voxel = M * (x, y, z, 1)
    double voxelToPatient[16]; // its inverse
    uint32_t flags;            // BKSlabScan... rules used
} BKSlabScan;

// What: fills *out from *in. Returns 1, or 0 for NULL / a placement that cannot be inverted (cannot happen after
// the substitutions, kept as a safety net).
int BKSlabScanMake(const BKSlabScanInput *in, BKSlabScan *out);

// What: patient mm of the continuous voxel position (i, j, k).
BKVec3d BKSlabScanVoxelToPatient(const BKSlabScan *scan, BKVec3d voxel);
// What: continuous voxel position of the patient point p (mm).
BKVec3d BKSlabScanPatientToVoxel(const BKSlabScan *scan, BKVec3d p);

// What: can these slices be one volume? sliceCount slices, widths[i] x heights[i] pixels each (NULL arrays = all
// equal). Returns BKSlabScanVolumic, or the reason it cannot.
typedef enum {
    BKSlabScanVolumic = 0,
    BKSlabScanTooFewSlices = 1,       // fewer than 3 slices
    BKSlabScanUnequalSlices = 2,      // slices of different sizes
    BKSlabScanEmptySlices = 3,        // a slice of 0 pixels
} BKSlabScanVolumicStatus;
BKSlabScanVolumicStatus BKSlabScanCheckVolumic(int32_t sliceCount, const int32_t *widths, const int32_t *heights);

#ifdef __cplusplus
}
#endif

#endif
