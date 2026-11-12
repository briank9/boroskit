// Tests for BorosKitMesh: the mesh geometry (BKMesh) and the file readers/writers
// (BKMeshIO). No GPU needed.
//
// What is checked, in plain terms:
//  - known answers: a 1 mm cube has area 6 mm^2, volume 1 mm^3 and is closed; with one
//    face missing it is not closed; a sphere's volume and area match the formulas;
//  - moving, mirroring, normals and welding behave;
//  - every file format gives back exactly the same shape after saving and reopening;
//  - damaged files of every kind return an error message and never crash.

#import <XCTest/XCTest.h>
#import "BorosKitMesh.h"

@interface BKMeshTests : XCTestCase
@end

@implementation BKMeshTests

#pragma mark - Helpers

// What: the unit cube from (0,0,0) to (1,1,1). Why: the classic known-answer shape.
- (BKMesh *)unitCube
{
    return [BKMesh boxMeshWithMin:simd_make_float3(0, 0, 0) max:simd_make_float3(1, 1, 1)];
}

// What: a mesh from plain arrays (test shorthand). Fails the test if it is rejected.
- (BKMesh *)meshWithVertices:(const simd_float3 *)v count:(NSUInteger)n indices:(const uint32_t *)idx count:(NSUInteger)m
{
    NSError *error = nil;
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:v vertexCount:n indices:idx indexCount:m normals:NULL colors:NULL error:&error];
    XCTAssertNotNil(mesh, @"%@", error);
    return mesh;
}

// What: YES if both meshes hold exactly the same numbers (vertices, triangles, and
// normals/colours when `attributes`). Why: "round trip = identical geometry".
- (void)assertMesh:(BKMesh *)a identicalTo:(BKMesh *)b attributes:(BOOL)attributes
{
    XCTAssertEqual(a.vertexCount, b.vertexCount);
    XCTAssertEqual(a.triangleCount, b.triangleCount);
    if (a.vertexCount != b.vertexCount || a.triangleCount != b.triangleCount) return;
    XCTAssertEqual(memcmp(a.indices, b.indices, a.triangleCount * 3 * sizeof(uint32_t)), 0, @"triangles differ");
    for (NSUInteger i = 0; i < a.vertexCount; i++)
        XCTAssertTrue(simd_equal(a.vertices[i], b.vertices[i]), @"vertex %lu differs", (unsigned long)i);
    if (!attributes) return;
    XCTAssertEqual(a.normals == NULL, b.normals == NULL);
    XCTAssertEqual(a.colors == NULL, b.colors == NULL);
    for (NSUInteger i = 0; a.normals && b.normals && i < a.vertexCount; i++)
        XCTAssertTrue(simd_equal(a.normals[i], b.normals[i]), @"normal %lu differs", (unsigned long)i);
    for (NSUInteger i = 0; a.colors && b.colors && i < a.vertexCount; i++)
        XCTAssertTrue(simd_equal(a.colors[i], b.colors[i]), @"colour %lu differs", (unsigned long)i);
}

// What: the list of triangles as corner coordinates. Why: STL does not keep the
// vertex numbering, so "same geometry" there means the same triangles in the same order.
- (NSData *)triangleSoup:(BKMesh *)mesh
{
    NSMutableData *soup = [NSMutableData data];
    for (NSUInteger i = 0; i < mesh.triangleCount * 3; i++) {
        simd_float3 v = mesh.vertices[mesh.indices[i]];
        float xyz[3] = {v.x, v.y, v.z};
        [soup appendBytes:xyz length:sizeof xyz];
    }
    return soup;
}

// What: a mesh with odd coordinates, normals and colours on k/255 steps (exactly
// representable in a PLY byte). Why: catches rounding in the text formats.
- (BKMesh *)awkwardMesh
{
    BKMesh *mesh = [BKMesh sphereMeshWithCenter:simd_make_float3(12.345678f, -98.7654321f, 1e-7f) radius:7.1234567f subdivisions:2];
    NSMutableData *colors = [NSMutableData dataWithLength:mesh.vertexCount * sizeof(simd_float4)];
    simd_float4 *c = colors.mutableBytes;
    for (NSUInteger i = 0; i < mesh.vertexCount; i++)
        c[i] = simd_make_float4((i % 256) / 255.0f, ((i * 7) % 256) / 255.0f, ((i * 13) % 256) / 255.0f, ((i * 3) % 256) / 255.0f);
    [mesh setColors:c];
    return mesh;
}

