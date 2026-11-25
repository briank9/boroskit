// BorosKitCore: BKContourCore - see BKContourCore.h.
// Original BorosKit code written for this project; contains no third-party code.
// Boros 6 (2026-11-24, vtk-data).

#include "BKContourCore.h"
#include <stdlib.h>
#include <string.h>

void BKContourLinesFree(BKContourLines *lines)
{
    if (lines == NULL) return;
    free(lines->xy); free(lines->lineStart); free(lines->lineClosed);
    memset(lines, 0, sizeof(*lines));
}

int BKContourLineSegments(const BKContourLines *lines, int k)
{
    if (lines == NULL || k < 0 || k >= lines->lineCount) return 0;
    int points = lines->lineStart[k + 1] - lines->lineStart[k];
    return lines->lineClosed[k] ? points : points - 1;
}

int BKContourLargestLine(const BKContourLines *lines)
{
    int best = -1, bestSegments = -1;
    for (int k = 0; lines && k < lines->lineCount; k++)
    {
        int s = BKContourLineSegments(lines, k);
        if (s > bestSegments) { best = k; bestSegments = s; }
    }
    return best;
}

typedef struct {
    const unsigned char *img;
    int w, h;
    size_t rowBytes;
    double level;
    int hCount;            // number of horizontal square sides; vertical sides are numbered after them
} BKContourGrid;

static inline double BKContourValue(const BKContourGrid *g, int x, int y) { return g->img[(size_t)y * g->rowBytes + (size_t)x]; }

// The crossing point on side `edge`, always computed from the side's own first corner (left / lower index), so
// both squares sharing the side get the identical point.
static void BKContourEdgePoint(const BKContourGrid *g, int edge, double *px, double *py)
{
    int x0, y0, x1, y1;
    if (edge < g->hCount) { y0 = y1 = edge / (g->w - 1); x0 = edge % (g->w - 1); x1 = x0 + 1; }
    else { int e = edge - g->hCount; y0 = e / g->w; x0 = x1 = e % g->w; y1 = y0 + 1; }
    double a = BKContourValue(g, x0, y0), b = BKContourValue(g, x1, y1);
    double t = (g->level - a) / (b - a);      // a != b: one corner is inside, the other outside
    *px = x0 + t * (x1 - x0);
    *py = y0 + t * (y1 - y0);
}

