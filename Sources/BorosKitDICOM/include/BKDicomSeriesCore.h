// BorosKitDICOM: BKDicomSeriesCore - puts the slices of one series in order and works out the 3D volume they
// make (voxel size, where it sits in the patient).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends, Windows / Linux):
// - Pure C99 with BorosKit's own vector type BKVec3d (BKVec.h), <stdint.h>, <stdlib.h>, <math.h>; no Apple
//   frameworks or simd, no Horos (LGPL) types. Compiles unchanged on Windows/Linux. Deterministic.
// - Matrices are 4 x 4 doubles, COLUMN-MAJOR, column-vector convention (p' = M * p, translation in
//   elements 12-14) - the layout BKVolumeTexture -initWithFloatVoxels:...patientToVoxel: takes.
// - Written from the DICOM image-plane definition (PS3.3 C.7.6.2): a pixel (column i, row j) of a slice
//   lies at position + rowDirection * i * columnSpacing + columnDirection * j * rowSpacing.
//
// Plain language: a CT / CBCT series arrives as many files in any order. Each slice says where its top-left
// pixel is and which way its rows and columns run. We sort the slices along the direction perpendicular to
// them (the "normal"), check they are evenly spaced and parallel, and build the one matrix that turns a
// voxel number (column, row, slice) into a point in the patient (mm) - and its inverse.

#ifndef BK_DICOM_SERIES_CORE_H
#define BK_DICOM_SERIES_CORE_H

#include <stdint.h>
#include <stddef.h>
#include "BKVec.h"

#ifdef __cplusplus
extern "C" {
#endif

// What: one slice (a single-frame file or one frame of a multi-frame file) as the sorter sees it.
typedef struct {
    int32_t hasGeometry;      // 1 when position and orientation are known
    BKVec3d position;         // centre of the top-left pixel (mm)
    BKVec3d rowDirection;     // unit: along a row (image x)
    BKVec3d columnDirection;  // unit: down a column (image y)
    int32_t instanceNumber;   // INT32_MIN when missing
    uint32_t sourceIndex;     // the caller's index (file / frame), handed back in the sorted order
} BKDicomSlice;

typedef enum {
    BKSeriesOK = 0,
    BKSeriesWarningUneven = 1 << 0,       // slice gaps differ by more than 10% (or 0.1 mm): spacing = average
    BKSeriesWarningDuplicates = 1 << 1,   // slices at the same position were dropped
    BKSeriesWarningNoGeometry = 1 << 2,   // positions missing: sorted by instance number, spacing assumed
    BKSeriesWarningTilted = 1 << 3,       // slices are shifted sideways (gantry tilt): volume is sheared
    BKSeriesWarningMixedOrientation = 1 << 4, // slices are not parallel: those that differ were dropped
} BKSeriesWarning;

typedef struct {
    uint32_t count;           // slices kept (the first `count` entries of order[])
    uint32_t *order;          // sorted sourceIndex values (malloc'd by BKDicomSeriesSort; free with free())
    double sliceSpacing;      // mm between consecutive kept slices (> 0)
    BKVec3d sliceStep;        // patient-mm step from one kept slice to the next
    uint32_t warnings;        // BKSeriesWarning bits
    uint32_t dropped;         // slices left out (duplicates / different orientation)
} BKDicomSeriesOrder;

// What: sorts `slices` (count of them). `fallbackSpacing` (> 0) is used when geometry is missing or there
// is a single slice (pass the slice thickness or 1). Returns 1 on success (0 = no slices / no memory).
int BKDicomSeriesSort(const BKDicomSlice *slices, uint32_t count, double fallbackSpacing, BKDicomSeriesOrder *result);

// What: voxel (i = column, j = row, k = sorted slice) -> patient mm, column-major 4x4, for the first sorted
// slice `first`: columns are rowDirection * columnSpacing, columnDirection * rowSpacing, sliceStep, position.
// columnSpacing = mm between columns (DICOM PixelSpacing[1]), rowSpacing = mm between rows (PixelSpacing[0]).
void BKDicomVoxelToPatient(const BKDicomSlice *first, double columnSpacing, double rowSpacing, BKVec3d sliceStep,
                           double out[16]);

// What: the inverse of an affine column-major 4x4 matrix (last row 0 0 0 1). Returns 0 when singular.
int BKDicomInvertAffine(const double m[16], double out[16]);

// What: the DICOM letters for a patient direction, strongest axis first, up to 3 letters
// (x: R -> L, y: A -> P, z: F -> H). e.g. (1, 0, 0) -> "L", (0, -0.7, 0.7) -> "AH" (ties: x, y, z order).
// Axes contributing less than `minimum` (e.g. 0.25) are left out. `letters` needs 4 bytes.
void BKDicomOrientationLetters(BKVec3d direction, double minimum, char letters[4]);

#ifdef __cplusplus
}
#endif

#endif
