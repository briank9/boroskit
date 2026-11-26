// BorosKitRender: BKMPRGeometryCore - the geometry of linked MPR planes (axial / coronal / sagittal that can
// be tilted into oblique planes) and of curved-MPR (panoramic) columns, in plain C.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends, Windows / Linux):
// - Pure C99 with BorosKit's own vector types (BKVec.h) and <math.h>; no Objective-C, Metal, Apple simd,
//   VTK or Horos (LGPL) types. Compiles unchanged on Windows/Linux (clang -std=c99 -pedantic -Werror
//   -fno-modules). Deterministic, no state, no allocation.
// - Nothing here goes to the GPU. The results feed the slab renderer's orthographic camera
//   (BKVolumeRenderer: image-plane centre, right / up, size in mm, slab plane) and the curved-reformat
//   kernel's per-column frames (BKReformatFrame, BKCurvedReformatCore.h). A Vulkan build uses both as is.
// - Matrices are 4 x 4 doubles, COLUMN-MAJOR, column-vector convention (p' = M * p, translation in 12-14),
//   the layout of BKVolumeTexture's patientToVoxel.
// - Written for Boros Mobile (2026-11-24) from plane geometry (orthonormal frames, rotations about an
//   axis by Rodrigues' formula, projections). Screen conventions follow the radiology standard:
//   axial seen from the feet (patient left on screen right, anterior up), coronal seen from the front
//   (patient left on screen right, head up), sagittal seen from the patient's left (anterior on screen
//   left, head up).
//
// Plain language: a 3D MPR shows three cuts through the scan that meet at one point (the "centre"). The
// three cuts are kept as one little set of three perpendicular directions (the "frame"). Turning the
// cross lines in one view turns the frame about that view's viewing direction, so the other two cuts tilt
// (oblique MPR). Each cut becomes a picture whose size covers the whole scan, so a picture does not jump
// when the centre moves. The curved MPR (dental panorex) is a row of thin vertical columns along the
// arch; for each column we work out where it starts inside the scan and which way it runs.

#ifndef BK_MPR_GEOMETRY_CORE_H
#define BK_MPR_GEOMETRY_CORE_H

#include "BKVec.h"
#include "BKCurvedReformatCore.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Linked MPR planes ----------------------------------------------------------------------------

typedef enum {
    BKMPRViewAxial = 0,
    BKMPRViewCoronal = 1,
    BKMPRViewSagittal = 2,
} BKMPRView;

// What: the shared centre and three perpendicular unit directions. Untilted: axis[0] = patient x (to the
// patient's left), axis[1] = y (to the back), axis[2] = z (to the head).
typedef struct {
    BKVec3d centre;
    BKVec3d axis[3];
} BKMPRFrame;

// What: an untilted frame at `centre`.
BKMPRFrame BKMPRFrameMake(BKVec3d centre);

// What: a view's picture directions (unit): `right` = screen right, `down` = screen down, `normal` = the
// viewing direction into the screen (right x down = normal ... see BKMPRViewAxes rules in the .c).
//   axial: right = axis0, down = axis1, normal = axis2
//   coronal: right = axis0, down = -axis2, normal = axis1
//   sagittal: right = axis1, down = -axis2, normal = -axis0
void BKMPRViewAxes(const BKMPRFrame *frame, BKMPRView view, BKVec3d *right, BKVec3d *down, BKVec3d *normal);

// What: turns the frame about `view`'s viewing direction by `degrees` (clockwise on that view's screen), so
// the other two planes tilt. The view's own plane does not change.
void BKMPRRotateInView(BKMPRFrame *frame, BKMPRView view, double degrees);

// What: keeps the frame orthonormal and right-handed after many small turns (Gram-Schmidt).
void BKMPRFrameOrthonormalize(BKMPRFrame *frame);

// What: the 8 corners of the scan in patient mm, from voxelToPatient (voxel centres; the box spans
// -0.5 .. size-0.5 voxels so the outer half voxels are included).
void BKMPRScanCorners(const double voxelToPatient[16], uint32_t width, uint32_t height, uint32_t depth,
                      BKVec3d corners[8]);

