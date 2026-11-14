// Tests for BKMeshProcessing: non-shrinking smoothing and quadric decimation.
// Original BorosKit code written for this project; contains no third-party code.
//
// What is checked, in plain terms:
//  - smoothing a noisy 20 mm ball removes the noise but keeps its volume (within 1%),
//    while plain (Laplacian) smoothing shrinks it more; the surface stays closed;
//  - decimating a ball and a ring (torus) by 50% and 90% reaches the target within 3%,
//    stays on the true surface, stays closed and clean, and no triangle turns over;
//  - a ball with its top cut off keeps its open border exactly where it was;
//  - results are bit-for-bit the same with 1 thread and with all threads;
//  - progress is reported and cancelling works; colours are carried over;
//  - timings on a 5-million-triangle surface are logged (no strict limits).

#import <XCTest/XCTest.h>
#import "BorosKitMesh.h"

@interface BKMeshProcessingTests : XCTestCase
@end

@implementation BKMeshProcessingTests

#pragma mark - Helpers

// What: a repeatable "random" number in -1...1 (same sequence every run).
static double BKTestRandom(uint64_t *state)
{
    *state = *state * 6364136223846793005ULL + 1442695040888963407ULL;
    return ((double)(*state >> 11) / (double)(1ULL << 53)) * 2.0 - 1.0;
}

// What: a copy of `mesh` with every vertex moved along the line from `center` by a random
// amount of up to +-noise mm. Why: imitates the grainy surface of a scan.
- (BKMesh *)mesh:(BKMesh *)mesh withRadialNoise:(float)noise center:(simd_float3)center
{
    NSMutableData *points = [NSMutableData dataWithBytes:mesh.vertices length:mesh.vertexCount * sizeof(simd_float3)];
    simd_float3 *v = points.mutableBytes;
    uint64_t state = 12345;
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
        simd_float3 d = simd_normalize(v[i] - center);
        v[i] += d * (float)(noise * BKTestRandom(&state));
    }
    return [[BKMesh alloc] initWithVertices:v vertexCount:mesh.vertexCount indices:mesh.indices
                                 indexCount:mesh.triangleCount * 3 normals:NULL colors:NULL error:NULL];
}

// What: a closed ring ("doughnut") around the z axis: big radius R, tube radius r,
// nu x nv grid of squares split into 2 triangles each (2*nu*nv triangles), outward-facing.
- (BKMesh *)torusWithR:(float)R r:(float)r nu:(uint32_t)nu nv:(uint32_t)nv
{
    NSMutableData *vd = [NSMutableData dataWithLength:(NSUInteger)nu * nv * sizeof(simd_float3)];
    NSMutableData *id_ = [NSMutableData dataWithLength:(NSUInteger)nu * nv * 6 * sizeof(uint32_t)];
    simd_float3 *v = vd.mutableBytes;
    uint32_t *f = id_.mutableBytes;
    for (uint32_t i = 0; i < nu; i++)
        for (uint32_t j = 0; j < nv; j++) {
            double u = 2 * M_PI * i / nu, w = 2 * M_PI * j / nv;
            v[i * nv + j] = simd_make_float3((float)((R + r * cos(w)) * cos(u)), (float)((R + r * cos(w)) * sin(u)), (float)(r * sin(w)));
        }
    size_t k = 0;
    for (uint32_t i = 0; i < nu; i++)
        for (uint32_t j = 0; j < nv; j++) {
            uint32_t a = i * nv + j, b = ((i + 1) % nu) * nv + j, c = ((i + 1) % nu) * nv + (j + 1) % nv, d = i * nv + (j + 1) % nv;
            uint32_t tri[6] = {a, b, c, a, c, d};
            memcpy(f + k, tri, sizeof tri);
            k += 6;
        }
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:v vertexCount:(NSUInteger)nu * nv indices:f indexCount:k normals:NULL colors:NULL error:NULL];
    if (mesh.enclosedVolume < 0) {   // make it face outward
        for (size_t t = 0; t < k; t += 3) { uint32_t s = f[t + 1]; f[t + 1] = f[t + 2]; f[t + 2] = s; }
        mesh = [[BKMesh alloc] initWithVertices:v vertexCount:(NSUInteger)nu * nv indices:f indexCount:k normals:NULL colors:NULL error:NULL];
    }
    return mesh;
}