- (NSURL *)temporaryDirectory
{
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    [self addTeardownBlock:^{ [[NSFileManager defaultManager] removeItemAtURL:dir error:NULL]; }];
    return dir;
}

- (NSData *)utf8:(NSString *)s
{
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Known answers

// A 1 mm cube: 8 corners, 12 triangles, area 6, volume 1, closed, every edge shared twice.
- (void)testUnitCubeKnownAnswers
{
    BKMesh *cube = [self unitCube];
    XCTAssertEqual(cube.vertexCount, 8u);
    XCTAssertEqual(cube.triangleCount, 12u);
    XCTAssertEqualWithAccuracy(cube.surfaceArea, 6.0, 1e-12);
    XCTAssertEqualWithAccuracy(cube.enclosedVolume, 1.0, 1e-12);
    XCTAssertTrue(cube.watertight);
    XCTAssertTrue(cube.manifold);
    BKMeshEdgeReport r = cube.edgeReport;
    XCTAssertEqual(r.edgeCount, 18u);
    XCTAssertEqual(r.boundaryEdgeCount, 0u);
    XCTAssertEqual(r.nonManifoldEdgeCount, 0u);
    XCTAssertEqual(r.misorientedEdgeCount, 0u);
    XCTAssertTrue(simd_equal(cube.boundsMin, simd_make_float3(0, 0, 0)));
    XCTAssertTrue(simd_equal(cube.boundsMax, simd_make_float3(1, 1, 1)));
}

// Removing one face (2 triangles) leaves a square hole: 4 open edges, not closed.
- (void)testCubeWithMissingFaceIsNotWatertight
{
    BKMesh *cube = [self unitCube];
    BKMesh *open = [self meshWithVertices:cube.vertices count:8 indices:cube.indices count:30];
    XCTAssertFalse(open.watertight);
    XCTAssertTrue(open.manifold);
    XCTAssertEqual(open.edgeReport.boundaryEdgeCount, 4u);
    XCTAssertEqualWithAccuracy(open.surfaceArea, 5.0, 1e-12);
}

// One flipped triangle: still closed, but reported as inconsistently oriented.
- (void)testFlippedTriangleIsReported
{
    BKMesh *cube = [self unitCube];
    uint32_t idx[36];
    memcpy(idx, cube.indices, sizeof idx);
    uint32_t t = idx[1]; idx[1] = idx[2]; idx[2] = t;
    BKMesh *bad = [self meshWithVertices:cube.vertices count:8 indices:idx count:36];
    XCTAssertTrue(bad.watertight);
    XCTAssertEqual(bad.edgeReport.misorientedEdgeCount, 3u);
}

// Three triangles on one edge = a "fin": not manifold, not watertight.
- (void)testNonManifoldEdge
{
    simd_float3 v[5] = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}};
    uint32_t idx[9] = {0, 1, 2,  1, 0, 3,  0, 1, 4};
    BKMesh *fin = [self meshWithVertices:v count:5 indices:idx count:9];
    XCTAssertFalse(fin.manifold);
    XCTAssertFalse(fin.watertight);
    XCTAssertEqual(fin.edgeReport.nonManifoldEdgeCount, 1u);
}

- (void)testEmptyMesh
{
    BKMesh *mesh = [[BKMesh alloc] init];
    XCTAssertEqual(mesh.vertexCount, 0u);
    XCTAssertFalse(mesh.watertight);
    XCTAssertEqual(mesh.surfaceArea, 0.0);
    XCTAssertTrue(simd_equal(mesh.boundsMax, simd_make_float3(0, 0, 0)));
    XCTAssertEqual([mesh weldVerticesWithTolerance:0.1f], 0u);
}

// The sphere approaches 4/3 pi r^3 and 4 pi r^2 and is closed and outward-facing.
- (void)testSphere
{
    float r = 10;
    BKMesh *sphere = [BKMesh sphereMeshWithCenter:simd_make_float3(5, 6, 7) radius:r subdivisions:4];
    XCTAssertEqual(sphere.triangleCount, 20u * 256u);
    XCTAssertTrue(sphere.watertight);
    XCTAssertEqual(sphere.edgeReport.misorientedEdgeCount, 0u);
    XCTAssertEqualWithAccuracy(sphere.enclosedVolume, 4.0 / 3.0 * M_PI * r * r * r, 0.01 * 4.0 / 3.0 * M_PI * r * r * r);
    XCTAssertEqualWithAccuracy(sphere.surfaceArea, 4.0 * M_PI * r * r, 0.01 * 4.0 * M_PI * r * r);
    XCTAssertEqualWithAccuracy(sphere.boundsMin.x, 5 - r, 1e-4);
    XCTAssertEqualWithAccuracy(sphere.boundsMax.z, 7 + r, 1e-4);
    // Normals point away from the centre.
    for (NSUInteger i = 0; i < sphere.vertexCount; i += 97)
        XCTAssertGreaterThan(simd_dot(sphere.normals[i], sphere.vertices[i] - simd_make_float3(5, 6, 7)), 0);
}

