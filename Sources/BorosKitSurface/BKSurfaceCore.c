// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSurface: the backend-neutral core (see BKSurfaceCore.h).

/* BOROS OVERVIEW (plain language)
 * To turn a scan into a bone surface, the scan is looked at as a grid of small cubes
 * ("cells") whose 8 corners are scan points. Each corner is either inside the bone
 * (value at or above the threshold) or outside. Wherever an edge of a cube joins an
 * inside corner to an outside corner, the surface crosses that edge, and the surface
 * point is placed along the edge in proportion to the values (linear interpolation).
 * Inside each cube those points are connected into a few triangles; this is the classic
 * "marching cubes" method (Lorensen & Cline, 1987). Which triangles to make depends only
 * on which of the 8 corners are inside: 2^8 = 256 possible "cases".
 *
 * This file works out that 256-case table itself, from the geometry of a cube, instead
 * of copying one of the published tables (so the code carries no third-party licence).
 * It also contains the bookkeeping shared by every GPU backend, and a simple, slow CPU
 * version of the whole method that the tests use as the trusted answer.
 */

#include "BKSurfaceCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

const char *BKSurfaceStatusMessage(BKSurfaceStatus status)
{
    switch (status) {
        case BKSurfaceStatusOK:           return "No error.";
        case BKSurfaceStatusInvalidInput: return "The surface settings or the volume are not valid (size, resolution, smoothing, threshold or geometry).";
        case BKSurfaceStatusTooLarge:     return "The surface is too large for the graphics memory at this resolution. Try a lower resolution.";
        case BKSurfaceStatusOutOfMemory:  return "There is not enough memory to build the surface.";
        case BKSurfaceStatusGPUFailed:    return "The graphics processor failed while building the surface.";
    }
    return "Unknown error.";
}

#pragma mark - Cube geometry

// What: the 12 edges of a cube, derived from the corner and edge numbering in the header.
// Why a function and not a hand-typed list: so the numbering rule is the only source of
// truth (edge 4*axis + j starts at the j-th corner whose `axis` bit is 0).
static BKSurfaceEdge gEdges[12];

// What: the cube edge joining corners a and b (which differ in exactly one bit).
static int BKEdgeBetween(int a, int b)
{
    int bit = a ^ b;
    int axis = bit == 1 ? 0 : (bit == 2 ? 1 : 2);
    int base = a < b ? a : b;
    int j;
    if (axis == 0) j = (base >> 1) & 3;                        // corners 0,2,4,6
    else if (axis == 1) j = (base & 1) | (((base >> 2) & 1) << 1);   // corners 0,1,4,5
    else j = base & 3;                                         // corners 0,1,2,3
    return 4 * axis + j;
}

// The 6 faces of the cube, each as its 4 corners in ANTICLOCKWISE order when the face is
// seen from outside the cube (i.e. turning right-handed about the face's outward normal).
// Derived by hand from corner c = (c&1, c>>1&1, c>>2&1):
//   x = 0 (normal -x): 0 4 6 2     x = 1 (normal +x): 1 3 7 5
//   y = 0 (normal -y): 0 1 5 4     y = 1 (normal +y): 2 6 7 3
//   z = 0 (normal -z): 0 2 3 1     z = 1 (normal +z): 4 5 7 6
// Each cube edge belongs to two faces and, with this ordering, is walked in opposite
// directions by them (a unit test checks this).
static const int kFaces[6][4] = {
    {0, 4, 6, 2}, {1, 3, 7, 5},
    {0, 1, 5, 4}, {2, 6, 7, 3},
    {0, 2, 3, 1}, {4, 5, 7, 6},
};

#pragma mark - Table generation

