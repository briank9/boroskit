// Original BorosKit code written for this project; contains no third-party code.
//
// Tests for BKSurfaceExtractor (GPU surface building). They run on the real GPU and
// skip themselves on a machine without one.
//
// What is checked, in plain terms (radius errors are in voxels of 1 mm unless noted):
//  1. a ball: every surface point lies within 0.1 voxel of the true radius; the surface
//     is closed with no bad edges; normals point outward; triangle order agrees;
//  2. a tilted grid with 0.3 x 0.4 x 0.5 mm voxels: points land in the right patient mm;
//  3. the GPU gives EXACTLY the CPU reference's mesh (same vertices within 1e-4 voxel,
//     same triangles) on random noise, also at resolution 0.5;
//  4. resolution 0.5 halves the grid in X and Y only and stays accurate;
//  5. smoothing a noisy ball calms the noise without shrinking it;
//  6. negative thresholds (-500 HU) work;
//  7. a mirroring output transform (negative z scale) keeps triangles and normals outward;
//  plus: two thresholds in one call, concurrent calls, errors instead of crashes, the
//  GPU/C parameter struct sizes, and a timing run on a 512^3 volume (logged, not judged).

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "BorosKitSurface.h"
#import "BKSurfaceShaderTypes.h"
#import "BorosKitMesh.h"
#import "BKVolumeTexture.h"
#import "CPRVolumeData.h"

NSString *BKSurfaceShaderSource(void);

// What: fills a volume from a function of the patient position (mm) and uploads it.
// orientation: 9 direction cosines (row direction, column direction, slice direction).
static BKVolumeTexture *BKMakeVolume(id<MTLDevice> device, NSUInteger nx, NSUInteger ny, NSUInteger nz,
                                     simd_double3 origin, const double orientation[9], simd_double3 spacing,
                                     float (^value)(simd_double3 p, NSUInteger x, NSUInteger y, NSUInteger z))
{
    float *voxels = malloc(sizeof(float) * nx * ny * nz);
    simd_double3 row = simd_make_double3(orientation[0], orientation[1], orientation[2]);
    simd_double3 col = simd_make_double3(orientation[3], orientation[4], orientation[5]);
    simd_double3 slc = simd_make_double3(orientation[6], orientation[7], orientation[8]);
    dispatch_apply(nz, DISPATCH_APPLY_AUTO, ^(size_t z) {
        for (NSUInteger y = 0; y < ny; y++)
            for (NSUInteger x = 0; x < nx; x++) {
                simd_double3 p = origin + row * (x * spacing.x) + col * (y * spacing.y) + slc * (z * spacing.z);
                voxels[(z * ny + y) * nx + x] = value(p, x, y, z);
            }
    });
    CPRVolumeData *data = [[CPRVolumeData alloc] initWithFloatBytesNoCopy:voxels pixelsWide:nx pixelsHigh:ny pixelsDeep:nz
                                                                   origin:N3VectorMake(origin.x, origin.y, origin.z) orientation:orientation
                                                                 spacingX:spacing.x spacingY:spacing.y spacingZ:spacing.z freeWhenDone:YES];
    NSError *error = nil;
    BKVolumeTexture *texture = [[BKVolumeTexture alloc] initWithVolumeData:data device:device error:&error];
    NSCAssert(texture, @"%@", error);
    return texture;
}

static const double kIdentity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};

// A ball: a signed-distance "ramp" of 200 HU per mm around radius R (1000 inside,
// -1000 outside, smooth edge), so the 0 HU surface is exactly the sphere of radius R
// and the -500 HU surface the sphere of radius R + 2.5.
static float BKBall(simd_double3 p, simd_double3 centre, double radius)
{
    double v = 200.0 * (radius - simd_distance(p, centre));
    return (float)fmax(-1000.0, fmin(1000.0, v));
}

// What we measure on a mesh that should be a sphere.
typedef struct {
    double maxRadiusError, meanRadius, rmsRadiusError;
    double meanNormalDot;          // average of normal . radial direction
    double windingAgreement;       // fraction of triangles whose CCW normal agrees with the vertex normals
} BKSphereStats;

