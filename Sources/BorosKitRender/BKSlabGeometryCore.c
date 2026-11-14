// BorosKitRender: picture geometry of an MPR / curved-MPR thick-slab view (plain C).
// See include/BKSlabGeometryCore.h for what it does, the rules and the porting notes.
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKSlabGeometryCore.h"
#include <math.h>

// What: is x a usable, finite, strictly positive number?
static int BKSlabPositive(double x)
{
    return x > 0 && isfinite(x);
}

// What: is every component of v finite?
static int BKSlabFinite3(BKVec3d v)
{
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z);
}

// What: solves  a*axes[0] + b*axes[1] + c*axes[2] = v  for (a, b, c) (Cramer's rule).
// Why: tells where the camera sits in the scan's own index directions, even if the three scan
// axes are not exactly perpendicular. Returns 0 when the axes are degenerate.
static int BKSlabSolveAxes(const BKVec3d axes[3], BKVec3d v, double out[3])
{
    double det = BKV3dDot(axes[0], BKV3dCross(axes[1], axes[2]));
    if (!(fabs(det) > 1e-12)) return 0;
    out[0] = BKV3dDot(v, BKV3dCross(axes[1], axes[2])) / det;
    out[1] = BKV3dDot(axes[0], BKV3dCross(v, axes[2])) / det;
    out[2] = BKV3dDot(axes[0], BKV3dCross(axes[1], v)) / det;
    return 1;
}

double BKSlabGeometryResolution(double parallelScale, int32_t renderHeight)
{
    if (!BKSlabPositive(parallelScale) || renderHeight <= 0) return 0;
    return 2.0 * parallelScale / (double)renderHeight;
}

void BKSlabGeometryOrientation(const BKSlabGeometry *g, double out[9])
{
    if (g == NULL || out == NULL) return;
    out[0] = g->right.x;        out[1] = g->right.y;        out[2] = g->right.z;
    out[3] = g->down.x;         out[4] = g->down.y;         out[5] = g->down.z;
    out[6] = g->towardViewer.x; out[7] = g->towardViewer.y; out[8] = g->towardViewer.z;
}