#pragma mark - Bad input

- (void)testRejectsBadArrays
{
    simd_float3 v[3] = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}};
    uint32_t outOfRange[3] = {0, 1, 3};
    NSError *error = nil;
    XCTAssertNil([[BKMesh alloc] initWithVertices:v vertexCount:3 indices:outOfRange indexCount:3 normals:NULL colors:NULL error:&error]);
    XCTAssertEqual(error.code, BKMeshErrorInvalidGeometry);
    uint32_t ok[3] = {0, 1, 2};
    error = nil;
    XCTAssertNil([[BKMesh alloc] initWithVertices:v vertexCount:3 indices:ok indexCount:2 normals:NULL colors:NULL error:&error]);
    XCTAssertNotNil(error);
    simd_float3 nan[3] = {{0, 0, 0}, {NAN, 0, 0}, {0, 1, 0}};
    error = nil;
    XCTAssertNil([[BKMesh alloc] initWithVertices:nan vertexCount:3 indices:ok indexCount:3 normals:NULL colors:NULL error:&error]);
    XCTAssertNotNil(error);
}

#pragma mark - Transform, normals, welding

- (void)testTranslateAndRotate
{
    BKMesh *cube = [self unitCube];
    NSUInteger version = cube.version;
    [cube transformByMatrix:simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0),
                                        simd_make_float4(0, 0, 1, 0), simd_make_float4(10, 20, 30, 1))];
    XCTAssertGreaterThan(cube.version, version);
    XCTAssertTrue(simd_equal(cube.boundsMin, simd_make_float3(10, 20, 30)));
    XCTAssertEqualWithAccuracy(cube.enclosedVolume, 1.0, 1e-5);

    // N3AffineTransform (row-vector convention) gives the same result as its simd form.
    BKMesh *a = [self unitCube], *b = [self unitCube];
    N3AffineTransform t = N3AffineTransformConcat(N3AffineTransformMakeRotation(0.3, 0, 0, 1), N3AffineTransformMakeTranslation(5, -2, 7));
    [a transformByN3AffineTransform:t];
    for (NSUInteger i = 0; i < b.vertexCount; i++) {
        simd_float3 p = b.vertices[i];
        N3Vector q = N3VectorApplyTransform(N3VectorMake(p.x, p.y, p.z), t);
        XCTAssertEqualWithAccuracy(a.vertices[i].x, q.x, 1e-5);
        XCTAssertEqualWithAccuracy(a.vertices[i].y, q.y, 1e-5);
        XCTAssertEqualWithAccuracy(a.vertices[i].z, q.z, 1e-5);
    }
    XCTAssertEqualWithAccuracy(a.surfaceArea, 6.0, 1e-4);
}

// A mirror must keep the outside outside (positive volume, normals still outward).
- (void)testMirrorKeepsOrientation
{
    BKMesh *sphere = [BKMesh sphereMeshWithCenter:simd_make_float3(3, 0, 0) radius:2 subdivisions:2];
    double before = sphere.enclosedVolume;
    [sphere transformByMatrix:simd_matrix(simd_make_float4(-1, 0, 0, 0), simd_make_float4(0, 1, 0, 0),
                                          simd_make_float4(0, 0, 1, 0), simd_make_float4(0, 0, 0, 1))];
    XCTAssertEqualWithAccuracy(sphere.enclosedVolume, before, 1e-4);
    XCTAssertEqual(sphere.edgeReport.misorientedEdgeCount, 0u);
    for (NSUInteger i = 0; i < sphere.vertexCount; i += 13)
        XCTAssertGreaterThan(simd_dot(sphere.normals[i], sphere.vertices[i] - simd_make_float3(-3, 0, 0)), 0);
}