static BKSphereStats BKMeasureSphere(BKMesh *mesh, simd_float3 centre, double radius)
{
    BKSphereStats s = {0};
    const simd_float3 *v = mesh.vertices, *n = mesh.normals;
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
        simd_float3 d = v[i] - centre;
        double r = simd_length(d);
        s.maxRadiusError = fmax(s.maxRadiusError, fabs(r - radius));
        s.meanRadius += r;
        s.rmsRadiusError += (r - radius) * (r - radius);
        if (n) s.meanNormalDot += simd_dot(n[i], d / (float)r);
    }
    s.meanRadius /= mesh.vertexCount;
    s.rmsRadiusError = sqrt(s.rmsRadiusError / mesh.vertexCount);
    s.meanNormalDot /= mesh.vertexCount;
    NSUInteger agree = 0;
    const uint32_t *t = mesh.indices;
    for (NSUInteger i = 0; i < mesh.triangleCount; i++) {
        simd_float3 a = v[t[3 * i]], b = v[t[3 * i + 1]], c = v[t[3 * i + 2]];
        simd_float3 face = simd_cross(b - a, c - a);
        simd_float3 vn = n ? n[t[3 * i]] + n[t[3 * i + 1]] + n[t[3 * i + 2]] : (a + b + c) / 3 - centre;
        if (simd_dot(face, vn) > 0) agree++;
    }
    s.windingAgreement = mesh.triangleCount ? (double)agree / mesh.triangleCount : 0;
    return s;
}

@interface BKSurfaceExtractorTests : XCTestCase
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) BKSurfaceExtractor *extractor;
@end

@implementation BKSurfaceExtractorTests

- (void)setUp
{
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) return;
    NSError *error = nil;
    self.extractor = [[BKSurfaceExtractor alloc] initWithDevice:self.device error:&error];
    XCTAssertNotNil(self.extractor, @"%@", error);
}

// A 64^3 volume, 1 mm voxels, centred ball of radius 20 mm (shared by several tests).
- (BKVolumeTexture *)ballVolumeWithNoise:(float)noise
{
    simd_double3 centre = simd_make_double3(0.3, -0.2, 0.1);
    return BKMakeVolume(self.device, 64, 64, 64, simd_make_double3(-32, -32, -32), kIdentity, simd_make_double3(1, 1, 1),
                        ^float(simd_double3 p, NSUInteger x, NSUInteger y, NSUInteger z) {
        float v = BKBall(p, centre, 20.0);
        if (noise > 0) {   // deterministic "random" noise from the voxel number
            uint32_t h = (uint32_t)(x * 73856093u ^ y * 19349663u ^ z * 83492791u);
            h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
            v += noise * ((h & 0xffff) / 32767.5f - 1.0f);
        }
        return v;
    });
}

- (void)assertClosedAndOriented:(BKMesh *)mesh label:(NSString *)label
{
    BKMeshEdgeReport r = mesh.edgeReport;
    XCTAssertEqual(r.boundaryEdgeCount, 0u, @"%@", label);
    XCTAssertEqual(r.nonManifoldEdgeCount, 0u, @"%@", label);
    XCTAssertEqual(r.misorientedEdgeCount, 0u, @"%@", label);
    XCTAssertEqual(r.degenerateTriangleCount, 0u, @"%@", label);
    XCTAssertGreaterThan(mesh.enclosedVolume, 0, @"%@: inside-out", label);
}

#pragma mark - 1. Sphere

- (void)testSphereIsAccurateClosedAndOutward
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeTexture *volume = [self ballVolumeWithNoise:0];
    NSError *error = nil;
    BKSurfaceTimings *timings = nil;
    BKMesh *mesh = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@0] options:nil timings:&timings error:&error].firstObject;
    XCTAssertNotNil(mesh, @"%@", error);
    simd_float3 centre = simd_make_float3(0.3f, -0.2f, 0.1f);
    BKSphereStats s = BKMeasureSphere(mesh, centre, 20.0);
    NSLog(@"sphere: %@ | max radius error %.4f, rms %.4f, normal dot %.4f, winding %.4f, volume %.1f vs %.1f",
          timings, s.maxRadiusError, s.rmsRadiusError, s.meanNormalDot, s.windingAgreement, mesh.enclosedVolume, 4.0 / 3.0 * M_PI * 8000);
    XCTAssertLessThan(s.maxRadiusError, 0.1);
    XCTAssertGreaterThan(s.meanNormalDot, 0.99);
    XCTAssertGreaterThan(s.windingAgreement, 0.999);
    // Triangle count: a sphere of area 4*pi*R^2 = 5027 mm^2 on 1 mm cells gives roughly 2 triangles per mm^2.
    XCTAssertGreaterThan(mesh.triangleCount, 6000u);
    XCTAssertLessThan(mesh.triangleCount, 20000u);
    XCTAssertEqualWithAccuracy(mesh.enclosedVolume, 4.0 / 3.0 * M_PI * 8000.0, 0.01 * 4.0 / 3.0 * M_PI * 8000.0);
    [self assertClosedAndOriented:mesh label:@"sphere"];
    XCTAssertEqual(timings.vertexCount, mesh.vertexCount);
    XCTAssertNotNil(self.extractor.lastTimings[@"extractionMilliseconds"]);
}