BKSlabGeometryStatus BKSlabGeometryCompute(const BKSlabGeometryInput *in, BKSlabGeometry *out)
{
    if (in == NULL || out == NULL) return BKSlabGeometryBadInput;

    // ---- check the input ------------------------------------------------------------------
    if (in->renderWidth <= 0 || in->renderHeight <= 0 ||
        !BKSlabPositive(in->parallelScale) || !BKSlabPositive(in->slabThickness) ||
        !BKSlabPositive(in->frameWidth) || !BKSlabPositive(in->frameHeight) ||
        !(in->sampleDistance >= 0.01) || !isfinite(in->sampleDistance) ||
        !isfinite(in->windowCenterX) || !isfinite(in->windowCenterY) ||
        !BKSlabFinite3(in->position) || !BKSlabFinite3(in->focalPoint) || !BKSlabFinite3(in->viewUp) ||
        !BKSlabFinite3(in->volumeOrigin) ||
        !BKSlabPositive(in->voxelSpacing.x) || !BKSlabPositive(in->voxelSpacing.y) || !BKSlabPositive(in->voxelSpacing.z))
        return BKSlabGeometryBadInput;
    for (int a = 0; a < 3; a++)
        if (!BKSlabFinite3(in->volumeAxes[a]) || in->indexMax[a] < in->indexMin[a])
            return BKSlabGeometryBadInput;

    // ---- rule 1: the camera's axes ----------------------------------------------------------
    BKVec3d toFocal = BKV3dSub(in->focalPoint, in->position);
    double focalDistance = BKV3dLength(toFocal);
    if (!(focalDistance > 1e-12)) return BKSlabGeometryBadInput;
    BKVec3d dir = BKV3dDiv(toFocal, focalDistance);
    BKVec3d side = BKV3dCross(dir, in->viewUp);
    double sideLength = BKV3dLength(side);
    if (!(sideLength > 1e-12)) return BKSlabGeometryBadInput;   // up parallel to the view
    BKVec3d right = BKV3dDiv(side, sideLength);
    BKVec3d up = BKV3dCross(right, dir);                         // unit: right and dir are unit, perpendicular

    // ---- rule 2: the picture grid (single precision, as the classic engine) ------------------
    float sampleDistanceF = (float)in->sampleDistance;
    double sampleDistance = (double)sampleDistanceF;
    int32_t gridW = (int32_t)((float)in->renderWidth / sampleDistanceF);
    int32_t gridH = (int32_t)((float)in->renderHeight / sampleDistanceF);
    if (gridW <= 0 || gridH <= 0) return BKSlabGeometryBadInput;

    // ---- rule 3: which part of the grid the scan covers ---------------------------------------
    int wholeView = 0;

    // Camera inside the scan box (in index units, inclusive)?
    double camIndex[3];
    if (!BKSlabSolveAxes(in->volumeAxes, BKV3dSub(in->position, in->volumeOrigin), camIndex))
        return BKSlabGeometryBadInput;
    double spacing[3] = { in->voxelSpacing.x, in->voxelSpacing.y, in->voxelSpacing.z };
    int inside = 1;
    for (int a = 0; a < 3; a++) {
        double t = camIndex[a] / spacing[a];
        if (!(t >= (double)in->indexMin[a] && t <= (double)in->indexMax[a])) inside = 0;
    }

    double aspect = (double)in->renderWidth / (double)in->renderHeight;
    double halfWidth = in->parallelScale * aspect;
    double minX = 1.0, minY = 1.0, maxX = -1.0, maxY = -1.0, minZ = 1.0, maxZ = 0.0;
    if (inside) {
        wholeView = 1;
    } else {
        // Project the 8 corners (min starts at +1, max at -1: classic rule): x, y in normalised view units (-1..1 across the view, shifted by
        // the window centre), z = fraction of the slab depth (0 = front face, 1 = back face).
        for (int corner = 0; corner < 8; corner++) {
            BKVec3d p = in->volumeOrigin;
            for (int a = 0; a < 3; a++) {
                int32_t index = (corner >> a) & 1 ? in->indexMax[a] : in->indexMin[a];
                p = BKV3dAddScaled(p, in->volumeAxes[a], (double)index * spacing[a]);
            }
            BKVec3d rel = BKV3dSub(p, in->position);
            double x = BKV3dDot(rel, right) / halfWidth - in->windowCenterX;
            double y = BKV3dDot(rel, up) / in->parallelScale - in->windowCenterY;
            double z = BKV3dDot(rel, dir) / in->slabThickness;
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
            if (z < minZ) minZ = z;
            if (z > maxZ) maxZ = z;
        }
        if (minZ < 0.001 || maxZ > 0.9999) wholeView = 1;
    }

    int32_t width = gridW, height = gridH, gridOriginX = 0, gridOriginY = 0;
    if (!wholeView) {
        // To grid pixels, with a margin of 2 pixels on each side.
        double pMinX = (minX + 1.0) * 0.5 * gridW - 2, pMaxX = (maxX + 1.0) * 0.5 * gridW + 2;
        double pMinY = (minY + 1.0) * 0.5 * gridH - 2, pMaxY = (maxY + 1.0) * 0.5 * gridH + 2;
        // (Because the minimum starts at +1 and the maximum at -1, the range always overlaps the
        // grid, so no "completely outside" case can arise here.)
        if (pMinX < 0) pMinX = 0;
        if (pMinY < 0) pMinY = 0;
        if (pMaxX > gridW - 1) pMaxX = gridW - 1;
        if (pMaxY > gridH - 1) pMaxY = gridH - 1;
        width = (int32_t)(pMaxX - pMinX + 1.0);
        height = (int32_t)(pMaxY - pMinY + 1.0);
        gridOriginX = (int32_t)pMinX;
        gridOriginY = (int32_t)pMinY;
    }

    // ---- rules 4 + 5: scale and placement -----------------------------------------------------
    double resolution = BKSlabGeometryResolution(in->parallelScale, in->renderHeight);
    int32_t x1 = (int32_t)((double)gridOriginX * sampleDistance);
    int32_t y1 = (int32_t)((double)gridOriginY * sampleDistance);
    double x = (double)x1 - (double)in->renderWidth / 2.0 + in->windowCenterX * (in->frameWidth / 2.0);
    double y = (double)y1 - (double)in->renderHeight / 2.0 - in->windowCenterY * (in->frameHeight / 2.0);
    BKVec3d down = BKV3dNeg(up);

    BKVec3d origin = in->position;
    origin = BKV3dAddScaled(origin, down, y * resolution);
    origin = BKV3dAddScaled(origin, right, x * resolution);
    origin = BKV3dAddScaled(origin, dir, in->slabThickness / 2.0);

    out->width = width;
    out->height = height;
    out->gridWidth = gridW;
    out->gridHeight = gridH;
    out->gridOriginX = gridOriginX;
    out->gridOriginY = gridOriginY;
    out->coversWholeView = wholeView ? 1 : 0;
    out->resolution = resolution;
    out->pixelSpacing = resolution * sampleDistance;
    out->sampleDistance = sampleDistance;
    out->slabThickness = in->slabThickness;
    out->origin = origin;
    out->right = right;
    out->down = down;
    out->towardViewer = BKV3dNeg(dir);
    out->viewDirection = dir;
    return BKSlabGeometryOK;
}
