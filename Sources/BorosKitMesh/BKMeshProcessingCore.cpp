// BorosKitMesh: BKMeshProcessingCore implementation (see BKMeshProcessingCore.h).
// Original BorosKit code written for this project from the published mathematics;
// no third-party code. Plain portable C++17 (no Objective-C, no Apple types).

/* BOROS OVERVIEW (plain language)
 * Two optional clean-up steps for bone surfaces made from a CBCT scan:
 *
 * 1. SMOOTHING (Taubin "lambda/mu"): every vertex is moved towards the average of its
 *    neighbours (removes the staircase/noise look), then moved back out by a slightly
 *    larger negative amount. Noise disappears but the bone keeps its size, unlike plain
 *    smoothing, which makes it shrink. Vertices on the open border of the surface stay put.
 *
 * 2. DECIMATION (quadric error edge collapse, Garland-Heckbert): repeatedly merge the two
 *    ends of a short edge into one point, removing the two triangles that shared the edge.
 *    Each vertex remembers the planes of the original triangles around it (packed into a
 *    small 4x4 "quadric"), so we can always compute how far a merged point would be from
 *    the ORIGINAL surface and choose the merges that change the shape least. Merges that
 *    would turn a triangle over, tear the surface, or move the open border are refused.
 *
 *    Speed (13 million triangles): instead of one global "cheapest first" queue that is
 *    updated after every merge (slow), we work in rounds ("passes"): compute the cost of
 *    every edge in parallel, sort them once, then walk the list cheapest-first and merge
 *    every edge whose two ends were not already merged in this round (every check reads
 *    the current corners and positions, so every decision is correct). A few rounds
 *    (2-5) reach the requested number of triangles exactly.
 *    The walk is split into fixed blocks of triangles that cannot affect each other and
 *    run on all cores, followed by one single-threaded walk for the edges between
 *    blocks. Blocks and order depend only on the mesh, never on the number of threads,
 *    so the result is always identical (tested with 1 thread vs all threads).
 */

