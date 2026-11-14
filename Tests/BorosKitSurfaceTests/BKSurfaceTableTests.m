// Copyright (c) 2026 Serdal Kocak. All rights reserved.
//
// Tests for the backend-neutral surface core (BKSurfaceCore): no GPU needed.
//
// What is checked, in plain terms:
//  - the self-generated marching-cubes table is right for all 256 cases: every crossed
//    cube edge gets a surface point and no other edge does; inside a cube every
//    triangle side is shared by exactly two triangles except the lines on the cube's
//    faces; two neighbouring cubes always draw IDENTICAL lines on their shared face
//    (this is what makes the whole surface watertight); triangles face outward;
//  - the planner sizes the grid like the old Horos/VTK resolution setting and refuses
//    bad or too-large requests;
//  - the row prefix sum is right and refuses overflow;
//  - the CPU reference extractor gives closed, consistently oriented surfaces on random
//    noise (the hardest case for marching cubes), also through a mirroring transform.

#import <XCTest/XCTest.h>
#import "BKSurfaceCore.h"
#import "BKMesh.h"

// What: the cube corner position (0/1 per axis) of corner c.
static void BKCorner(int c, double p[3])
{
    p[0] = c & 1; p[1] = (c >> 1) & 1; p[2] = (c >> 2) & 1;
}

// What: YES if cube edge e lies on the face "axis = side".
static BOOL BKEdgeOnFace(const BKSurfaceEdge *e, int axis, int side)
{
    return ((e->corner0 >> axis) & 1) == side && ((e->corner1 >> axis) & 1) == side;
}

// What: the edge number of the edge joining corners a and b (searched in the table).
static int BKFindEdge(int a, int b)
{
    const BKSurfaceEdge *edges = BKSurfaceEdges();
    for (int e = 0; e < 12; e++)
        if ((edges[e].corner0 == a && edges[e].corner1 == b) || (edges[e].corner0 == b && edges[e].corner1 == a)) return e;
    return -1;
}

// What: wraps reference output in a BKMesh (for edgeReport / enclosedVolume).
static BKMesh *BKMeshFromData(const BKSurfaceMeshData *d)
{
    simd_float3 *v = malloc(sizeof(simd_float3) * (d->vertexCount + 1));
    for (uint64_t i = 0; i < d->vertexCount; i++) v[i] = simd_make_float3(d->positions[4 * i], d->positions[4 * i + 1], d->positions[4 * i + 2]);
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:v vertexCount:d->vertexCount indices:d->indices indexCount:d->triangleCount * 3
                                            normals:NULL colors:NULL error:NULL];
    free(v);
    return mesh;
}

@interface BKSurfaceTableTests : XCTestCase
@end

@implementation BKSurfaceTableTests

- (void)testEdgesFollowTheNumberingRule
{
    const BKSurfaceEdge *edges = BKSurfaceEdges();
    for (int e = 0; e < 12; e++) {
        XCTAssertEqual(edges[e].axis, e / 4);
        XCTAssertEqual(edges[e].corner1, edges[e].corner0 | (1 << edges[e].axis));
        XCTAssertEqual(edges[e].corner0 & (1 << edges[e].axis), 0);
        XCTAssertEqual(edges[e].dx, edges[e].corner0 & 1);
        XCTAssertEqual(edges[e].dy, (edges[e].corner0 >> 1) & 1);
        XCTAssertEqual(edges[e].dz, (edges[e].corner0 >> 2) & 1);
    }
}