#pragma mark - 2. Anisotropic, tilted grid

- (void)testAnisotropicTiltedGridLandsInPatientMillimetres
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    // Grid turned 20 degrees about a slanted axis, voxels 0.3 x 0.4 x 0.5 mm, origin far from 0.
    simd_double3 axis = simd_normalize(simd_make_double3(1, 2, 3));
    simd_quatd q = simd_quaternion(20.0 * M_PI / 180.0, axis);
    simd_double3 r = simd_act(q, simd_make_double3(1, 0, 0)), c = simd_act(q, simd_make_double3(0, 1, 0)), n = simd_act(q, simd_make_double3(0, 0, 1));
    const double orientation[9] = {r.x, r.y, r.z, c.x, c.y, c.z, n.x, n.y, n.z};
    simd_double3 spacing = simd_make_double3(0.3, 0.4, 0.5);
    simd_double3 origin = simd_make_double3(100, -50, 300);
    simd_double3 centreVoxel = simd_make_double3(40, 32, 24);   // middle of an 80 x 64 x 48 grid
    simd_double3 centre = origin + r * (centreVoxel.x * spacing.x) + c * (centreVoxel.y * spacing.y) + n * (centreVoxel.z * spacing.z);
    const double radius = 7.0;
    BKVolumeTexture *volume = BKMakeVolume(self.device, 80, 64, 48, origin, orientation, spacing,
                                           ^float(simd_double3 p, NSUInteger x, NSUInteger y, NSUInteger z) {
        // Ramp of 1000 HU per mm: steeper, since the voxels are small.
        return (float)fmax(-1000.0, fmin(1000.0, 1000.0 * (radius - simd_distance(p, centre))));
    });
    NSError *error = nil;
    BKMesh *mesh = [self.extractor extractSurfaceFromVolume:volume threshold:0 resolution:1 scanSmoothing:0 error:&error];
    XCTAssertNotNil(mesh, @"%@", error);
    simd_float3 cf = simd_make_float3(centre.x, centre.y, centre.z);
    BKSphereStats s = BKMeasureSphere(mesh, cf, radius);
    simd_float3 mid = (mesh.boundsMin + mesh.boundsMax) * 0.5f;
    NSLog(@"tilted anisotropic: max radius error %.4f mm, centre off by %.4f mm, normal dot %.4f", s.maxRadiusError, simd_distance(mid, cf), s.meanNormalDot);
    XCTAssertLessThan(s.maxRadiusError, 0.05);       // 0.1 of the largest voxel side
    XCTAssertLessThan(simd_distance(mid, cf), 0.05);
    XCTAssertGreaterThan(s.meanNormalDot, 0.99);
    [self assertClosedAndOriented:mesh label:@"tilted"];
}

#pragma mark - 3. GPU == CPU reference