// Distance from p to the true torus surface (R, r around the z axis).
static double BKTorusDistance(simd_float3 p, double R, double r)
{
    double q = hypot(p.x, p.y) - R;
    return fabs(hypot(q, p.z) - r);
}

// Outward direction of the true torus at p.
static simd_double3 BKTorusNormal(simd_float3 p, double R)
{
    double rho = hypot(p.x, p.y);
    simd_double3 ring = simd_make_double3(p.x / rho * R, p.y / rho * R, 0);
    return simd_normalize(simd_make_double3(p.x, p.y, p.z) - ring);
}

// What: root-mean-square of (distance to centre - average distance). Why: a measure of
// roughness that does not change if the ball merely gets smaller or larger.
static double BKRadialRoughness(BKMesh *mesh, simd_float3 center)
{
    double sum = 0, sum2 = 0;
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
        double d = simd_distance(mesh.vertices[i], center);
        sum += d; sum2 += d * d;
    }
    double mean = sum / mesh.vertexCount;
    return sqrt(MAX(0, sum2 / mesh.vertexCount - mean * mean));
}

// What: the triangle's outward direction (not normalised).
static simd_double3 BKTriangleNormal(BKMesh *mesh, NSUInteger t, simd_double3 *centroid)
{
    const uint32_t *c = mesh.indices + 3 * t;
    simd_double3 a = simd_double(mesh.vertices[c[0]]), b = simd_double(mesh.vertices[c[1]]), d = simd_double(mesh.vertices[c[2]]);
    if (centroid) *centroid = (a + b + d) / 3.0;
    return simd_cross(b - a, d - a);
}

// What: fails the test unless the mesh is closed, manifold, consistently oriented.
- (void)assertCleanClosed:(BKMesh *)mesh label:(NSString *)label
{
    BKMeshEdgeReport r = [mesh edgeReport];
    XCTAssertEqual(r.boundaryEdgeCount, 0u, @"%@: holes", label);
    XCTAssertEqual(r.nonManifoldEdgeCount, 0u, @"%@: non-manifold edges", label);
    XCTAssertEqual(r.misorientedEdgeCount, 0u, @"%@: inconsistent orientation", label);
    XCTAssertEqual(r.degenerateTriangleCount, 0u, @"%@: degenerate triangles", label);
    XCTAssertGreaterThan(mesh.enclosedVolume, 0, @"%@: inside-out", label);
}

#pragma mark - Smoothing