// Smooth normals of a cube corner point diagonally outward; flat normals give each
// triangle its own corners with the face direction.
- (void)testNormals
{
    BKMesh *cube = [self unitCube];
    [cube computeSmoothNormals];
    for (NSUInteger i = 0; i < 8; i++) {
        simd_float3 outward = simd_normalize(cube.vertices[i] - simd_make_float3(0.5f, 0.5f, 0.5f));
        XCTAssertGreaterThan(simd_dot(cube.normals[i], outward), 0.9f);
        XCTAssertEqualWithAccuracy(simd_length(cube.normals[i]), 1.0f, 1e-5);
    }
    [cube computeFlatNormals];
    XCTAssertEqual(cube.vertexCount, 36u);
    XCTAssertEqualWithAccuracy(cube.surfaceArea, 6.0, 1e-12);
    for (NSUInteger i = 0; i < 36; i++) {
        simd_float3 n = cube.normals[i];
        XCTAssertEqualWithAccuracy(fabsf(n.x) + fabsf(n.y) + fabsf(n.z), 1.0f, 1e-6);   // axis-aligned
    }
    // Unshared corners: the triangles no longer "touch" ...
    XCTAssertFalse(cube.watertight);
    // ... until they are welded back together.
    XCTAssertEqual([cube weldVerticesWithTolerance:0], 28u);
    XCTAssertEqual(cube.vertexCount, 8u);
    XCTAssertTrue(cube.watertight);
    XCTAssertEqualWithAccuracy(cube.enclosedVolume, 1.0, 1e-12);
}

// Welding with a tolerance merges nearly equal points and drops collapsed triangles.
- (void)testWeldWithTolerance
{
    simd_float3 v[6] = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1.0004f, 0, 0}, {0, 1.0003f, 0}, {1, 1, 0}};
    uint32_t idx[9] = {0, 1, 2,  3, 5, 4,  1, 3, 2};   // the last one collapses after welding
    BKMesh *mesh = [self meshWithVertices:v count:6 indices:idx count:9];
    XCTAssertEqual([mesh weldVerticesWithTolerance:0], 0u);      // nothing exactly equal
    XCTAssertEqual([mesh weldVerticesWithTolerance:0.001f], 2u);
    XCTAssertEqual(mesh.vertexCount, 4u);
    XCTAssertEqual(mesh.triangleCount, 2u);
    XCTAssertEqual(mesh.edgeReport.boundaryEdgeCount, 4u);       // a square made of 2 triangles
}

- (void)testCopyIsIndependent
{
    BKMesh *a = [self unitCube];
    BKMesh *b = [a copy];
    [b transformByMatrix:simd_matrix(simd_make_float4(2, 0, 0, 0), simd_make_float4(0, 2, 0, 0),
                                     simd_make_float4(0, 0, 2, 0), simd_make_float4(0, 0, 0, 1))];
    XCTAssertEqualWithAccuracy(a.enclosedVolume, 1.0, 1e-12);
    XCTAssertEqualWithAccuracy(b.enclosedVolume, 8.0, 1e-12);
}

#pragma mark - Round trips

- (void)testSTLRoundTrip
{
    BKMesh *mesh = [self awkwardMesh];
    NSError *error = nil;
    NSData *data = [BKMeshIO dataForMesh:mesh format:BKMeshFileFormatSTL error:&error];
    XCTAssertNotNil(data, @"%@", error);
    XCTAssertEqual(data.length, 84 + 50 * mesh.triangleCount);
    XCTAssertEqual([BKMeshIO detectFormatOfData:data], BKMeshFileFormatSTL);
    BKMesh *back = [BKMeshIO readMeshFromData:data format:BKMeshFileFormatUnknown error:&error];
    XCTAssertNotNil(back, @"%@", error);
    // STL has no shared corners; the reader welds exact repeats, which restores the
    // sphere's 162 shared vertices and its closed surface.
    XCTAssertEqual(back.vertexCount, mesh.vertexCount);
    XCTAssertEqualObjects([self triangleSoup:back], [self triangleSoup:mesh]);
    XCTAssertTrue(back.watertight);
    XCTAssertEqual(back.enclosedVolume, mesh.enclosedVolume);
}

- (void)testPLYBinaryRoundTrip
{
    BKMesh *mesh = [self awkwardMesh];
    NSError *error = nil;
    NSData *data = [BKMeshIO dataForMesh:mesh format:BKMeshFileFormatPLY error:&error];
    XCTAssertEqual([BKMeshIO detectFormatOfData:data], BKMeshFileFormatPLY);
    BKMesh *back = [BKMeshIO readMeshFromData:data format:BKMeshFileFormatUnknown error:&error];
    XCTAssertNotNil(back, @"%@", error);
    [self assertMesh:back identicalTo:mesh attributes:YES];
}

