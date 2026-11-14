// BorosKitGoldenTests: the golden-output harness (Metal runner).
// Original BorosKit code written for this project; contains no third-party code.
//
// What it does, in plain words: builds fixed synthetic scans ("phantoms"), runs every
// GPU operation of BorosKit on them with fixed settings, and compares the results with
// reference files recorded earlier ("golden" outputs). Today the references are made by
// the Metal backend; a future Vulkan backend will be checked against the SAME files
// with the same tolerances, which is how we prove it draws the same pictures and builds
// the same surfaces.
//
// Two modes:
//   compare (default):  swift test -c release --filter BKGoldenTests
//   record (rewrite the reference files after an intended change):
//                       BK_GOLDEN_RECORD=1 swift test -c release --filter BKGoldenTests
//   strict compare (zero tolerance; use to prove a refactor changes NOTHING):
//                       BK_GOLDEN_STRICT=1 swift test -c release --filter BKGoldenTests
// The reference files live in Tests/BorosKitGoldenTests/References (found from this
// source file's path; BK_GOLDEN_REFERENCES=/some/dir overrides it). MANIFEST.txt there
// lists every file with its size and hash.
//
// Tolerances (agreed with the user):
//   - 8-bit images: every channel within +-1 grey level, except at most 0.5% of channels
//     (edge pixels, where a different GPU may round a sharp edge the other way);
//   - float images: HU values within 1 HU, opacity within 1/255, ray distances within
//     0.01 mm, with the same 0.5% allowance;
//   - meshes: identical counts and triangle lists, positions within 1e-4 voxel, normals
//     within 1e-3;
//   - scene export files: byte-identical;
//   - numbers: within 1e-9 + 1e-6 relative.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BKGoldenCore.h"
#import "BKGoldenMetal.h"
#import "BorosKitRender.h"
#import "BorosKitMesh.h"
#import "BorosKitSurface.h"

#pragma mark - Mode and paths

// What: YES when the reference files should be (re)written instead of compared.
static BOOL BKGoldenRecording(void)
{
    const char *v = getenv("BK_GOLDEN_RECORD");
    return v && strcmp(v, "1") == 0;
}

// What: YES for zero-tolerance comparisons. Why: proves a refactor is bit-identical.
static BOOL BKGoldenStrict(void)
{
    const char *v = getenv("BK_GOLDEN_STRICT");
    return v && strcmp(v, "1") == 0;
}

