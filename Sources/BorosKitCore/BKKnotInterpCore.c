// BorosKitCore: BKKnotInterpCore - see BKKnotInterpCore.h.
// Original BorosKit code written for this project; contains no third-party code.
// Boros 6 (2026-11-24, vtk-data).

#include "BKKnotInterpCore.h"
#include <string.h>

int BKKnotInsert(double *t, double *v, int dim, int n, int capacity, double tNew, const double *vNew)
{
    if (t == NULL || v == NULL || vNew == NULL || dim <= 0 || n < 0) return -1;
    // Find the first knot with t >= tNew (knots are sorted).
    int lo = 0, hi = n;
    while (lo < hi) { int mid = (lo + hi) / 2; if (t[mid] < tNew) lo = mid + 1; else hi = mid; }
    if (lo < n && t[lo] == tNew)
    {
        // Same t: the new value replaces the old one (no duplicate knots).
        memcpy(v + (size_t)lo * dim, vNew, sizeof(double) * (size_t)dim);
        return n;
    }
    if (n >= capacity) return -1;
    memmove(t + lo + 1, t + lo, sizeof(double) * (size_t)(n - lo));
    memmove(v + (size_t)(lo + 1) * dim, v + (size_t)lo * dim, sizeof(double) * (size_t)(n - lo) * (size_t)dim);
    t[lo] = tNew;
    memcpy(v + (size_t)lo * dim, vNew, sizeof(double) * (size_t)dim);
    return n + 1;
}

// Index i of the interval [t[i], t[i+1]] holding x (x already clamped), 0 <= i <= n-2.
static int BKKnotInterval(const double *t, int n, double x)
{
    int lo = 0, hi = n - 1;   // invariant: t[lo] <= x <= t[hi]
    while (hi - lo > 1) { int mid = (lo + hi) / 2; if (t[mid] <= x) lo = mid; else hi = mid; }
    return lo;
}

int BKSplineClampedMoments(const double *t, const double *y, int ystride, int n, double slope0, double slopeN,
                           double *m, double *work)
{
    if (n < 0 || m == NULL) return -1;
    if (n < 2) { for (int i = 0; i < n; i++) m[i] = 0; return 0; }
    if (t == NULL || y == NULL || work == NULL || ystride <= 0) return -1;
    for (int i = 0; i + 1 < n; i++) if (!(t[i + 1] > t[i])) return -1;

    // The tridiagonal system for the second derivatives M[i] (h = knot spacing, d = slope of each piece):
    //   first row (slope at t0 given):   2 h0 M0 + h0 M1                       = 6 (d0 - slope0)
    //   rows 1..n-2:                     h(i-1) M(i-1) + 2 (h(i-1)+h(i)) M(i) + h(i) M(i+1) = 6 (d(i) - d(i-1))
    //   last row (slope at tn given):    h(n-2) M(n-2) + 2 h(n-2) M(n-1)      = 6 (slopeN - d(n-2))
    // Solved by forward elimination / back substitution (the matrix is diagonally dominant, so this is
    // stable without pivoting). work[] keeps the eliminated upper diagonal; m[] the right-hand side.
#define Y(i) y[(size_t)(i) * (size_t)ystride]
    double h0 = t[1] - t[0];
    double d0 = (Y(1) - Y(0)) / h0;
    double diag = 2 * h0;
    work[0] = h0 / diag;                         // upper diagonal / diagonal
    m[0] = 6 * (d0 - slope0) / diag;
    for (int i = 1; i < n; i++)
    {
        double hl = t[i] - t[i - 1];
        double dl = (Y(i) - Y(i - 1)) / hl;
        double b, c, r;
        if (i < n - 1)
        {
            double hr = t[i + 1] - t[i];
            double dr = (Y(i + 1) - Y(i)) / hr;
            b = 2 * (hl + hr); c = hr; r = 6 * (dr - dl);
        }
        else { b = 2 * hl; c = 0; r = 6 * (slopeN - dl); }
        double denom = b - hl * work[i - 1];
        work[i] = c / denom;
        m[i] = (r - hl * m[i - 1]) / denom;
    }
    for (int i = n - 2; i >= 0; i--) m[i] -= work[i] * m[i + 1];
#undef Y
    return 0;
}

double BKSplineEvaluate(const double *t, const double *y, int ystride, const double *m, int n, double x)
{
    if (n <= 0 || t == NULL || y == NULL) return 0;
    if (n == 1) return y[0];
    if (x <= t[0]) return y[0];
    if (x >= t[n - 1]) return y[(size_t)(n - 1) * (size_t)ystride];
    int i = BKKnotInterval(t, n, x);
    double h = t[i + 1] - t[i];
    double a = (t[i + 1] - x) / h, b = (x - t[i]) / h;
    double yi = y[(size_t)i * (size_t)ystride], yj = y[(size_t)(i + 1) * (size_t)ystride];
    // Cubic between the two knots: the straight line plus the curvature terms from the moments.
    return a * yi + b * yj + ((a * a * a - a) * m[i] + (b * b * b - b) * m[i + 1]) * h * h / 6.0;
}

double BKLinearEvaluate(const double *t, const double *y, int ystride, int n, double x)
{
    if (n <= 0 || t == NULL || y == NULL) return 0;
    if (n == 1 || x <= t[0]) return y[0];
    if (x >= t[n - 1]) return y[(size_t)(n - 1) * (size_t)ystride];
    int i = BKKnotInterval(t, n, x);
    double f = (x - t[i]) / (t[i + 1] - t[i]);
    double yi = y[(size_t)i * (size_t)ystride], yj = y[(size_t)(i + 1) * (size_t)ystride];
    return yi + (yj - yi) * f;
}