/* HOW THE 256-CASE TABLE IS DERIVED (plain language)
 *
 * Instead of looking up the 15 textbook pictures and rotating them, the triangles are
 * traced directly on the cube's faces, which gives the same kind of table and makes the
 * "no holes" property true by construction:
 *
 * 1. On each square face, look at its 4 corners in the anticlockwise order above. Where
 *    the walk goes from an inside corner to an outside one (or back), the surface crosses
 *    that edge. A face has 0, 2 or 4 such crossings.
 *    - 2 crossings: the surface crosses the face along one line between them.
 *    - 4 crossings (the "ambiguous" face: two inside corners diagonally opposite, two
 *      outside corners on the other diagonal): the inside corners could be joined across
 *      the face or kept apart. OUR RULE: the inside corners are always JOINED (the two
 *      outside corners are each cut off by their own short line). Why this rule:
 *        (a) it depends only on the 4 corners of that face, and the neighbouring cube
 *            sees the very same 4 corners, so both cubes draw identical lines on their
 *            shared face: the surface can never have a gap between cubes (watertight);
 *        (b) for bone it keeps thin plates (e.g. the buccal plate, sinus floor) in one
 *            piece where two bone voxels only touch diagonally, instead of punching
 *            false holes, which is what a surgeon wants to see.
 * 2. Each face line gets a direction: it starts where the walk went inside -> outside
 *    and ends where it went outside -> inside. A crossed cube edge belongs to two faces,
 *    which walk it in opposite directions, so the edge is the START of a line on one face
 *    and the END of a line on the other. Therefore the lines join head-to-tail into
 *    closed loops around the cube: one loop per separate piece of surface in that cube.
 * 3. Each loop (3 or more points) is cut into triangles. Of all the ways to do that, we
 *    take the one with the shortest total length of the cuts ("diagonals"), which gives
 *    the best-shaped triangles, with one hard rule: a cut may never join two points that
 *    lie on the same cube face. Why: such a cut would lie across the face, and the
 *    neighbouring cube could make the very same cut from its side; that line would then
 *    belong to four triangles instead of two (a "non-manifold" edge). With the rule, the
 *    only lines on a face are the face lines of step 1, shared by exactly two triangles.
 *    The loop direction from step 2 turns out to go clockwise seen from outside, so each
 *    triangle is written in reverse corner order to make it anticlockwise from outside
 *    (the BKMesh convention). Example: only corner 0 inside -> one triangle around
 *    corner 0 whose front side faces away from corner 0 (a unit test checks all cases).
 *
 * Inside each cube the loops never share a point, and every crossed edge is used by
 * exactly one loop, so the result is a proper closed surface everywhere the inside
 * region does not touch the edge of the scan. The largest cases give 5 triangles
 * (BK_SURFACE_MAX_CELL_TRIANGLES; the builder stops the program if that were ever
 * exceeded, and a unit test checks the whole table).
 */
static BKSurfaceCase gCases[256];
static pthread_once_t gTableOnce = PTHREAD_ONCE_INIT;

// What: bit mask of the (up to two) faces that contain cube edge e.
static int BKEdgeFaces(int e)
{
    int mask = 0;
    for (int f = 0; f < 6; f++) {
        int has0 = 0, has1 = 0;
        for (int i = 0; i < 4; i++) {
            if (kFaces[f][i] == gEdges[e].corner0) has0 = 1;
            if (kFaces[f][i] == gEdges[e].corner1) has1 = 1;
        }
        if (has0 && has1) mask |= 1 << f;
    }
    return mask;
}

// What: squared distance between the midpoints of two cube edges (cube of side 2, so
// the numbers are whole). Used as the "length" of a cut when choosing triangles.
static int BKEdgeDistance2(int a, int b)
{
    int d2 = 0;
    for (int axis = 0; axis < 3; axis++) {
        int pa = ((gEdges[a].corner0 >> axis) & 1) + ((gEdges[a].corner1 >> axis) & 1);
        int pb = ((gEdges[b].corner0 >> axis) & 1) + ((gEdges[b].corner1 >> axis) & 1);
        d2 += (pa - pb) * (pa - pb);
    }
    return d2;
}

