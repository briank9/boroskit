// BorosKitCore: clipping-plane math (plain C, no GPU code).
//
// What: helpers for "a set of up to BK_MAX_CLIP_PLANES planes that cut a volume",
// e.g. the (possibly rotated) cropping box of the 3D window, which is 6 planes.
// Why plain C here and not in the Metal renderer: the same math (VTK -> patient mm
// conversion, which side is kept, packing for the GPU) is needed by every GPU
// backend - Metal today, Vulkan later - and by the unit tests on the CPU.
//
// Convention (same as BKVolumeRenderer's single clipPlane): for every plane, the side
// its normal points to is CUT AWAY; a point x is kept when dot(x - point, normal) <= 0
// for all planes. Units: patient millimetres.

#ifndef BK_CLIP_PLANES_H
#define BK_CLIP_PLANES_H

#import "N3Geometry.h"

// A box needs 6 planes; VTK's volume mappers also accept at most 6.
#define BK_MAX_CLIP_PLANES 6

#ifdef __cplusplus
extern "C" {
#endif

// What: YES when `point` is on the kept side of every plane (see convention above).
// Why: CPU reference for tests and for callers that want to check a point.
BOOL BKClipPlanesKeepPoint(const N3Plane *planes, NSUInteger count, N3Vector point);

// What: average of the planes' points. For the 6 planes of a box whose points are the
// face centres (VTK's vtkBoxWidget), this is the centre of the box.
N3Vector BKClipPlanesCentroid(const N3Plane *planes, NSUInteger count);

// What: flips the normal of every plane that would cut away `keepPoint`, so that point
// ends up on the kept side of all planes. Returns how many planes were flipped.
// Why: makes the conversion independent of which way another engine's normals point
// (e.g. VTK's box widget flips them with its "InsideOut" flag).
NSUInteger BKClipPlanesOrientToKeepPoint(N3Plane *planes, NSUInteger count, N3Vector keepPoint);

// What: converts planes given the VTK way (the side the normal points to is KEPT, as
// in vtkVolumeMapper::SetClippingPlanes) in a world scaled by `worldScale` (VTK world
// = patient mm x worldScale in the Boros 3D window, `factor` in VRView) into BorosKit
// planes (patient mm, normal side cut away, unit normals).
// origins / normals: 3 doubles per plane. At most BK_MAX_CLIP_PLANES are converted;
// planes with a zero normal are skipped. When exactly 6 planes come in (a box), they
// are additionally oriented so the box centre is kept (safety net if a normal points
// the "wrong" way). Returns the number of planes written to `out`.
NSUInteger BKClipPlanesFromVTK(const double *origins, const double *normals, NSUInteger count,
                               double worldScale, N3Plane *out);

// What: packs planes for a GPU as 4 floats each: (nx, ny, nz, w) with a unit normal and
// w = -dot(normal, point), so "cut" is nx*x + ny*y + nz*z + w > 0.
// Why: the narrow, API-neutral GPU interface (plain float4 data that a Metal or a Vulkan
// shader reads the same way). Writes min(count, BK_MAX_CLIP_PLANES) planes and returns that
// number; planes with a zero normal are dropped.
NSUInteger BKClipPlanesPack(const N3Plane *planes, NSUInteger count, float *outXYZW);

#ifdef __cplusplus
}
#endif

#endif
