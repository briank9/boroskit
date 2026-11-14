// BorosKitMesh: BKMeshProcessingCore (internal C++ header; the public API is BKMeshProcessing.h)
// Original BorosKit code written for this project from the published mathematics
// (Taubin's lambda/mu smoothing, 1995; Garland & Heckbert's quadric error metric, 1997).
// No code was copied or translated from VTK or any other library; no third-party code.
//
// What it is: the actual mesh post-processing algorithms, in plain portable C++:
//   - SmoothLambdaMu: non-shrinking ("Taubin") smoothing of a surface;
//   - Decimate: reduces the number of triangles while keeping the shape (quadric error);
//   - AreaWeightedNormals: per-vertex "outward" directions for lighting.
// The Objective-C methods on BKMesh (BKMeshProcessing.h) are thin wrappers around these.
//
// PORTING NOTES (Windows / Linux / a future Vulkan or GPU version)
//   - This header and BKMeshProcessingCore.cpp use only standard C++17: no Foundation,
//     no Objective-C, no Apple simd types, no N3* geometry. Data in and out is plain
//     std::vector<float> positions packed x,y,z,x,y,z... (millimetres) and
//     std::vector<uint32_t> triangle corner numbers (3 per triangle, anticlockwise seen
//     from outside).
//   - All multithreading goes through BKParallelFor in BKParallel.h. On Apple it uses
//     Grand Central Dispatch, elsewhere std::thread (compile-time switch inside that
//     file). Nothing else here knows about threads.
//   - Results are DETERMINISTIC: identical bits whatever the number of threads. The
//     parallel steps only compute per-vertex / per-edge values that do not depend on
//     each other, and every decision that changes the mesh (which edge collapses, in
//     which order) is made in one fixed, sorted order on a single thread. A port or a
//     GPU version can therefore be checked against the same "golden" numbers (see the
//     1-thread vs all-threads test in BKMeshProcessingTests.m).
//   - Progress/cancel is a plain C function pointer + context, called on the calling
//     thread between iterations/passes.

#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace boroskit {
namespace meshcore {

// Called now and then with a fraction 0..1 of the work done. Return false to cancel.
typedef bool (*ProgressFunction)(double fraction, void *context);

// --- Threads ---------------------------------------------------------------------------
// The most threads the algorithms may use: 0 = all cores (default), 1 = single thread.
// Results are identical either way; this exists for tests and debugging.
void SetMaxThreads(unsigned maxThreads);
unsigned MaxThreads();

// --- Smoothing -------------------------------------------------------------------------
// What Taubin smoothing is, in plain words: plain ("Laplacian") smoothing moves every
// vertex part of the way towards the average of its neighbours. That removes noise but
// also pulls every curved surface inwards, so a smoothed bone becomes slightly smaller
// (tenths of a mm after 20 rounds): bad for surgical measurements. Taubin's method does
// each round in two steps: first the usual shrinking step (factor lambda > 0), then an
// "inflating" step of the same kind with a negative factor mu, slightly larger than
// lambda. Small bumps (noise) are flattened by both steps together, while the overall
// shape (large, smooth curvature) is shrunk by the first step and restored by the
// second. The pass band says where "noise" begins: lower = smoother.

// Turns a pass band (useful range 0.01...0.2; default 0.1) into the lambda/mu factors.
// lambda is fixed at 0.5 and mu chosen so 1/lambda + 1/mu = passBand (Taubin's rule).
// Values outside 0.01...0.2 are clamped (above 0.2 the method starts to amplify gentle
// waves instead of keeping them).
void TaubinFactorsForPassBand(float passBand, float &lambda, float &mu);

struct SmoothStats {
    size_t fixedVertexCount = 0;   // vertices kept in place (open borders / non-manifold)
    unsigned iterationsDone = 0;
    bool cancelled = false;
};

// Smooths `xyz` IN PLACE. One iteration = one lambda step followed by one mu step.
// mu = 0 gives plain Laplacian smoothing (only used to show the difference in tests).
// Vertices on an open border (edge used by only one triangle) or on a non-manifold edge
// do not move, so the border where a surface meets the edge of the scan stays exactly
// where it was. Triangles are not changed. If cancelled, xyz is left unchanged.
SmoothStats SmoothLambdaMu(std::vector<float> &xyz, const std::vector<uint32_t> &indices,
                           unsigned iterations, float lambda, float mu,
                           ProgressFunction progress, void *context);

// --- Decimation ------------------------------------------------------------------------
struct DecimateStats {
    size_t inputTriangleCount = 0;
    size_t outputTriangleCount = 0;
    size_t passes = 0;
    size_t fixedVertexCount = 0;   // vertices never removed or moved (borders, non-manifold)
    double achievedReduction = 0;  // 1 - output/input triangles
    bool reachedTarget = false;    // false if no further safe collapse was possible
    bool cancelled = false;
};

// Reduces the triangle count by `targetReduction` (0..1; 0.5 = remove half), keeping the
// shape as closely as possible. Replaces `xyz` and `indices` with the result (unchanged
// if cancelled). If `sourceVertex` is not null it receives, for every output vertex, the
// number of the input vertex it continues (to carry colours over).
// Guarantees: the result is manifold and consistently oriented if the input was; no
// triangle turns over; open borders keep exactly their vertices and positions.
DecimateStats Decimate(std::vector<float> &xyz, std::vector<uint32_t> &indices, double targetReduction,
                       std::vector<uint32_t> *sourceVertex, ProgressFunction progress, void *context);

// --- Normals ---------------------------------------------------------------------------
// Area-weighted vertex normals (packed x,y,z, unit length; 0,0,0 for unused vertices).
// Same definition as -[BKMesh computeSmoothNormals], but multithreaded.
void AreaWeightedNormals(const std::vector<float> &xyz, const std::vector<uint32_t> &indices,
                         std::vector<float> &normals);

} // namespace meshcore
} // namespace boroskit