// What: clamps `point` into the scan box (in voxel space, using patientToVoxel / voxelToPatient).
BKVec3d BKMPRClampToScan(BKVec3d point, const double patientToVoxel[16], const double voxelToPatient[16],
                         uint32_t width, uint32_t height, uint32_t depth);

// What: one plane's picture: pixel (i, j) (centres at i + 0.5, j + 0.5 in image coordinates, i right, j down)
// lies at origin + right * i * spacing + down * j * spacing, where origin is the centre of pixel (0, 0).
typedef struct {
    uint32_t width, height;     // pixels
    double spacing;             // mm per pixel (square pixels)
    BKVec3d origin;             // centre of pixel (0, 0), patient mm
    BKVec3d right, down, normal;
} BKMPRPicture;

// What: the picture of a plane through `pointOnPlane` with the given directions, sized to cover the
// projection of the scan corners (so it depends only on the plane, not on where in it the centre is).
// spacing = the wanted mm per pixel (e.g. the smallest voxel size); if width or height would exceed
// `maxPixels`, the spacing grows so it fits. Returns 0 on bad input.
int BKMPRPictureForPlane(const BKVec3d corners[8], BKVec3d pointOnPlane, BKVec3d right, BKVec3d down, double spacing,
                         uint32_t maxPixels, BKMPRPicture *picture);

// What: image coordinates (x right, y down; pixel centres at +0.5) <-> patient mm on the picture's plane.
BKVec3d BKMPRPictureImageToPatient(const BKMPRPicture *picture, double x, double y);
void BKMPRPicturePatientToImage(const BKMPRPicture *picture, BKVec3d point, double *x, double *y);

// What: the orthographic slab-renderer camera for a picture: image-plane centre, viewing direction, screen
// up (= -down) and the size in mm, so that render pixel (i, j) is the picture's pixel (i, j).
void BKMPRPictureCamera(const BKMPRPicture *picture, BKVec3d *position, BKVec3d *direction, BKVec3d *up,
                        double *viewWidthMm, double *viewHeightMm);

// ---- Curved MPR (panoramic) columns -----------------------------------------------------------------

// What: the reformat frames of `count` columns. Column i is centred at centres[i] (patient mm, the middle
// of the column); rows run along downs[i] (unit) every rowSpacing mm; the slab runs along slabs[i] (unit)
// every slabStep mm. The frames are in voxel index space (patientToVoxel), as BKCurvedReformat wants.
void BKMPRColumnFrames(const double patientToVoxel[16], const BKVec3d *centres, const BKVec3d *downs,
                       const BKVec3d *slabs, uint32_t count, double rowSpacing, double slabStep,
                       BKReformatFrame *frames);

// What: the panoramic columns for curve samples (positions + tangents along the arch, `count` of them):
// rows go down the patient (`down`, unit, e.g. -z for an axial arch), each column at the curve point,
// slab across the arch = unit(tangent projected perpendicular to down) x down... oriented to point
// AWAY from `inside` (a point inside the arch, e.g. its centroid), i.e. towards the cheek (buccal).
// Writes downs[] and slabs[] (centres are the positions). Returns 0 on bad input.
int BKMPRPanoramicDirections(const BKVec3d *positions, const BKVec3d *tangents, uint32_t count, BKVec3d down,
                             BKVec3d inside, BKVec3d *downs, BKVec3d *slabs);

// What: sets the reformat's height band (params->clip*) so that only slab samples whose patient position p
// has  lowMm <= axis . p <= highMm  are used (`axis` = patient direction, unit, e.g. (0, 0, 1) = towards the
// head; lowMm / highMm in mm along it, e.g. patient z). `voxelToPatient` = the scan's matrix (column-major,
// as BKVolumeTexture's). enabled == 0 clears the band. Limits given the wrong way round are swapped.
// Why (2026-11-25, Boros Mobile "Height limits"): the band is a patient-space idea (top / bottom height of
// the head) but the kernel works in voxel index space; this turns one into the other once per picture.
void BKMPRSetHeightBand(BKReformatParams *params, const double voxelToPatient[16], BKVec3d axis,
                        double lowMm, double highMm, int enabled);

// What: the slab sample count for a thickness: floor(thickness / step) + 1 (1 = thin).
uint32_t BKMPRSlabDepth(double thicknessMm, double stepMm);

#ifdef __cplusplus
}
#endif

#endif
