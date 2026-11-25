// BorosKitRender: curved-MPR / cross-section picture generator - CPU reference (plain C).
// See include/BKCurvedReformatCore.h for the definition, the classic rules kept and the porting notes
// (VULKAN: safe to translate directly - the GPU kernel in BKCurvedReformat.m mirrors these functions
// line by line; this file is the golden output to compare a Vulkan port against).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKCurvedReformatCore.h"
#include <math.h>

float BKReformatRadiographK(double strength, double slabStepMm)
{
    const double muWater = 0.0195;   // 1/mm, water at typical dental X-ray energies (~70 keV)
    if (!(strength > 0)) strength = 0.75;
    return (float)(strength * muWater / 1000.0 * slabStepMm);
}

// What: the voxel value at integer index (x, y, z), or outOfBoundsValue outside the scan.
static float BKRFetch(const BKReformatParams *p, const float *v, long x, long y, long z)
{
    if (x < 0 || y < 0 || z < 0 || x >= (long)p->volumeWide || y >= (long)p->volumeHigh || z >= (long)p->volumeDeep)
        return p->outOfBoundsValue;
    return v[(size_t)x + (size_t)p->volumeWide * ((size_t)y + (size_t)p->volumeHigh * (size_t)z)];
}

// What: Catmull-Rom weights (cubic convolution, a = -0.5) for fractional offset d in [0, 1).
static void BKRCubicWeights(double d, double w[4])
{
    double d2 = d * d, d3 = d2 * d;
    w[0] = 0.5 * (-d + 2.0 * d2 - d3);
    w[1] = 0.5 * (2.0 - 5.0 * d2 + 3.0 * d3);
    w[2] = 0.5 * (d + 4.0 * d2 - 3.0 * d3);
    w[3] = 0.5 * (-d2 + d3);
}

float BKReformatSample(const BKReformatParams *p, const float *v, double x, double y, double z)
{
    if (p->interpolation == BKReformatNearest) {
        // Classic rule: (long)(c + 0.5), i.e. cut toward zero.
        return BKRFetch(p, v, (long)(x + 0.5), (long)(y + 0.5), (long)(z + 0.5));
    }
    if (p->interpolation == BKReformatLinear) {
        // Classic linear rule (recorded from the old engine, 2026-11-15): the base voxel is the coordinate
        // cut toward zero (so -1 < c < 0 uses voxels 0 and 1 and extrapolates), and the WHOLE sample is
        // outOfBounds when any of the 8 voxels is outside (so the last row / column / slice is outside).
        long ix = (long)x, iy = (long)y, iz = (long)z;
        if (ix < 0 || iy < 0 || iz < 0 || ix + 1 >= (long)p->volumeWide || iy + 1 >= (long)p->volumeHigh ||
            iz + 1 >= (long)p->volumeDeep)
            return p->outOfBoundsValue;
        double dx = x - (double)ix, dy = y - (double)iy, dz = z - (double)iz;
        double sum = 0;
        for (int k = 0; k < 2; k++)
            for (int j = 0; j < 2; j++)
                for (int i = 0; i < 2; i++) {
                    double w = (i ? dx : 1.0 - dx) * (j ? dy : 1.0 - dy) * (k ? dz : 1.0 - dz);
                    sum += w * BKRFetch(p, v, ix + i, iy + j, iz + k);
                }
        return (float)sum;
    }
    double fx = floor(x), fy = floor(y), fz = floor(z);
    double dx = x - fx, dy = y - fy, dz = z - fz;
    long ix = (long)fx, iy = (long)fy, iz = (long)fz;
    double wx[4], wy[4], wz[4];
    BKRCubicWeights(dx, wx);
    BKRCubicWeights(dy, wy);
    BKRCubicWeights(dz, wz);
    double sum = 0;
    for (int k = 0; k < 4; k++) {
        double plane = 0;
        for (int j = 0; j < 4; j++) {
            double line = 0;
            for (int i = 0; i < 4; i++) line += wx[i] * BKRFetch(p, v, ix + i - 1, iy + j - 1, iz + k - 1);
            plane += wy[j] * line;
        }
        sum += wz[k] * plane;
    }
    return (float)sum;
}