- (void)testPLYASCIIRoundTrip
{
    BKMesh *mesh = [self awkwardMesh];
    NSError *error = nil;
    NSData *data = [BKMeshIO dataForMesh:mesh format:BKMeshFileFormatPLYASCII error:&error];
    XCTAssertTrue([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] hasPrefix:@"ply\nformat ascii 1.0\n"]);
    BKMesh *back = [BKMeshIO readMeshFromData:data format:BKMeshFileFormatUnknown error:&error];
    XCTAssertNotNil(back, @"%@", error);
    [self assertMesh:back identicalTo:mesh attributes:YES];
}

- (void)testOBJRoundTrip
{
    // With normals and colours (OBJ stores RGB only, so alpha must be 1 to compare).
    BKMesh *mesh = [self awkwardMesh];
    NSMutableData *colors = [NSMutableData dataWithBytes:mesh.colors length:mesh.vertexCount * sizeof(simd_float4)];
    simd_float4 *c = colors.mutableBytes;
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) c[i].w = 1;
    [mesh setColors:c];
    NSError *error = nil;
    NSData *data = [BKMeshIO dataForMesh:mesh format:BKMeshFileFormatOBJ error:&error];
    XCTAssertEqual([BKMeshIO detectFormatOfData:data], BKMeshFileFormatOBJ);
    BKMesh *back = [BKMeshIO readMeshFromData:data format:BKMeshFileFormatUnknown error:&error];
    XCTAssertNotNil(back, @"%@", error);
    [self assertMesh:back identicalTo:mesh attributes:YES];

    // Plain shape only.
    BKMesh *cube = [self unitCube];
    back = [BKMeshIO readMeshFromData:[BKMeshIO dataForMesh:cube format:BKMeshFileFormatOBJ error:NULL] format:BKMeshFileFormatOBJ error:&error];
    [self assertMesh:back identicalTo:cube attributes:YES];
}

// Through real files: the format follows the extension and the name the file name.
- (void)testFileRoundTripAndNames
{
    NSURL *dir = [self temporaryDirectory];
    BKMesh *cube = [self unitCube];
    for (NSString *ext in @[@"stl", @"ply", @"obj", @"PLY"]) {
        NSURL *url = [dir URLByAppendingPathComponent:[@"Guide." stringByAppendingString:ext]];
        NSError *error = nil;
        XCTAssertTrue([BKMeshIO writeMesh:cube toURL:url format:BKMeshFileFormatUnknown error:&error], @"%@", error);
        BKMesh *back = [BKMeshIO readMeshFromURL:url error:&error];
        XCTAssertNotNil(back, @"%@ %@", ext, error);
        XCTAssertEqualObjects(back.name, @"Guide");
        XCTAssertTrue(back.watertight, @"%@", ext);
        XCTAssertEqualWithAccuracy(back.enclosedVolume, 1.0, 1e-12, @"%@", ext);
    }
    // A misnamed file is still recognised from its content.
    NSURL *misnamed = [dir URLByAppendingPathComponent:@"scan.obj"];
    XCTAssertTrue([[BKMeshIO dataForMesh:cube format:BKMeshFileFormatPLY error:NULL] writeToURL:misnamed atomically:YES]);
    XCTAssertEqual([BKMeshIO readMeshFromURL:misnamed error:NULL].vertexCount, 8u);
    // Unknown extension when writing, missing file when reading.
    NSError *error = nil;
    XCTAssertFalse([BKMeshIO writeMesh:cube toURL:[dir URLByAppendingPathComponent:@"x.vtk"] format:BKMeshFileFormatUnknown error:&error]);
    XCTAssertEqual(error.code, BKMeshErrorUnknownFormat);
    error = nil;
    XCTAssertNil([BKMeshIO readMeshFromURL:[dir URLByAppendingPathComponent:@"missing.stl"] error:&error]);
    XCTAssertEqual(error.code, BKMeshErrorUnreadableFile);
}

#pragma mark - Reading files from other programs