// What: cuts one closed loop of n edge points into n-2 triangles (step 3 above) and
// appends them to `out`, reversed so they are anticlockwise from outside.
// How: the classic "minimum-weight polygon triangulation" by dynamic programming:
// best[i][j] = cheapest way to triangulate the sub-polygon loop[i..j]; a cut joining two
// points on a common cube face costs "infinity" (forbidden). n <= 12, so this is tiny.
static void BKTriangulateLoop(const int *loop, int n, BKSurfaceCase *out)
{
    enum { INF = 1 << 28 };
    int best[12][12], apex[12][12];
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) { best[i][j] = 0; apex[i][j] = -1; }
    for (int len = 2; len < n; len++) {
        for (int i = 0; i + len < n; i++) {
            int j = i + len;
            best[i][j] = INF;
            for (int k = i + 1; k < j; k++) {
                // The triangle (i, k, j) adds the cuts i-k and k-j unless they are loop sides.
                int cost = best[i][k] + best[k][j];
                int cuts[2][2] = {{i, k}, {k, j}};
                for (int c = 0; c < 2; c++) {
                    int a = cuts[c][0], b = cuts[c][1];
                    if (b - a == 1) continue;                     // a side of the loop, not a cut
                    if (BKEdgeFaces(loop[a]) & BKEdgeFaces(loop[b])) cost = INF;
                    else if (cost < INF) cost += BKEdgeDistance2(loop[a], loop[b]);
                }
                if (cost < best[i][j]) { best[i][j] = cost; apex[i][j] = k; }
            }
        }
    }
    if (n < 3 || best[0][n - 1] >= INF) abort();   // no valid triangulation: programming error
    // Read the triangles back out (iteratively, with a small stack of sub-polygons).
    int stack[24][2], top = 0;
    stack[top][0] = 0; stack[top][1] = n - 1; top++;
    while (top) {
        top--;
        int i = stack[top][0], j = stack[top][1];
        if (j - i < 2) continue;
        int k = apex[i][j];
        if (out->triangleCount >= BK_SURFACE_MAX_CELL_TRIANGLES) abort();   // table constant too small
        uint8_t *t = out->edges + 3 * out->triangleCount++;
        t[0] = (uint8_t)loop[i];   // (i, k, j) follows the loop; reversed = (i, j, k)
        t[1] = (uint8_t)loop[j];
        t[2] = (uint8_t)loop[k];
        stack[top][0] = i; stack[top][1] = k; top++;
        stack[top][0] = k; stack[top][1] = j; top++;
    }
}

static void BKBuildTables(void)
{
    // Edges.
    for (int c = 0; c < 8; c++) {
        for (int axis = 0; axis < 3; axis++) {
            if (c & (1 << axis)) continue;
            int e = BKEdgeBetween(c, c | (1 << axis));
            gEdges[e].corner0 = (uint8_t)c;
            gEdges[e].corner1 = (uint8_t)(c | (1 << axis));
            gEdges[e].axis = (uint8_t)axis;
            gEdges[e].dx = (uint8_t)(c & 1);
            gEdges[e].dy = (uint8_t)((c >> 1) & 1);
            gEdges[e].dz = (uint8_t)((c >> 2) & 1);
        }
    }

    for (int cs = 0; cs < 256; cs++) {
        // next[e] = the edge where the face line starting at edge e ends (-1 = none).
        int next[12];
        for (int e = 0; e < 12; e++) next[e] = -1;

        for (int f = 0; f < 6; f++) {
            const int *q = kFaces[f];
            int inOut[2], outIn[2], nIO = 0, nOI = 0;   // positions i of the crossing edges q[i]-q[i+1]
            for (int i = 0; i < 4; i++) {
                int a = (cs >> q[i]) & 1, b = (cs >> q[(i + 1) & 3]) & 1;
                if (a && !b) inOut[nIO++] = i;
                if (!a && b) outIn[nOI++] = i;
            }
            if (nIO == 1) {
                next[BKEdgeBetween(q[inOut[0]], q[(inOut[0] + 1) & 3])] =
                    BKEdgeBetween(q[outIn[0]], q[(outIn[0] + 1) & 3]);
            } else if (nIO == 2) {
                // Ambiguous face: join the inside corners, i.e. the line leaving at position
                // i ends at position i+1 and cuts off the outside corner q[i+1].
                for (int k = 0; k < 2; k++) {
                    int i = inOut[k];
                    next[BKEdgeBetween(q[i], q[(i + 1) & 3])] = BKEdgeBetween(q[(i + 1) & 3], q[(i + 2) & 3]);
                }
            }
        }

        // Chain the lines into loops and fan-triangulate each loop (reversed order).
        int used[12] = {0};
        BKSurfaceCase out;
        memset(&out, 0, sizeof out);
        for (int start = 0; start < 12; start++) {
            if (next[start] < 0 || used[start]) continue;
            int loop[12], n = 0, e = start;
            while (!used[e] && n < 12) {
                used[e] = 1;
                loop[n++] = e;
                e = next[e];
            }
            BKTriangulateLoop(loop, n, &out);
        }
        gCases[cs] = out;
    }
}

const BKSurfaceEdge *BKSurfaceEdges(void)
{
    pthread_once(&gTableOnce, BKBuildTables);
    return gEdges;
}

