// BorosKitRender: the curve of the curved MPR (panorex) - a smooth curve through the user's nodes,
// and everything the curved-MPR views and the panorex generator measure on it (plain C).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 with BorosKit's own vector types (BKVec.h),
//   <math.h> and <stdlib.h> only; no Objective-C, Metal, VTK, OpenGL, Apple simd or Horos-derived
//   (LGPL) types. It runs on the CPU on every platform (nothing here goes to the GPU); the panorex
//   generator turns its samples into per-column frames for the GPU (BKCurvedReformatCore.h).
//   Check: clang -std=c99 -pedantic -Werror -fno-modules, no Apple headers.
// - Written from the mathematics: a natural cubic spline with chord-length parameters through the
//   nodes (plus one mirrored point before the first and after the last node, so the curve leaves the
//   end nodes almost straight), converted to cubic Bezier segments; a fine polyline made by splitting
//   the segments; arc-length sampling along that polyline with tangents and normals carried from
//   segment to segment by the rotation between neighbouring segment directions (discrete parallel
//   transport) and blended at the corners. The curve SHAPE through the nodes is the same as Horos'
//   curved MPR had (same spline definition); the sampled points can differ from the old code by at
//   most the flatness (measured and documented in Tests/BorosKitRenderTests/BKCurveCoreTests.m).
//   No code was copied from Horos/OsiriX or elsewhere.
// - ONE set of rules for every caller (panorex columns, cross-lines, cross-section placement, ROI
//   positions), so they always agree - before 2026-11-15 the panorex used a coarser polyline (0.6)
//   than the lines (0.1).
// - Deterministic, no threads, no state. Functions that return arrays allocate them with malloc;
//   free them with free() (or BKCurvePolylineFree).
//
// Plain language: the user clicks a few points along the jaw (nodes). This file draws the smooth
// line through them, measures it, finds points along it at equal steps, and tells which way is
// "across" the curve at each point - exactly what the panoramic picture and its lines need.
//
// Units: patient millimetres.

#ifndef BK_CURVE_CORE_H
#define BK_CURVE_CORE_H

#include "BKVec.h"     // BorosKit neutral vectors (no Apple simd: VULKAN-PORT-PLAN rule 1)
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: one cubic Bezier segment: from p0 to p1 with control points c0 (near p0) and c1 (near p1).
typedef struct {
    BKVec3d p0, c0, c1, p1;
} BKCurveSegment;

// What: the fine straight-line version of a curve (points in order along the curve).
typedef struct {
    BKVec3d *points;
    size_t count;
} BKCurvePolyline;

// What: the defaults (the values the curved MPR has always used for its lines): segments longer than
// 3 mm are split first, then split further until every piece is within 0.1 mm of the true curve.
#define BK_CURVE_DEFAULT_MAX_SEGMENT_LENGTH 3.0
#define BK_CURVE_DEFAULT_FLATNESS 0.1

// What: the curve through `count` nodes. Writes count-1 segments to `segments` (caller array of at
// least count-1). Two nodes give a straight segment. Returns the number of segments (count-1), 0 for fewer
// than 2 distinct nodes or non-finite numbers. A node repeated right after itself gets a zero-length
// segment and the curve is fitted through the distinct nodes (segment i always joins nodes i and i+1).
// Rule: natural cubic spline (second derivative 0 at the ends of the extended node list) with
// parameter = distance along the node polygon, through the node list extended by 2*n1 - n2 in front
// and 2*nk - nk-1 at the back; each piece between two real nodes becomes one Bezier segment.
size_t BKCurveSegmentsFromNodes(const BKVec3d *nodes, size_t count, BKCurveSegment *segments);

// What: the same for a CLOSED outline (ROI polygons / pencil outlines; callers normally repeat the first node
// at the end). Rule ("ends meet", as Horos had it for ROI outlines): the extra point in front of the first
// node is the second-to-last node and the extra point after the last node is the second node, so the curve
// meets itself smoothly; then the same natural spline. Needs at least 3 distinct nodes (else 0); repeats as above.
size_t BKCurveSegmentsFromNodesClosed(const BKVec3d *nodes, size_t count, BKCurveSegment *segments);

// What: the point at parameter t (0..1) of one segment, and its (unnormalised) derivative.
BKVec3d BKCurveSegmentPoint(const BKCurveSegment *segment, double t);
BKVec3d BKCurveSegmentDerivative(const BKCurveSegment *segment, double t);

// What: the polyline of `segmentCount` segments: each segment is first cut into equal-parameter
// pieces no longer than about `maxSegmentLength` (control polygon length), then each piece is halved
// until both control points lie within `flatness` of its chord (at most 2^16 pieces per segment).
// The first point is segments[0].p0; consecutive equal points are dropped. Returns 0 on bad input or
// no memory (out->points NULL).
int BKCurveFlatten(const BKCurveSegment *segments, size_t segmentCount, double maxSegmentLength,
                   double flatness, BKCurvePolyline *out);
void BKCurvePolylineFree(BKCurvePolyline *polyline);

// What: total length of the polyline (sum of its pieces).
double BKCurvePolylineLength(const BKCurvePolyline *polyline);