- (void)testASCIISTL
{
    NSString *text = @"solid cube_corner\n"
        "  facet normal 0 0 -1\n    outer loop\n      vertex 0 0 0\n      vertex 0 1 0\n      vertex 1 0 0\n    endloop\n  endfacet\n"
        "  facet normal 0 0 -1\n    outer loop\n      vertex 1 0 0\n      vertex 0 1 0\n      vertex 1.5e0 1 0\n    endloop\n  endfacet\n"
        "endsolid cube_corner\n";
    NSError *error = nil;
    BKMesh *mesh = [BKMeshIO readMeshFromData:[self utf8:text] format:BKMeshFileFormatUnknown error:&error];
    XCTAssertNotNil(mesh, @"%@", error);
    XCTAssertEqual(mesh.triangleCount, 2u);
    XCTAssertEqual(mesh.vertexCount, 4u);   // the shared corners are merged
    XCTAssertEqualWithAccuracy(mesh.surfaceArea, 1.25, 1e-6);
}

// A binary STL whose header starts with "solid" (some exporters do this) is still binary.
- (void)testBinarySTLWithSolidHeader
{
    NSMutableData *data = [[BKMeshIO dataForMesh:[self unitCube] format:BKMeshFileFormatSTL error:NULL] mutableCopy];
    memcpy(data.mutableBytes, "solid binary", 12);
    BKMesh *mesh = [BKMeshIO readMeshFromData:data format:BKMeshFileFormatUnknown error:NULL];
    XCTAssertEqual(mesh.triangleCount, 12u);
    XCTAssertTrue(mesh.watertight);
}

// PLY as scanners write it: comments, extra properties and elements, quads, colours.
- (void)testPLYFromOtherSoftware
{
    NSString *text = @"ply\r\nformat ascii 1.0\r\ncomment made by a scanner\r\nobj_info test\r\n"
        "element vertex 4\r\nproperty double x\r\nproperty double y\r\nproperty double z\r\nproperty float quality\r\n"
        "property uchar red\r\nproperty uchar green\r\nproperty uchar blue\r\n"
        "element face 1\r\nproperty list uint8 int32 vertex_index\r\nproperty uchar flags\r\n"
        "element edge 1\r\nproperty int vertex1\r\nproperty int vertex2\r\n"
        "end_header\r\n"
        "0 0 0 0.5 255 0 0\r\n2 0 0 0.5 0 255 0\r\n2 2 0 0.5 0 0 255\r\n0 2 0 0.5 255 255 255\r\n"
        "4 0 1 2 3 7\r\n"
        "0 1\r\n";
    NSError *error = nil;
    BKMesh *mesh = [BKMeshIO readMeshFromData:[self utf8:text] format:BKMeshFileFormatUnknown error:&error];
    XCTAssertNotNil(mesh, @"%@", error);
    XCTAssertEqual(mesh.vertexCount, 4u);
    XCTAssertEqual(mesh.triangleCount, 2u);         // the quad is split in two
    XCTAssertEqualWithAccuracy(mesh.surfaceArea, 4.0, 1e-9);
    XCTAssertTrue(mesh.colors != NULL);
    XCTAssertTrue(simd_equal(mesh.colors[1], simd_make_float4(0, 1, 0, 1)));
    XCTAssertTrue(mesh.normals == NULL);
}

// Big-endian binary PLY (old workstations) with a float colour and a uint index list.
- (void)testPLYBigEndian
{
    NSMutableData *data = [[self utf8:@"ply\nformat binary_big_endian 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\n"
                            "element face 1\nproperty list uchar uint vertex_indices\nend_header\n"] mutableCopy];
    float coords[9] = {0, 0, 0, 3, 0, 0, 0, 4, 0};
    for (int i = 0; i < 9; i++) { uint32_t b; memcpy(&b, &coords[i], 4); b = CFSwapInt32HostToBig(b); [data appendBytes:&b length:4]; }
    uint8_t n = 3; [data appendBytes:&n length:1];
    for (uint32_t i = 0; i < 3; i++) { uint32_t b = CFSwapInt32HostToBig(i); [data appendBytes:&b length:4]; }
    NSError *error = nil;
    BKMesh *mesh = [BKMeshIO readMeshFromData:data format:BKMeshFileFormatUnknown error:&error];
    XCTAssertNotNil(mesh, @"%@", error);
    XCTAssertEqualWithAccuracy(mesh.surfaceArea, 6.0, 1e-9);
}