// What: the reference directory: next to this source file, unless overridden.
static NSString *BKGoldenReferenceDirectory(void)
{
    const char *v = getenv("BK_GOLDEN_REFERENCES");
    if (v && *v) return @(v);
    return [[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"References"];
}

static NSString *BKGoldenPath(NSString *fileName)
{
    return [BKGoldenReferenceDirectory() stringByAppendingPathComponent:fileName];
}

// What: rewrites MANIFEST.txt (every reference file with byte size and hash).
// Why: a quick human-readable overview, and a way to see at a glance which references an
// intended change touched (git diff of the manifest).
static void BKGoldenWriteManifest(void)
{
    NSString *dir = BKGoldenReferenceDirectory();
    NSArray<NSString *> *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]
                                  sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *text = [NSMutableString stringWithString:
        @"# BorosKit golden references (recorded from the Metal backend).\n"
        @"# file  bytes  hash (bk_golden_hash, hex)\n"];
    unsigned long long total = 0;
    for (NSString *name in names) {
        if ([name isEqualToString:@"MANIFEST.txt"] || [name hasPrefix:@"."]) continue;
        uint8_t *bytes = NULL;
        size_t size = 0;
        if (bk_golden_read_file([dir stringByAppendingPathComponent:name].fileSystemRepresentation, &bytes, &size) != 0) continue;
        [text appendFormat:@"%@  %zu  %016llx\n", name, size, (unsigned long long)bk_golden_hash(bytes, size)];
        total += size;
        free(bytes);
    }
    [text appendFormat:@"# total %llu bytes\n", total];
    [text writeToFile:[dir stringByAppendingPathComponent:@"MANIFEST.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - Shared fixture

// The phantom and the producer are built once for all tests (building takes ~0.1 s,
// compiling the GPU programs a little longer).
static BKGoldenVolume gPhantom;
static BOOL gPhantomReady;
static BKGoldenMetalProducer *gProducer;

@interface BKGoldenTests : XCTestCase
@end

@implementation BKGoldenTests

+ (void)setUp
{
    [super setUp];
    if (!gPhantomReady) gPhantomReady = bk_golden_make_head_phantom(&gPhantom) == 0;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device && gPhantomReady && !gProducer) gProducer = [[BKGoldenMetalProducer alloc] initWithDevice:device volume:&gPhantom error:NULL];
    if (BKGoldenRecording())
        [[NSFileManager defaultManager] createDirectoryAtPath:BKGoldenReferenceDirectory() withIntermediateDirectories:YES attributes:nil error:NULL];
}

+ (void)tearDown
{
    if (BKGoldenRecording()) BKGoldenWriteManifest();
    [super tearDown];
}

// What: skips the test without a GPU (e.g. a headless build machine).
- (BOOL)requireGPU
{
    XCTAssertTrue(gPhantomReady, @"phantom could not be built");
    if (gProducer) return YES;
    XCTSkip(@"No Metal GPU available");
    return NO;
}

#pragma mark - Comparison helpers

// What: records or compares one image. `pfm` = float image (else PAM).
- (void)checkImage:(const BKGoldenImage *)image file:(NSString *)file tolerance:(BKGoldenImageTolerance)tolerance
{
    NSString *path = BKGoldenPath(file);
    BOOL pfm = image->format == BKGoldenFormatF32;
    if (BKGoldenRecording()) {
        int ok = pfm ? bk_golden_write_pfm(path.fileSystemRepresentation, image) : bk_golden_write_pam(path.fileSystemRepresentation, image);
        XCTAssertEqual(ok, 0, @"could not write %@", path);
        return;
    }
    BKGoldenImage reference;
    int ok = pfm ? bk_golden_read_pfm(path.fileSystemRepresentation, &reference) : bk_golden_read_pam(path.fileSystemRepresentation, &reference);
    XCTAssertEqual(ok, 0, @"missing or unreadable reference %@ (record with BK_GOLDEN_RECORD=1)", file);
    if (ok != 0) return;
    if (BKGoldenStrict()) tolerance = (BKGoldenImageTolerance){0.0, 0.0};
    BKGoldenImageReport report = bk_golden_compare_images(&reference, image, tolerance);
    char text[256];
    bk_golden_describe_image_report(&report, text, sizeof text);
    NSLog(@"GOLDEN | %@ | %s", file, text);
    XCTAssertTrue(report.pass, @"%@: %s", file, text);
    bk_golden_image_free(&reference);
}

// What: records or compares one mesh (also logs its plain measurements).
- (void)checkMesh:(const BKGoldenMesh *)mesh file:(NSString *)file
{
    NSString *path = BKGoldenPath(file);
    BKGoldenMeshSummary s = bk_golden_mesh_summary(mesh);
    NSLog(@"GOLDEN | %@ | %llu vertices, %llu triangles, area %.3f mm2, volume %.3f mm3, bounds (%.3f %.3f %.3f)-(%.3f %.3f %.3f), hash %016llx",
          file, s.vertexCount, s.triangleCount, s.area, s.volume, s.boundsMin[0], s.boundsMin[1], s.boundsMin[2],
          s.boundsMax[0], s.boundsMax[1], s.boundsMax[2], s.quantizedHash);
    if (BKGoldenRecording()) {
        XCTAssertEqual(bk_golden_write_mesh(path.fileSystemRepresentation, mesh), 0, @"could not write %@", path);
        return;
    }
    BKGoldenMesh reference;
    int ok = bk_golden_read_mesh(path.fileSystemRepresentation, &reference);
    XCTAssertEqual(ok, 0, @"missing or unreadable reference %@ (record with BK_GOLDEN_RECORD=1)", file);
    if (ok != 0) return;
    BKGoldenMeshTolerance tolerance = {{gPhantom.spacing[0], gPhantom.spacing[1], gPhantom.spacing[2]}, 1e-4, 1e-3};
    if (BKGoldenStrict()) { tolerance.maxPositionVoxels = 0; tolerance.maxNormalDiff = 0; }
    BKGoldenMeshReport report = bk_golden_compare_meshes(&reference, mesh, tolerance);
    char text[256];
    bk_golden_describe_mesh_report(&report, text, sizeof text);
    NSLog(@"GOLDEN | %@ | %s", file, text);
    XCTAssertTrue(report.pass, @"%@: %s", file, text);
    // The plain measurements must agree too (a second, independent view of the same thing).
    BKGoldenMeshSummary r = bk_golden_mesh_summary(&reference);
    XCTAssertTrue(bk_golden_numbers_close(s.area, r.area, 1e-6, 1e-5), @"%@ area %.6f vs %.6f", file, s.area, r.area);
    XCTAssertTrue(bk_golden_numbers_close(s.volume, r.volume, 1e-6, 1e-5), @"%@ volume %.6f vs %.6f", file, s.volume, r.volume);
    bk_golden_mesh_free(&reference);
}

// What: records or compares a list of named numbers.
- (void)checkNumbers:(const BKGoldenNumber *)numbers count:(size_t)count file:(NSString *)file
{
    NSString *path = BKGoldenPath(file);
    if (BKGoldenRecording()) {
        XCTAssertEqual(bk_golden_write_numbers(path.fileSystemRepresentation, numbers, count), 0, @"could not write %@", path);
        return;
    }
    BKGoldenNumber *reference = NULL;
    size_t referenceCount = 0;
    XCTAssertEqual(bk_golden_read_numbers(path.fileSystemRepresentation, &reference, &referenceCount), 0,
                   @"missing reference %@ (record with BK_GOLDEN_RECORD=1)", file);
    XCTAssertEqual(referenceCount, count, @"%@: number of values changed", file);
    double absTol = BKGoldenStrict() ? 0 : 1e-9, relTol = BKGoldenStrict() ? 0 : 1e-6;
    for (size_t i = 0; i < MIN(count, referenceCount); i++) {
        XCTAssertEqual(strcmp(numbers[i].name, reference[i].name), 0, @"%@: value %zu is %s, expected %s", file, i, numbers[i].name, reference[i].name);
        XCTAssertTrue(bk_golden_numbers_close(numbers[i].value, reference[i].value, absTol, relTol),
                      @"%@: %s = %.17g, reference %.17g", file, numbers[i].name, numbers[i].value, reference[i].value);
    }
    free(reference);
}

// What: records or compares a file byte for byte.
- (void)checkBytes:(NSData *)data file:(NSString *)file
{
    NSString *path = BKGoldenPath(file);
    if (BKGoldenRecording()) {
        XCTAssertTrue([data writeToFile:path atomically:YES], @"could not write %@", path);
        return;
    }
    NSData *reference = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(reference, @"missing reference %@ (record with BK_GOLDEN_RECORD=1)", file);
    XCTAssertEqualObjects(data, reference, @"%@ differs from the reference (%lu vs %lu bytes)", file,
                          (unsigned long)data.length, (unsigned long)reference.length);
    NSLog(@"GOLDEN | %@ | %s (%lu bytes)", file, [data isEqualToData:reference] ? "identical" : "DIFFERENT", (unsigned long)data.length);
}

// What: the reference version of a mesh if one exists (compare mode), else `fresh`.
// Why: the CPU mesh steps and the mesh render are checked on the REFERENCE surface, so a
// small difference in surface extraction (e.g. on another backend) cannot cascade into
// failures of the later, independent steps.
- (BKMesh *)referenceMeshFile:(NSString *)file orFresh:(BKMesh *)fresh
{
    if (BKGoldenRecording()) return fresh;
    BKGoldenMesh m;
    if (bk_golden_read_mesh(BKGoldenPath(file).fileSystemRepresentation, &m) != 0) return fresh;
    BKMesh *mesh = BKMeshFromGoldenMesh(&m);
    bk_golden_mesh_free(&m);
    return mesh ?: fresh;
}

#pragma mark - Phantom

// The phantom itself: its hash and simple statistics. A Vulkan port first checks that its
// copy of bk_golden_make_head_phantom produces exactly this (same hash).
- (void)testPhantom
{
    XCTAssertTrue(gPhantomReady);
    size_t count = (size_t)gPhantom.width * gPhantom.height * gPhantom.depth;
    double sum = 0, lo = INFINITY, hi = -INFINITY;
    BOOL whole = YES;
    for (size_t i = 0; i < count; i++) {
        double v = gPhantom.voxels[i];
        sum += v;
        lo = fmin(lo, v);
        hi = fmax(hi, v);
        whole = whole && v == floor(v);
    }
    XCTAssertTrue(whole, @"phantom values must be whole HU");
    XCTAssertGreaterThanOrEqual(lo, -1024.0);
    XCTAssertLessThanOrEqual(hi, 3071.0);
    // Spot checks of the known contents (noise is 15 HU, so +-80 HU is generous).
    // Voxel of patient point p: (p - origin) / spacing.
    double (^at)(double, double, double) = ^double(double x, double y, double z) {
        int i = (int)floor((x - gPhantom.origin[0]) / gPhantom.spacing[0] + 0.5);
        int j = (int)floor((y - gPhantom.origin[1]) / gPhantom.spacing[1] + 0.5);
        int k = (int)floor((z - gPhantom.origin[2]) / gPhantom.spacing[2] + 0.5);
        return gPhantom.voxels[((size_t)k * gPhantom.height + (size_t)j) * gPhantom.width + (size_t)i];
    };
    XCTAssertEqualWithAccuracy(at(10, 6, 8), 1000, 80);      // bone ball centre
    XCTAssertEqualWithAccuracy(at(-12, -8, 6), -100, 80);    // fat ball
    XCTAssertEqualWithAccuracy(at(0, 0, 0), 40, 80);         // soft tissue
    XCTAssertEqualWithAccuracy(at(-31, -31, -29), -1000, 80); // air corner
    XCTAssertEqualWithAccuracy(at(14, 4, 0), 400, 80);       // cylinder
    // Jaw tube and nerve canal at voxel centres of slice 19 (z = -5.625 mm, 0.375 mm from
    // the tube's plane); the curve passes through (0, -18).
    XCTAssertEqualWithAccuracy(at(0.5, -15.5, -5.625), 1500, 80);   // tube wall
    XCTAssertEqualWithAccuracy(at(0.5, -17.5, -5.625), 300, 80);    // nerve canal

    BKGoldenNumber numbers[] = {
        {"phantom_hash_low32", (double)(bk_golden_hash(gPhantom.voxels, count * sizeof(float)) & 0xFFFFFFFFu)},
        {"phantom_hash_high32", (double)(bk_golden_hash(gPhantom.voxels, count * sizeof(float)) >> 32)},
        {"phantom_min", lo}, {"phantom_max", hi}, {"phantom_mean", sum / (double)count},
        {"noise_first_value", bk_golden_noise(BK_GOLDEN_HEAD_SEED, 0)},
    };
    [self checkNumbers:numbers count:sizeof numbers / sizeof numbers[0] file:@"numbers_phantom.txt"];
}

#pragma mark - Volume rendering

- (void)testVolumeRenders
{
    if (![self requireGPU]) return;
    for (uint32_t i = 0; i < kBKGoldenVolumeCaseCount; i++) {
        const BKGoldenVolumeCase *c = &kBKGoldenVolumeCases[i];
        BKGoldenImage rgba = {0}, values = {0};
        NSError *error = nil;
        XCTAssertTrue([gProducer renderVolumeCase:c rgba:&rgba values:&values error:&error], @"%s: %@", c->name, error);
        if (!rgba.data) continue;
        NSString *name = @(c->name);
        [self checkImage:&rgba file:[name stringByAppendingString:@".rgba.pam"] tolerance:bk_golden_tolerance_u8()];
        // Composite: accumulated opacity 0...1 (one 8-bit step); projections: HU (1 HU).
        BKGoldenImageTolerance valueTolerance = {c->mode == 0 ? 1.0 / 255.0 : 1.0, 0.005};
        [self checkImage:&values file:[name stringByAppendingString:@".values.pfm"] tolerance:valueTolerance];
        bk_golden_image_free(&rgba);
        bk_golden_image_free(&values);
    }
}

// Skipping empty space must not change the picture: every case rendered with skipping
// on and off must give identical bytes (a backend-independent rule, also for Vulkan).
- (void)testEmptySpaceSkippingIsInvisible
{
    if (![self requireGPU]) return;
    for (uint32_t i = 0; i < kBKGoldenVolumeCaseCount; i++) {
        BKGoldenVolumeCase c = kBKGoldenVolumeCases[i];
        BKGoldenImage a[2] = {{0}}, v[2] = {{0}};
        for (int s = 0; s < 2; s++) {
            c.skipEmptySpace = s;
            XCTAssertTrue([gProducer renderVolumeCase:&c rgba:&a[s] values:&v[s] error:NULL]);
        }
        BKGoldenImageReport ra = bk_golden_compare_images(&a[0], &a[1], (BKGoldenImageTolerance){0, 0});
        BKGoldenImageReport rv = bk_golden_compare_images(&v[0], &v[1], (BKGoldenImageTolerance){0, 0});
        XCTAssertTrue(ra.pass && rv.pass, @"%s: skipping changed the image (max %.4g / %.4g)", c.name, ra.maxDiff, rv.maxDiff);
        for (int s = 0; s < 2; s++) { bk_golden_image_free(&a[s]); bk_golden_image_free(&v[s]); }
    }
}

// The volume as stored on the GPU must equal the portable plain-C conversion
// (BKRenderQuantizeToSteps): a Vulkan upload built on the core stores the same volume.
- (void)testVolumeStorageMatchesCore
{
    if (![self requireGPU]) return;
    NSError *error = nil;
    NSData *gpu = [gProducer storedVolumeStepsWithError:&error];
    XCTAssertNotNil(gpu, @"%@", error);
    size_t n = (size_t)gPhantom.width * gPhantom.height * gPhantom.depth;
    float lo = INFINITY, hi = -INFINITY;
    for (size_t i = 0; i < n; i++) { lo = fminf(lo, gPhantom.voxels[i]); hi = fmaxf(hi, gPhantom.voxels[i]); }
    BKRenderQuantization q = BKRenderQuantizationForRange(lo, hi, BKRenderAllIntegral(gPhantom.voxels, n));
    XCTAssertEqual(q.valueScale, gProducer.volumeTexture.valueScale);
    XCTAssertEqual(q.valueOffset, gProducer.volumeTexture.valueOffset);
    uint16_t *steps = malloc(n * sizeof(uint16_t));
    BKRenderQuantizeToSteps(gPhantom.voxels, n, q, steps);
    const float *g = gpu.bytes;
    size_t differ = 0;
    for (size_t i = 0; i < n && g; i++) differ += (float)steps[i] != g[i];
    XCTAssertEqual(differ, 0u, @"GPU volume differs from the plain-C conversion");
    free(steps);
}

// The hand-written filter (for GPUs / Vulkan devices that cannot linearly filter 16-bit
// volumes or float colour tables) compared with the hardware filter that made the
// references. The 8-bit pictures must meet the normal tolerance. The float HU values
// cannot: GPU filters blend with 8-bit fixed-point weights (Apple's, and the D3D/Vulkan
// minimum too), so a filtered sample next to a sharp edge can be off by up to about
// 1/256 of the jump between the two voxels (measured here: up to ~5 HU next to the
// 2500 HU ball). So float values get a "different filter" tolerance of 1/256 of the
// volume's value range. Lesson for the Vulkan port (see VULKAN-PORT-PLAN.md): HU-exact
// outputs should use the same (manual) filter on both backends.
- (void)testManualFilteringMatchesReferences
{
    if (![self requireGPU]) return;
    gProducer.manualFiltering = YES;
    for (uint32_t i = 0; i < kBKGoldenVolumeCaseCount; i++) {
        const BKGoldenVolumeCase *c = &kBKGoldenVolumeCases[i];
        BKGoldenImage rgba = {0}, values = {0}, refRGBA = {0}, refValues = {0};
        XCTAssertTrue([gProducer renderVolumeCase:c rgba:&rgba values:&values error:NULL]);
        NSString *name = @(c->name);
        if (bk_golden_read_pam(BKGoldenPath([name stringByAppendingString:@".rgba.pam"]).fileSystemRepresentation, &refRGBA) != 0 ||
            bk_golden_read_pfm(BKGoldenPath([name stringByAppendingString:@".values.pfm"]).fileSystemRepresentation, &refValues) != 0) {
            if (!BKGoldenRecording()) XCTFail(@"%@: reference missing", name);
        } else {
            BKGoldenImageReport ra = bk_golden_compare_images(&refRGBA, &rgba, bk_golden_tolerance_u8());
            double range = gProducer.volumeTexture.maximumValue - gProducer.volumeTexture.minimumValue;
            BKGoldenImageTolerance vt = {c->mode == 0 ? 2.0 / 255.0 : range / 256.0, 0.005};
            BKGoldenImageReport rv = bk_golden_compare_images(&refValues, &values, vt);
            char ta[256], tv[256];
            bk_golden_describe_image_report(&ra, ta, sizeof ta);
            bk_golden_describe_image_report(&rv, tv, sizeof tv);
            NSLog(@"GOLDEN | %@ | manual filtering vs hardware reference: colour %s; values %s", name, ta, tv);
            XCTAssertTrue(ra.pass, @"%@ manual filtering colour: %s", name, ta);
            XCTAssertTrue(rv.pass, @"%@ manual filtering values: %s", name, tv);
        }
        bk_golden_image_free(&rgba); bk_golden_image_free(&values);
        bk_golden_image_free(&refRGBA); bk_golden_image_free(&refValues);
    }
    gProducer.manualFiltering = NO;
}

#pragma mark - 2D image display

- (void)testImageLayerRenders
{
    if (![self requireGPU]) return;
    for (uint32_t i = 0; i < kBKGoldenImageCaseCount; i++) {
        const BKGoldenImageCase *c = &kBKGoldenImageCases[i];
        BKGoldenImage rgba = {0};
        NSError *error = nil;
        XCTAssertTrue([gProducer renderImageCase:c volume:&gPhantom rgba:&rgba error:&error], @"%s: %@", c->name, error);
        if (!rgba.data) continue;
        [self checkImage:&rgba file:[@(c->name) stringByAppendingString:@".rgba.pam"] tolerance:bk_golden_tolerance_u8()];
        bk_golden_image_free(&rgba);
    }
}

#pragma mark - Surfaces, mesh processing, mesh rendering

- (void)testSurfaces
{
    if (![self requireGPU]) return;
    NSError *error = nil;
    NSData *steps = [gProducer storedVolumeStepsWithError:&error];
    XCTAssertNotNil(steps, @"%@", error);
    for (uint32_t i = 0; i < kBKGoldenSurfaceCaseCount; i++) {
        const BKGoldenSurfaceCase *c = &kBKGoldenSurfaceCases[i];
        BKMesh *mesh = [gProducer extractSurfaceCase:c error:&error];
        XCTAssertNotNil(mesh, @"%s: %@", c->name, error);
        if (!mesh) continue;
        BKGoldenMesh m = BKGoldenMeshFromBKMesh(mesh);
        [self checkMesh:&m file:[@(c->name) stringByAppendingString:@".bkmesh"]];

        // CPU reference vs Metal (only where the reference applies: full resolution, no
        // smoothing; the reference works on the voxel grid itself). Uses the volume as
        // stored on the GPU, so both see the very same 16-bit numbers.
        if (steps && c->resolution == 1.0f && c->smoothing == 0.0f) {
            float thresholdSteps = BKSurfaceThresholdToSteps(c->threshold, gProducer.volumeTexture.valueScale,
                                                             gProducer.volumeTexture.valueOffset);
            BKSurfaceMeshData ref;
            XCTAssertEqual(BKSurfaceReferenceExtract(steps.bytes, gPhantom.width, gPhantom.height, gPhantom.depth,
                                                     thresholdSteps, gPhantom.voxelToPatient, &ref), BKSurfaceStatusOK);
            BKGoldenMesh r = {ref.vertexCount, ref.triangleCount, malloc(12 * ref.vertexCount + 4),
                              malloc(12 * ref.vertexCount + 4), malloc(12 * ref.triangleCount + 4)};
            for (uint64_t v = 0; v < ref.vertexCount; v++)
                for (int a = 0; a < 3; a++) {
                    r.positions[3 * v + a] = ref.positions[4 * v + a];
                    r.normals[3 * v + a] = ref.normals[4 * v + a];
                }
            memcpy(r.indices, ref.indices, 12 * ref.triangleCount);
            BKGoldenMeshTolerance tolerance = {{gPhantom.spacing[0], gPhantom.spacing[1], gPhantom.spacing[2]}, 1e-4, 1e-3};
            BKGoldenMeshReport report = bk_golden_compare_meshes(&r, &m, tolerance);
            char text[256];
            bk_golden_describe_mesh_report(&report, text, sizeof text);
            NSLog(@"GOLDEN | %s | CPU reference vs Metal: %s", c->name, text);
            XCTAssertTrue(report.pass, @"%s CPU reference vs Metal: %s", c->name, text);
            bk_golden_mesh_free(&r);
            BKSurfaceMeshDataFree(&ref);
        }
        bk_golden_mesh_free(&m);
    }
}

// Smoothing and decimation (CPU, C++ core) of the bone surface: golden meshes, and the
// result must not depend on the number of threads.
- (void)testMeshProcessing
{
    if (![self requireGPU]) return;
    NSString *bone = [@(kBKGoldenSurfaceCases[0].name) stringByAppendingString:@".bkmesh"];
    BKMesh *input = [self referenceMeshFile:bone orFresh:[gProducer extractSurfaceCase:&kBKGoldenSurfaceCases[0] error:NULL]];
    XCTAssertNotNil(input);
    if (!input) return;
    BKMesh *results[2][2];
    for (int threads = 0; threads < 2; threads++) {
        BKMesh.processingMaxThreads = threads ? 0 : 1;   // pass 0: one thread, pass 1: all cores
        results[threads][0] = [input meshBySmoothingWithIterations:BK_GOLDEN_SMOOTH_ITERATIONS passBand:BK_GOLDEN_SMOOTH_PASSBAND
                                                          progress:nil report:NULL];
        results[threads][1] = [input meshByDecimatingWithTargetReduction:BK_GOLDEN_DECIMATE_REDUCTION progress:nil report:NULL];
    }
    BKMesh.processingMaxThreads = 0;
    NSString *files[2] = {@"mesh_smooth_taubin10.bkmesh", @"mesh_decimate_50.bkmesh"};
    for (int k = 0; k < 2; k++) {
        XCTAssertNotNil(results[0][k]);
        XCTAssertNotNil(results[1][k]);
        if (!results[0][k] || !results[1][k]) continue;
        BKGoldenMesh one = BKGoldenMeshFromBKMesh(results[0][k]), all = BKGoldenMeshFromBKMesh(results[1][k]);
        BKGoldenMeshReport same = bk_golden_compare_meshes(&one, &all, (BKGoldenMeshTolerance){{1, 1, 1}, 0, 0});
        XCTAssertTrue(same.pass, @"%@: 1 thread and all threads differ", files[k]);
        [self checkMesh:&all file:files[k]];
        bk_golden_mesh_free(&one);
        bk_golden_mesh_free(&all);
    }
}

- (void)testMeshRenders
{
    if (![self requireGPU]) return;
    NSString *bone = [@(kBKGoldenSurfaceCases[0].name) stringByAppendingString:@".bkmesh"];
    BKMesh *mesh = [self referenceMeshFile:bone orFresh:[gProducer extractSurfaceCase:&kBKGoldenSurfaceCases[0] error:NULL]];
    XCTAssertNotNil(mesh);
    if (!mesh) return;
    for (uint32_t i = 0; i < kBKGoldenMeshRenderCaseCount; i++) {
        const BKGoldenMeshRenderCase *c = &kBKGoldenMeshRenderCases[i];
        BKGoldenImage rgba = {0}, distance = {0};
        NSError *error = nil;
        XCTAssertTrue([gProducer renderMeshCase:c mesh:mesh rgba:&rgba distance:&distance error:&error], @"%s: %@", c->name, error);
        if (!rgba.data) continue;
        NSString *name = @(c->name);
        [self checkImage:&rgba file:[name stringByAppendingString:@".rgba.pam"] tolerance:bk_golden_tolerance_u8()];
        [self checkImage:&distance file:[name stringByAppendingString:@".distance.pfm"] tolerance:(BKGoldenImageTolerance){0.01, 0.005}];
        bk_golden_image_free(&rgba);
        bk_golden_image_free(&distance);
    }
}

#pragma mark - Scene export

// A small fixed scene (a ball, a box, an outline, a camera, a background) written in all
// four formats; the files must be byte-identical to the references.
- (void)testSceneExport
{
    BKSceneExport *scene = [[BKSceneExport alloc] init];
    BKSceneMaterial ballMaterial = BKSceneMaterialDefault();
    ballMaterial.color = simd_make_float3(0.9f, 0.85f, 0.7f);
    [scene addMesh:[BKMesh sphereMeshWithCenter:simd_make_float3(10, 6, 8) radius:6 subdivisions:1]
         transform:matrix_identity_float4x4 material:ballMaterial name:@"Bone ball"];
    BKSceneMaterial boxMaterial = BKSceneMaterialDefault();
    boxMaterial.color = simd_make_float3(0.2f, 0.5f, 0.9f);
    boxMaterial.opacity = 0.5f;
    simd_float4x4 moved = matrix_identity_float4x4;
    moved.columns[3] = simd_make_float4(-5, 2, 1, 1);
    [scene addMesh:[BKMesh boxMeshWithMin:simd_make_float3(-4, -3, -2) max:simd_make_float3(4, 3, 2)]
         transform:moved material:boxMaterial name:@"Guide block"];
    simd_float3 outline[8] = {{-30, -30, -28}, {30, -30, -28}, {30, -30, -28}, {30, 30, -28},
                              {30, 30, -28}, {-30, 30, -28}, {-30, 30, -28}, {-30, -30, -28}};
    [scene addLineSegments:outline count:8 transform:matrix_identity_float4x4 color:simd_make_float3(1, 1, 0)
                opacity:1 lineWidth:2 name:@"Outline"];
    [scene setPerspectiveCameraWithPosition:simd_make_double3(-110, -150, 60) focalPoint:simd_make_double3(0, 0, 0)
                                     viewUp:simd_make_double3(0, 0, 1) viewAngle:30];
    scene.backgroundColor = simd_make_float3(0.1f, 0.1f, 0.15f);
    scene.title = @"BorosKit golden scene";

    // A fixed scratch folder whose files are simply overwritten on every run (nothing is
    // ever deleted).
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"BorosKitGoldenSceneExport"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    struct { BKSceneFileFormat format; NSString *file; } outputs[] = {
        {BKSceneFileFormatOBJ, @"scene.obj"}, {BKSceneFileFormatVRML, @"scene.wrl"},
        {BKSceneFileFormatInventor, @"scene.iv"}, {BKSceneFileFormatRIB, @"scene.rib"},
    };
    for (size_t i = 0; i < sizeof outputs / sizeof outputs[0]; i++) {
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:outputs[i].file]];
        NSError *error = nil;
        XCTAssertTrue([scene writeToURL:url format:outputs[i].format error:&error], @"%@: %@", outputs[i].file, error);
        NSData *data = [NSData dataWithContentsOfURL:url];
        XCTAssertNotNil(data);
        if (data) [self checkBytes:data file:[@"scene_export_" stringByAppendingString:outputs[i].file]];
        if (outputs[i].format == BKSceneFileFormatOBJ) {
            NSData *mtl = [NSData dataWithContentsOfURL:[BKSceneExport materialLibraryURLForOBJURL:url]];
            XCTAssertNotNil(mtl);
            if (mtl) [self checkBytes:mtl file:@"scene_export_scene.mtl"];
        }
    }
}