// Every crossed edge used, nothing else; triangle sides: interior ones shared by two
// triangles in opposite directions, the others (open sides) lying on a cube face.
- (void)testEveryCaseIsAClosedPatchUsingExactlyTheCrossedEdges
{
    const BKSurfaceCase *cases = BKSurfaceCaseTable();
    const BKSurfaceEdge *edges = BKSurfaceEdges();
    int maxTriangles = 0;
    for (int cs = 0; cs < 256; cs++) {
        const BKSurfaceCase *k = &cases[cs];
        maxTriangles = MAX(maxTriangles, k->triangleCount);
        XCTAssertLessThanOrEqual(k->triangleCount, BK_SURFACE_MAX_CELL_TRIANGLES);
        int used[12] = {0};
        int directed[12][12] = {{0}};
        for (int t = 0; t < k->triangleCount; t++) {
            const uint8_t *tri = k->edges + 3 * t;
            XCTAssertTrue(tri[0] != tri[1] && tri[1] != tri[2] && tri[0] != tri[2], @"case %d degenerate", cs);
            for (int j = 0; j < 3; j++) {
                used[tri[j]] = 1;
                directed[tri[j]][tri[(j + 1) % 3]]++;
            }
        }
        for (int e = 0; e < 12; e++) {
            BOOL crossed = ((cs >> edges[e].corner0) & 1) != ((cs >> edges[e].corner1) & 1);
            XCTAssertEqual((BOOL)used[e], crossed, @"case %d edge %d", cs, e);
        }
        for (int a = 0; a < 12; a++)
            for (int b = 0; b < 12; b++) {
                XCTAssertLessThanOrEqual(directed[a][b], 1, @"case %d: side %d->%d used twice in the same direction", cs, a, b);
                BOOL onFace = NO;
                for (int axis = 0; axis < 3; axis++)
                    for (int side = 0; side < 2; side++)
                        onFace |= BKEdgeOnFace(&edges[a], axis, side) && BKEdgeOnFace(&edges[b], axis, side);
                if (directed[a][b] && !directed[b][a]) {
                    // An open side: must lie on a cube face (both edges on the same face).
                    XCTAssertTrue(onFace, @"case %d: open side %d->%d is not on a face", cs, a, b);
                } else if (directed[a][b] && directed[b][a]) {
                    // An inner cut: must NOT lie on a face (else a neighbour could reuse it).
                    XCTAssertFalse(onFace, @"case %d: inner cut %d-%d lies on a face", cs, a, b);
                }
            }
    }
    XCTAssertEqual(maxTriangles, BK_SURFACE_MAX_CELL_TRIANGLES);
    XCTAssertEqual(cases[0].triangleCount, 0);
    XCTAssertEqual(cases[255].triangleCount, 0);
    XCTAssertEqual(cases[1].triangleCount, 1);
}

// The watertightness guarantee: for two cubes side by side along `axis`, the open
// triangle sides on the shared face are the same lines, run in opposite directions.
- (void)testNeighbourCubesDrawIdenticalLinesOnTheSharedFace
{
    const BKSurfaceCase *cases = BKSurfaceCaseTable();
    const BKSurfaceEdge *edges = BKSurfaceEdges();
    NSUInteger pairsChecked = 0, mismatches = 0;
    for (int axis = 0; axis < 3; axis++) {
        const int bit = 1 << axis;
        for (int a = 0; a < 256; a++) {
            for (int b = 0; b < 256; b++) {
                // Cube A's far face (bit set) must have the same corners as cube B's near face.
                BOOL match = YES;
                for (int c = 0; c < 8 && match; c++)
                    if (c & bit) match = ((a >> c) & 1) == ((b >> (c ^ bit)) & 1);
                if (!match) continue;
                // Directed open sides of A on its far face, moved into B's numbering.
                NSMutableSet *sidesA = [NSMutableSet set], *sidesB = [NSMutableSet set];
                for (int which = 0; which < 2; which++) {
                    const BKSurfaceCase *k = &cases[which ? b : a];
                    int side = which ? 0 : 1;
                    for (int t = 0; t < k->triangleCount; t++)
                        for (int j = 0; j < 3; j++) {
                            int e0 = k->edges[3 * t + j], e1 = k->edges[3 * t + (j + 1) % 3];
                            if (!BKEdgeOnFace(&edges[e0], axis, side) || !BKEdgeOnFace(&edges[e1], axis, side)) continue;
                            if (which == 0) {
                                int m0 = BKFindEdge(edges[e0].corner0 ^ bit, edges[e0].corner1 ^ bit);
                                int m1 = BKFindEdge(edges[e1].corner0 ^ bit, edges[e1].corner1 ^ bit);
                                [sidesA addObject:@(m1 * 16 + m0)];   // reversed direction
                            } else {
                                [sidesB addObject:@(e0 * 16 + e1)];
                            }
                        }
                }
                if (![sidesA isEqualToSet:sidesB]) mismatches++;
                pairsChecked++;
            }
        }
    }
    XCTAssertEqual(mismatches, 0u);
    XCTAssertEqual(pairsChecked, (NSUInteger)3 * 256 * 16);
}