// Random whole numbers 0...65535 (the full range, so 1 stored step = 1 value and the
// reference sees exactly the GPU's numbers), threshold between two whole numbers.
- (void)testMatchesCPUReferenceExactly
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    const NSUInteger nx = 37, ny = 23, nz = 19;
    float *values = malloc(sizeof(float) * nx * ny * nz);
    srand48(42);
    for (NSUInteger i = 0; i < nx * ny * nz; i++) values[i] = (float)floor(drand48() * 65536.0);
    values[0] = 0; values[1] = 65535;
    BKVolumeTexture *volume = BKMakeVolume(self.device, nx, ny, nz, simd_make_double3(0, 0, 0), kIdentity, simd_make_double3(1, 1, 1),
                                           ^float(simd_double3 p, NSUInteger x, NSUInteger y, NSUInteger z) {
        return values[(z * ny + y) * nx + x];
    });
    XCTAssertEqual(volume.valueScale, 65535.0f);
    XCTAssertEqual(volume.valueOffset, 0.0f);

    // A non-trivial output transform (anisotropic scale + shift), applied to both.
    BKSurfaceOptions *options = [[BKSurfaceOptions alloc] init];
    options.hasOutputTransform = YES;
    options.outputTransform = simd_matrix(simd_make_float4(0.5f, 0, 0, 0), simd_make_float4(0, 0.25f, 0, 0),
                                          simd_make_float4(0, 0, 2.0f, 0), simd_make_float4(3, -4, 5, 1));
    double m[16] = {0.5, 0, 0, 0, 0, 0.25, 0, 0, 0, 0, 2.0, 0, 3, -4, 5, 1};

    for (int pass = 0; pass < 2; pass++) {
        // pass 0: resolution 1 (values read straight from the texture);
        // pass 1: resolution 0.5 with manual sampling: grid points are every second voxel
        //         in X/Y (exact voxels), read through the 16-bit field buffer.
        options.resolution = pass ? 0.5f : 1.0f;
        options.sampling = pass ? BKSurfaceSamplingManualTrilinear : BKSurfaceSamplingHardwareLinear;
        NSUInteger gx = pass ? (nx - 1) / 2 + 1 : nx, gy = pass ? (ny - 1) / 2 + 1 : ny;
        float *grid = malloc(sizeof(float) * gx * gy * nz);
        for (NSUInteger z = 0; z < nz; z++)
            for (NSUInteger y = 0; y < gy; y++)
                for (NSUInteger x = 0; x < gx; x++)
                    grid[(z * gy + y) * gx + x] = values[(z * ny + y * (pass ? 2 : 1)) * nx + x * (pass ? 2 : 1)];
        double gm[16];
        memcpy(gm, m, sizeof gm);
        if (pass) for (int k = 0; k < 4; k++) { gm[k] *= 2; gm[4 + k] *= 2; }   // grid step = 2 voxels in X/Y

        NSError *error = nil;
        BKMesh *mesh = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@30000.5] options:options timings:NULL error:&error].firstObject;
        XCTAssertNotNil(mesh, @"%@", error);
        BKSurfaceMeshData ref;
        XCTAssertEqual(BKSurfaceReferenceExtract(grid, (uint32_t)gx, (uint32_t)gy, (uint32_t)nz, 30000.5f, gm, &ref), BKSurfaceStatusOK);
        XCTAssertEqual(mesh.vertexCount, ref.vertexCount, @"pass %d", pass);
        XCTAssertEqual(mesh.triangleCount, ref.triangleCount, @"pass %d", pass);
        XCTAssertGreaterThan(mesh.triangleCount, 1000u);
        if (mesh.vertexCount == ref.vertexCount && mesh.triangleCount == ref.triangleCount) {
            double maxPos = 0, maxNormal = 0;
            for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
                simd_float3 p = mesh.vertices[i], n = mesh.normals[i];
                simd_float3 rp = simd_make_float3(ref.positions[4 * i], ref.positions[4 * i + 1], ref.positions[4 * i + 2]);
                simd_float3 rn = simd_make_float3(ref.normals[4 * i], ref.normals[4 * i + 1], ref.normals[4 * i + 2]);
                // Position error measured in voxels (undo the output scale per axis).
                simd_float3 d = (p - rp) / simd_make_float3(0.5f, 0.25f, 2.0f);
                maxPos = fmax(maxPos, simd_length(d));
                maxNormal = fmax(maxNormal, simd_length(n - rn));
            }
            XCTAssertLessThan(maxPos, 1e-4, @"pass %d", pass);
            XCTAssertLessThan(maxNormal, 1e-3, @"pass %d", pass);
            XCTAssertEqual(memcmp(mesh.indices, ref.indices, mesh.triangleCount * 12), 0, @"pass %d: triangles differ", pass);
            NSLog(@"GPU vs CPU reference (pass %d): %lu vertices, %lu triangles, max position difference %.2e voxel, normal %.2e",
                  pass, (unsigned long)mesh.vertexCount, (unsigned long)mesh.triangleCount, maxPos, maxNormal);
        }
        BKSurfaceMeshDataFree(&ref);
        free(grid);
    }
    free(values);
}

#pragma mark - 4. Resolution 0.5

