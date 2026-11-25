// BorosKitCore: BKRigidFitCore - the best rotation + shift that moves one set of 3D points onto another
// (point-based registration). Plain C99.
// Boros 6 (2026-11-24, vtk-data): replaces VTK's vtkLandmarkTransform (rigid mode) in HornRegistration
// (2D viewer "Point-based registration": matching named points on two series).
//
// Original BorosKit code written for this project; contains no third-party code. Method: B. K. P. Horn,
// "Closed-form solution of absolute orientation using unit quaternions", J. Opt. Soc. Am. A 4 (1987): move both
// point sets to their centres, build the 3x3 sum of products, put it into Horn's symmetric 4x4 matrix, and take
// the eigenvector of its largest eigenvalue (found here with the classic Jacobi rotation method) as the unit
// quaternion of the rotation. The shift then moves the rotated centre onto the target centre. This gives the
// least-squares rigid fit (smallest sum of squared distances), always a proper rotation (no mirroring).
//
// Degenerate input (1 point, 2 points, or all points on one line): the rotation is not fully determined (any turn
// around the line fits equally well). Then the SMALLEST such rotation is chosen (1 point: no rotation at all) -
// a defined, repeatable answer. The 2D viewer asks for at least 3 points, so this only matters for points that
// happen to lie on one line.
//
// PORTING NOTES (Vulkan / other backends): VULKAN: safe to translate directly. CPU only, pure C99 (math.h),
// BKVec3d points; deterministic (fixed Jacobi sweep order, no threads).
//
// Plain language: given the same landmarks marked on two scans, finds how to turn and slide the first so its
// landmarks land as closely as possible on the second's.

#ifndef BK_RIGID_FIT_CORE_H
#define BK_RIGID_FIT_CORE_H

#include "BKVec.h"

#ifdef __cplusplus
extern "C" {
#endif

// What: the rigid transform with target[i] ~= R * source[i] + T for i = 0..n-1 (least squares).
// R = 3x3 rotation, ROW-major (R[row*3+col]); T = shift. rmsOut (optional) = root-mean-square distance left
// between the moved source points and the target points. Returns 0, or -1 for n < 1 / NULL arrays
// (R = identity, T = 0 then).
int BKRigidFitHorn(const BKVec3d *source, const BKVec3d *target, int n, double R[9], double T[3], double *rmsOut);

// What: eigenvalues (descending) and eigenvectors (vectors[k*4 + i] = component i of eigenvector k, unit
// length) of the symmetric 4x4 matrix a (row-major). Cyclic Jacobi method. Exposed for the tests.
void BKSymmetricEigen4(const double a[16], double values[4], double vectors[16]);

#ifdef __cplusplus
}
#endif

#endif