// Triangles face outward: each triangle (corners at the edge midpoints) has its front
// side toward the outside corners of the edges it sits on.
- (void)testTrianglesFaceOutward
{
    const BKSurfaceCase *cases = BKSurfaceCaseTable();
    const BKSurfaceEdge *edges = BKSurfaceEdges();
    for (int cs = 0; cs < 256; cs++) {
        for (int t = 0; t < cases[cs].triangleCount; t++) {
            double p[3][3], outward[3] = {0, 0, 0};
            for (int j = 0; j < 3; j++) {
                const BKSurfaceEdge *e = &edges[cases[cs].edges[3 * t + j]];
                double c0[3], c1[3];
                BKCorner(e->corner0, c0);
                BKCorner(e->corner1, c1);
                BOOL in0 = (cs >> e->corner0) & 1;
                for (int k = 0; k < 3; k++) {
                    p[j][k] = 0.5 * (c0[k] + c1[k]);
                    outward[k] += in0 ? c1[k] - c0[k] : c0[k] - c1[k];
                }
            }
            double u[3], v[3];
            for (int k = 0; k < 3; k++) { u[k] = p[1][k] - p[0][k]; v[k] = p[2][k] - p[0][k]; }
            double n[3] = {u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]};
            XCTAssertGreaterThan(n[0] * outward[0] + n[1] * outward[1] + n[2] * outward[2], 0, @"case %d triangle %d faces inward", cs, t);
        }
    }
}

- (void)testGPUTableLayout
{
    uint32_t words[BK_SURFACE_TABLE_WORDS];
    BKSurfaceFillGPUTable(words);
    const BKSurfaceCase *cases = BKSurfaceCaseTable();
    for (int cs = 0; cs < 256; cs++) {
        XCTAssertEqual(words[cs * BK_SURFACE_CASE_STRIDE], cases[cs].triangleCount);
        for (int i = 0; i < 3 * cases[cs].triangleCount; i++) XCTAssertEqual(words[cs * BK_SURFACE_CASE_STRIDE + 1 + i], cases[cs].edges[i]);
    }
    const BKSurfaceEdge *edges = BKSurfaceEdges();
    for (int e = 0; e < 12; e++) {
        uint32_t w = words[BK_SURFACE_EDGE_TABLE_OFFSET + e];
        XCTAssertEqual(w & 0xff, edges[e].dx);
        XCTAssertEqual((w >> 8) & 0xff, edges[e].dy);
        XCTAssertEqual((w >> 16) & 0xff, edges[e].dz);
        XCTAssertEqual(w >> 24, edges[e].axis);
    }
    // std430 / C layout of the parameter block: no hidden padding.
    XCTAssertEqual(sizeof(BKSurfaceParams) % 16, 0u);
    XCTAssertEqual(sizeof(BKSurfaceParams), (16 + 12 + 4 + 4 + BK_SURFACE_MAX_BLUR_WEIGHTS + 4 + 4 + 8) * 4u);
}

#pragma mark - Plan

static BKSurfacePlanRequest BKRequest(uint32_t w, uint32_t h, uint32_t d, float resolution, float sigma)
{
    BKSurfacePlanRequest rq = {0};
    rq.volumeWidth = w; rq.volumeHeight = h; rq.volumeDepth = d;
    rq.resolution = resolution;
    rq.smoothingSigma = sigma;
    for (int i = 0; i < 4; i++) rq.voxelToOutput[i * 5] = 1;
    return rq;
}

- (void)testPlanGridSizes
{
    BKSurfacePlan plan;
    BKSurfacePlanRequest rq = BKRequest(512, 512, 727, 1.0f, 0);
    XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusOK);
    XCTAssertEqual(plan.gridWidth, 512u); XCTAssertEqual(plan.gridHeight, 512u); XCTAssertEqual(plan.gridDepth, 727u);
    XCTAssertFalse(plan.usesField);
    XCTAssertEqual(plan.params.source, (uint32_t)BK_SURFACE_SOURCE_TEXTURE);
    XCTAssertEqual(plan.packedBytes, 512ull * 512 * 727 * 2);

    rq = BKRequest(512, 512, 727, 0.5f, 0);
    XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusOK);
    XCTAssertEqual(plan.gridWidth, 256u); XCTAssertEqual(plan.gridHeight, 256u); XCTAssertEqual(plan.gridDepth, 727u);   // Z unchanged
    XCTAssertTrue(plan.usesField);
    XCTAssertEqualWithAccuracy(plan.params.gridToVoxel[0], 2.0f, 1e-6);
    XCTAssertEqualWithAccuracy(plan.params.gridToOutput[0], 2.0f, 1e-6);   // grid step = 2 voxels in x
    XCTAssertEqualWithAccuracy(plan.params.gridToOutput[10], 1.0f, 1e-6);  // z untouched

    rq = BKRequest(101, 51, 20, 0.3f, 1.0f);   // odd width -> even row stride; blur radii per axis
    XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusOK);
    XCTAssertEqual(plan.gridWidth, 31u);
    XCTAssertEqual(plan.rowStride, 32u);
    XCTAssertEqual(plan.blurRadius[0], 1u);   // sigma 0.3 grid voxels
    XCTAssertEqual(plan.blurRadius[2], 3u);   // sigma 1 voxel
    double sum = plan.blurWeights[2][0];
    for (uint32_t k = 1; k <= plan.blurRadius[2]; k++) sum += 2 * plan.blurWeights[2][k];
    XCTAssertEqualWithAccuracy(sum, 1.0, 1e-6);
}