- (void)testHalfResolutionThinsXYOnly
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeTexture *volume = [self ballVolumeWithNoise:0];
    BKSurfaceTimings *full = nil, *half = nil;
    BKSurfaceOptions *options = [[BKSurfaceOptions alloc] init];
    BKMesh *fullMesh = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@0] options:options timings:&full error:NULL].firstObject;
    options.resolution = 0.5f;
    NSError *error = nil;
    BKMesh *mesh = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@0] options:options timings:&half error:&error].firstObject;
    XCTAssertNotNil(mesh, @"%@", error);
    XCTAssertEqual(half.gridWidth, 32u);   // floor(63 * 0.5) + 1
    XCTAssertEqual(half.gridHeight, 32u);
    XCTAssertEqual(half.gridDepth, 64u);   // Z unchanged
    BKSphereStats s = BKMeasureSphere(mesh, simd_make_float3(0.3f, -0.2f, 0.1f), 20.0);
    NSLog(@"half resolution: %lu vs %lu triangles, max radius error %.4f voxel", (unsigned long)mesh.triangleCount,
          (unsigned long)fullMesh.triangleCount, s.maxRadiusError);
    XCTAssertLessThan(s.maxRadiusError, 0.1);
    XCTAssertGreaterThan(s.meanNormalDot, 0.99);
    XCTAssertLessThan(mesh.triangleCount, fullMesh.triangleCount * 0.6);
    [self assertClosedAndOriented:mesh label:@"half resolution"];

    // Non-integer resolution, hardware and manual interpolation agree closely.
    options.resolution = 0.7f;
    BKMesh *hw = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@0] options:options timings:NULL error:NULL].firstObject;
    options.sampling = BKSurfaceSamplingManualTrilinear;
    BKMesh *manual = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@0] options:options timings:NULL error:NULL].firstObject;
    BKSphereStats sh = BKMeasureSphere(hw, simd_make_float3(0.3f, -0.2f, 0.1f), 20.0);
    BKSphereStats sm = BKMeasureSphere(manual, simd_make_float3(0.3f, -0.2f, 0.1f), 20.0);
    NSLog(@"resolution 0.7: hardware max error %.4f, manual %.4f", sh.maxRadiusError, sm.maxRadiusError);
    XCTAssertEqual(hw.triangleCount, manual.triangleCount);
    XCTAssertLessThan(sh.maxRadiusError, 0.1);
    XCTAssertLessThan(sm.maxRadiusError, 0.1);
}

#pragma mark - 5. Smoothing

- (void)testSmoothingCalmsNoiseWithoutShrinking
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeTexture *volume = [self ballVolumeWithNoise:150];   // +-150 HU noise on a 200 HU/mm edge
    simd_float3 centre = simd_make_float3(0.3f, -0.2f, 0.1f);
    BKMesh *raw = [self.extractor extractSurfaceFromVolume:volume threshold:0 resolution:1 scanSmoothing:0 error:NULL];
    NSError *error = nil;
    BKSurfaceOptions *options = [[BKSurfaceOptions alloc] init];
    options.scanSmoothing = 1.0f;
    BKSurfaceTimings *timings = nil;
    BKMesh *smooth = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@0] options:options timings:&timings error:&error].firstObject;
    XCTAssertNotNil(smooth, @"%@", error);
    BKSphereStats a = BKMeasureSphere(raw, centre, 20.0), b = BKMeasureSphere(smooth, centre, 20.0);
    NSLog(@"noisy ball: raw rms %.4f / mean radius %.4f (%lu triangles); smoothed rms %.4f / mean radius %.4f (%lu triangles); %@",
          a.rmsRadiusError, a.meanRadius, (unsigned long)raw.triangleCount, b.rmsRadiusError, b.meanRadius, (unsigned long)smooth.triangleCount, timings);
    XCTAssertLessThan(b.rmsRadiusError, a.rmsRadiusError * 0.5);   // noise at least halved
    XCTAssertLessThan(fabs(b.meanRadius - 20.0), 0.1);              // no shrinking
    XCTAssertGreaterThan(b.meanNormalDot, a.meanNormalDot);
    XCTAssertGreaterThan(timings.samplingMilliseconds, 0);
    [self assertClosedAndOriented:smooth label:@"smoothed"];
}

#pragma mark - 6. Negative threshold