const BKSurfaceCase *BKSurfaceCaseTable(void)
{
    pthread_once(&gTableOnce, BKBuildTables);
    return gCases;
}

void BKSurfaceFillGPUTable(uint32_t words[BK_SURFACE_TABLE_WORDS])
{
    const BKSurfaceCase *cases = BKSurfaceCaseTable();
    const BKSurfaceEdge *edges = BKSurfaceEdges();
    memset(words, 0, sizeof(uint32_t) * BK_SURFACE_TABLE_WORDS);
    for (int cs = 0; cs < 256; cs++) {
        uint32_t *w = words + cs * BK_SURFACE_CASE_STRIDE;
        w[0] = cases[cs].triangleCount;
        for (int i = 0; i < 3 * cases[cs].triangleCount; i++) w[1 + i] = cases[cs].edges[i];
    }
    for (int e = 0; e < 12; e++)
        words[BK_SURFACE_EDGE_TABLE_OFFSET + e] = (uint32_t)edges[e].dx | ((uint32_t)edges[e].dy << 8) |
                                                  ((uint32_t)edges[e].dz << 16) | ((uint32_t)edges[e].axis << 24);
}

#pragma mark - Geometry helpers

int BKSurfaceGridTransform(const double voxelToOutput[16], const double gridToVoxel[3],
                           float gridToOutput[16], float normalMatrix[12], uint32_t *mirrors)
{
    // A = voxelToOutput * diag(gridToVoxel, 1): scale the first three columns.
    double A[16];
    for (int c = 0; c < 4; c++)
        for (int r = 0; r < 4; r++)
            A[c * 4 + r] = voxelToOutput[c * 4 + r] * (c < 3 ? gridToVoxel[c] : 1.0);
    for (int i = 0; i < 16; i++) if (!isfinite(A[i])) return 0;

    // Normals: the gradient turns with the inverse-transpose of the 3x3 part, whose
    // columns are (c1 x c2, c2 x c0, c0 x c1) / det for the columns c0, c1, c2 of A.
    const double *c0 = A, *c1 = A + 4, *c2 = A + 8;
    double x12[3] = {c1[1] * c2[2] - c1[2] * c2[1], c1[2] * c2[0] - c1[0] * c2[2], c1[0] * c2[1] - c1[1] * c2[0]};
    double x20[3] = {c2[1] * c0[2] - c2[2] * c0[1], c2[2] * c0[0] - c2[0] * c0[2], c2[0] * c0[1] - c2[1] * c0[0]};
    double x01[3] = {c0[1] * c1[2] - c0[2] * c1[1], c0[2] * c1[0] - c0[0] * c1[2], c0[0] * c1[1] - c0[1] * c1[0]};
    double det = c0[0] * x12[0] + c0[1] * x12[1] + c0[2] * x12[2];
    double scale = fabs(A[0]) + fabs(A[5]) + fabs(A[10]) + 1e-300;
    if (!isfinite(det) || fabs(det) < 1e-12 * scale * scale * scale) return 0;

    for (int i = 0; i < 16; i++) gridToOutput[i] = (float)A[i];
    for (int r = 0; r < 3; r++) {
        normalMatrix[0 + r] = (float)(x12[r] / det);
        normalMatrix[4 + r] = (float)(x20[r] / det);
        normalMatrix[8 + r] = (float)(x01[r] / det);
    }
    normalMatrix[3] = normalMatrix[7] = normalMatrix[11] = 0;
    // A mirroring transform turns anticlockwise triangles clockwise: the GPU swaps two
    // corners of every triangle to undo that.
    *mirrors = det < 0 ? 1u : 0u;
    return 1;
}

float BKSurfaceThresholdToSteps(float threshold, float valueScale, float valueOffset)
{
    if (!isfinite(threshold) || !isfinite(valueScale) || !isfinite(valueOffset) || valueScale == 0) return NAN;
    return (float)(((double)threshold - valueOffset) / valueScale * 65535.0);
}

#pragma mark - Planning