- (void)testPlanRefusesBadInput
{
    BKSurfacePlan plan;
    float badResolutions[] = {0, -1, 1.01f, NAN};
    for (int i = 0; i < 4; i++) {
        BKSurfacePlanRequest rq = BKRequest(64, 64, 64, badResolutions[i], 0);
        XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusInvalidInput);
    }
    BKSurfacePlanRequest rq = BKRequest(64, 64, 64, 1, 10.5f);
    XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusInvalidInput);
    rq = BKRequest(1, 64, 64, 1, 0);
    XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusInvalidInput);
    rq = BKRequest(4096, 64, 64, 1, 0);
    XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusTooLarge);
    rq = BKRequest(64, 64, 64, 1, 0);
    rq.voxelToOutput[10] = 0;   // singular (flat) transform
    XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusInvalidInput);
    rq = BKRequest(512, 512, 512, 1, 0);
    rq.memoryBudgetBytes = 100ull * 1024 * 1024;   // 100 MB is not enough for 2 bytes x 134 M points
    XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusTooLarge);
    XCTAssertTrue(isnan(BKSurfaceThresholdToSteps(NAN, 1, 0)));
    XCTAssertEqualWithAccuracy(BKSurfaceThresholdToSteps(-500, 2000, -1000), 500.0 / 2000.0 * 65535.0, 1e-2);
}

- (void)testMirroringTransformIsDetected
{
    BKSurfacePlan plan;
    BKSurfacePlanRequest rq = BKRequest(16, 16, 16, 1, 0);
    rq.voxelToOutput[10] = -0.5;
    XCTAssertEqual(BKSurfacePlanMake(&rq, &plan), BKSurfaceStatusOK);
    XCTAssertEqual(plan.params.flipWinding, 1u);
    XCTAssertEqualWithAccuracy(plan.params.normalMatrix[10], -2.0f, 1e-6);   // inverse-transpose of -0.5
}

- (void)testExclusiveScan
{
    uint32_t v[5] = {3, 0, 2, 5, 1};
    XCTAssertEqual(BKSurfaceExclusiveScan(v, 5), 11ull);
    uint32_t expected[5] = {0, 3, 3, 5, 10};
    for (int i = 0; i < 5; i++) XCTAssertEqual(v[i], expected[i]);
    uint32_t big[3] = {UINT32_MAX - 1, 1, 1};
    XCTAssertEqual(BKSurfaceExclusiveScan(big, 3), UINT64_MAX);   // total does not fit in 32 bits
}

#pragma mark - CPU reference

// Random noise with an "outside" border: the surface must be closed, manifold and
// consistently oriented, even with countless ambiguous faces.
- (void)testReferenceIsWatertightOnNoise
{
    const uint32_t n = 24;
    float *v = malloc(sizeof(float) * n * n * n);
    srand48(7);
    for (uint32_t z = 0; z < n; z++)
        for (uint32_t y = 0; y < n; y++)
            for (uint32_t x = 0; x < n; x++) {
                BOOL border = x == 0 || y == 0 || z == 0 || x == n - 1 || y == n - 1 || z == n - 1;
                v[x + n * (y + n * z)] = border ? 0.0f : (float)drand48();
            }
    for (int mirrored = 0; mirrored < 2; mirrored++) {
        double m[16] = {0};
        m[0] = 0.4; m[5] = 0.3; m[10] = mirrored ? -0.5 : 0.5; m[15] = 1; m[12] = 10;
        BKSurfaceMeshData data;
        XCTAssertEqual(BKSurfaceReferenceExtract(v, n, n, n, 0.5f, m, &data), BKSurfaceStatusOK);
        XCTAssertGreaterThan(data.triangleCount, 1000ull);
        BKMesh *mesh = BKMeshFromData(&data);
        BKMeshEdgeReport r = mesh.edgeReport;
        XCTAssertEqual(r.boundaryEdgeCount, 0u);
        XCTAssertEqual(r.nonManifoldEdgeCount, 0u);
        XCTAssertEqual(r.misorientedEdgeCount, 0u);
        XCTAssertEqual(r.degenerateTriangleCount, 0u);
        XCTAssertGreaterThan(mesh.enclosedVolume, 0, @"mirrored %d: surface is inside-out", mirrored);
        BKSurfaceMeshDataFree(&data);
    }
    free(v);
}

@end
