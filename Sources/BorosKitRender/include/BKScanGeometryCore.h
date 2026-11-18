// BorosKitRender: BKScanGeometryCore - where a scan sits in a 3D window, its orientation letters and the trackball
// mouse maths of the 3D windows, in plain C99. Boros 6 (2026-11-17, 3D-off-VTK plan step 5): written for the native
// surface view so none of this maths lives in Apple-only code.
//
// Original BorosKit code written for this project; contains no third-party code. The placement follows the DICOM
// image-plane definition (row / column direction cosines, slice normal, image origin); the letters follow the DICOM
// patient axes (x: right -> left, y: anterior -> posterior, z: inferior -> superior).
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 on doubles; no Objective-C, Apple, GPU, VTK or LGPL types.
// - Matrices are 4 x 4, column by column (element [col * 4 + row]), points multiplied on the right
//   (p' = M * p) - the same layout as Apple simd and as a std430 mat4 in a Vulkan shader.
//
// Plain language: "the scan's pixel (i, j) on slice k is this point in the 3D window", "which letters go on the left,
// right, top and bottom of the view", and "how much the mouse turned or zoomed the camera".

#ifndef BK_SCAN_GEOMETRY_CORE_H
#define BK_SCAN_GEOMETRY_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: grid (voxel index i, j, k) -> the window's local space in mm: x = i * spacingX, y = j * spacingY,
// z = k * slice step. The slice step is sliceInterval (or sliceThickness when the interval is 0), keeping the
// interval's sign (negative = slices running backwards, as the classic windows store them).
void BKScanGridToLocal(double spacingX, double spacingY, double sliceInterval, double sliceThickness, double out[16]);

// What: local -> window space: rotation columns = cosines[0..2] (row direction), cosines[3..5] (column direction),
// cosines[6..8] (slice normal); translation = the image origin written in that frame and rotated back
// (= R * (R^T * origin) for an orthonormal frame, kept in this form for frames that are not quite orthonormal,
// matching the classic windows' numbers).
void BKScanPlacement(const double cosines[9], const double origin[3], double out[16]);

// What: out = a * b (out may not be a or b).
void BKMat4dMultiply(const double a[16], const double b[16], double out[16]);
// What: the inverse of m; returns 0 (and leaves out unchanged) when m cannot be inverted.
int BKMat4dInvert(const double m[16], double out[16]);
// What: the point p moved by m (w = 1).
void BKMat4dApplyToPoint(const double m[16], const double p[3], double out[3]);

// What: the orientation letters of a direction (DICOM patient axes): x < 0 'R' else 'L', y < 0 'A' else 'P',
// z < 0 'I' else 'S' (all reversed when `inverted`); up to three letters, strongest axis first, an axis counts when
// its share is above 0.2. Writes a 0-terminated string (out: room for 4 chars) and returns the number of letters.
int BKOrientationLetters(const double v[3], int inverted, char out[4]);

// What: the trackball "spin" (roll) in degrees for a pointer moving from (x0, y0) to (x1, y1) around the view's
// centre (cx, cy): the angle it turned around the centre (y up; positive = counter-clockwise).
double BKTrackballSpinDegrees(double cx, double cy, double x0, double y0, double x1, double y1);
// What: the trackball "dolly" zoom factor for a vertical pointer move of dyUp view points in a view viewHeight tall:
// 1.1 ^ (10 * dyUp / half the height) (> 1 = closer); 1 when the height is not positive.
double BKTrackballDollyFactor(double dyUp, double viewHeight);

// What: a colour scan (A, R, G, B bytes per voxel) as grey values (R + G + B) / 3, `count` voxels.
void BKScanGreyFromARGB(const unsigned char *argb, size_t count, float *out);

#ifdef __cplusplus
}
#endif

#endif