BKSurfaceStatus BKSurfacePlanMake(const BKSurfacePlanRequest *rq, BKSurfacePlan *plan)
{
    memset(plan, 0, sizeof *plan);
    if (rq->volumeWidth < 2 || rq->volumeHeight < 2 || rq->volumeDepth < 2) return BKSurfaceStatusInvalidInput;
    // The packed buffer keeps a vertex count of up to 3 per grid point of a row in 13 bits:
    // 3 * 2048 < 8192, so rows are limited to 2048 points (Metal's 3D texture limit too).
    if (rq->volumeWidth > 2048 || rq->volumeHeight > 2048 || rq->volumeDepth > 2048) return BKSurfaceStatusTooLarge;
    if (!(rq->resolution > 0.0f && rq->resolution <= 1.0f)) return BKSurfaceStatusInvalidInput;
    if (!(rq->smoothingSigma >= 0.0f && rq->smoothingSigma <= 10.0f)) return BKSurfaceStatusInvalidInput;
    if (rq->sampling != BK_SURFACE_SAMPLING_HARDWARE && rq->sampling != BK_SURFACE_SAMPLING_MANUAL) return BKSurfaceStatusInvalidInput;

    // Grid size like VTK's resample: the last grid point is the last whole step that
    // still lies inside the volume (a tiny tolerance absorbs float rounding, e.g. 0.1*10).
    const double r = rq->resolution;
    plan->gridWidth = (uint32_t)floor((rq->volumeWidth - 1) * r + 1e-6) + 1;
    plan->gridHeight = (uint32_t)floor((rq->volumeHeight - 1) * r + 1e-6) + 1;
    plan->gridDepth = rq->volumeDepth;
    if (plan->gridWidth < 2 || plan->gridHeight < 2) return BKSurfaceStatusInvalidInput;
    plan->rowStride = plan->gridWidth + (plan->gridWidth & 1u);
    plan->rowCount = plan->gridHeight * plan->gridDepth;

    const uint64_t points = (uint64_t)plan->rowStride * plan->gridHeight * plan->gridDepth;
    if (points >= (1ull << 31)) return BKSurfaceStatusTooLarge;   // GPU index math is 32-bit

    plan->usesField = rq->resolution < 1.0f || rq->smoothingSigma > 0.0f;
    plan->fieldBytes = plan->usesField ? points * 2 : 0;
    plan->packedBytes = points * 2;
    plan->rowTableBytes = (uint64_t)plan->rowCount * 4;

    // Blur weights per axis. The setting is in voxels of the original scan, so the grid
    // sigma is smaller in X/Y when the grid is thinned (same physical smoothing).
    const double sigmaGrid[3] = {rq->smoothingSigma * r, rq->smoothingSigma * r, rq->smoothingSigma};
    for (int a = 0; a < 3; a++) {
        if (sigmaGrid[a] <= 1e-3) continue;
        uint32_t radius = (uint32_t)ceil(3.0 * sigmaGrid[a]);   // 3 sigma holds 99.7% of the weight
        if (radius > BK_SURFACE_MAX_BLUR_WEIGHTS - 1) radius = BK_SURFACE_MAX_BLUR_WEIGHTS - 1;
        double w[BK_SURFACE_MAX_BLUR_WEIGHTS], sum = 0;
        for (uint32_t k = 0; k <= radius; k++) {
            w[k] = exp(-(double)(k * k) / (2.0 * sigmaGrid[a] * sigmaGrid[a]));
            sum += k ? 2 * w[k] : w[k];
        }
        for (uint32_t k = 0; k <= radius; k++) plan->blurWeights[a][k] = (float)(w[k] / sum);
        plan->blurRadius[a] = radius;
        plan->blurs = 1;
    }

    const uint64_t extraction = plan->fieldBytes + plan->packedBytes + 2 * plan->rowTableBytes +
                                sizeof(uint32_t) * BK_SURFACE_TABLE_WORDS;
    const uint64_t smoothing = plan->blurs ? 2 * plan->fieldBytes : 0;
    plan->peakTemporaryBytes = extraction > smoothing ? extraction : smoothing;
    if (rq->maxBufferBytes && (plan->fieldBytes > rq->maxBufferBytes || plan->packedBytes > rq->maxBufferBytes))
        return BKSurfaceStatusTooLarge;
    if (rq->memoryBudgetBytes && plan->peakTemporaryBytes > rq->memoryBudgetBytes) return BKSurfaceStatusTooLarge;

    // GPU parameters shared by every step.
    BKSurfaceParams *p = &plan->params;
    const double gridToVoxel[3] = {1.0 / r, 1.0 / r, 1.0};
    if (!BKSurfaceGridTransform(rq->voxelToOutput, gridToVoxel, p->gridToOutput, p->normalMatrix, &p->flipWinding))
        return BKSurfaceStatusInvalidInput;
    p->gridToVoxel[0] = (float)gridToVoxel[0];
    p->gridToVoxel[1] = (float)gridToVoxel[1];
    p->gridToVoxel[2] = 1.0f;
    p->volumeSizeInv[0] = 1.0f / rq->volumeWidth;
    p->volumeSizeInv[1] = 1.0f / rq->volumeHeight;
    p->volumeSizeInv[2] = 1.0f / rq->volumeDepth;
    p->gridSize[0] = plan->gridWidth;
    p->gridSize[1] = plan->gridHeight;
    p->gridSize[2] = plan->gridDepth;
    p->gridSize[3] = plan->rowStride;
    p->volumeSize[0] = rq->volumeWidth;
    p->volumeSize[1] = rq->volumeHeight;
    p->volumeSize[2] = rq->volumeDepth;
    p->source = plan->usesField ? BK_SURFACE_SOURCE_FIELD : BK_SURFACE_SOURCE_TEXTURE;
    p->sampling = rq->sampling;
    return BKSurfaceStatusOK;
}