#pragma mark - Numbers

// Plain numbers that every backend must reproduce: the volume's 16-bit storage scale,
// the baked transfer function, the surface plan, and camera moves.
- (void)testNumbers
{
    NSMutableData *store = [NSMutableData data];
    // What: appends one named number. Why: keeps the list below readable.
    void (^add)(const char *, double) = ^(const char *name, double value) {
        BKGoldenNumber n;
        memset(&n, 0, sizeof n);
        snprintf(n.name, sizeof n.name, "%s", name);
        n.value = value;
        [store appendBytes:&n length:sizeof n];
    };

    if (gProducer) {
        BKVolumeTexture *vt = gProducer.volumeTexture;
        add("volume_value_scale", vt.valueScale);
        add("volume_value_offset", vt.valueOffset);
        add("volume_minimum", vt.minimumValue);
        add("volume_maximum", vt.maximumValue);
        add("volume_lossless", vt.isLossless ? 1 : 0);
    }

    // Transfer function baked into the 4096-entry table the GPU reads.
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    for (uint32_t i = 0; i < kBKGoldenColorPointCount; i++)
        [tf addColorPointAtValue:kBKGoldenColorPoints[i].value red:kBKGoldenColorPoints[i].red
                           green:kBKGoldenColorPoints[i].green blue:kBKGoldenColorPoints[i].blue];
    for (uint32_t i = 0; i < kBKGoldenOpacityPointCount; i++)
        [tf addOpacityPointAtValue:kBKGoldenOpacityPoints[i].value opacity:kBKGoldenOpacityPoints[i].opacity];
    float *table = malloc(4096 * 4 * sizeof(float));
    [tf bakeIntoRGBA:table count:4096];
    uint64_t tableHash = bk_golden_hash(table, 4096 * 4 * sizeof(float));
    add("tf_table_hash_low32", (double)(tableHash & 0xFFFFFFFFu));
    add("tf_table_hash_high32", (double)(tableHash >> 32));
    const int probes[] = {0, 1000, 2047, 2600, 3000, 4095};
    for (size_t k = 0; k < sizeof probes / sizeof probes[0]; k++)
        for (int ch = 0; ch < 4; ch++) {
            char name[64];
            snprintf(name, sizeof name, "tf_entry_%d_ch%d", probes[k], ch);
            add(name, table[4 * probes[k] + ch]);
        }
    free(table);

    // Surface plan (backend-neutral C core) for the smoothed half-resolution case.
    BKSurfacePlanRequest request;
    memset(&request, 0, sizeof request);
    request.volumeWidth = gPhantom.width;
    request.volumeHeight = gPhantom.height;
    request.volumeDepth = gPhantom.depth;
    request.resolution = 0.5f;
    request.smoothingSigma = 1.0f;
    memcpy(request.voxelToOutput, gPhantom.voxelToPatient, sizeof request.voxelToOutput);
    request.sampling = BK_SURFACE_SAMPLING_MANUAL;
    BKSurfacePlan plan;
    XCTAssertEqual(BKSurfacePlanMake(&request, &plan), BKSurfaceStatusOK);
    add("plan_grid_width", plan.gridWidth);
    add("plan_grid_height", plan.gridHeight);
    add("plan_grid_depth", plan.gridDepth);
    add("plan_row_stride", plan.rowStride);
    add("plan_blur_radius_x", plan.blurRadius[0]);
    add("plan_blur_radius_z", plan.blurRadius[2]);
    add("plan_blur_weight_x0", plan.blurWeights[0][0]);
    add("plan_blur_weight_x1", plan.blurWeights[0][1]);
    add("plan_blur_weight_z0", plan.blurWeights[2][0]);
    add("plan_peak_bytes", (double)plan.peakTemporaryBytes);

    // Camera moves (the interactive 3D camera's maths).
    BKVolumeCamera *camera = [[BKVolumeCamera alloc] init];
    [camera resetToBoxMin:N3VectorMake(-31.5, -31.5, -29.375) max:N3VectorMake(31.5, 31.5, 29.375)];
    [camera azimuth:30];
    [camera elevation:20];
    [camera roll:10];
    [camera zoomByFactor:1.5];
    [camera panByViewDelta:CGSizeMake(12, -7) viewSize:CGSizeMake(400, 300)];
    add("camera_direction_x", camera.direction.x);
    add("camera_direction_y", camera.direction.y);
    add("camera_direction_z", camera.direction.z);
    add("camera_up_x", camera.viewUp.x);
    add("camera_up_y", camera.viewUp.y);
    add("camera_up_z", camera.viewUp.z);
    add("camera_focal_x", camera.focalPoint.x);
    add("camera_focal_y", camera.focalPoint.y);
    add("camera_focal_z", camera.focalPoint.z);
    add("camera_parallel_scale", camera.parallelScale);
    add("camera_distance", camera.distance);

    [self checkNumbers:store.bytes count:store.length / sizeof(BKGoldenNumber) file:@"numbers_core.txt"];
}