// OBJ as other programs write it: quads, texture coordinates, negative (relative)
// numbers, groups and materials (ignored), and a vertex used with two normals.
- (void)testOBJFromOtherSoftware
{
    NSString *cubeWithQuads = @"# cube\nmtllib x.mtl\no Cube\n"
        "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nv 0 0 1\nv 1 0 1\nv 0 1 1\nv 1 1 1\n"
        "vt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\ng sides\nusemtl bone\ns off\n"
        "f 1/1 3/2 4/3 2/4\nf 5 6 8 7\nf 1 2 6 5\nf 3 7 8 4\nf -8 -4 -2 -6\nf 2 4 8 6\n";
    NSError *error = nil;
    BKMesh *cube = [BKMeshIO readMeshFromData:[self utf8:cubeWithQuads] format:BKMeshFileFormatUnknown error:&error];
    XCTAssertNotNil(cube, @"%@", error);
    XCTAssertEqual(cube.triangleCount, 12u);
    XCTAssertTrue(cube.watertight);
    XCTAssertEqualWithAccuracy(cube.enclosedVolume, 1.0, 1e-12);

    // Vertex 1 is used with normal 1 and with normal 2: it is copied for the second use.
    NSString *sharp = @"v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nvn 0 0 1\nvn 0 1 0\n"
        "f 1//1 2//1 3//1\nf 1//2 4//2 2//2\n";
    BKMesh *mesh = [BKMeshIO readMeshFromData:[self utf8:sharp] format:BKMeshFileFormatOBJ error:&error];
    XCTAssertNotNil(mesh, @"%@", error);
    XCTAssertEqual(mesh.vertexCount, 6u);   // 4 + copies of vertices 1 and 2
    XCTAssertTrue(simd_equal(mesh.normals[0], simd_make_float3(0, 0, 1)));
    XCTAssertTrue(simd_equal(mesh.normals[mesh.indices[3]], simd_make_float3(0, 1, 0)));
}

#pragma mark - Damaged files

// Each damaged file must give an error (never a crash, never a mesh).
- (void)testMalformedFilesReturnErrors
{
    NSData *stl = [BKMeshIO dataForMesh:[self unitCube] format:BKMeshFileFormatSTL error:NULL];
    NSMutableData *hugeCount = [stl mutableCopy];
    uint32_t big = 0xFFFFFFFF;
    [hugeCount replaceBytesInRange:NSMakeRange(80, 4) withBytes:&big];
    NSMutableData *nanSTL = [stl mutableCopy];
    float nan = NAN;
    [nanSTL replaceBytesInRange:NSMakeRange(84 + 12, 4) withBytes:&nan];

    NSDictionary<NSString *, NSArray *> *cases = @{
        @"empty":                @[[NSData data], @(BKMeshFileFormatUnknown)],
        @"random bytes":         @[[NSData dataWithBytes:"\x01\x02\x03\xff\x00garbage" length:12], @(BKMeshFileFormatUnknown)],
        @"STL too short":        @[[NSData dataWithBytes:"abc" length:3], @(BKMeshFileFormatSTL)],
        @"STL cut short":        @[[stl subdataWithRange:NSMakeRange(0, stl.length - 7)], @(BKMeshFileFormatSTL)],
        @"STL huge count":       @[hugeCount, @(BKMeshFileFormatSTL)],
        @"STL NaN":              @[nanSTL, @(BKMeshFileFormatSTL)],
        @"ASCII STL bad vertex": @[[self utf8:@"solid x\nfacet normal 0 0 1\nouter loop\nvertex 0 0 zero\n"], @(BKMeshFileFormatUnknown)],
        @"ASCII STL 4 corners":  @[[self utf8:@"solid x\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nvertex 1 1 1\nendsolid\n"], @(BKMeshFileFormatUnknown)],
        @"PLY no end_header":    @[[self utf8:@"ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\n"], @(BKMeshFileFormatUnknown)],
        @"PLY no format":        @[[self utf8:@"ply\nelement vertex 0\nend_header\n"], @(BKMeshFileFormatUnknown)],
        @"PLY bad type":         @[[self utf8:@"ply\nformat ascii 1.0\nelement vertex 1\nproperty float128 x\nend_header\n1\n"], @(BKMeshFileFormatUnknown)],
        @"PLY no xyz":           @[[self utf8:@"ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nend_header\n1\n"], @(BKMeshFileFormatUnknown)],
        @"PLY huge count":       @[[self utf8:@"ply\nformat binary_little_endian 1.0\nelement vertex 4000000000\nproperty float x\nproperty float y\nproperty float z\nend_header\n\x01\x02"], @(BKMeshFileFormatUnknown)],
        @"PLY negative count":   @[[self utf8:@"ply\nformat ascii 1.0\nelement vertex -3\nproperty float x\nend_header\n"], @(BKMeshFileFormatUnknown)],
        @"PLY cut short":        @[[self utf8:@"ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nend_header\n0 0 0\n1 0 0\n"], @(BKMeshFileFormatUnknown)],
        @"PLY bad index":        @[[self utf8:@"ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n1 0 0\n0 1 0\n3 0 1 9\n"], @(BKMeshFileFormatUnknown)],
        @"PLY negative index":   @[[self utf8:@"ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n1 0 0\n0 1 0\n3 0 1 -1\n"], @(BKMeshFileFormatUnknown)],
        @"PLY huge list":        @[[self utf8:@"ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uint int vertex_indices\nend_header\n0 0 0\n1 0 0\n0 1 0\n4000000000 0 1 2\n"], @(BKMeshFileFormatUnknown)],
        @"PLY text garbage":     @[[self utf8:@"ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nend_header\n1 2 three\n"], @(BKMeshFileFormatUnknown)],
        @"OBJ missing vertex":   @[[self utf8:@"v 0 0 0\nv 1 0 0\nf 1 2 3\n"], @(BKMeshFileFormatUnknown)],
        @"OBJ index zero":       @[[self utf8:@"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 0 1 2\n"], @(BKMeshFileFormatUnknown)],
        @"OBJ bad relative":     @[[self utf8:@"v 0 0 0\nv 1 0 0\nv 0 1 0\nf -1 -2 -9\n"], @(BKMeshFileFormatUnknown)],
        @"OBJ bad vertex":       @[[self utf8:@"v 0 x 0\nf 1 1 1\n"], @(BKMeshFileFormatUnknown)],
        @"OBJ two corners":      @[[self utf8:@"v 0 0 0\nv 1 0 0\nf 1 2\n"], @(BKMeshFileFormatUnknown)],
        @"OBJ missing normal":   @[[self utf8:@"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1//1 2//1 3//1\n"], @(BKMeshFileFormatUnknown)],
        @"OBJ bad corner":       @[[self utf8:@"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1/a 2 3\n"], @(BKMeshFileFormatUnknown)],
    };
    for (NSString *name in cases) {
        NSError *error = nil;
        BKMesh *mesh = [BKMeshIO readMeshFromData:cases[name][0] format:[cases[name][1] integerValue] error:&error];
        XCTAssertNil(mesh, @"%@ should fail", name);
        XCTAssertNotNil(error, @"%@ should explain why", name);
        XCTAssertEqualObjects(error.domain, BKMeshErrorDomain, @"%@", name);
        XCTAssertGreaterThan(error.localizedDescription.length, 10u, @"%@", name);
    }
}

