// BorosKitRender: BKScanGeometryCore - see BKScanGeometryCore.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKScanGeometryCore.h"
#include <math.h>
#include <string.h>

static void Identity(double m[16])
{
    memset(m, 0, 16 * sizeof(double));
    m[0] = m[5] = m[10] = m[15] = 1;
}

void BKScanGridToLocal(double spacingX, double spacingY, double sliceInterval, double sliceThickness, double out[16])
{
    double step = sliceInterval != 0 ? sliceInterval : sliceThickness;
    Identity(out);
    out[0] = spacingX;
    out[5] = spacingY;
    out[10] = step < 0 ? -fabs(step) : fabs(step);
}

void BKScanPlacement(const double cosines[9], const double origin[3], double out[16])
{
    Identity(out);
    for (int c = 0; c < 3; c++)
        for (int r = 0; r < 3; r++) out[c * 4 + r] = cosines[3 * c + r];
    // The origin in the image frame: one coordinate per direction (dot products), then rotated by the frame.
    double local[3];
    for (int c = 0; c < 3; c++)
        local[c] = origin[0] * cosines[3 * c] + origin[1] * cosines[3 * c + 1] + origin[2] * cosines[3 * c + 2];
    for (int r = 0; r < 3; r++)
        out[12 + r] = out[r] * local[0] + out[4 + r] * local[1] + out[8 + r] * local[2];
}

void BKMat4dMultiply(const double a[16], const double b[16], double out[16])
{
    for (int c = 0; c < 4; c++)
        for (int r = 0; r < 4; r++) {
            double s = 0;
            for (int k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
            out[c * 4 + r] = s;
        }
}

int BKMat4dInvert(const double m[16], double out[16])
{
    // Gauss-Jordan elimination with partial pivoting on [m | I].
    double a[4][8];
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) { a[r][c] = m[c * 4 + r]; a[r][4 + c] = (r == c) ? 1 : 0; }
    }
    for (int col = 0; col < 4; col++) {
        int pivot = col;
        for (int r = col + 1; r < 4; r++) if (fabs(a[r][col]) > fabs(a[pivot][col])) pivot = r;
        if (!(fabs(a[pivot][col]) > 1e-300)) return 0;
        if (pivot != col) for (int k = 0; k < 8; k++) { double t = a[col][k]; a[col][k] = a[pivot][k]; a[pivot][k] = t; }
        double d = a[col][col];
        for (int k = 0; k < 8; k++) a[col][k] /= d;
        for (int r = 0; r < 4; r++) {
            if (r == col) continue;
            double f = a[r][col];
            if (f != 0) for (int k = 0; k < 8; k++) a[r][k] -= f * a[col][k];
        }
    }
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) out[c * 4 + r] = a[r][4 + c];
    return 1;
}

void BKMat4dApplyToPoint(const double m[16], const double p[3], double out[3])
{
    double o[3];
    for (int r = 0; r < 3; r++) o[r] = m[r] * p[0] + m[4 + r] * p[1] + m[8 + r] * p[2] + m[12 + r];
    out[0] = o[0]; out[1] = o[1]; out[2] = o[2];
}

int BKOrientationLetters(const double v[3], int inverted, char out[4])
{
    double x = inverted ? -v[0] : v[0], y = inverted ? -v[1] : v[1], z = inverted ? -v[2] : v[2];
    char lx = x < 0 ? 'R' : 'L', ly = y < 0 ? 'A' : 'P', lz = z < 0 ? 'I' : 'S';
    double ax = fabs(x), ay = fabs(y), az = fabs(z);
    int n = 0;
    for (int i = 0; i < 3; i++) {
        if (ax > .2 && ax >= ay && ax >= az) { out[n++] = lx; ax = 0; }
        else if (ay > .2 && ay >= ax && ay >= az) { out[n++] = ly; ay = 0; }
        else if (az > .2 && az >= ax && az >= ay) { out[n++] = lz; az = 0; }
        else break;
    }
    out[n] = 0;
    return n;
}

double BKTrackballSpinDegrees(double cx, double cy, double x0, double y0, double x1, double y1)
{
    double a0 = atan2(y0 - cy, x0 - cx), a1 = atan2(y1 - cy, x1 - cx);
    double d = (a1 - a0) * 180.0 / 3.14159265358979323846;
    if (d > 180) d -= 360;      // the short way round across the +-180 line
    if (d < -180) d += 360;
    return d;
}

double BKTrackballDollyFactor(double dyUp, double viewHeight)
{
    if (!(viewHeight > 0)) return 1.0;
    return pow(1.1, 10.0 * dyUp / (viewHeight / 2.0));
}

void BKScanGreyFromARGB(const unsigned char *argb, size_t count, float *out)
{
    if (!argb || !out) return;
    for (size_t i = 0; i < count; i++, argb += 4) out[i] = (float)((argb[1] + argb[2] + argb[3]) / 3.0);
}
