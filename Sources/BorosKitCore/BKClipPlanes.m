// BorosKitCore: clipping-plane math (plain C). See include/BKClipPlanes.h.

#import "BKClipPlanes.h"
#include <math.h>

// What: signed distance-like value of `point` against one plane (> 0 = cut side).
static CGFloat BKClipPlaneSide(N3Plane plane, N3Vector point)
{
    return N3VectorDotProduct(N3VectorSubtract(point, plane.point), plane.normal);
}

BOOL BKClipPlanesKeepPoint(const N3Plane *planes, NSUInteger count, N3Vector point)
{
    for (NSUInteger i = 0; i < count; i++)
        if (BKClipPlaneSide(planes[i], point) > 0) return NO;
    return YES;
}

N3Vector BKClipPlanesCentroid(const N3Plane *planes, NSUInteger count)
{
    N3Vector sum = N3VectorZero;
    if (count == 0) return sum;
    for (NSUInteger i = 0; i < count; i++)
        sum = N3VectorAdd(sum, planes[i].point);
    return N3VectorScalarMultiply(sum, 1.0 / (CGFloat)count);
}

NSUInteger BKClipPlanesOrientToKeepPoint(N3Plane *planes, NSUInteger count, N3Vector keepPoint)
{
    NSUInteger flipped = 0;
    for (NSUInteger i = 0; i < count; i++) {
        if (BKClipPlaneSide(planes[i], keepPoint) > 0) {
            planes[i].normal = N3VectorInvert(planes[i].normal);
            flipped++;
        }
    }
    return flipped;
}

NSUInteger BKClipPlanesFromVTK(const double *origins, const double *normals, NSUInteger count,
                               double worldScale, N3Plane *out)
{
    // Why divide by worldScale: VTK world coordinates are patient mm multiplied by the
    // window's factor; directions are unaffected by a uniform scale.
    double s = (worldScale != 0) ? 1.0 / worldScale : 1.0;
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < count && n < BK_MAX_CLIP_PLANES; i++) {
        N3Vector normal = N3VectorMake(normals[3 * i], normals[3 * i + 1], normals[3 * i + 2]);
        if (N3VectorLength(normal) < 1e-12) continue;
        // VTK keeps the normal side; BorosKit cuts the normal side -> invert.
        out[n].normal = N3VectorInvert(N3VectorNormalize(normal));
        out[n].point = N3VectorMake(origins[3 * i] * s, origins[3 * i + 1] * s, origins[3 * i + 2] * s);
        n++;
    }
    if (n == 6)
        BKClipPlanesOrientToKeepPoint(out, n, BKClipPlanesCentroid(out, n));
    return n;
}

NSUInteger BKClipPlanesPack(const N3Plane *planes, NSUInteger count, float *outXYZW)
{
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < count && n < BK_MAX_CLIP_PLANES; i++) {
        if (N3VectorLength(planes[i].normal) < 1e-12) continue;
        N3Vector u = N3VectorNormalize(planes[i].normal);
        outXYZW[4 * n + 0] = (float)u.x;
        outXYZW[4 * n + 1] = (float)u.y;
        outXYZW[4 * n + 2] = (float)u.z;
        outXYZW[4 * n + 3] = (float)(-N3VectorDotProduct(u, planes[i].point));
        n++;
    }
    return n;
}
