// Tests for BKSceneExport (OBJ+MTL, VRML 2.0, Inventor 2.1, RenderMan RIB scene files).
// Original BorosKit code written for this project; contains no third-party code.
//
// What is checked, in plain terms: a scene of two boxes (one moved, one mirrored and
// moved) plus a line set is written in every format; the files are read back with
// small counting readers: number of points / faces / materials, the points are in
// world millimetres, the mirrored box still faces outwards (positive volume), the OBJ
// material names match the .mtl, and BKMeshIO re-reads the OBJ. A 5-million-triangle
// export is timed for each format (logged, no strict limits).

#import <XCTest/XCTest.h>
#import "BorosKitMesh.h"

@interface BKSceneExportTests : XCTestCase
@end

@implementation BKSceneExportTests

// What: a temporary file URL for this test run.
- (NSURL *)tempURL:(NSString *)name
{
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"BKSceneExportTests"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
}

static simd_float4x4 BKTranslate(float x, float y, float z)
{
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(x, y, z, 1);
    return m;
}

// Box A: unit box moved by (10,0,0). Box B: unit box mirrored in x then moved by (0,20,0).
- (BKSceneExport *)smallScene
{
    BKSceneExport *scene = [BKSceneExport new];
    BKMesh *a = [BKMesh boxMeshWithMin:simd_make_float3(0, 0, 0) max:simd_make_float3(1, 1, 1)];
    [a computeSmoothNormals];
    BKSceneMaterial m = BKSceneMaterialDefault();
    m.color = simd_make_float3(1, 0, 0);
    [scene addMesh:a transform:BKTranslate(10, 0, 0) material:m name:@"Box A"];
    BKMesh *b = [BKMesh boxMeshWithMin:simd_make_float3(0, 0, 0) max:simd_make_float3(1, 1, 1)];
    simd_float4x4 mirror = BKTranslate(0, 20, 0);
    mirror.columns[0] = simd_make_float4(-1, 0, 0, 0);
    m.color = simd_make_float3(0, 0, 1); m.opacity = 0.5f;
    [scene addMesh:b transform:mirror material:m name:@"Box B"];
    simd_float3 pts[4] = {{0, 0, 0}, {5, 0, 0}, {0, 0, 0}, {0, 5, 0}};
    [scene addLineSegments:pts count:4 transform:matrix_identity_float4x4 color:simd_make_float3(0, 1, 0)
                   opacity:1 lineWidth:2 name:@"Axes"];
    [scene setPerspectiveCameraWithPosition:simd_make_double3(0, -200, 0) focalPoint:simd_make_double3(0, 0, 0)
                                     viewUp:simd_make_double3(0, 0, 1) viewAngle:30];
    scene.backgroundColor = simd_make_float3(0.1f, 0.1f, 0.1f);
    scene.title = @"Test scene";
    return scene;
}

// What: all numbers inside the first "[ ... ]" after `key` (starting at `from`).
static NSArray<NSNumber *> *BKNumbersAfter(NSString *text, NSString *key, NSUInteger *from)
{
    NSRange r = [text rangeOfString:key options:0 range:NSMakeRange(*from, text.length - *from)];
    if (r.location == NSNotFound) return nil;
    NSRange open = [text rangeOfString:@"[" options:0 range:NSMakeRange(NSMaxRange(r), text.length - NSMaxRange(r))];
    NSRange close = [text rangeOfString:@"]" options:0 range:NSMakeRange(NSMaxRange(open), text.length - NSMaxRange(open))];
    *from = NSMaxRange(close);
    NSString *inner = [text substringWithRange:NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))];
    NSMutableArray *out = [NSMutableArray array];
    NSScanner *s = [NSScanner scannerWithString:[inner stringByReplacingOccurrencesOfString:@"," withString:@" "]];
    double v;
    while ([s scanDouble:&v]) [out addObject:@(v)];
    return out;
}

// What: signed volume of triangles (flat list of indices into flat xyz list).
static double BKVolume(NSArray<NSNumber *> *xyz, NSArray<NSNumber *> *tri)
{
    double vol = 0;
    for (NSUInteger t = 0; t + 2 < tri.count; t += 3) {
        simd_double3 p[3];
        for (int j = 0; j < 3; j++) {
            NSUInteger i = tri[t + j].unsignedIntegerValue;
            p[j] = simd_make_double3(xyz[3 * i].doubleValue, xyz[3 * i + 1].doubleValue, xyz[3 * i + 2].doubleValue);
        }
        vol += simd_dot(p[0], simd_cross(p[1], p[2])) / 6.0;
    }
    return vol;
}