- (void)testTaubinSmoothingDoesNotShrink
{
    simd_float3 center = simd_make_float3(10, -5, 30);
    BKMesh *clean = [BKMesh sphereMeshWithCenter:center radius:20 subdivisions:7];   // 327,680 triangles
    BKMesh *noisy = [self mesh:clean withRadialNoise:0.2f center:center];
    double cleanVolume = clean.enclosedVolume;
    double roughBefore = BKRadialRoughness(noisy, center);

    BKMeshProcessingReport report;
    BKMesh *taubin = [noisy meshBySmoothingWithIterations:BKMeshSmoothingDefaultIterations
                                                  passBand:BKMeshSmoothingDefaultPassBand progress:nil report:&report];
    XCTAssertNotNil(taubin);
    XCTAssertEqual(report.iterations, 20u);
    XCTAssertEqual(report.fixedVertexCount, 0u, @"a closed ball has no border vertices");
    XCTAssertNotEqual(taubin.normals, NULL);
    BKMesh *laplace = [noisy meshBySmoothingWithIterations:20 lambda:0.5f mu:0 progress:nil report:NULL];

    double taubinError = (taubin.enclosedVolume - cleanVolume) / cleanVolume;
    double laplaceError = (laplace.enclosedVolume - cleanVolume) / cleanVolume;
    double roughTaubin = BKRadialRoughness(taubin, center);
    NSLog(@"Smoothing noisy sphere (%lu tris, %.1f ms): volume change Taubin %+.4f%%, Laplacian %+.4f%%; roughness %.4f -> Taubin %.4f, Laplacian %.4f mm",
          (unsigned long)noisy.triangleCount, report.milliseconds, 100 * taubinError, 100 * laplaceError,
          roughBefore, roughTaubin, BKRadialRoughness(laplace, center));

    XCTAssertLessThan(fabs(taubinError), 0.01, @"Taubin smoothing must keep the volume within 1%%");
    XCTAssertLessThan(fabs(taubinError), fabs(laplaceError), @"plain Laplacian smoothing should shrink more");
    XCTAssertLessThan(roughTaubin, roughBefore / 3, @"the noise should be clearly reduced");
    [self assertCleanClosed:taubin label:@"Taubin"];
    XCTAssertEqual(taubin.triangleCount, noisy.triangleCount);

    // The same on the CLEAN ball: the shape is already smooth, so a good smoother should
    // leave the size alone, while Laplacian visibly shrinks it (mean radius, mm).
    BKMesh *taubinClean = [clean meshBySmoothingWithIterations:20 passBand:0.1f progress:nil report:NULL];
    BKMesh *laplaceClean = [clean meshBySmoothingWithIterations:20 lambda:0.5f mu:0 progress:nil report:NULL];
    double rT = cbrt(3 * taubinClean.enclosedVolume / (4 * M_PI)), rL = cbrt(3 * laplaceClean.enclosedVolume / (4 * M_PI));
    double r0 = cbrt(3 * cleanVolume / (4 * M_PI));
    NSLog(@"Clean sphere radius %.4f mm: after Taubin %.4f mm, after Laplacian %.4f mm", r0, rT, rL);
    XCTAssertLessThan(fabs(rT - r0), fabs(rL - r0));
}

- (void)testSmoothingKeepsOpenBorderInPlace
{
    BKMesh *open = [self cutSphere];
    BKMesh *noisy = [self mesh:open withRadialNoise:0.2f center:simd_make_float3(0, 0, 0)];
    BKMeshProcessingReport report;
    BKMesh *smooth = [noisy meshBySmoothingWithIterations:20 passBand:0.1f progress:nil report:&report];
    XCTAssertGreaterThan(report.fixedVertexCount, 0u);
    NSSet *before = [self boundaryEdgeSet:noisy], *after = [self boundaryEdgeSet:smooth];
    XCTAssertGreaterThan(before.count, 0u);
    XCTAssertEqualObjects(before, after, @"the open border must not move");
}

#pragma mark - Decimation