// What: samples along the polyline every `spacing` mm starting `startDistance` mm from its start,
// up to `maxSamples` (positions / tangents / normals may each be NULL). Returns how many were written
// (sampling stops at the end of the polyline).
// Rules (per piece of the polyline, from its start): position = on the piece; tangent = the unit
// directions of the neighbouring pieces averaged at each corner, blended linearly along the piece;
// normal = `initialNormal` made perpendicular to the first piece (if it is along the piece: -x cross
// direction, then +y cross direction), carried to each next piece by the rotation that turns one piece
// direction into the next, made exactly perpendicular, averaged at corners and blended like the
// tangent. Normals are not needed (pass NULL) for positions/tangents only.
size_t BKCurvePolylineSample(const BKCurvePolyline *polyline, double spacing, double startDistance,
                             BKVec3d initialNormal, BKVec3d *positions, BKVec3d *tangents, BKVec3d *normals,
                             size_t maxSamples);

// What: "stretched" sampling: samples every `spacing` mm measured along the polyline as seen along
// `projectionDirection` (projected onto a plane perpendicular to it), starting `startDistance` mm into
// that projected length. Each sample is the matching point on the REAL (unprojected) polyline (same
// fraction of the piece); tangent = real piece directions blended as in BKCurvePolylineSample;
// normal = unit (projected piece direction x projectionDirection) (any unit vector perpendicular to
// projectionDirection when the piece is seen end-on), blended the same way; relativePosition =
// distance along the REAL polyline / its length. Any output may be NULL. Returns how many were
// written. Why: the stretched curved MPR keeps the vertical direction of the patient for every
// column, so its columns are equally spaced as seen from that direction.
size_t BKCurvePolylineSampleProjected(const BKCurvePolyline *polyline, double spacing, double startDistance,
                                      BKVec3d projectionDirection, BKVec3d *positions, BKVec3d *tangents,
                                      BKVec3d *normals, double *relativePositions, size_t maxSamples);

// What: one sample at `distance` mm along the polyline (clamped to the ends; the end of the polyline
// gives the last point and the last piece's tangent / normal). Any output may be NULL. Returns 0 for an
// empty polyline.
int BKCurvePolylineSampleAt(const BKCurvePolyline *polyline, double distance, BKVec3d initialNormal,
                            BKVec3d *position, BKVec3d *tangent, BKVec3d *normal);

// What: the relative position (0..1 of the length) of the point of the polyline closest to `point`,
// and that point (optional) and its distance (optional).
double BKCurvePolylineClosestToPoint(const BKCurvePolyline *polyline, BKVec3d point,
                                     BKVec3d *closest, double *distance);

// What: the same for the line through `linePoint` along `lineDirection` (closest pair of points).
double BKCurvePolylineClosestToLine(const BKCurvePolyline *polyline, BKVec3d linePoint, BKVec3d lineDirection,
                                    BKVec3d *closest, double *distance);

// What: a copy of the polyline with an extra point wherever it crosses the plane (point, normal), so
// the parts on each side can be drawn separately. Returns 0 on no memory.
int BKCurvePolylineSplitAtPlane(const BKCurvePolyline *polyline, BKVec3d planePoint, BKVec3d planeNormal,
                                BKCurvePolyline *out);

// What: the points where the polyline crosses or touches the plane (point, normal), in order along it,
// and their relative positions (0..1 of the length); either output may be NULL; returns how many (at most
// maxResults). Half-open rule as the classic engine: a point on the plane counts as the +normal side, so
// a pass-through vertex counts once and a vertex touching the plane from the -normal side counts twice
// (even/odd counts for scan-line ROI filling).
size_t BKCurvePolylinePlaneIntersections(const BKCurvePolyline *polyline, BKVec3d planePoint, BKVec3d planeNormal,
                                         BKVec3d *points, double *relativePositions, size_t maxResults);

// What: the polyline moved `distance` mm along its normal (initialNormal as in BKCurvePolylineSample),
// sampled every `spacing` mm (the slab borders drawn beside the curve). Returns 0 on bad input.
int BKCurvePolylineOutline(const BKCurvePolyline *polyline, double distance, double spacing,
                           BKVec3d initialNormal, BKCurvePolyline *out);

// What: the polyline projected onto the plane (point, normal) along the normal.
int BKCurvePolylineProjectToPlane(const BKCurvePolyline *polyline, BKVec3d planePoint, BKVec3d planeNormal,
                                  BKCurvePolyline *out);

// What: the planes perpendicular to `normal` that touch the polyline on its +normal side (top) and
// -normal side (bottom): each as a point on the plane (the normal is `normal`, unit).
int BKCurvePolylineBoundingPlanes(const BKCurvePolyline *polyline, BKVec3d normal, BKVec3d *topPoint,
                                  BKVec3d *bottomPoint);

// What: the plane fitted through the points (least squares): centroid + unit normal (the direction of
// least spread). Returns 0 for fewer than 3 points. isPlanar: 1 when every point is within `tolerance`
// mm of that plane.
int BKCurvePolylineLeastSquaresPlane(const BKCurvePolyline *polyline, BKVec3d *point, BKVec3d *normal);
int BKCurvePolylineIsPlanar(const BKCurvePolyline *polyline, double tolerance);

#ifdef __cplusplus
}
#endif

#endif