#include "BKMeshProcessingCore.h"
#include "BKParallel.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace boroskit {
namespace meshcore {

#pragma mark - Threads

void SetMaxThreads(unsigned maxThreads) { BKParallelMaxThreadsStorage().store(maxThreads); }
unsigned MaxThreads() { return BKParallelMaxThreadsStorage().load(); }

namespace {

#pragma mark - Small vector maths (double precision)

// A 3D point or direction in double precision. Why double: decimation compares tiny
// distances (hundredths of a mm) on shapes ~100 mm wide; float would lose them.
struct Vec3 {
    double x, y, z;
};
inline Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 operator*(Vec3 a, double s) { return {a.x * s, a.y * s, a.z * s}; }
inline double Dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 Cross(Vec3 a, Vec3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline double Length(Vec3 a) { return std::sqrt(Dot(a, a)); }

// Reads vertex `i` from a packed x,y,z float array.
inline Vec3 Load(const float *xyz, uint32_t i) { return {xyz[3 * (size_t)i], xyz[3 * (size_t)i + 1], xyz[3 * (size_t)i + 2]}; }
inline void Store(float *xyz, uint32_t i, Vec3 v)
{
    xyz[3 * (size_t)i] = (float)v.x; xyz[3 * (size_t)i + 1] = (float)v.y; xyz[3 * (size_t)i + 2] = (float)v.z;
}

// YES if the triangle uses three different, existing vertices.
inline bool ValidTriangle(const uint32_t *t, size_t vertexCount)
{
    return t[0] < vertexCount && t[1] < vertexCount && t[2] < vertexCount &&
           t[0] != t[1] && t[1] != t[2] && t[0] != t[2];
}

#pragma mark - Vertex -> triangles table

// What: for every vertex, the list of triangles that use it (a "compressed" table: one
// long list plus where each vertex's part starts). Triangles are listed in increasing
// order, so everything built on it is deterministic.
// Why: smoothing, decimation and normals all need "what is around this vertex".
struct VertexTriangles {
    std::vector<uint32_t> start;   // vertexCount + 1 entries
    std::vector<uint32_t> list;    // triangle numbers
    inline uint32_t count(uint32_t v) const { return start[v + 1] - start[v]; }
    inline const uint32_t *begin(uint32_t v) const { return list.data() + start[v]; }
};

// Builds the table (triangles that are invalid are left out).
void BuildVertexTriangles(const uint32_t *tri, size_t triangleCount, size_t vertexCount, VertexTriangles &out)
{
    out.start.assign(vertexCount + 1, 0);
    for (size_t t = 0; t < triangleCount; t++) {
        const uint32_t *c = tri + 3 * t;
        if (!ValidTriangle(c, vertexCount)) continue;
        out.start[c[0] + 1]++; out.start[c[1] + 1]++; out.start[c[2] + 1]++;
    }
    for (size_t v = 0; v < vertexCount; v++) out.start[v + 1] += out.start[v];
    out.list.resize(out.start[vertexCount]);
    std::vector<uint32_t> cursor(out.start.begin(), out.start.end() - 1);
    for (size_t t = 0; t < triangleCount; t++) {
        const uint32_t *c = tri + 3 * t;
        if (!ValidTriangle(c, vertexCount)) continue;
        for (int k = 0; k < 3; k++) out.list[cursor[c[k]]++] = (uint32_t)t;
    }
}

// Grain sizes for BKParallelFor (smallest chunk worth a thread).
const size_t kVertexGrain = 4096;
const size_t kEdgeGrain = 8192;

} // namespace

#pragma mark - Smoothing

void TaubinFactorsForPassBand(float passBand, float &lambda, float &mu)
{
    // Taubin's rule: the filter keeps shapes whose "frequency" k is below the pass band
    // kPB = 1/lambda + 1/mu. With lambda = 0.5 the highest frequency (zig-zag noise,
    // k = 2 for neighbour averaging) is removed completely in each round.
    if (!(passBand >= 0.01f)) passBand = 0.01f;   // also catches NaN
    if (passBand > 0.2f) passBand = 0.2f;
    lambda = 0.5f;
    mu = 1.0f / (passBand - 1.0f / lambda);       // negative, slightly larger than lambda
}

SmoothStats SmoothLambdaMu(std::vector<float> &xyz, const std::vector<uint32_t> &indices,
                           unsigned iterations, float lambda, float mu,
                           ProgressFunction progress, void *context)
{
    SmoothStats stats;
    const size_t vertexCount = xyz.size() / 3;
    const size_t triangleCount = indices.size() / 3;
    if (vertexCount == 0 || triangleCount == 0 || iterations == 0) return stats;

    // 1. Neighbour lists. Every triangle (a,b,c) tells a "b and c are your neighbours",
    // and so on. A neighbour reached through an edge used by exactly two triangles is
    // listed twice; listed once = open border, three or more times = non-manifold.
    // Those vertices are "fixed": they keep their position (see header).
    std::vector<uint32_t> start(vertexCount + 1, 0);
    for (size_t t = 0; t < triangleCount; t++) {
        const uint32_t *c = &indices[3 * t];
        if (!ValidTriangle(c, vertexCount)) continue;
        start[c[0] + 1] += 2; start[c[1] + 1] += 2; start[c[2] + 1] += 2;
    }
    for (size_t v = 0; v < vertexCount; v++) start[v + 1] += start[v];
    std::vector<uint32_t> neighbours(start[vertexCount]);
    {
        std::vector<uint32_t> cursor(start.begin(), start.end() - 1);
        for (size_t t = 0; t < triangleCount; t++) {
            const uint32_t *c = &indices[3 * t];
            if (!ValidTriangle(c, vertexCount)) continue;
            for (int k = 0; k < 3; k++) {
                uint32_t v = c[k];
                neighbours[cursor[v]++] = c[(k + 1) % 3];
                neighbours[cursor[v]++] = c[(k + 2) % 3];
            }
        }
    }
    // Sort each vertex's list, count how often each neighbour appears, keep each once.
    std::vector<uint32_t> neighbourCount(vertexCount, 0);
    std::vector<uint8_t> fixed(vertexCount, 0);
    BKParallelFor(vertexCount, kVertexGrain, [&](size_t begin, size_t end) {
        for (size_t v = begin; v < end; v++) {
            uint32_t *first = neighbours.data() + start[v], *last = neighbours.data() + start[v + 1];
            std::sort(first, last);
            uint32_t unique = 0;
            for (uint32_t *p = first; p < last;) {
                uint32_t *q = p;
                while (q < last && *q == *p) q++;
                if (q - p != 2) fixed[v] = 1;
                first[unique++] = *p;
                p = q;
            }
            neighbourCount[v] = unique;
        }
    });
    for (size_t v = 0; v < vertexCount; v++) stats.fixedVertexCount += fixed[v];

    // 2. The rounds. Each step reads the old positions and writes new ones into a second
    // buffer ("Jacobi" style), so all vertices can be updated in parallel and the result
    // does not depend on the order or the number of threads.
    std::vector<float> a(xyz), b(xyz.size());
    auto step = [&](const std::vector<float> &in, std::vector<float> &out, double factor) {
        BKParallelFor(vertexCount, kVertexGrain, [&](size_t begin, size_t end) {
            for (size_t v = begin; v < end; v++) {
                Vec3 p = Load(in.data(), (uint32_t)v);
                uint32_t n = neighbourCount[v];
                if (fixed[v] || n == 0) { Store(out.data(), (uint32_t)v, p); continue; }
                // Average of the neighbours ("umbrella"), then move part of the way there
                // (factor > 0) or away from it (factor < 0).
                Vec3 sum = {0, 0, 0};
                const uint32_t *list = neighbours.data() + start[v];
                for (uint32_t i = 0; i < n; i++) sum = sum + Load(in.data(), list[i]);
                Vec3 average = sum * (1.0 / n);
                Store(out.data(), (uint32_t)v, p + (average - p) * factor);
            }
        });
    };
    for (unsigned it = 0; it < iterations; it++) {
        step(a, b, lambda);
        if (mu != 0.0f) step(b, a, mu);
        else a.swap(b);
        stats.iterationsDone = it + 1;
        if (progress && !progress((double)(it + 1) / iterations, context)) {
            stats.cancelled = true;
            return stats;   // xyz untouched
        }
    }
    xyz.swap(a);
    return stats;
}

#pragma mark - Normals

void AreaWeightedNormals(const std::vector<float> &xyz, const std::vector<uint32_t> &indices, std::vector<float> &normals)
{
    const size_t vertexCount = xyz.size() / 3;
    normals.assign(xyz.size(), 0.0f);
    VertexTriangles vt;
    BuildVertexTriangles(indices.data(), indices.size() / 3, vertexCount, vt);
    // Each vertex adds up the "area vectors" of its triangles (direction = the triangle's
    // outward side, length = twice its area, so big triangles count more). Gathering per
    // vertex (instead of each triangle adding to its corners) lets threads work without
    // ever writing to the same vertex, and always adds in the same order.
    BKParallelFor(vertexCount, kVertexGrain, [&](size_t begin, size_t end) {
        for (size_t v = begin; v < end; v++) {
            Vec3 sum = {0, 0, 0};
            for (uint32_t i = 0; i < vt.count((uint32_t)v); i++) {
                const uint32_t *c = &indices[3 * (size_t)vt.begin((uint32_t)v)[i]];
                Vec3 p0 = Load(xyz.data(), c[0]), p1 = Load(xyz.data(), c[1]), p2 = Load(xyz.data(), c[2]);
                sum = sum + Cross(p1 - p0, p2 - p0);
            }
            double len = Length(sum);
            if (len > 0) Store(normals.data(), (uint32_t)v, sum * (1.0 / len));
        }
    });
}

#pragma mark - Decimation: quadrics

namespace {

// What: a "quadric", the sum of squared distances to a set of planes, stored as the
// symmetric 3x3 matrix A, the vector b and the number c of the formula
//     error(p) = p.A.p + 2 b.p + c.
// For one plane n.p + d = 0 (n unit length): A = n n^T, b = d n, c = d^2, so error(p) is
// exactly the squared distance from p to the plane. Adding quadrics adds the errors, so a
// vertex can carry "distance to all original triangles around me" in 10 numbers.
struct Quadric {
    double a00, a01, a02, a11, a12, a22, b0, b1, b2, c;
};

inline void AddPlane(Quadric &q, Vec3 n, double d, double weight)
{
    q.a00 += weight * n.x * n.x; q.a01 += weight * n.x * n.y; q.a02 += weight * n.x * n.z;
    q.a11 += weight * n.y * n.y; q.a12 += weight * n.y * n.z; q.a22 += weight * n.z * n.z;
    q.b0 += weight * d * n.x;    q.b1 += weight * d * n.y;    q.b2 += weight * d * n.z;
    q.c += weight * d * d;
}

inline Quadric Sum(const Quadric &p, const Quadric &q)
{
    return {p.a00 + q.a00, p.a01 + q.a01, p.a02 + q.a02, p.a11 + q.a11, p.a12 + q.a12,
            p.a22 + q.a22, p.b0 + q.b0, p.b1 + q.b1, p.b2 + q.b2, p.c + q.c};
}

// A times v.
inline Vec3 MulA(const Quadric &q, Vec3 v)
{
    return {q.a00 * v.x + q.a01 * v.y + q.a02 * v.z,
            q.a01 * v.x + q.a11 * v.y + q.a12 * v.z,
            q.a02 * v.x + q.a12 * v.y + q.a22 * v.z};
}

// The error at point p (clamped at 0: rounding can make it a hair negative).
inline double Evaluate(const Quadric &q, Vec3 p)
{
    double e = Dot(p, MulA(q, p)) + 2.0 * (q.b0 * p.x + q.b1 * p.y + q.b2 * p.z) + q.c;
    return e > 0 ? e : 0;
}

// What: the best place for the merged point of edge (pa, pb).
// How: the error is a bowl-shaped (quadratic) function, so its lowest point solves
// A p = -b. When the planes around the edge are nearly parallel (a flat or gently curved
// area) that answer is unreliable and can lie far away; then we use the best point ON
// the edge instead (also a quadratic, in one variable t, solved exactly).
Vec3 BestPosition(const Quadric &q, Vec3 pa, Vec3 pb)
{
    // Inverse of A by cofactors (A is symmetric).
    double c00 = q.a11 * q.a22 - q.a12 * q.a12;
    double c01 = q.a02 * q.a12 - q.a01 * q.a22;
    double c02 = q.a01 * q.a12 - q.a02 * q.a11;
    double det = q.a00 * c00 + q.a01 * c01 + q.a02 * c02;
    double trace = q.a00 + q.a11 + q.a22;
    Vec3 d = pb - pa;
    double edgeLength2 = Dot(d, d);
    if (trace > 0 && std::fabs(det) > 1e-9 * trace * trace * trace) {
        double c11 = q.a00 * q.a22 - q.a02 * q.a02;
        double c12 = q.a01 * q.a02 - q.a00 * q.a12;
        double c22 = q.a00 * q.a11 - q.a01 * q.a01;
        Vec3 rhs = {-q.b0, -q.b1, -q.b2};
        Vec3 p = {(c00 * rhs.x + c01 * rhs.y + c02 * rhs.z) / det,
                  (c01 * rhs.x + c11 * rhs.y + c12 * rhs.z) / det,
                  (c02 * rhs.x + c12 * rhs.y + c22 * rhs.z) / det};
        // Accept it only if it stays near the edge (within one edge length of its middle).
        Vec3 offset = p - (pa + pb) * 0.5;
        if (std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z) && Dot(offset, offset) <= edgeLength2) return p;
    }
    // Along the edge: p(t) = pa + t d, error(t) = t^2 (d.A.d) + 2 t d.(A pa + b) + const.
    double dAd = Dot(d, MulA(q, d));
    Vec3 g = MulA(q, pa) + Vec3{q.b0, q.b1, q.b2};
    double t;
    if (dAd > 1e-300) t = std::min(1.0, std::max(0.0, -Dot(d, g) / dAd));
    else t = Evaluate(q, pa) <= Evaluate(q, pb) ? 0.0 : 1.0;
    return pa + d * t;
}

#pragma mark - Decimation: vertex kinds

// What kind of place a vertex is in. Only "interior" vertices can be removed or moved.
enum VertexKind : uint8_t {
    kInterior = 0,    // triangles all around it form one closed fan: normal surface
    kBorder = 1,      // one open fan: lies on the open border of the surface (kept in place)
    kComplex = 2,     // non-manifold, inconsistent orientation, or unused: never touched
};

// What: works out the kind of vertex v by walking around it from triangle to triangle.
// Each triangle around v has a corner "after v" and "before v" (anticlockwise). In a
// clean surface, the corner after v in one triangle is the corner before v in exactly
// one other triangle; following that chain goes once around v (closed fan) or from one
// border edge to the other (open fan). Anything else is "complex".
VertexKind ClassifyVertex(uint32_t v, const VertexTriangles &vt, const uint32_t *tri)
{
    uint32_t n = vt.count(v);
    if (n == 0 || n > 512) return kComplex;   // unused, or an absurd fan we will not touch
    const uint32_t *list = vt.begin(v);
    // after[i] / before[i]: the corners following / preceding v in triangle i.
    uint32_t afterSmall[64], beforeSmall[64];
    std::vector<uint32_t> afterBig, beforeBig;
    uint32_t *after = afterSmall, *before = beforeSmall;
    if (n > 64) { afterBig.resize(n); beforeBig.resize(n); after = afterBig.data(); before = beforeBig.data(); }
    for (uint32_t i = 0; i < n; i++) {
        const uint32_t *c = tri + 3 * (size_t)list[i];
        int k = c[0] == v ? 0 : (c[1] == v ? 1 : 2);
        after[i] = c[(k + 1) % 3];
        before[i] = c[(k + 2) % 3];
    }
    // next[i]: the triangle that continues the fan after triangle i (or none).
    const uint32_t none = UINT32_MAX;
    uint32_t nextSmall[64];
    std::vector<uint32_t> nextBig;
    uint32_t *next = nextSmall;
    if (n > 64) { nextBig.resize(n); next = nextBig.data(); }
    uint32_t starts = 0, startIndex = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t successors = 0, predecessors = 0;
        next[i] = none;
        for (uint32_t j = 0; j < n; j++) {
            if (j == i) continue;
            if (before[j] == after[i]) { successors++; next[i] = j; }
            if (after[j] == before[i]) predecessors++;
            // The same neighbour on the same side twice = edge used 3+ times or flipped.
            if (after[j] == after[i] || before[j] == before[i]) return kComplex;
        }
        if (successors > 1 || predecessors > 1) return kComplex;
        if (predecessors == 0) { starts++; startIndex = i; }
    }
    if (starts > 1) return kComplex;   // several separate fans meet here (a "bow tie")
    uint32_t i = starts ? startIndex : 0, steps = 0;
    do {
        steps++;
        i = next[i];
    } while (i != none && i != (starts ? none : 0) && steps <= n);
    if (steps != n) return kComplex;    // the walk did not visit every triangle
    if (starts == 0) return i == 0 ? kInterior : kComplex;
    return i == none ? kBorder : kComplex;
}

#pragma mark - Decimation: sorting

// What: sorts 64-bit keys by their upper 32 bits (the cost), keeping the original order
// for equal costs ("stable"), so the result is always the same.
// How: radix sort in two rounds of 16 bits: much faster than comparison sorting for the
// tens of millions of edges of a big scan.
void SortByUpper32(std::vector<uint64_t> &keys, std::vector<uint64_t> &scratch)
{
    scratch.resize(keys.size());
    std::vector<size_t> count(65536);
    for (int shift = 32; shift <= 48; shift += 16) {
        std::fill(count.begin(), count.end(), 0);
        for (uint64_t k : keys) count[(k >> shift) & 0xFFFF]++;
        size_t sum = 0;
        for (auto &c : count) { size_t n = c; c = sum; sum += n; }
        for (uint64_t k : keys) scratch[count[(k >> shift) & 0xFFFF]++] = k;
        keys.swap(scratch);
    }
}

// What: turns a non-negative cost into 32 bits that sort in the same order.
// Why: for positive floats the raw bit pattern increases with the value.
inline uint32_t CostBits(double cost)
{
    float f = (float)cost;
    if (!(f >= 0)) f = std::numeric_limits<float>::infinity();   // NaN: last
    uint32_t bits;
    std::memcpy(&bits, &f, 4);
    return bits;
}

const uint32_t kDeadTriangle = UINT32_MAX;

} // namespace