void BKSurfacePlanSetBlurAxis(const BKSurfacePlan *plan, uint32_t axis, BKSurfaceParams *params)
{
    params->blurAxis = axis;
    params->blurRadius = plan->blurRadius[axis];
    memcpy(params->blurWeights, plan->blurWeights[axis], sizeof params->blurWeights);
}

uint64_t BKSurfaceExclusiveScan(uint32_t *values, size_t count)
{
    uint64_t sum = 0;
    for (size_t i = 0; i < count; i++) {
        uint32_t v = values[i];
        values[i] = (uint32_t)sum;
        sum += v;
        if (sum > UINT32_MAX) return UINT64_MAX;
    }
    return sum;
}

uint64_t BKSurfaceOutputBytes(uint64_t vertexCount, uint64_t triangleCount)
{
    return vertexCount * 32 + triangleCount * 12;
}

#pragma mark - CPU reference

void BKSurfaceMeshDataFree(BKSurfaceMeshData *mesh)
{
    free(mesh->positions);
    free(mesh->normals);
    free(mesh->indices);
    memset(mesh, 0, sizeof *mesh);
}

// What: the value gradient at a grid point (central differences, one-sided at the
// border), in grid units. Same formula as bk_gradient in the GPU source.
static void BKReferenceGradient(const float *v, uint32_t w, uint32_t h, uint32_t d,
                                uint32_t x, uint32_t y, uint32_t z, double g[3])
{
    const uint32_t p[3] = {x, y, z}, n[3] = {w, h, d};
    for (int a = 0; a < 3; a++) {
        uint32_t lo[3] = {x, y, z}, hi[3] = {x, y, z};
        lo[a] = p[a] > 0 ? p[a] - 1 : 0;
        hi[a] = p[a] + 1 < n[a] ? p[a] + 1 : p[a];
        double vl = v[lo[0] + (size_t)w * (lo[1] + (size_t)h * lo[2])];
        double vh = v[hi[0] + (size_t)w * (hi[1] + (size_t)h * hi[2])];
        g[a] = (vh - vl) / (double)(hi[a] - lo[a]);
    }
}

