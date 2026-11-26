// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSegmentation: BKSegmentationCore - a SEGMENTATION as its own data type (2026-11-26, agent "segmentation").
//
// What it is: a LABEL MAP on a scan's exact voxel grid (one 16-bit class number per voxel, 0 = background) plus
// a class table (value, name, category, colour, opacity, visible) and a little information (name, source, time,
// SeriesInstanceUID). Functions: load / save the own ".boroseg" file (versioned JSON header + run-length labels,
// checksum), voxel counts and volumes per class, bounding boxes, slice extraction, nearest-neighbour sampling of
// any plane in patient mm, slice -> RGBA overlay picture, per-class binary masks for the surface builder.
//
// Why: AI (and later manual) segmentations used to become brush ROIs, which cluttered the ROI tools and had to be
// rebuilt from outlines for 3D. A label map is exact (one voxel = one answer), small on disk, and is what the
// BorosCMF planner needs (safety distances, canals, guides). User decision 2026-11-26 (BOROSCMF-FRAMEWORK.md 4).
//
// Coordinates and numbers:
//   - patient millimetres, DICOM LPS; voxel (i, j, k) centre = origin + i*sx*a + j*sy*b + k*sz*c with a, b, c the
//     unit column / row / slice directions (axes) and sx, sy, sz the steps (spacing) - computed with explicit fma;
//   - every geometry number and every measurement is double; counts are uint64; results are identical on every
//     run and machine (no threads, no fast-math; built with -ffp-contract=off);
//   - a pixel / voxel covers [i - 0.5, i + 0.5] around its centre; nearest sampling = floor(x + 0.5).
//
// ---- PORTING NOTES (Vulkan / Windows / Linux) ----------------------------------------------------------------------
//   - Plain C API (extern "C"), implemented in C++17 (BKSegmentationCore.cpp) with only the C/C++ standard library:
//     no Foundation, Metal, simd or dispatch. Listed in cmake/BorosKitSources.cmake; tests in
//     Tests/BorosKitCoreTestsC/BKSegmentationTests.c (ctest core.seg_*), mirrored by the SwiftPM tests.
//   - CPU only. Nothing here is a GPU struct (no std430 rules apply). The GPU part of a segmentation is the surface
//     builder (BKSurfaceExtractor / BKSurfacePass) fed with BKLabelMaskFill16 - already Vulkan-ready.
//   - File names are UTF-8 (fopen); on Windows a UTF-8 -> wide-char open must be added in BKSegOpenFile (marked).
//   - Text numbers: written with "%.*g" (shortest exact, 15-17 digits) and read with our own locale-proof reader,
//     so a German "," decimal locale cannot change a file.
// --------------------------------------------------------------------------------------------------------------------

#ifndef BK_SEGMENTATION_CORE_H
#define BK_SEGMENTATION_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Status --------------------------------------------------------------------------------------------------------
typedef enum {
    BKSegStatusOK = 0,
    BKSegStatusInvalidInput = 1,       // bad grid, NULL pointer, value 0 as a class, index out of range
    BKSegStatusOutOfMemory = 2,
    BKSegStatusIOError = 3,            // file could not be opened / read / written / renamed
    BKSegStatusBadFormat = 4,          // not a .boroseg file, broken header or payload
    BKSegStatusUnsupportedVersion = 5, // written by a newer Boros: refused, never half-read
    BKSegStatusChecksumMismatch = 6,   // the label data was damaged
    BKSegStatusNoLabels = 7,           // the volume was read header-only (no voxels)
} BKSegStatus;

// A short plain-language explanation (static text, never NULL).
const char *BKSegStatusMessage(BKSegStatus status);

// ---- Grid ----------------------------------------------------------------------------------------------------------
typedef struct {
    uint32_t dims[3];     // columns (i), rows (j), slices (k); each >= 1
    double spacing[3];    // mm per step along i, j, k; each > 0
    double origin[3];     // patient mm (LPS) of the centre of voxel (0, 0, 0)
    double axes[9];       // unit directions: [0..2] along i, [3..5] along j, [6..8] along k (need not be orthogonal)
} BKLabelGrid;

// 1 when the grid is usable (dims >= 1, spacing > 0 and finite, axes finite and not degenerate), else 0.
int BKLabelGridIsValid(const BKLabelGrid *grid);
// Patient position (mm) of voxel coordinates (i, j, k) (may be fractional).
void BKLabelGridVoxelToPatient(const BKLabelGrid *grid, double i, double j, double k, double out[3]);
// Voxel coordinates of a patient point; returns 0 if the grid is degenerate.
int BKLabelGridPatientToVoxel(const BKLabelGrid *grid, const double p[3], double outIJK[3]);
// The same as 4x4 matrices (column-major, column vectors: out = M * (x, y, z, 1)).
void BKLabelGridVoxelToPatientMatrix(const BKLabelGrid *grid, double m[16]);
int BKLabelGridPatientToVoxelMatrix(const BKLabelGrid *grid, double m[16]);
// Volume of one voxel in mm3: |det| of the three edge vectors (sx*a, sy*b, sz*c).
double BKLabelGridVoxelVolume(const BKLabelGrid *grid);