#pragma mark - Decimation

DecimateStats Decimate(std::vector<float> &xyz, std::vector<uint32_t> &indices, double targetReduction,
                       std::vector<uint32_t> *sourceVertex, ProgressFunction progress, void *context)
{
    DecimateStats stats;
    const size_t vertexCount = xyz.size() / 3;
    stats.inputTriangleCount = indices.size() / 3;
    stats.outputTriangleCount = stats.inputTriangleCount;
    if (!(targetReduction > 0)) targetReduction = 0;
    if (targetReduction > 1) targetReduction = 1;

    // --- Set-up ---------------------------------------------------------------------
    // Keep only proper triangles (three different, existing corners).
    std::vector<uint32_t> tri;
    tri.reserve(indices.size());
    for (size_t t = 0; t + 2 < indices.size(); t += 3)
        if (ValidTriangle(&indices[t], vertexCount)) tri.insert(tri.end(), &indices[t], &indices[t] + 3);
    size_t triangleCount = tri.size() / 3;
    // How many triangles to end with. Never fewer than 4 (a tetrahedron, the smallest
    // closed shape).
    size_t target = (size_t)std::llround((double)stats.inputTriangleCount * (1.0 - targetReduction));
    target = std::max(target, (size_t)4);

    // Work relative to the middle of the shape: numbers near 0 keep more precision.
    float lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
    if (vertexCount) for (int k = 0; k < 3; k++) { lo[k] = hi[k] = xyz[k]; }
    for (size_t i = 0; i < vertexCount; i++)
        for (int k = 0; k < 3; k++) { lo[k] = std::min(lo[k], xyz[3 * i + k]); hi[k] = std::max(hi[k], xyz[3 * i + k]); }
    const Vec3 centre = {0.5 * ((double)lo[0] + hi[0]), 0.5 * ((double)lo[1] + hi[1]), 0.5 * ((double)lo[2] + hi[2])};
    std::vector<double> pos(3 * vertexCount);
    for (size_t i = 0; i < vertexCount; i++) {
        pos[3 * i] = xyz[3 * i] - centre.x; pos[3 * i + 1] = xyz[3 * i + 1] - centre.y; pos[3 * i + 2] = xyz[3 * i + 2] - centre.z;
    }
    auto P = [&](uint32_t v) -> Vec3 { return {pos[3 * (size_t)v], pos[3 * (size_t)v + 1], pos[3 * (size_t)v + 2]}; };

    VertexTriangles vt;
    BuildVertexTriangles(tri.data(), triangleCount, vertexCount, vt);

    // Kind of every vertex, decided once on the input. It never changes later: merges
    // keep the surface clean, and border/complex vertices are never merged away.
    std::vector<uint8_t> kind(vertexCount);
    BKParallelFor(vertexCount, kVertexGrain, [&](size_t begin, size_t end) {
        for (size_t v = begin; v < end; v++) kind[v] = ClassifyVertex((uint32_t)v, vt, tri.data());
    });
    for (uint8_t k : kind) stats.fixedVertexCount += (k != kInterior);

    // Each vertex starts with the planes of its own triangles, weighted by area so many
    // tiny triangles do not outvote a large one.
    std::vector<Quadric> quadric(vertexCount);
    BKParallelFor(vertexCount, kVertexGrain, [&](size_t begin, size_t end) {
        for (size_t v = begin; v < end; v++) {
            Quadric q = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
            for (uint32_t i = 0; i < vt.count((uint32_t)v); i++) {
                const uint32_t *c = &tri[3 * (size_t)vt.begin((uint32_t)v)[i]];
                Vec3 p0 = P(c[0]);
                Vec3 n = Cross(P(c[1]) - p0, P(c[2]) - p0);
                double twiceArea = Length(n);
                if (twiceArea <= 0) continue;
                n = n * (1.0 / twiceArea);
                AddPlane(q, n, -Dot(n, p0), 0.5 * twiceArea);
            }
            quadric[v] = q;
        }
    });

    // --- Rounds of merges -------------------------------------------------------------
    std::vector<uint32_t> lockedInPass(vertexCount, 0);   // = pass number when merged
    std::vector<uint32_t> vertexBlock(vertexCount);       // see "blocks" below
    std::vector<uint64_t> keys, scratch;
    size_t current = triangleCount;
    const size_t toRemove = current > target ? current - target : 0;
    double windowFactor = 2.0;   // how many edges to look at per merge still needed

    // Scratch lists for one merge attempt (each thread has its own).
    struct Scratch {
        std::vector<uint32_t> goneTris, keepTris, goneNeighbours;
    };

    // What: tries to merge the edge stored as "triangle * 3 + corner" `he`, in round
    // `pass`. Returns true if it merged (then two triangles are gone).
    // Every check reads the CURRENT corners and positions, so it is exact even when
    // other merges happened nearby earlier in the same round.
    auto tryMerge = [&](uint32_t he, uint32_t pass, Scratch &s) -> bool {
        size_t t = he / 3;
        if (tri[3 * t] == kDeadTriangle) return false;
        uint32_t a = tri[he], b = tri[3 * t + (he % 3 + 1) % 3];
        // The two vertices of an edge merged in this round: the "kept" one has new
        // triangles that the table does not list yet, and its cost changed. Leave edges
        // touching them for the next round. (Every other vertex still has a correct list
        // of triangle numbers; removed triangles are skipped below.)
        if (lockedInPass[a] == pass || lockedInPass[b] == pass) return false;

        // Which end disappears (`gone`) and which stays (`keep`).
        uint32_t gone = a, keep = b;
        if (kind[a] == kBorder) { gone = b; keep = a; }
        // Their triangles that still exist.
        s.goneTris.clear();
        s.keepTris.clear();
        for (uint32_t j = 0; j < vt.count(gone); j++)
            if (tri[3 * (size_t)vt.begin(gone)[j]] != kDeadTriangle) s.goneTris.push_back(vt.begin(gone)[j]);
        for (uint32_t j = 0; j < vt.count(keep); j++)
            if (tri[3 * (size_t)vt.begin(keep)[j]] != kDeadTriangle) s.keepTris.push_back(vt.begin(keep)[j]);

        // The edge must be shared by exactly two triangles (they will disappear).
        uint32_t shared = 0;
        for (uint32_t g : s.goneTris) {
            const uint32_t *c = &tri[3 * (size_t)g];
            if (c[0] == keep || c[1] == keep || c[2] == keep) shared++;
        }
        if (shared != 2) return false;

        // Tetrahedron check: merging two corners of a closed 4-triangle piece would leave
        // two triangles lying on each other.
        if (s.goneTris.size() == 3 && s.keepTris.size() == 3) return false;

        // "Link condition": the two ends may share only the two neighbours opposite the
        // edge. Sharing another neighbour means the merge would pinch the surface (two
        // triangles glued back to back, or a tunnel closed off).
        s.goneNeighbours.clear();
        for (uint32_t g : s.goneTris) {
            const uint32_t *c = &tri[3 * (size_t)g];
            for (int k = 0; k < 3; k++)
                if (c[k] != gone && c[k] != keep &&
                    std::find(s.goneNeighbours.begin(), s.goneNeighbours.end(), c[k]) == s.goneNeighbours.end())
                    s.goneNeighbours.push_back(c[k]);
        }
        uint32_t common = 0;
        for (uint32_t w : s.goneNeighbours) {
            for (uint32_t kt : s.keepTris) {
                const uint32_t *c = &tri[3 * (size_t)kt];
                if (c[0] == w || c[1] == w || c[2] == w) { common++; break; }
            }
        }
        if (common != 2) return false;

        // Where the merged point goes.
        Quadric q = Sum(quadric[a], quadric[b]);
        Vec3 p = kind[keep] == kBorder ? P(keep) : BestPosition(q, P(a), P(b));

        // No triangle may turn over or collapse to a sliver: compare each surviving
        // triangle's direction before and after the move. Requiring cos(angle) > 0.2
        // (less than ~78 degrees of turning) also keeps the surface from folding.
        for (int side = 0; side < 2; side++) {
            uint32_t moving = side == 0 ? gone : keep;
            if (moving == keep && kind[keep] == kBorder) break;   // keep does not move
            const std::vector<uint32_t> &list = side == 0 ? s.goneTris : s.keepTris;
            for (uint32_t lt : list) {
                const uint32_t *c = &tri[3 * (size_t)lt];
                bool hasGone = c[0] == gone || c[1] == gone || c[2] == gone;
                bool hasKeep = c[0] == keep || c[1] == keep || c[2] == keep;
                if (hasGone && hasKeep) continue;   // disappears
                Vec3 before[3], after[3];
                for (int k = 0; k < 3; k++) {
                    before[k] = P(c[k]);
                    after[k] = c[k] == moving ? p : before[k];
                }
                Vec3 n0 = Cross(before[1] - before[0], before[2] - before[0]);
                Vec3 n1 = Cross(after[1] - after[0], after[2] - after[0]);
                double l0 = Length(n0), l1 = Length(n1);
                double size1 = Dot(after[1] - after[0], after[1] - after[0]) + Dot(after[2] - after[0], after[2] - after[0]);
                double size0 = Dot(before[1] - before[0], before[1] - before[0]) + Dot(before[2] - before[0], before[2] - before[0]);
                bool flatBefore = l0 <= 1e-12 * size0, flatAfter = l1 <= 1e-12 * size1;
                // A proper triangle must not be squashed flat. (A triangle that was
                // already flat - surface extractors make some - has no direction to
                // keep, so it does not block the merge.)
                if (flatAfter && !flatBefore) return false;
                if (!flatBefore && !flatAfter && Dot(n0, n1) < 0.2 * l0 * l1) return false;
            }
        }

        // --- Do the merge -----------------------------------------------------------------
        lockedInPass[gone] = lockedInPass[keep] = pass;
        // Triangles on the edge disappear; the others of `gone` now use `keep`.
        for (uint32_t g : s.goneTris) {
            uint32_t *c = &tri[3 * (size_t)g];
            if (c[0] == keep || c[1] == keep || c[2] == keep) { c[0] = kDeadTriangle; continue; }
            for (int k = 0; k < 3; k++) if (c[k] == gone) c[k] = keep;
        }
        pos[3 * (size_t)keep] = p.x; pos[3 * (size_t)keep + 1] = p.y; pos[3 * (size_t)keep + 2] = p.z;
        quadric[keep] = q;
        return true;
    };

    while (current > target) {
        stats.passes++;
        const uint32_t pass = (uint32_t)stats.passes;

        // Drop the triangles removed in the previous round and rebuild the table.
        if (stats.passes > 1) {
            size_t out = 0;
            for (size_t t = 0; t < triangleCount; t++) {
                if (tri[3 * t] == kDeadTriangle) continue;
                if (out != t) std::memcpy(&tri[3 * out], &tri[3 * t], 3 * sizeof(uint32_t));
                out++;
            }
            triangleCount = out;
            tri.resize(3 * out);
            BuildVertexTriangles(tri.data(), triangleCount, vertexCount, vt);
        }

        // Every edge once: in a consistently oriented surface each inner edge is walked
        // a->b by one triangle and b->a by the other; we take the one with a < b. An edge
        // is identified by "triangle * 3 + corner". Edges that could never be merged
        // (complex vertex, or both ends on the border) are skipped.
        keys.clear();
        for (size_t t = 0; t < triangleCount; t++) {
            for (uint32_t k = 0; k < 3; k++) {
                uint32_t a = tri[3 * t + k], b = tri[3 * t + (k + 1) % 3];
                if (a > b || kind[a] == kComplex || kind[b] == kComplex) continue;
                if (kind[a] == kBorder && kind[b] == kBorder) continue;
                keys.push_back((uint64_t)(3 * t + k));
            }
        }
        if (keys.empty()) break;

        // Cost of every edge (in parallel; each edge only reads): how far the merged
        // point would be from the original planes of both ends. A border vertex may only
        // absorb an inner neighbour and stays where it is, so the border never moves.
        BKParallelFor(keys.size(), kEdgeGrain, [&](size_t begin, size_t end) {
            for (size_t i = begin; i < end; i++) {
                uint32_t he = (uint32_t)keys[i];
                uint32_t a = tri[he], b = tri[3 * (he / 3) + (he % 3 + 1) % 3];
                Quadric q = Sum(quadric[a], quadric[b]);
                Vec3 p = kind[a] == kBorder ? P(a) : kind[b] == kBorder ? P(b) : BestPosition(q, P(a), P(b));
                keys[i] = ((uint64_t)CostBits(Evaluate(q, p)) << 32) | he;
            }
        });
        SortByUpper32(keys, scratch);

        // Walk the cheapest edges. Only look at roughly as many as merges are still
        // needed (times a factor adapted to how many succeed), so expensive edges are not
        // merged just because their cheaper neighbours were busy this round.
        size_t mergesNeeded = (current - target + 1) / 2;
        size_t window = std::min(keys.size(), (size_t)std::ceil((double)mergesNeeded * windowFactor) + 64);
        size_t merged = 0;

        // Step 1, in parallel: "blocks". The triangle list is cut into fixed blocks of
        // kBlockTriangles (fixed size, NOT based on the number of threads). A vertex whose
        // triangles all lie in one block belongs to that block. An edge between two such
        // vertices of the same block only reads and changes things inside that block
        // (its triangles, and the points and corners of those triangles), so different
        // blocks can be worked on at the same time without touching each other. Each
        // block walks its own edges in the same cheapest-first order. Because the blocks
        // and the order are fixed by the data alone, the result is the same with any
        // number of threads. Each block may do at most its share of the merges still
        // needed, so together they never overshoot the target.
        const size_t kBlockTriangles = 1u << 17;
        const uint32_t kNoBlock = UINT32_MAX;
        size_t blockCount = (triangleCount + kBlockTriangles - 1) / kBlockTriangles;
        if (blockCount > 1 && mergesNeeded > 1024) {
            BKParallelFor(vertexCount, kVertexGrain, [&](size_t begin, size_t end) {
                for (size_t v = begin; v < end; v++) {
                    uint32_t n = vt.count((uint32_t)v);
                    // The lists are in increasing triangle order: compare first and last.
                    vertexBlock[v] = n == 0 ? kNoBlock :
                        (vt.begin((uint32_t)v)[0] / kBlockTriangles == vt.begin((uint32_t)v)[n - 1] / kBlockTriangles ?
                         (uint32_t)(vt.begin((uint32_t)v)[0] / kBlockTriangles) : kNoBlock);
                }
            });
            // Positions (in the sorted list) of each block's edges, cheapest first.
            std::vector<uint32_t> blockStart(blockCount + 1, 0);
            std::vector<uint32_t> edgeBlock(window);
            for (size_t i = 0; i < window; i++) {
                uint32_t he = (uint32_t)keys[i];
                uint32_t a = tri[he], b = tri[3 * (he / 3) + (he % 3 + 1) % 3];
                edgeBlock[i] = vertexBlock[a] == vertexBlock[b] ? vertexBlock[a] : kNoBlock;
                if (edgeBlock[i] != kNoBlock) blockStart[edgeBlock[i] + 1]++;
            }
            for (size_t k = 0; k < blockCount; k++) blockStart[k + 1] += blockStart[k];
            size_t inBlocks = blockStart[blockCount];
            std::vector<uint32_t> blockEdges(inBlocks);
            {
                std::vector<uint32_t> cursor(blockStart.begin(), blockStart.end() - 1);
                for (size_t i = 0; i < window; i++)
                    if (edgeBlock[i] != kNoBlock) blockEdges[cursor[edgeBlock[i]]++] = (uint32_t)i;
            }
            std::vector<size_t> blockMerged(blockCount, 0);
            if (inBlocks > 0) {
                BKParallelFor(blockCount, 1, [&](size_t begin, size_t end) {
                    Scratch s;
                    for (size_t k = begin; k < end; k++) {
                        size_t count = blockStart[k + 1] - blockStart[k];
                        // This block's share of the merges still needed.
                        size_t quota = (size_t)((double)mergesNeeded * (double)count / (double)window);
                        for (size_t j = 0; j < count && blockMerged[k] < quota; j++) {
                            size_t i = blockEdges[blockStart[k] + j];
                            if (tryMerge((uint32_t)keys[i], pass, s)) blockMerged[k]++;
                        }
                    }
                });
            }
            for (size_t m : blockMerged) merged += m;
            current -= 2 * merged;
        }

        // Step 2, one thread: the whole window again in cheapest-first order. This does
        // the edges crossing between blocks and whatever the blocks left. Edges already
        // merged are skipped automatically (their triangle is gone or an end is locked).
        {
            Scratch s;
            for (size_t i = 0; i < window && current > target; i++) {
                if (tryMerge((uint32_t)keys[i], pass, s)) { current -= 2; merged++; }
            }
        }

        // Progress = share of the triangles to remove that are gone so far.
        double done = (double)(toRemove - (current > target ? current - target : 0)) / (double)toRemove;
        if (progress && toRemove > 0 && !progress(std::min(1.0, done), context)) {
            stats.cancelled = true;
            return stats;   // xyz / indices untouched
        }

        if (merged == 0) {
            // Nothing in the window could be merged: look further down the list next
            // time; if the whole list was tried, no safe merge is left.
            if (window >= keys.size()) break;
            windowFactor = std::min(windowFactor * 4, 1e6);
        } else {
            // Size the next window from this round's success rate (merges per edge
            // looked at), so a round usually does most of the remaining work. Kept
            // between 1x and 4x: looking much further would merge noticeably more
            // expensive edges just because their cheaper neighbours were busy.
            double perEdge = (double)merged / (double)window;
            windowFactor = std::min(4.0, std::max(1.0, 1.0 / perEdge));
        }
    }
    stats.reachedTarget = current <= target;

    // --- Output: keep only used vertices, in their original order ------------------------
    std::vector<uint32_t> newIndex(vertexCount, UINT32_MAX);
    std::vector<uint32_t> outIndices;
    outIndices.reserve(3 * current);
    for (size_t t = 0; t < triangleCount; t++) {
        if (tri[3 * t] == kDeadTriangle) continue;
        for (int k = 0; k < 3; k++) newIndex[tri[3 * t + k]] = 0;
    }
    std::vector<float> outXYZ;
    if (sourceVertex) sourceVertex->clear();
    for (size_t v = 0; v < vertexCount; v++) {
        if (newIndex[v] == UINT32_MAX) continue;
        newIndex[v] = (uint32_t)(outXYZ.size() / 3);
        outXYZ.push_back((float)(pos[3 * v] + centre.x));
        outXYZ.push_back((float)(pos[3 * v + 1] + centre.y));
        outXYZ.push_back((float)(pos[3 * v + 2] + centre.z));
        if (sourceVertex) sourceVertex->push_back((uint32_t)v);
    }
    for (size_t t = 0; t < triangleCount; t++) {
        if (tri[3 * t] == kDeadTriangle) continue;
        for (int k = 0; k < 3; k++) outIndices.push_back(newIndex[tri[3 * t + k]]);
    }
    xyz.swap(outXYZ);
    indices.swap(outIndices);
    stats.outputTriangleCount = indices.size() / 3;
    stats.achievedReduction = stats.inputTriangleCount ? 1.0 - (double)stats.outputTriangleCount / stats.inputTriangleCount : 0;
    return stats;
}

} // namespace meshcore
} // namespace boroskit