int BKContourExtractU8(const unsigned char *img, int width, int height, size_t rowBytes, double level,
                       BKContourLines *out)
{
    if (out == NULL) return -1;
    memset(out, 0, sizeof(*out));
    if (img == NULL || width < 0 || height < 0 || rowBytes < (size_t)width) return -1;
    if (width < 2 || height < 2) return 0;   // no square at all: no outline

    BKContourGrid g = { img, width, height, rowBytes, level, (width - 1) * height };
    size_t edges = (size_t)g.hCount + (size_t)width * (size_t)(height - 1);
    int *next = (int *)malloc(edges * sizeof(int));
    unsigned char *flags = (unsigned char *)calloc(edges, 1);      // bit 1: a piece arrives, bit 2: visited
    size_t startCap = 1024, nseg = 0;
    int *starts = (int *)malloc(startCap * sizeof(int));           // first side of every piece, in scan order
    if (next == NULL || flags == NULL || starts == NULL) { free(next); free(flags); free(starts); return -1; }
    for (size_t i = 0; i < edges; i++) next[i] = -1;

    // 1. Every square: its corners v0 (x,y), v1 (x+1,y), v2 (x+1,y+1), v3 (x,y+1), walked round in that order. Side k
    // joins corner k and corner k+1. Going round, a side from an inside to an outside corner is an EXIT, the other
    // way an ENTRY. Each piece runs from an exit to an entry, which keeps the inside on the same side of every
    // piece - so pieces chain up head to tail across neighbouring squares.
    for (int y = 0; y + 1 < height; y++)
        for (int x = 0; x + 1 < width; x++)
        {
            double v[4] = { BKContourValue(&g, x, y), BKContourValue(&g, x + 1, y),
                            BKContourValue(&g, x + 1, y + 1), BKContourValue(&g, x, y + 1) };
            int in[4], mask = 0;
            for (int k = 0; k < 4; k++) { in[k] = v[k] >= level; mask |= in[k] << k; }
            if (mask == 0 || mask == 15) continue;
            int side[4] = { y * (width - 1) + x,                      // v0 - v1 (horizontal, row y)
                            g.hCount + y * width + (x + 1),           // v1 - v2 (vertical, column x+1)
                            (y + 1) * (width - 1) + x,                // v2 - v3 (horizontal, row y+1)
                            g.hCount + y * width + x };               // v3 - v0 (vertical, column x)
            // Saddle (two opposite inside corners): the two inside corners stay apart (each gets its own piece),
            // whatever the values - the old VTK marching squares did the same (checked on recorded VTK output).
            int saddle = (mask == 5 || mask == 10);
            int joined = 0;
            for (int k = 0; k < 4; k++)
            {
                if (!(in[k] && !in[(k + 1) & 3])) continue;          // not an exit
                int partner;
                if (saddle) partner = joined ? ((k + 1) & 3) : ((k + 3) & 3);
                else { partner = -1; for (int j = 1; j < 4; j++) { int s = (k + j) & 3; if (!in[s] && in[(s + 1) & 3]) { partner = s; break; } } }
                int a = side[k], b = side[partner];
                next[a] = b;
                flags[b] |= 1;
                if (nseg == startCap)
                {
                    int *grown = (int *)realloc(starts, startCap * 2 * sizeof(int));
                    if (grown == NULL) { free(next); free(flags); free(starts); return -1; }
                    starts = grown; startCap *= 2;
                }
                starts[nseg++] = a;
            }
        }

    // 2. Follow the pieces into lines: first the open ones (starting at a side nothing arrives at - the picture
    // border), then the closed loops. Repeated points are dropped as they are added.
    size_t pointCap = 2 * nseg + 2, lineCap = nseg + 1;
    out->xy = (double *)malloc(pointCap * 2 * sizeof(double));
    out->lineStart = (int *)malloc((lineCap + 1) * sizeof(int));
    out->lineClosed = (int *)malloc(lineCap * sizeof(int));
    if (out->xy == NULL || out->lineStart == NULL || out->lineClosed == NULL)
    { BKContourLinesFree(out); free(next); free(flags); free(starts); return -1; }
    out->lineStart[0] = 0;
    for (int pass = 0; pass < 2; pass++)
        for (size_t i = 0; i < nseg; i++)
        {
            int s = starts[i];
            if (flags[s] & 2) continue;
            if (pass == 0 && (flags[s] & 1)) continue;   // open lines only start where nothing arrives
            int first = out->pointCount;
            int e = s;
            for (;;)
            {
                double px, py;
                BKContourEdgePoint(&g, e, &px, &py);
                int n = out->pointCount;
                if (n == first || out->xy[2 * (n - 1)] != px || out->xy[2 * (n - 1) + 1] != py)
                { out->xy[2 * n] = px; out->xy[2 * n + 1] = py; out->pointCount++; }
                flags[e] |= 2;
                e = next[e];
                if (e < 0 || e == s) break;
            }
            int closed = (pass == 1);
            int n = out->pointCount - first;
            if (closed && n > 1 && out->xy[2 * first] == out->xy[2 * (out->pointCount - 1)]
                && out->xy[2 * first + 1] == out->xy[2 * (out->pointCount - 1) + 1]) { out->pointCount--; n--; }
            if (n < (closed ? 3 : 2)) { out->pointCount = first; continue; }   // degenerate (a single point)
            // Direction: the pieces were followed with the inside on one side; the lines are handed out the other
            // way round (a loop keeps its first point), which is the point order the old VTK-based code produced
            // (checked on recorded VTK output, see BKContourCoreTests) - so converted ROIs keep the same points.
            for (int a = first + (closed ? 1 : 0), b = out->pointCount - 1; a < b; a++, b--)
            {
                double tx = out->xy[2 * a], ty = out->xy[2 * a + 1];
                out->xy[2 * a] = out->xy[2 * b]; out->xy[2 * a + 1] = out->xy[2 * b + 1];
                out->xy[2 * b] = tx; out->xy[2 * b + 1] = ty;
            }
            out->lineClosed[out->lineCount] = closed;
            out->lineCount++;
            out->lineStart[out->lineCount] = out->pointCount;
        }
    free(next); free(flags); free(starts);
    return 0;
}