// ---- Classes and information -----------------------------------------------------------------------------------------
enum { BKLabelNameBytes = 128, BKLabelCategoryBytes = 64, BKLabelInfoBytes = 256, BKLabelUIDBytes = 80 };

typedef struct {
    uint16_t value;                       // 1..65535 (0 = background, never a class)
    uint8_t rgb[3];                       // 0..255
    int32_t visible;                      // 1 shown, 0 hidden
    double opacity;                       // 0..1 (1 = solid)
    char name[BKLabelNameBytes];          // UTF-8, zero-terminated, e.g. "Tooth 19"
    char category[BKLabelCategoryBytes];  // UTF-8, e.g. "Lower teeth" ("" = none)
} BKLabelClass;

typedef struct {
    char name[BKLabelInfoBytes];          // e.g. "AI dental (combined)"
    char source[BKLabelInfoBytes];        // e.g. "BorosAI dental-combined"
    char created[40];                     // ISO 8601, e.g. "2026-11-25T18:45:03"
    char seriesInstanceUID[BKLabelUIDBytes];
} BKLabelInfo;

// ---- The label volume --------------------------------------------------------------------------------------------
typedef struct BKLabelVolume BKLabelVolume;

// A new volume, every voxel 0, no classes. NULL if the grid is invalid or memory is short.
BKLabelVolume *BKLabelVolumeCreate(const BKLabelGrid *grid);
void BKLabelVolumeFree(BKLabelVolume *volume);

const BKLabelGrid *BKLabelVolumeGetGrid(const BKLabelVolume *volume);
uint64_t BKLabelVolumeVoxelCount(const BKLabelVolume *volume);
// The labels (x fastest, then y, then slice); NULL for a header-only volume (BKLabelVolumeReadHeader).
uint16_t *BKLabelVolumeVoxels(BKLabelVolume *volume);
const uint16_t *BKLabelVolumeVoxelsConst(const BKLabelVolume *volume);
BKLabelInfo *BKLabelVolumeInfo(BKLabelVolume *volume);
const BKLabelInfo *BKLabelVolumeInfoConst(const BKLabelVolume *volume);

// Adds a class, or replaces the class with the same value. Returns its index, or -1 (value 0 / NULL).
int32_t BKLabelVolumeSetClass(BKLabelVolume *volume, const BKLabelClass *cls);
uint32_t BKLabelVolumeClassCount(const BKLabelVolume *volume);
BKLabelClass *BKLabelVolumeClassAt(BKLabelVolume *volume, uint32_t index);
const BKLabelClass *BKLabelVolumeClassAtConst(const BKLabelVolume *volume, uint32_t index);
BKLabelClass *BKLabelVolumeFindClass(BKLabelVolume *volume, uint16_t value);
// Removes the class; with clearVoxels its voxels become 0 (background). Returns 1 if it existed.
int BKLabelVolumeRemoveClass(BKLabelVolume *volume, uint16_t value, int clearVoxels);

// Copies 8-bit labels (e.g. an AI result, x fastest, same voxel order) into the volume. count = voxel count.
BKSegStatus BKLabelVolumeSetLabels8(BKLabelVolume *volume, const uint8_t *labels, uint64_t count);

// ---- File (.boroseg) ---------------------------------------------------------------------------------------------
// Current format version written by this code; files with a higher version are refused.
enum { BKSegFormatVersion = 1 };

// The whole file in memory (malloc'd; free with BKSegFree).
BKSegStatus BKLabelVolumeEncode(const BKLabelVolume *volume, uint8_t **bytes, size_t *size);
// Reads a whole file from memory. headerOnly = 1: grid, classes, info only (no voxels, no payload check).
// message (may be NULL) receives a short reason on failure.
BKSegStatus BKLabelVolumeDecode(const uint8_t *bytes, size_t size, int headerOnly, BKLabelVolume **out,
                                char *message, size_t messageSize);
// Writes `path` safely (path + ".tmp", then renamed over `path`).
BKSegStatus BKLabelVolumeSave(const BKLabelVolume *volume, const char *path);
BKSegStatus BKLabelVolumeLoad(const char *path, BKLabelVolume **out, char *message, size_t messageSize);
// Reads only the header of a file (fast: the label data is not read).
BKSegStatus BKLabelVolumeReadHeader(const char *path, BKLabelVolume **out, char *message, size_t messageSize);
void BKSegFree(void *pointer);