// Removes the "-1" face terminators of a VRML / Inventor coordIndex list.
static NSArray<NSNumber *> *BKWithoutTerminators(NSArray<NSNumber *> *list)
{
    return [list filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"intValue >= 0"]];
}

- (void)checkBoxesInText:(NSString *)text pointsKey:(NSString *)pointsKey facesKey:(NSString *)facesKey
{
    NSUInteger from = 0;
    for (int box = 0; box < 2; box++) {
        NSArray *xyz = BKNumbersAfter(text, pointsKey, &from);
        NSArray *faces = BKNumbersAfter(text, facesKey, &from);
        XCTAssertEqual(xyz.count, 24u);
        XCTAssertEqual(BKWithoutTerminators(faces).count, 36u);
        double minX = 1e9;
        for (NSUInteger i = 0; i < xyz.count; i += 3) minX = MIN(minX, [xyz[i] doubleValue]);
        XCTAssertEqualWithAccuracy(minX, box == 0 ? 10.0 : -1.0, 1e-6, @"world coordinates");
        XCTAssertEqualWithAccuracy(BKVolume(xyz, BKWithoutTerminators(faces)), 1.0, 1e-5, @"box %d faces outward", box);
    }
}

- (void)testOBJ
{
    NSURL *url = [self tempURL:@"scene test.obj"];
    NSError *error = nil;
    XCTAssertTrue([[self smallScene] writeToURL:url format:BKSceneFileFormatUnknown error:&error], @"%@", error);
    NSURL *mtlURL = [BKSceneExport materialLibraryURLForOBJURL:url];
    XCTAssertEqualObjects(mtlURL.lastPathComponent, @"scene_test.mtl");
    NSString *obj = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    NSString *mtl = [NSString stringWithContentsOfURL:mtlURL encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue([obj containsString:@"mtllib scene_test.mtl\n"]);
    NSMutableArray *verts = [NSMutableArray array], *faces = [NSMutableArray array];
    NSMutableSet *used = [NSMutableSet set], *defined = [NSMutableSet set];
    NSUInteger lines = 0;
    for (NSString *line in [obj componentsSeparatedByString:@"\n"]) {
        NSArray *w = [line componentsSeparatedByString:@" "];
        if ([w[0] isEqual:@"v"]) for (int i = 1; i <= 3; i++) [verts addObject:@([w[i] doubleValue])];
        if ([w[0] isEqual:@"f"]) for (int i = 1; i <= 3; i++) [faces addObject:@([w[i] integerValue] - 1)];
        if ([w[0] isEqual:@"l"]) lines++;
        if ([w[0] isEqual:@"usemtl"]) [used addObject:w[1]];
    }
    for (NSString *line in [mtl componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"newmtl "]) [defined addObject:[line substringFromIndex:7]];
    XCTAssertEqual(verts.count / 3, 8u + 8u + 4u);
    XCTAssertEqual(faces.count, 72u);
    XCTAssertEqual(lines, 2u);
    XCTAssertEqual(defined.count, 3u);
    XCTAssertEqualObjects(used, defined, @"OBJ material names match the .mtl");
    XCTAssertTrue([mtl containsString:@"d 0.5"]);
    // Both boxes outward: total volume 2.
    XCTAssertEqualWithAccuracy(BKVolume(verts, faces), 2.0, 1e-5);
    BKMesh *back = [BKMeshIO readMeshFromURL:url error:&error];
    XCTAssertNotNil(back, @"%@", error);
    XCTAssertEqual(back.vertexCount, 20u);
    XCTAssertEqual(back.triangleCount, 24u);
}

- (void)testVRML
{
    NSURL *url = [self tempURL:@"scene.wrl"];
    NSError *error = nil;
    XCTAssertTrue([[self smallScene] writeToURL:url format:BKSceneFileFormatUnknown error:&error], @"%@", error);
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue([text hasPrefix:@"#VRML V2.0 utf8\n"]);
    XCTAssertTrue([text containsString:@"DEF Box_A Shape"]);
    XCTAssertTrue([text containsString:@"transparency 0.5"]);
    XCTAssertTrue([text containsString:@"IndexedLineSet"]);
    XCTAssertTrue([text containsString:@"skyColor"]);
    [self checkBoxesInText:text pointsKey:@"point" facesKey:@"coordIndex"];
    // Viewpoint orientation turns the default view (-z) into our view (+y).
    NSRange r = [text rangeOfString:@"orientation "];
    NSScanner *s = [NSScanner scannerWithString:[text substringFromIndex:NSMaxRange(r)]];
    double ax, ay, az, angle;
    [s scanDouble:&ax]; [s scanDouble:&ay]; [s scanDouble:&az]; [s scanDouble:&angle];
    simd_double3 k = simd_make_double3(ax, ay, az), v = simd_make_double3(0, 0, -1);
    simd_double3 rotated = v * cos(angle) + simd_cross(k, v) * sin(angle) + k * simd_dot(k, v) * (1 - cos(angle));
    XCTAssertEqualWithAccuracy(rotated.y, 1.0, 1e-5);
}

- (void)testInventor
{
    NSURL *url = [self tempURL:@"scene.iv"];
    NSError *error = nil;
    XCTAssertTrue([[self smallScene] writeToURL:url format:BKSceneFileFormatUnknown error:&error], @"%@", error);
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue([text hasPrefix:@"#Inventor V2.1 ascii\n"]);
    XCTAssertTrue([text containsString:@"PerspectiveCamera"]);
    XCTAssertTrue([text containsString:@"DrawStyle { lineWidth 2 }"]);
    XCTAssertEqual([text componentsSeparatedByString:@"{"].count, [text componentsSeparatedByString:@"}"].count, @"braces balance");
    [self checkBoxesInText:text pointsKey:@"Coordinate3" facesKey:@"coordIndex"];
}

- (void)testRIB
{
    NSURL *url = [self tempURL:@"scene.rib"];
    NSError *error = nil;
    XCTAssertTrue([[self smallScene] writeToURL:url format:BKSceneFileFormatUnknown error:&error], @"%@", error);
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue([text containsString:@"Projection \"perspective\""]);
    XCTAssertTrue([text containsString:@"WorldBegin"] && [text containsString:@"WorldEnd"]);
    XCTAssertTrue([text containsString:@"Curves \"linear\""]);
    XCTAssertEqual([text componentsSeparatedByString:@"PointsPolygons"].count, 3u);
    // RIB lists faces before points: read both per object.
    NSUInteger from = 0;
    for (int box = 0; box < 2; box++) {
        NSArray *nverts = BKNumbersAfter(text, @"PointsPolygons", &from);
        // The corner list is the very next [ ... ] after the corners-per-face list.
        NSUInteger at = from - 1;
        NSArray *faces = BKNumbersAfter(text, @"]", &at);
        NSArray *xyz = BKNumbersAfter(text, @"\"P\"", &at);
        from = at;
        XCTAssertEqual(nverts.count, 12u);
        XCTAssertEqual(faces.count, 36u);
        XCTAssertEqual(xyz.count, 24u);
        XCTAssertEqualWithAccuracy(BKVolume(xyz, faces), 1.0, 1e-5);
    }
}

- (void)testBadPlacementIsRefused
{
    BKSceneExport *scene = [BKSceneExport new];
    simd_float4x4 flat = matrix_identity_float4x4;
    flat.columns[2] = simd_make_float4(0, 0, 0, 0);
    [scene addMesh:[BKMesh boxMeshWithMin:simd_make_float3(0, 0, 0) max:simd_make_float3(1, 1, 1)] transform:flat
          material:BKSceneMaterialDefault() name:@"Flat"];
    NSError *error = nil;
    XCTAssertFalse([scene writeToURL:[self tempURL:@"bad.wrl"] format:BKSceneFileFormatVRML error:&error]);
    XCTAssertEqual(error.code, BKMeshErrorInvalidGeometry);
}

- (void)testTiming5MillionTriangles
{
    // A subdivided sphere: 20 * 4^6 = 81920 triangles; 61 copies ~ 5 million.
    BKMesh *sphere = [BKMesh sphereMeshWithCenter:simd_make_float3(0, 0, 0) radius:20 subdivisions:6];
    BKSceneExport *scene = [BKSceneExport new];
    for (int i = 0; i < 61; i++)
        [scene addMesh:sphere transform:BKTranslate(50 * i, 0, 0) material:BKSceneMaterialDefault() name:@"Ball"];
    NSArray *names = @[@"big.obj", @"big.wrl", @"big.iv", @"big.rib"];
    for (NSString *name in names) {
        NSURL *url = [self tempURL:name];
        NSDate *t0 = [NSDate date];
        NSError *error = nil;
        XCTAssertTrue([scene writeToURL:url format:BKSceneFileFormatUnknown error:&error], @"%@", error);
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
        NSLog(@"BKSceneExport timing: %@ %lu triangles in %.0f ms (%.0f MB)", name, (unsigned long)(61 * sphere.triangleCount),
              -[t0 timeIntervalSinceNow] * 1000, [attrs fileSize] / 1e6);
        [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:nil];
    }
}

@end