- (void)testNegativeThreshold
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeTexture *volume = [self ballVolumeWithNoise:0];
    XCTAssertEqual(volume.valueOffset, -1000.0f);
    NSError *error = nil;
    BKMesh *mesh = [self.extractor extractSurfaceFromVolume:volume threshold:-500 resolution:1 scanSmoothing:0 error:&error];
    XCTAssertNotNil(mesh, @"%@", error);
    BKSphereStats s = BKMeasureSphere(mesh, simd_make_float3(0.3f, -0.2f, 0.1f), 22.5);   // -500 HU is 2.5 mm outside
    XCTAssertLessThan(s.maxRadiusError, 0.1);
    XCTAssertGreaterThan(s.meanNormalDot, 0.99);
    [self assertClosedAndOriented:mesh label:@"-500 HU"];
}

#pragma mark - 7. Mirroring output transform

// The Horos surface window's "VTK-local" coordinates: a diagonal scale with a negative
// z (slices stored feet-first). Triangles must stay anticlockwise from outside and the
// normals outward in THOSE coordinates.
- (void)testMirroringOutputTransform
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeTexture *volume = [self ballVolumeWithNoise:0];
    BKSurfaceOptions *options = [[BKSurfaceOptions alloc] init];
    options.hasOutputTransform = YES;
    options.outputTransform = simd_matrix(simd_make_float4(0.3f, 0, 0, 0), simd_make_float4(0, 0.3f, 0, 0),
                                          simd_make_float4(0, 0, -0.5f, 0), simd_make_float4(0, 0, 0, 1));
    NSError *error = nil;
    BKMesh *mesh = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@0] options:options timings:NULL error:&error].firstObject;
    XCTAssertNotNil(mesh, @"%@", error);
    [self assertClosedAndOriented:mesh label:@"mirrored"];
    // The ball's centre (voxel 32.3, 31.8, 32.1) in the output coordinates.
    simd_float3 centre = simd_make_float3(32.3f * 0.3f, 31.8f * 0.3f, 32.1f * -0.5f);
    double dotSum = 0, agree = 0;
    // The ball becomes an ellipsoid; its true outward normal at q is along
    // ((q - c).x / 0.3^2, (q - c).y / 0.3^2, (q - c).z / 0.5^2).
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
        simd_float3 d = mesh.vertices[i] - centre;
        simd_float3 truth = simd_normalize(d / simd_make_float3(0.09f, 0.09f, 0.25f));
        dotSum += simd_dot(mesh.normals[i], truth);
    }
    for (NSUInteger i = 0; i < mesh.triangleCount; i++) {
        const uint32_t *t = mesh.indices + 3 * i;
        simd_float3 face = simd_cross(mesh.vertices[t[1]] - mesh.vertices[t[0]], mesh.vertices[t[2]] - mesh.vertices[t[0]]);
        if (simd_dot(face, mesh.normals[t[0]] + mesh.normals[t[1]] + mesh.normals[t[2]]) > 0) agree++;
    }
    XCTAssertGreaterThan(dotSum / mesh.vertexCount, 0.99);   // outward, along the true ellipsoid normal
    XCTAssertGreaterThan(agree / mesh.triangleCount, 0.999);
}

#pragma mark - Several thresholds, concurrency, errors, struct size

- (void)testTwoThresholdsAndConcurrentCalls
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeTexture *volume = [self ballVolumeWithNoise:0];
    BKSurfaceOptions *options = [[BKSurfaceOptions alloc] init];
    options.scanSmoothing = 0.7f;
    NSArray<BKMesh *> *both = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@300, @-500] options:options timings:NULL error:NULL];
    XCTAssertEqual(both.count, 2u);
    // The same two, built at the same time on two threads.
    __block BKMesh *a = nil, *b = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        a = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@300] options:options timings:NULL error:NULL].firstObject;
    });
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        b = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@-500] options:options timings:NULL error:NULL].firstObject;
    });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    XCTAssertEqual(a.vertexCount, both[0].vertexCount);
    XCTAssertEqual(b.vertexCount, both[1].vertexCount);
    XCTAssertEqual(memcmp(a.vertices, both[0].vertices, a.vertexCount * sizeof(simd_float3)), 0);
    XCTAssertEqual(memcmp(b.indices, both[1].indices, b.triangleCount * 12), 0);
    XCTAssertLessThan(both[0].enclosedVolume, both[1].enclosedVolume);   // 300 HU ball is inside the -500 HU ball
}