void BKReformatComputeRows(const BKReformatParams *p, const BKReformatFrame *frames, const float *voxels,
                           uint32_t rowStart, uint32_t rowEnd, float *out)
{
    if (p == NULL || frames == NULL || voxels == NULL || out == NULL || p->depth == 0) return;
    if (rowEnd > p->height) rowEnd = p->height;
    const int band = p->bandEnabled != 0;   // Boros 6 (2026-11-25, cpr-cutoff): height cut-off on
    for (uint32_t y = rowStart; y < rowEnd; y++)
        for (uint32_t x = 0; x < p->width; x++) {
            const BKReformatFrame *f = &frames[x];
            double ry = (double)y - p->rowCentre;
            float acc = 0;
            uint32_t n = 0;   // samples taken so far (= z without the cut-off, so the formulas below are unchanged)
            for (uint32_t z = 0; z < p->depth; z++) {
                double rz = (double)z - p->slabCentre;
                if (band) {
                    // Cut-off: a sample outside the band is never read and does not count (BKHeightBandCore.h).
                    // Same float expression as the kernel: h0 + hRow * ry + hSlab * rz.
                    float h = f->base[3] + f->row[3] * (float)ry + f->slab[3] * (float)rz;
                    if (!BKHeightBandInside(p->bandLow, p->bandHigh, h)) continue;
                }
                double vx = f->base[0] + f->row[0] * ry + f->slab[0] * rz;
                double vy = f->base[1] + f->row[1] * ry + f->slab[1] * rz;
                double vz = f->base[2] + f->row[2] * ry + f->slab[2] * rz;
                float value = BKReformatSample(p, voxels, vx, vy, vz);
                switch (p->projection) {
                    case BKReformatMIP:   acc = (n == 0 || value > acc) ? value : acc; break;
                    case BKReformatMinIP: acc = (n == 0 || value < acc) ? value : acc; break;
                    case BKReformatMean:  acc = (n == 0) ? value : (acc * (float)n + value) / (float)(n + 1); break;   // running mean (classic order)
                    case BKReformatRadiograph: {
                        float hu = value < -1000.0f ? -1000.0f : value;   // below air counts as air
                        acc += (hu + 1000.0f) * p->radiographK;            // sum of mu * ds
                        break;
                    }
                    default: if (n == 0) acc = value; break;   // no projection: the first slab sample (classic)
                }
                n++;
            }
            if (band && n == 0)
                acc = p->bandOutsideValue;   // the whole pixel is cut off
            else if (p->projection == BKReformatRadiograph)
                acc = 3000.0f - 4000.0f * expf(-acc);   // -1000 + 4000 * (1 - transmitted)
            out[(size_t)y * p->width + x] = acc;
        }
}

// Boros 6 (2026-11-25, cpr-cutoff-2): see the header. Pure C99 (VULKAN: safe to translate directly; CPU only).
uint32_t BKReformatBandRows(const BKReformatFrame *frames, uint32_t width, uint32_t height, float rowCentre, float slabCentre,
                            float low, float high, int32_t *firstRow)
{
    if (firstRow) *firstRow = 0;
    if (frames == NULL || width == 0 || !(high >= low)) return 0;
    const double eps = 1e-4;   // rows whose sample sits on a limit (float rounding) count as inside
    double lo = INFINITY, hi = -INFINITY;
    for (uint32_t x = 0; x < width; x++) {
        const BKReformatFrame *f = &frames[x];
        double h0 = f->base[3], hr = f->row[3], spread = fabs((double)f->slab[3]) * (double)slabCentre;
        double a = (double)low - spread, b = (double)high + spread;   // the row's samples reach h0 + hr*ry +/- spread
        if (fabs(hr) < 1e-12) {
            if (h0 >= a && h0 <= b) { lo = fmin(lo, 0.0); hi = fmax(hi, (double)height - 1.0); }
            continue;
        }
        double y0 = (a - h0) / hr + rowCentre, y1 = (b - h0) / hr + rowCentre;
        if (y0 > y1) { double t = y0; y0 = y1; y1 = t; }
        lo = fmin(lo, ceil(y0 - eps));
        hi = fmax(hi, floor(y1 + eps));
    }
    if (!(hi >= lo) || !isfinite(lo) || !isfinite(hi)) return 0;
    if (hi - lo > 1e7) return 0;   // nonsense geometry: refuse rather than allocate a giant picture
    if (firstRow) *firstRow = (int32_t)lo;
    return (uint32_t)(hi - lo + 1.0);
}