// What: decimates and checks everything the integrator relies on. `distance` gives the
// distance of a point to the true surface; `normal` its true outward direction.
- (void)checkDecimation:(BKMesh *)mesh target:(double)target maxDistance:(double)maxDistance label:(NSString *)label
               distance:(double (^)(simd_float3))distance normal:(simd_double3 (^)(simd_double3))normal
{
    BKMeshProcessingReport report;
    BKMesh *out = [mesh meshByDecimatingWithTargetReduction:target progress:nil report:&report];
    XCTAssertNotNil(out);
    double achieved = 1.0 - (double)out.triangleCount / mesh.triangleCount;
    double worst = 0;
    for (NSUInteger i = 0; i < out.vertexCount; i++) worst = MAX(worst, distance(out.vertices[i]));
    NSUInteger flipped = 0;
    for (NSUInteger t = 0; t < out.triangleCount; t++) {
        simd_double3 centroid;
        simd_double3 n = BKTriangleNormal(out, t, &centroid);
        if (simd_dot(n, normal(centroid)) <= 0) flipped++;
    }
    NSLog(@"Decimate %@ %lu -> %lu tris: target %.2f achieved %.4f in %lu passes, %.1f ms; max distance to true surface %.5f mm",
          label, (unsigned long)mesh.triangleCount, (unsigned long)out.triangleCount, target, achieved,
          (unsigned long)report.iterations, report.milliseconds, worst);
    XCTAssertEqualWithAccuracy(achieved, target, 0.03, @"%@: reduction", label);
    XCTAssertEqualWithAccuracy(report.achievedReduction, achieved, 1e-12);
    XCTAssertTrue(report.reachedTarget, @"%@", label);
    XCTAssertLessThan(worst, maxDistance, @"%@: shape not kept", label);
    XCTAssertEqual(flipped, 0u, @"%@: triangles turned over", label);
    [self assertCleanClosed:out label:label];
    XCTAssertNotEqual(out.normals, NULL);
}

- (void)testDecimateSphere
{
    simd_float3 c = simd_make_float3(10, -5, 30);
    BKMesh *sphere = [BKMesh sphereMeshWithCenter:c radius:20 subdivisions:7];
    double (^dist)(simd_float3) = ^double(simd_float3 p) { return fabs(simd_distance(p, c) - 20.0); };
    simd_double3 (^nrm)(simd_double3) = ^simd_double3(simd_double3 p) { return p - simd_double(c); };
    [self checkDecimation:sphere target:0.5 maxDistance:0.05 label:@"sphere 50%" distance:dist normal:nrm];
    [self checkDecimation:sphere target:0.9 maxDistance:0.1 label:@"sphere 90%" distance:dist normal:nrm];
}

- (void)testDecimateTorus
{
    BKMesh *torus = [self torusWithR:30 r:10 nu:400 nv:200];   // 160,000 triangles
    double (^dist)(simd_float3) = ^double(simd_float3 p) { return BKTorusDistance(p, 30, 10); };
    simd_double3 (^nrm)(simd_double3) = ^simd_double3(simd_double3 p) { return BKTorusNormal(simd_make_float3((float)p.x, (float)p.y, (float)p.z), 30); };
    // The grid's own flat triangles already lie up to ~0.03 mm inside the true torus.
    [self checkDecimation:torus target:0.5 maxDistance:0.06 label:@"torus 50%" distance:dist normal:nrm];
    [self checkDecimation:torus target:0.9 maxDistance:0.15 label:@"torus 90%" distance:dist normal:nrm];
}

// What: a 20 mm ball with its top cut off (only triangles entirely below z = 8 kept):
// an open surface, like a bone surface cut by the edge of the scan.
- (BKMesh *)cutSphere
{
    BKMesh *sphere = [BKMesh sphereMeshWithCenter:simd_make_float3(0, 0, 0) radius:20 subdivisions:6];
    NSMutableData *kept = [NSMutableData data];
    for (NSUInteger t = 0; t < sphere.triangleCount; t++) {
        const uint32_t *c = sphere.indices + 3 * t;
        if (sphere.vertices[c[0]].z < 8 && sphere.vertices[c[1]].z < 8 && sphere.vertices[c[2]].z < 8)
            [kept appendBytes:c length:3 * sizeof(uint32_t)];
    }
    BKMesh *open = [[BKMesh alloc] initWithVertices:sphere.vertices vertexCount:sphere.vertexCount indices:kept.bytes
                                         indexCount:kept.length / sizeof(uint32_t) normals:NULL colors:NULL error:NULL];
    [open weldVerticesWithTolerance:0];   // drops the vertices of the removed cap
    return open;
}