// ---- Measurements ------------------------------------------------------------------------------------------------
// counts[v] = number of voxels with label v, for v = 0..65535 (counts must hold 65536 entries).
BKSegStatus BKLabelVolumeCount(const BKLabelVolume *volume, uint64_t *counts);
// Volume of `count` voxels in mm3 (count x voxel volume, double).
double BKLabelGridVolumeOfCount(const BKLabelGrid *grid, uint64_t count);
// Smallest box (inclusive voxel indices) holding every voxel of `value`; 0 if there is none.
int BKLabelVolumeClassBounds(const BKLabelVolume *volume, uint16_t value, uint32_t minIJK[3], uint32_t maxIJK[3]);

// ---- Slices and planes -------------------------------------------------------------------------------------------
// Copies slice k (dims[0] x dims[1] labels, row 0 = j 0). Returns 0 on bad input.
int BKLabelVolumeExtractSlice(const BKLabelVolume *volume, uint32_t k, uint16_t *out);
// Nearest-neighbour sampling of a plane: out[v*width + u] = label at patient point origin + u*uStep + v*vStep
// (mm); 0 outside the volume. Returns 0 on bad input.
int BKLabelVolumeSamplePlane(const BKLabelVolume *volume, const double origin[3], const double uStep[3],
                             const double vStep[3], uint32_t width, uint32_t height, uint16_t *out);
// If the plane (origin + u*uStep + v*vStep, width x height) lies exactly on slice k of the grid with u along i
// and v along j, one sample per voxel (within `toleranceMM` and 1e-6 in direction), returns 1 and sets *k, the
// first voxel (*i0, *j0) - then BKLabelVolumeExtractSlice gives the same answer faster. Else 0.
int BKLabelVolumePlaneIsGridSlice(const BKLabelVolume *volume, const double origin[3], const double uStep[3],
                                  const double vStep[3], double toleranceMM, uint32_t *k, int64_t *i0, int64_t *j0);

// ---- Overlay picture ---------------------------------------------------------------------------------------------
// The colour table: 65536 x 4 bytes RGBA (straight alpha); label v -> its class colour with alpha = class opacity
// x `overallOpacity` (0..1), rounded; hidden classes, unknown labels and 0 are fully transparent.
enum { BKLabelColourTableBytes = 65536 * 4 };
void BKLabelColourTableBuild(const BKLabelVolume *volume, double overallOpacity, uint8_t *table);
// Labels (width x height) -> RGBA picture (width x height x 4 bytes, row 0 = first label row) through `table`.
// outlineOnly = 1: only pixels whose label differs from one of their 4 neighbours (or that touch the picture edge)
// are coloured - the outline of each region. box (may be NULL) receives x, y, w, h of the coloured part (w = 0:
// nothing coloured). Returns the number of coloured pixels.
uint64_t BKLabelSliceToRGBA(const uint16_t *labels, uint32_t width, uint32_t height, const uint8_t *table,
                            int outlineOnly, uint8_t *rgba, uint32_t box[4]);

// ---- Masks for the surface builder -------------------------------------------------------------------------------
// The class's bounding box grown by `margin` voxels on every side (it may reach outside the volume: those voxels
// count as background, so a surface touching the scan edge is still closed). 0 if the class has no voxels.
int BKLabelMaskBox(const BKLabelVolume *volume, uint16_t value, uint32_t margin, int64_t boxMin[3], uint32_t boxDims[3]);
// Fills slices [zFirst, zFirst + zCount) of the box (box-relative) with `inside` where the label is `value`, else 0
// (x fastest; zCount x boxDims[1] x boxDims[0] entries). 16-bit for GPU upload; float for the CPU reference.
void BKLabelMaskFill16(const BKLabelVolume *volume, uint16_t value, const int64_t boxMin[3], const uint32_t boxDims[3],
                       uint32_t zFirst, uint32_t zCount, uint16_t inside, uint16_t *out);
void BKLabelMaskFillFloat(const BKLabelVolume *volume, uint16_t value, const int64_t boxMin[3],
                          const uint32_t boxDims[3], float *out);
// Box voxel (0, 0, 0) is volume voxel boxMin: the box-voxel -> patient matrix (column-major).
void BKLabelMaskBoxToPatient(const BKLabelGrid *grid, const int64_t boxMin[3], double m[16]);

#ifdef __cplusplus
}
#endif

#endif // BK_SEGMENTATION_CORE_H