BKSurfaceStatus BKSurfaceReferenceExtract(const float *values, uint32_t w, uint32_t h, uint32_t d,
                                          float threshold, const double gridToOutput[16],
                                          BKSurfaceMeshData *out)
{
    memset(out, 0, sizeof *out);
    if (!values || w < 2 || h < 2 || d < 2 || !isfinite(threshold)) return BKSurfaceStatusInvalidInput;
    const BKSurfaceCase *cases = BKSurfaceCaseTable();
    const BKSurfaceEdge *edges = BKSurfaceEdges();
    const double one[3] = {1, 1, 1};
    float M[16], N[12];
    uint32_t mirrors;
    if (!BKSurfaceGridTransform(gridToOutput, one, M, N, &mirrors)) return BKSurfaceStatusInvalidInput;

    const size_t points = (size_t)w * h * d;
    uint32_t *ids = malloc(points * 3 * sizeof(uint32_t));   // vertex number per owned edge
    size_t capV = 1024, capT = 1024;
    out->positions = malloc(capV * 16);
    out->normals = malloc(capV * 16);
    out->indices = malloc(capT * 12);
    if (!ids || !out->positions || !out->normals || !out->indices) {
        free(ids);
        BKSurfaceMeshDataFree(out);
        return BKSurfaceStatusOutOfMemory;
    }
#define VAL(X, Y, Z) ((double)values[(X) + (size_t)w * ((Y) + (size_t)h * (Z))])
    // Pass 1: vertices on owned edges, in the shared order (rows y then z, x, axis).
    for (uint32_t z = 0; z < d; z++)
        for (uint32_t y = 0; y < h; y++)
            for (uint32_t x = 0; x < w; x++) {
                const size_t i = x + (size_t)w * (y + (size_t)h * z);
                const double v0 = VAL(x, y, z);
                for (int a = 0; a < 3; a++) {
                    ids[3 * i + a] = UINT32_MAX;
                    uint32_t q[3] = {x, y, z};
                    q[a]++;
                    if (q[0] >= w || q[1] >= h || q[2] >= d) continue;
                    const double v1 = VAL(q[0], q[1], q[2]);
                    if ((v0 >= threshold) == (v1 >= threshold)) continue;
                    if (out->vertexCount == capV) {
                        capV *= 2;
                        float *np = realloc(out->positions, capV * 16), *nn = realloc(out->normals, capV * 16);
                        if (np) out->positions = np;
                        if (nn) out->normals = nn;
                        if (!np || !nn) { free(ids); BKSurfaceMeshDataFree(out); return BKSurfaceStatusOutOfMemory; }
                    }
                    const double t = ((double)threshold - v0) / (v1 - v0);
                    double g[3] = {x, y, z};
                    g[a] += t;
                    double ga[3], gb[3], gr[3];
                    BKReferenceGradient(values, w, h, d, x, y, z, ga);
                    BKReferenceGradient(values, w, h, d, q[0], q[1], q[2], gb);
                    for (int k = 0; k < 3; k++) gr[k] = ga[k] + (gb[k] - ga[k]) * t;
                    float *P = out->positions + 4 * out->vertexCount, *Nn = out->normals + 4 * out->vertexCount;
                    double n[3], len = 0;
                    for (int r = 0; r < 3; r++) {
                        P[r] = (float)(gridToOutput[r] * g[0] + gridToOutput[4 + r] * g[1] + gridToOutput[8 + r] * g[2] + gridToOutput[12 + r]);
                        // Outward = toward lower values = minus the gradient.
                        n[r] = -(N[r] * gr[0] + N[4 + r] * gr[1] + N[8 + r] * gr[2]);
                        len += n[r] * n[r];
                    }
                    len = sqrt(len);
                    for (int r = 0; r < 3; r++) Nn[r] = len > 0 ? (float)(n[r] / len) : 0.0f;
                    P[3] = Nn[3] = 0;
                    ids[3 * i + a] = (uint32_t)out->vertexCount++;
                }
            }
    // Pass 2: triangles, cell by cell in the same order.
    for (uint32_t z = 0; z + 1 < d; z++)
        for (uint32_t y = 0; y + 1 < h; y++)
            for (uint32_t x = 0; x + 1 < w; x++) {
                int cs = 0;
                for (int c = 0; c < 8; c++)
                    if (VAL(x + (c & 1), y + ((c >> 1) & 1), z + ((c >> 2) & 1)) >= threshold) cs |= 1 << c;
                const BKSurfaceCase *k = &cases[cs];
                for (int t = 0; t < k->triangleCount; t++) {
                    if (out->triangleCount == capT) {
                        capT *= 2;
                        uint32_t *ni = realloc(out->indices, capT * 12);
                        if (!ni) { free(ids); BKSurfaceMeshDataFree(out); return BKSurfaceStatusOutOfMemory; }
                        out->indices = ni;
                    }
                    uint32_t tri[3];
                    for (int j = 0; j < 3; j++) {
                        const BKSurfaceEdge *e = &edges[k->edges[3 * t + j]];
                        size_t owner = (x + e->dx) + (size_t)w * ((y + e->dy) + (size_t)h * (z + e->dz));
                        tri[j] = ids[3 * owner + e->axis];
                    }
                    uint32_t *o = out->indices + 3 * out->triangleCount++;
                    o[0] = tri[0];
                    o[1] = mirrors ? tri[2] : tri[1];
                    o[2] = mirrors ? tri[1] : tri[2];
                }
            }
#undef VAL
    free(ids);
    return BKSurfaceStatusOK;
}
