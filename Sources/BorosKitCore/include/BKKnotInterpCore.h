// BorosKitCore: BKKnotInterpCore - values that pass through given knots (t, value): a smooth cubic spline
// and straight-line (piecewise linear) interpolation. Plain C99.
// Boros 6 (2026-11-24, vtk-data): replaces VTK's vtkCardinalSpline and vtkPiecewiseFunction in the fly-through
// path (Spline3D / Piecewise3D) and the endoscopy centreline smoothing (FlyAssistant).
//
// Original BorosKit code written for this project; contains no third-party code. Written from the textbook
// maths: the "clamped" cubic spline through the knots (twice continuously differentiable, first derivative
// given at both ends), solved in its second-derivative ("moment") form with a tridiagonal system; the
// straight-line interpolation joins neighbouring knots.
//
// Behaviour (matches what Boros needs from the old VTK classes, see the tests):
// - knots are kept sorted by t; adding a knot at a t that is already there replaces its value;
// - the spline's end slopes are given (Boros uses 0 at both ends - the old default);
// - outside the knots' range t is clamped to the first / last knot (no extrapolation);
// - 1 knot -> that value everywhere; 0 knots -> 0.
//
// PORTING NOTES (Vulkan / other backends): VULKAN: safe to translate directly. CPU only, pure C99 (math.h);
// no Apple, GPU or Objective-C types. Deterministic (no threads). The caller owns all arrays.
//
// Plain language: draws a smooth (or straight) path through the points you give it, in order of t.

#ifndef BK_KNOT_INTERP_CORE_H
#define BK_KNOT_INTERP_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// What: puts knot (tNew, vNew[0..dim-1]) into the sorted arrays t[n] / v[n*dim] (room for `capacity` knots).
// A knot at exactly the same t is replaced. Returns the new number of knots, or -1 when there is no room.
int BKKnotInsert(double *t, double *v, int dim, int n, int capacity, double tNew, const double *vNew);

// What: the clamped cubic spline's second derivatives m[n] for knots t[n] (strictly increasing) and values
// y[n] (stride `ystride` doubles apart, so one call per coordinate of interleaved points), with first
// derivative slope0 at t[0] and slopeN at t[n-1]. work = scratch of at least n doubles.
// Returns 0 on success, -1 for n < 0 or knots that do not increase. n < 2: m filled with 0.
int BKSplineClampedMoments(const double *t, const double *y, int ystride, int n, double slope0, double slopeN,
                           double *m, double *work);

// What: the spline's value at x (clamped to [t[0], t[n-1]]), from the moments of BKSplineClampedMoments.
double BKSplineEvaluate(const double *t, const double *y, int ystride, const double *m, int n, double x);

// What: straight-line interpolation at x (clamped to [t[0], t[n-1]]).
double BKLinearEvaluate(const double *t, const double *y, int ystride, int n, double x);

#ifdef __cplusplus
}
#endif

#endif