// What: the open-border edges as a set of exact coordinate pairs (order-independent).
- (NSSet<NSString *> *)boundaryEdgeSet:(BKMesh *)mesh
{
    NSCountedSet *edges = [NSCountedSet set];
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    for (NSUInteger t = 0; t < mesh.triangleCount; t++)
        for (int k = 0; k < 3; k++) {
            uint32_t a = mesh.indices[3 * t + k], b = mesh.indices[3 * t + (k + 1) % 3];
            NSString *key = [NSString stringWithFormat:@"%u-%u", MIN(a, b), MAX(a, b)];
            [edges addObject:key];
            simd_float3 p = mesh.vertices[a], q = mesh.vertices[b];
            NSString *s1 = [NSString stringWithFormat:@"%a,%a,%a", p.x, p.y, p.z], *s2 = [NSString stringWithFormat:@"%a,%a,%a", q.x, q.y, q.z];
            names[key] = [s1 compare:s2] < 0 ? [s1 stringByAppendingFormat:@"|%@", s2] : [s2 stringByAppendingFormat:@"|%@", s1];
        }
    NSMutableSet *border = [NSMutableSet set];
    for (NSString *key in edges) if ([edges countForObject:key] == 1) [border addObject:names[key]];
    return border;
}

- (void)testDecimateOpenSurfaceKeepsBorder
{
    BKMesh *open = [self cutSphere];
    BKMeshEdgeReport before = [open edgeReport];
    XCTAssertGreaterThan(before.boundaryEdgeCount, 0u);
    for (NSNumber *target in @[@0.5, @0.9]) {
        BKMeshProcessingReport report;
        BKMesh *out = [open meshByDecimatingWithTargetReduction:target.doubleValue progress:nil report:&report];
        BKMeshEdgeReport after = [out edgeReport];
        NSLog(@"Open sphere %lu -> %lu tris (target %.2f, achieved %.4f); border edges %lu -> %lu",
              (unsigned long)open.triangleCount, (unsigned long)out.triangleCount, target.doubleValue,
              report.achievedReduction, (unsigned long)before.boundaryEdgeCount, (unsigned long)after.boundaryEdgeCount);
        XCTAssertEqualWithAccuracy(report.achievedReduction, target.doubleValue, 0.03);
        XCTAssertEqual(after.nonManifoldEdgeCount, 0u);
        XCTAssertEqual(after.misorientedEdgeCount, 0u);
        XCTAssertEqualObjects([self boundaryEdgeSet:out], [self boundaryEdgeSet:open], @"the border loop must be kept exactly");
    }
}

#pragma mark - Determinism, progress, colours

// What: the exact bytes of a mesh's points and triangles (to compare runs).
- (NSData *)fingerprint:(BKMesh *)mesh
{
    NSMutableData *d = [NSMutableData dataWithBytes:mesh.vertices length:mesh.vertexCount * sizeof(simd_float3)];
    [d appendBytes:mesh.indices length:mesh.triangleCount * 3 * sizeof(uint32_t)];
    [d appendBytes:mesh.normals length:mesh.vertexCount * sizeof(simd_float3)];
    return d;
}

- (void)testSameResultWithOneThreadAndAllThreads
{
    simd_float3 c = simd_make_float3(0, 0, 0);
    BKMesh *noisy = [self mesh:[BKMesh sphereMeshWithCenter:c radius:20 subdivisions:7] withRadialNoise:0.2f center:c];
    NSData *smooth[2], *decimated[2];
    for (int run = 0; run < 2; run++) {
        BKMesh.processingMaxThreads = run == 0 ? 1 : 0;
        BKMesh *s = [noisy meshBySmoothingWithIterations:20 passBand:0.1f progress:nil report:NULL];
        smooth[run] = [self fingerprint:s];
        decimated[run] = [self fingerprint:[s meshByDecimatingWithTargetReduction:0.7 progress:nil report:NULL]];
    }
    BKMesh.processingMaxThreads = 0;
    XCTAssertEqualObjects(smooth[0], smooth[1], @"smoothing must not depend on the thread count");
    XCTAssertEqualObjects(decimated[0], decimated[1], @"decimation must not depend on the thread count");
}