#pragma mark - The harness checks itself

// The comparers must accept what is within tolerance and reject what is not, and the
// file formats must give back exactly what was written. Pure C, no GPU needed.
- (void)testComparersAndFileFormats
{
    // Images: +-1 everywhere passes; +2 on 1% of channels fails; +2 on 0.4% passes.
    BKGoldenImage a = bk_golden_image_make(50, 40, 4, BKGoldenFormatU8), b = bk_golden_image_make(50, 40, 4, BKGoldenFormatU8);
    uint8_t *pa = a.data, *pb = b.data;
    size_t n = bk_golden_image_bytes(&a);
    for (size_t i = 0; i < n; i++) { pa[i] = (uint8_t)(i * 7 % 200 + 20); pb[i] = (uint8_t)(pa[i] + ((i % 2) ? 1 : -1)); }
    XCTAssertTrue(bk_golden_compare_images(&a, &b, bk_golden_tolerance_u8()).pass);
    for (size_t i = 0; i < n / 100; i++) pb[i * 100] = (uint8_t)(pa[i * 100] + 2);   // 1% of channels
    XCTAssertFalse(bk_golden_compare_images(&a, &b, bk_golden_tolerance_u8()).pass);
    for (size_t i = 0; i < n; i++) pb[i] = pa[i];
    for (size_t i = 0; i < n / 250; i++) pb[i * 250] = (uint8_t)(pa[i * 250] + 9);    // 0.4%
    BKGoldenImageReport r = bk_golden_compare_images(&a, &b, bk_golden_tolerance_u8());
    XCTAssertTrue(r.pass);
    XCTAssertEqual(r.maxDiff, 9.0);

    // Files: PAM (8 and 16 bit), PFM and mesh round trips are exact.
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"BorosKitGoldenSelfTest"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    const char *pam = [dir stringByAppendingPathComponent:@"a.pam"].fileSystemRepresentation;
    BKGoldenImage back;
    XCTAssertEqual(bk_golden_write_pam(pam, &a), 0);
    XCTAssertEqual(bk_golden_read_pam(pam, &back), 0);
    XCTAssertTrue(bk_golden_compare_images(&a, &back, (BKGoldenImageTolerance){0, 0}).pass);
    bk_golden_image_free(&back);

    BKGoldenImage w = bk_golden_image_make(7, 5, 2, BKGoldenFormatU16);
    for (size_t i = 0; i < 70; i++) ((uint16_t *)w.data)[i] = (uint16_t)(i * 937 + 11);
    XCTAssertEqual(bk_golden_write_pam(pam, &w), 0);
    XCTAssertEqual(bk_golden_read_pam(pam, &back), 0);
    XCTAssertTrue(bk_golden_compare_images(&w, &back, (BKGoldenImageTolerance){0, 0}).pass);
    bk_golden_image_free(&back);
    bk_golden_image_free(&w);

    BKGoldenImage f = bk_golden_image_make(9, 4, 1, BKGoldenFormatF32);
    for (size_t i = 0; i < 36; i++) ((float *)f.data)[i] = (float)i * -3.25f + 0.1f;
    ((float *)f.data)[5] = INFINITY;
    const char *pfm = [dir stringByAppendingPathComponent:@"f.pfm"].fileSystemRepresentation;
    XCTAssertEqual(bk_golden_write_pfm(pfm, &f), 0);
    XCTAssertEqual(bk_golden_read_pfm(pfm, &back), 0);
    XCTAssertTrue(bk_golden_compare_images(&f, &back, (BKGoldenImageTolerance){0, 0}).pass, @"PFM round trip (incl. row flip)");
    // Float tolerance: 0.5 HU off everywhere passes at 1 HU; 2 HU off fails.
    for (size_t i = 0; i < 36; i++) if (i != 5) ((float *)back.data)[i] += 0.5f;
    XCTAssertTrue(bk_golden_compare_images(&f, &back, (BKGoldenImageTolerance){1.0, 0.0}).pass);
    for (size_t i = 0; i < 36; i++) if (i != 5) ((float *)back.data)[i] += 1.5f;
    XCTAssertFalse(bk_golden_compare_images(&f, &back, (BKGoldenImageTolerance){1.0, 0.005}).pass);
    bk_golden_image_free(&back);
    bk_golden_image_free(&f);
    bk_golden_image_free(&a);
    bk_golden_image_free(&b);

    // Meshes: 0.5e-4 voxel passes, 2e-4 voxel fails, a swapped triangle corner fails.
    BKGoldenMesh m = BKGoldenMeshFromBKMesh([BKMesh sphereMeshWithCenter:simd_make_float3(1, 2, 3) radius:5 subdivisions:2]);
    const char *meshPath = [dir stringByAppendingPathComponent:@"m.bkmesh"].fileSystemRepresentation;
    BKGoldenMesh mb;
    XCTAssertEqual(bk_golden_write_mesh(meshPath, &m), 0);
    XCTAssertEqual(bk_golden_read_mesh(meshPath, &mb), 0);
    BKGoldenMeshTolerance tol = {{1.0, 1.0, 1.25}, 1e-4, 1e-3};
    XCTAssertTrue(bk_golden_compare_meshes(&m, &mb, (BKGoldenMeshTolerance){{1, 1, 1}, 0, 0}).pass, @"mesh round trip");
    mb.positions[0] += 0.5e-4f;
    XCTAssertTrue(bk_golden_compare_meshes(&m, &mb, tol).pass);
    mb.positions[0] += 1.5e-4f;
    XCTAssertFalse(bk_golden_compare_meshes(&m, &mb, tol).pass);
    mb.positions[0] = m.positions[0];
    uint32_t t = mb.indices[1]; mb.indices[1] = mb.indices[2]; mb.indices[2] = t;
    BKGoldenMeshReport mr = bk_golden_compare_meshes(&m, &mb, tol);
    XCTAssertFalse(mr.pass);
    XCTAssertTrue(mr.triangleMismatch);
    bk_golden_mesh_free(&m);
    bk_golden_mesh_free(&mb);

    // Noise generator: mean about 0, standard deviation about 1, and repeatable.
    double sum = 0, sum2 = 0;
    for (uint64_t i = 0; i < 100000; i++) { double v = bk_golden_noise(7, i); sum += v; sum2 += v * v; }
    XCTAssertEqualWithAccuracy(sum / 100000, 0.0, 0.02);
    XCTAssertEqualWithAccuracy(sqrt(sum2 / 100000), 1.0, 0.02);
    XCTAssertEqual(bk_golden_noise(7, 123), bk_golden_noise(7, 123));
}

@end