// Every possible cut-off point and many random byte changes in every format: the
// reader may succeed or fail, but must never crash or return a mesh with bad indices
// (BKMesh re-checks everything, so a returned mesh is always safe to draw).
- (void)testTruncatedAndCorruptedFilesNeverCrash
{
    BKMesh *mesh = [self awkwardMesh];
    BKMesh *small = [BKMesh sphereMeshWithCenter:simd_make_float3(0, 0, 0) radius:1 subdivisions:0];
    [small setColors:mesh.colors];   // 12 vertices: the first 12 colours
    srand48(42);
    for (NSNumber *format in @[@(BKMeshFileFormatSTL), @(BKMeshFileFormatPLY), @(BKMeshFileFormatPLYASCII), @(BKMeshFileFormatOBJ)]) {
        NSData *good = [BKMeshIO dataForMesh:small format:format.integerValue error:NULL];
        for (NSUInteger cut = 0; cut < good.length; cut++)
            @autoreleasepool { (void)[BKMeshIO readMeshFromData:[good subdataWithRange:NSMakeRange(0, cut)] format:BKMeshFileFormatUnknown error:NULL]; }
        for (int trial = 0; trial < 500; trial++) @autoreleasepool {
            NSMutableData *bad = [good mutableCopy];
            uint8_t *b = bad.mutableBytes;
            for (int k = 0; k < 4; k++) b[(NSUInteger)(drand48() * bad.length)] = (uint8_t)(drand48() * 256);
            BKMesh *m = [BKMeshIO readMeshFromData:bad format:BKMeshFileFormatUnknown error:NULL];
            for (NSUInteger i = 0; m && i < m.triangleCount * 3; i++) XCTAssertLessThan(m.indices[i], m.vertexCount);
        }
    }
}

@end