- (void)testErrorsInsteadOfCrashes
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeTexture *volume = [self ballVolumeWithNoise:0];
    NSError *error = nil;
    XCTAssertNil([self.extractor extractSurfaceFromVolume:volume threshold:0 resolution:0 scanSmoothing:0 error:&error]);
    XCTAssertEqual(error.code, BKSurfaceErrorInvalidInput);
    error = nil;
    XCTAssertNil([self.extractor extractSurfaceFromVolume:volume threshold:0 resolution:1 scanSmoothing:50 error:&error]);
    XCTAssertEqual(error.code, BKSurfaceErrorInvalidInput);
    error = nil;
    XCTAssertNil([self.extractor extractSurfaceFromVolume:volume threshold:NAN resolution:1 scanSmoothing:0 error:&error]);
    XCTAssertEqual(error.code, BKSurfaceErrorInvalidInput);
    XCTAssertNil([self.extractor extractSurfacesFromVolume:volume thresholds:@[] options:nil timings:NULL error:NULL]);
    // Nothing above the threshold: an empty mesh, not an error.
    BKMesh *empty = [self.extractor extractSurfaceFromVolume:volume threshold:5000 resolution:1 scanSmoothing:0 error:&error];
    XCTAssertNotNil(empty);
    XCTAssertEqual(empty.triangleCount, 0u);
}

- (void)testParameterStructSizeMatchesGPU
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    NSError *error = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:BKSurfaceShaderSource() options:[[MTLCompileOptions alloc] init] error:&error];
    XCTAssertNotNil(library, @"%@", error);
    id<MTLComputePipelineState> pipeline = [self.device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_surface_params_size"] error:&error];
    id<MTLBuffer> out = [self.device newBufferWithLength:4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [self.device newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pipeline];
    [enc setBuffer:out offset:0 atIndex:0];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    XCTAssertEqual(*(uint32_t *)out.contents, (uint32_t)sizeof(BKSurfaceParams));
}

#pragma mark - Performance (logged, not judged)

// A 512^3 "trabecular bone" pattern (a gyroid, period 40 voxels) giving millions of
// triangles, like a real CBCT bone surface.
- (void)testPerformance512
{
    if (!self.device) { XCTSkip(@"No Metal GPU available"); return; }
    const double k = 2.0 * M_PI / 40.0;
    double tUpload = CACurrentMediaTime();
    BKVolumeTexture *volume = BKMakeVolume(self.device, 512, 512, 512, simd_make_double3(0, 0, 0), kIdentity, simd_make_double3(0.3, 0.3, 0.3),
                                           ^float(simd_double3 p, NSUInteger x, NSUInteger y, NSUInteger z) {
        double g = sin(x * k) * cos(y * k) + sin(y * k) * cos(z * k) + sin(z * k) * cos(x * k);
        return (float)round(1000.0 * g);   // whole numbers, -1500...1500 "HU"
    });
    NSLog(@"PERF | 512^3 volume built + uploaded in %.0f ms", (CACurrentMediaTime() - tUpload) * 1000.0);
    struct { float resolution, smoothing; } runs[] = {{1, 0}, {1, 0}, {0.5f, 0}, {1, 1.0f}, {0.5f, 1.0f}};
    for (size_t i = 0; i < sizeof runs / sizeof runs[0]; i++) {
        BKSurfaceOptions *options = [[BKSurfaceOptions alloc] init];
        options.resolution = runs[i].resolution;
        options.scanSmoothing = runs[i].smoothing;
        BKSurfaceTimings *timings = nil;
        NSError *error = nil;
        @autoreleasepool {
            BKMesh *mesh = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@300] options:options timings:&timings error:&error].firstObject;
            XCTAssertNotNil(mesh, @"%@", error);
            NSLog(@"PERF | resolution %.1f smoothing %.1f: %@", runs[i].resolution, runs[i].smoothing, timings);
        }
    }
    // Two thresholds in one call (bone + soft tissue).
    BKSurfaceTimings *timings = nil;
    @autoreleasepool {
        NSArray *meshes = [self.extractor extractSurfacesFromVolume:volume thresholds:@[@300, @-500] options:nil timings:&timings error:NULL];
        XCTAssertEqual(meshes.count, 2u);
    }
    NSLog(@"PERF | two thresholds, resolution 1: %@", timings);
}

@end