- (void)testProgressAndCancel
{
    BKMesh *sphere = [BKMesh sphereMeshWithCenter:simd_make_float3(0, 0, 0) radius:20 subdivisions:6];
    __block double last = 0;
    __block NSUInteger calls = 0;
    BKMesh *out = [sphere meshByDecimatingWithTargetReduction:0.8 progress:^BOOL(double f) {
        XCTAssertGreaterThanOrEqual(f, last); last = f; calls++; return YES;
    } report:NULL];
    XCTAssertNotNil(out);
    XCTAssertGreaterThan(calls, 0u);
    XCTAssertEqualWithAccuracy(last, 1.0, 1e-9);

    BKMeshProcessingReport report;
    XCTAssertNil([sphere meshByDecimatingWithTargetReduction:0.8 progress:^BOOL(double f) { return NO; } report:&report]);
    XCTAssertTrue(report.cancelled);
    calls = 0;
    XCTAssertNil([sphere meshBySmoothingWithIterations:20 passBand:0.1f progress:^BOOL(double f) { return ++calls < 5; } report:&report]);
    XCTAssertTrue(report.cancelled);
    XCTAssertEqual(report.iterations, 5u);
}

- (void)testColoursAreCarriedOver
{
    BKMesh *sphere = [BKMesh sphereMeshWithCenter:simd_make_float3(0, 0, 0) radius:20 subdivisions:5];
    NSMutableData *cd = [NSMutableData dataWithLength:sphere.vertexCount * sizeof(simd_float4)];
    simd_float4 *colors = cd.mutableBytes;
    // Red on the top half, blue on the bottom.
    for (NSUInteger i = 0; i < sphere.vertexCount; i++)
        colors[i] = sphere.vertices[i].z > 0 ? simd_make_float4(1, 0, 0, 1) : simd_make_float4(0, 0, 1, 1);
    [sphere setColors:colors];
    BKMesh *out = [sphere meshByDecimatingWithTargetReduction:0.5 progress:nil report:NULL];
    XCTAssertNotEqual(out.colors, NULL);
    for (NSUInteger i = 0; i < out.vertexCount; i++) {
        if (fabsf(out.vertices[i].z) < 1) continue;   // merged points near the equator may move across
        XCTAssertEqual(out.colors[i].x > 0.5f, out.vertices[i].z > 0);
    }
    BKMesh *smooth = [sphere meshBySmoothingWithIterations:5 passBand:0.1f progress:nil report:NULL];
    XCTAssertEqual(memcmp(smooth.colors, sphere.colors, sphere.vertexCount * sizeof(simd_float4)), 0);
}

#pragma mark - Performance (logged only)

- (void)testPerformanceFiveMillionTriangles
{
    // 1600 x 1600 grid = 5.12 million triangles, with 0.05 mm noise like a scan.
    BKMesh *torus = [self mesh:[self torusWithR:40 r:15 nu:1600 nv:1600] withRadialNoise:0.05f center:simd_make_float3(0, 0, 0)];
    BKMeshProcessingReport smoothReport, decimateReport;
    BKMesh *smooth = [torus meshBySmoothingWithIterations:20 passBand:0.1f progress:nil report:&smoothReport];
    BKMesh *decimated = [smooth meshByDecimatingWithTargetReduction:0.5 progress:nil report:&decimateReport];
    NSLog(@"PERF %lu triangles: smoothing 20 iterations %.0f ms; decimate 50%% %.0f ms (%lu passes, achieved %.4f)",
          (unsigned long)torus.triangleCount, smoothReport.milliseconds, decimateReport.milliseconds,
          (unsigned long)decimateReport.iterations, decimateReport.achievedReduction);
    XCTAssertEqualWithAccuracy(decimateReport.achievedReduction, 0.5, 0.03);
    XCTAssertEqual([decimated edgeReport].nonManifoldEdgeCount, 0u);
}

@end
