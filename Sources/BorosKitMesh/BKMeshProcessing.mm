// BorosKitMesh: BKMeshProcessing implementation (see the header for what it does).
// Original BorosKit code written for this project; contains no third-party code.
//
// This file is only the bridge between BKMesh (Objective-C, Apple simd vectors) and the
// portable C++ algorithms in BKMeshProcessingCore: it copies the points into plain
// x,y,z float lists, runs the algorithm, and builds the new BKMesh. Keeping all the
// real work in the core means a Windows/Linux port reuses it unchanged.

#import "BKMeshProcessing.h"
#include "BKMeshProcessingCore.h"
#include <chrono>
#include <vector>

using namespace boroskit;

const NSUInteger BKMeshSmoothingDefaultIterations = 20;
const float BKMeshSmoothingDefaultPassBand = 0.1f;

// What: passes the core's plain-C progress call on to the Objective-C block.
static bool BKMeshProgressTrampoline(double fraction, void *context)
{
    BKMeshProgressHandler handler = (__bridge BKMeshProgressHandler)context;
    return handler(fraction) ? true : false;
}

// What: the mesh's points as a packed x,y,z float list (simd_float3 has a 4th padding
// float, the core does not want it).
static std::vector<float> BKPackedPoints(BKMesh *mesh)
{
    std::vector<float> xyz(3 * mesh.vertexCount);
    const simd_float3 *v = mesh.vertices;
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
        xyz[3 * i] = v[i].x; xyz[3 * i + 1] = v[i].y; xyz[3 * i + 2] = v[i].z;
    }
    return xyz;
}

// What: builds the result mesh from packed lists, with the core's multithreaded
// area-weighted normals and optional colours.
static BKMesh *BKMeshFromPacked(const std::vector<float> &xyz, const std::vector<uint32_t> &indices,
                                const simd_float4 *colors, NSString *name)
{
    size_t n = xyz.size() / 3;
    std::vector<float> packedNormals;
    meshcore::AreaWeightedNormals(xyz, indices, packedNormals);
    std::vector<simd_float3> vertices(n), normals(n);
    for (size_t i = 0; i < n; i++) {
        vertices[i] = simd_make_float3(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]);
        normals[i] = simd_make_float3(packedNormals[3 * i], packedNormals[3 * i + 1], packedNormals[3 * i + 2]);
    }
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:vertices.data() vertexCount:n
                                            indices:indices.data() indexCount:indices.size()
                                            normals:normals.data() colors:colors error:NULL];
    mesh.name = name;
    return mesh;
}

// Milliseconds since `start`.
static double BKMillisecondsSince(std::chrono::steady_clock::time_point start)
{
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

@implementation BKMesh (BKMeshProcessing)

+ (NSUInteger)processingMaxThreads { return meshcore::MaxThreads(); }
+ (void)setProcessingMaxThreads:(NSUInteger)maxThreads { meshcore::SetMaxThreads((unsigned)MIN(maxThreads, (NSUInteger)UINT_MAX)); }

+ (void)getTaubinLambda:(float *)lambda mu:(float *)mu forPassBand:(float)passBand
{
    float l, m;
    meshcore::TaubinFactorsForPassBand(passBand, l, m);
    if (lambda) *lambda = l;
    if (mu) *mu = m;
}

- (BKMesh *)meshBySmoothingWithIterations:(NSUInteger)iterations passBand:(float)passBand
                                 progress:(BKMeshProgressHandler)progress report:(BKMeshProcessingReport *)report
{
    float lambda, mu;
    meshcore::TaubinFactorsForPassBand(passBand, lambda, mu);
    return [self meshBySmoothingWithIterations:iterations lambda:lambda mu:mu progress:progress report:report];
}

- (BKMesh *)meshBySmoothingWithIterations:(NSUInteger)iterations lambda:(float)lambda mu:(float)mu
                                 progress:(BKMeshProgressHandler)progress report:(BKMeshProcessingReport *)report
{
    auto start = std::chrono::steady_clock::now();
    std::vector<float> xyz = BKPackedPoints(self);
    std::vector<uint32_t> indices(self.indices, self.indices + 3 * self.triangleCount);
    meshcore::SmoothStats stats = meshcore::SmoothLambdaMu(xyz, indices, (unsigned)MIN(iterations, (NSUInteger)UINT_MAX),
                                                           lambda, mu, progress ? BKMeshProgressTrampoline : nullptr,
                                                           (__bridge void *)progress);
    BKMesh *result = stats.cancelled ? nil : BKMeshFromPacked(xyz, indices, self.colors, self.name);
    if (report) {
        *report = (BKMeshProcessingReport){0};
        report->inputTriangleCount = report->outputTriangleCount = self.triangleCount;
        report->iterations = stats.iterationsDone;
        report->fixedVertexCount = stats.fixedVertexCount;
        report->cancelled = stats.cancelled;
        report->reachedTarget = !stats.cancelled;
        report->milliseconds = BKMillisecondsSince(start);
    }
    return result;
}

- (BKMesh *)meshByDecimatingWithTargetReduction:(double)targetReduction
                                       progress:(BKMeshProgressHandler)progress report:(BKMeshProcessingReport *)report
{
    auto start = std::chrono::steady_clock::now();
    std::vector<float> xyz = BKPackedPoints(self);
    std::vector<uint32_t> indices(self.indices, self.indices + 3 * self.triangleCount);
    std::vector<uint32_t> source;
    meshcore::DecimateStats stats = meshcore::Decimate(xyz, indices, targetReduction, &source,
                                                       progress ? BKMeshProgressTrampoline : nullptr,
                                                       (__bridge void *)progress);
    BKMesh *result = nil;
    if (!stats.cancelled) {
        // Colours: each remaining vertex keeps the colour of the input vertex it continues.
        std::vector<simd_float4> colors;
        if (self.colors) {
            colors.resize(source.size());
            for (size_t i = 0; i < source.size(); i++) colors[i] = self.colors[source[i]];
        }
        result = BKMeshFromPacked(xyz, indices, colors.empty() ? NULL : colors.data(), self.name);
    }
    if (report) {
        *report = (BKMeshProcessingReport){0};
        report->inputTriangleCount = stats.inputTriangleCount;
        report->outputTriangleCount = stats.outputTriangleCount;
        report->requestedReduction = targetReduction;
        report->achievedReduction = stats.achievedReduction;
        report->iterations = stats.passes;
        report->fixedVertexCount = stats.fixedVertexCount;
        report->reachedTarget = stats.reachedTarget;
        report->cancelled = stats.cancelled;
        report->milliseconds = BKMillisecondsSince(start);
    }
    return result;
}

@end
