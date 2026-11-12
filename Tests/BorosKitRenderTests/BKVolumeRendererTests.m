// Tests for the Metal volume renderer (BorosKitRender), run on the real GPU.
//
// Test volume: 64 x 64 x 64 voxels, identity orientation, origin 0.
//  - inside a sphere of radius 10 voxels centred at voxel (31, 31, 31): 1000
//  - everywhere else a gradient along z: -1000 + 10 * z  (-1000 at z = 0, -370 at z = 63)
// Because the background is linear in z, trilinear interpolation reproduces it
// exactly, so expected MIP / MinIP / average / thin-slice values can be computed by hand.
//
// Camera used by most tests: orthographic, looking along +z, up = +y, centred on
// voxel (31.5, 31.5, 31.5) and 64 mm wide, so with a 64 x 64 image each pixel ray
// runs exactly along one voxel column: pixel (i, j) -> x = 63 - i, y = 63 - j.
// (right = forward x up = -x, and row 0 is the top of the image.)

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

static const NSUInteger kSize = 64;

@interface BKVolumeRendererTests : XCTestCase
@end

@implementation BKVolumeRendererTests {
    BKVolumeRenderer *_renderer;
}

// Builds the sphere-plus-gradient volume described above with the given voxel size
// (mm) along each axis.
- (CPRVolumeData *)testVolumeWithSpacingX:(double)sx y:(double)sy z:(double)sz
{
    float *bytes = malloc(sizeof(float) * kSize * kSize * kSize);
    for (NSUInteger z = 0; z < kSize; z++)
        for (NSUInteger y = 0; y < kSize; y++)
            for (NSUInteger x = 0; x < kSize; x++) {
                double dx = (double)x - 31, dy = (double)y - 31, dz = (double)z - 31;
                BOOL inSphere = dx * dx + dy * dy + dz * dz <= 100.0;
                bytes[(z * kSize + y) * kSize + x] = inSphere ? 1000.0f : -1000.0f + 10.0f * (float)z;
            }
    double orientation[9] = {1,0,0, 0,1,0, 0,0,1};
    return [[CPRVolumeData alloc] initWithFloatBytesNoCopy:bytes pixelsWide:kSize pixelsHigh:kSize pixelsDeep:kSize
                                                     origin:N3VectorZero orientation:orientation
                                                   spacingX:sx spacingY:sy spacingZ:sz freeWhenDone:YES];
}

// Creates a renderer on the system GPU (skips the test when there is none, e.g. on a
// headless CI machine) and loads the 1 mm test volume with the standard camera.
- (void)setUp
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    NSError *error = nil;
    _renderer = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(_renderer, @"%@", error);
    XCTAssertTrue([_renderer setVolumeData:[self testVolumeWithSpacingX:1 y:1 z:1] error:&error], @"%@", error);
    _renderer.projection = BKProjectionOrthographic;
    _renderer.cameraPosition = N3VectorMake(31.5, 31.5, 31.5);
    _renderer.cameraDirection = N3VectorMake(0, 0, 1);
    _renderer.cameraUp = N3VectorMake(0, 1, 0);
    _renderer.viewWidth = 64;
    _renderer.viewHeight = 64;
    _renderer.sampleSpacing = 0.5;
}

// Skips the current test when no GPU is available.
- (BOOL)requireGPU
{
    if (_renderer) return YES;
    XCTSkip(@"No Metal GPU available");
    return NO;
}

// Renders a 64 x 64 image with the current settings and checks its size.
- (BKRenderResult *)render
{
    NSError *error = nil;
    BKRenderResult *result = [_renderer renderWithWidth:kSize height:kSize error:&error];
    XCTAssertNotNil(result, @"%@", error);
    XCTAssertEqual(result.width, kSize);
    XCTAssertEqual(result.height, kSize);
    XCTAssertEqual(result.rgba8Data.length, kSize * kSize * 4);
    XCTAssertEqual(result.floatData.length, kSize * kSize * sizeof(float));
    return result;
}

// The CPU and GPU must agree on the parameter block, or every render reads garbage.
- (void)testParameterLayoutMatchesGPU
{
    if (![self requireGPU]) return;
    XCTAssertEqual([_renderer gpuParameterBlockSize], [BKVolumeRenderer cpuParameterBlockSize]);
}

// Whole-number CT data must be recoverable exactly (each voxel within half a 16-bit
// step of its true value, and steps far smaller than 1 HU).
- (void)testVolumeUploadIsLossless
{
    if (![self requireGPU]) return;
    BKVolumeTexture *vt = _renderer.volumeTexture;
    XCTAssertTrue(vt.lossless);
    XCTAssertEqual(vt.minimumValue, -1000.0f);
    XCTAssertEqual(vt.maximumValue, 1000.0f);
    XCTAssertEqual(vt.texture.pixelFormat, MTLPixelFormatR16Unorm);
    XCTAssertEqual(vt.texture.depth, kSize);
    XCTAssertLessThan(vt.valueScale / 65535.0f, 0.05f);   // < 0.05 HU per step
}

// MIP: the ray through the sphere centre sees 1000; a corner ray (outside the
// sphere) sees the brightest background, near z = 63 (-370; the last sample sits a
// quarter voxel in, at z = 62.75 -> -372.5).
- (void)testMIP
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    BKRenderResult *r = [self render];
    XCTAssertEqualWithAccuracy([r valueAtX:32 y:32], 1000.0f, 0.5f);   // x = y = 31: sphere centre column
    XCTAssertEqualWithAccuracy([r valueAtX:0 y:0], -372.5f, 0.5f);     // x = y = 63: background only
}

// MinIP: every column starts at the darkest background near z = 0 (-997.5 at z = 0.25).
- (void)testMinIP
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMinIP;
    BKRenderResult *r = [self render];
    XCTAssertEqualWithAccuracy([r valueAtX:0 y:0], -997.5f, 0.5f);
    XCTAssertEqualWithAccuracy([r valueAtX:32 y:32], -997.5f, 0.5f);
}

// Average: the background column averages to -1000 + 10 * 31.5 = -685 exactly
// (midpoint sampling of a straight line). The centre column includes bright sphere
// voxels, so its average must be clearly higher.
- (void)testAverage
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeAverage;
    BKRenderResult *r = [self render];
    XCTAssertEqualWithAccuracy([r valueAtX:0 y:0], -685.0f, 0.5f);
    XCTAssertGreaterThan([r valueAtX:32 y:32], -685.0f + 300.0f);
}

// Thick-slab MIP (what replaces the hidden VTK renderers for MPR / CPR slabs):
// a 4 mm slab around z = 5 must NOT see the sphere (which spans z 21..41), while
// one around z = 31 must.
- (void)testSlabMIPExcludesAndIncludesSphere
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    _renderer.slabEnabled = YES;
    _renderer.slabThickness = 4;

    _renderer.slabPlane = N3PlaneMake(N3VectorMake(0, 0, 5), N3VectorMake(0, 0, 1));
    BKRenderResult *outside = [self render];
    float v = [outside valueAtX:32 y:32];
    XCTAssertLessThan(v, -900.0f, @"slab at z=5 must not see the sphere");
    XCTAssertEqualWithAccuracy(v, -932.5f, 0.5f);                  // brightest sample z = 6.75

    _renderer.slabPlane = N3PlaneMake(N3VectorMake(0, 0, 31), N3VectorMake(0, 0, 1));
    BKRenderResult *inside = [self render];
    XCTAssertEqualWithAccuracy([inside valueAtX:32 y:32], 1000.0f, 0.5f);
}

// Zero-thickness slab = one interpolated sample on the plane (a classic MPR slice).
// z = 10.25 lies between voxels, so this also checks trilinear interpolation:
// -1000 + 10 * 10.25 = -897.5.
- (void)testThinSliceInterpolates
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    _renderer.slabEnabled = YES;
    _renderer.slabThickness = 0;
    _renderer.slabPlane = N3PlaneMake(N3VectorMake(0, 0, 10.25), N3VectorMake(0, 0, 1));
    BKRenderResult *r = [self render];
    XCTAssertEqualWithAccuracy([r valueAtX:0 y:0], -897.5f, 0.05f);
    XCTAssertEqualWithAccuracy([r valueAtX:40 y:20], -897.5f, 0.05f);
}

// Patient-space geometry: with 0.5 mm voxels along z, patient z = 5.125 mm is voxel
// z = 10.25, so the thin slice must give the same -897.5 as above.
- (void)testThinSliceUsesPatientMillimetres
{
    if (![self requireGPU]) return;
    NSError *error = nil;
    XCTAssertTrue([_renderer setVolumeData:[self testVolumeWithSpacingX:1 y:1 z:0.5] error:&error], @"%@", error);
    _renderer.mode = BKRenderModeMIP;
    _renderer.slabEnabled = YES;
    _renderer.slabThickness = 0;
    _renderer.slabPlane = N3PlaneMake(N3VectorMake(0, 0, 5.125), N3VectorMake(0, 0, 1));
    BKRenderResult *r = [self render];
    XCTAssertEqualWithAccuracy([r valueAtX:0 y:0], -897.5f, 0.05f);
}

// The cropping box removes the sphere: crop to x 50..63 and the centre column
// (x = 31) is outside the box, so its ray misses (-> outOfBoundsValue), while a
// column inside the box still sees the background.
- (void)testCroppingBox
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    _renderer.cropMin = N3VectorMake(50, 0, 0);
    _renderer.cropMax = N3VectorMake(63, 63, 63);
    BKRenderResult *r = [self render];
    XCTAssertEqual([r valueAtX:32 y:32], _renderer.volumeTexture.outOfBoundsValue);
    XCTAssertEqualWithAccuracy([r valueAtX:0 y:0], -372.5f, 0.5f);   // x = 63 is inside the box
}

// What: 6 planes of a box centred at voxel (31, 31, cz), half-sizes (hx, hy, hz), rotated by
// `angleZ` degrees about z and then `angleX` degrees about x (patient mm = voxel here).
// Normals point out of the box (BorosKit cuts the normal side).
static void BKBoxPlanes(double cz, double hx, double hy, double hz, double angleZ, double angleX, N3Plane out[6])
{
    double az = angleZ * M_PI / 180, ax = angleX * M_PI / 180;
    N3AffineTransform rot = N3AffineTransformConcat(N3AffineTransformMakeRotation(az, 0, 0, 1),
                                                    N3AffineTransformMakeRotation(ax, 1, 0, 0));
    N3Vector c = N3VectorMake(31, 31, cz);
    N3Vector axes[3] = {N3VectorMake(1, 0, 0), N3VectorMake(0, 1, 0), N3VectorMake(0, 0, 1)};
    double h[3] = {hx, hy, hz};
    for (int a = 0; a < 3; a++) {
        N3Vector u = N3VectorApplyTransformToDirectionalVector(axes[a], rot);
        out[2 * a]     = N3PlaneMake(N3VectorAdd(c, N3VectorScalarMultiply(u, h[a])), u);
        out[2 * a + 1] = N3PlaneMake(N3VectorSubtract(c, N3VectorScalarMultiply(u, h[a])), N3VectorInvert(u));
    }
}

// Rotated cropping box (6 planes, rotated 45 degrees about the viewing axis): every pixel
// ray (one voxel column, x = 63 - i, y = 63 - j) must hit exactly when its column lies
// inside the rotated square, and miss otherwise. Columns within half a voxel of an edge
// are not checked (sampling there is legitimately either way).
- (void)testRotatedBoxCropsTheRightVoxels
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    N3Plane planes[6];
    BKBoxPlanes(31, 8, 8, 40, 45, 0, planes);
    [_renderer setClipPlanes:planes count:6];
    XCTAssertEqual(_renderer.clipPlaneCount, 6u);
    BKRenderResult *r = [self render];
    float miss = _renderer.volumeTexture.outOfBoundsValue;
    double c = cos(M_PI / 4), s = sin(M_PI / 4);
    NSUInteger checked = 0, kept = 0;
    for (NSUInteger j = 0; j < kSize; j++)
        for (NSUInteger i = 0; i < kSize; i++) {
            double x = 63.0 - i - 31, y = 63.0 - j - 31;
            double u = c * x + s * y, v = -s * x + c * y;   // box-local coordinates
            double margin = MAX(fabs(u), fabs(v)) - 8;
            if (fabs(margin) < 0.75) continue;
            float value = [r valueAtX:i y:j];
            checked++;
            if (margin < 0) { kept++; XCTAssertNotEqual(value, miss, @"column (%g, %g) should be kept", x + 31, y + 31); }
            else XCTAssertEqual(value, miss, @"column (%g, %g) should be cut", x + 31, y + 31);
        }
    XCTAssertGreaterThan(kept, 100u);
    XCTAssertGreaterThan(checked, 3000u);
    // Distinguishes rotated from axis-aligned: column (38, 38) is inside an axis-aligned
    // 8-voxel box (and inside the sphere) but outside the rotated one.
    XCTAssertEqual([r valueAtX:63 - 38 y:63 - 38], miss);
    // Column (40, 31) is outside an axis-aligned box but inside the rotated one, and its ray
    // passes through the sphere.
    XCTAssertEqualWithAccuracy([r valueAtX:63 - 40 y:63 - 31], 1000.0f, 0.5f);
    // Clearing the planes restores the full picture.
    [_renderer setClipPlanes:NULL count:0];
    r = [self render];
    XCTAssertEqualWithAccuracy([r valueAtX:63 - 38 y:63 - 38], 1000.0f, 0.5f);
}

// Box tilted about x (so the planes cut each ray at an angle) with its top inside the
// volume: where a column's ray does not meet the sphere, the MIP of the z-gradient
// background (-1000 + 10 z) equals the value at the highest kept z, which a CPU march
// through the same planes gives. Tolerance: one sample step (0.5 mm -> 5 HU) plus margin.
- (void)testTiltedBoxLimitsEachRay
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    N3Plane planes[6];
    BKBoxPlanes(30, 20, 20, 12, 10, 25, planes);
    [_renderer setClipPlanes:planes count:6];
    BKRenderResult *r = [self render];
    float miss = _renderer.volumeTexture.outOfBoundsValue;
    NSUInteger compared = 0;
    for (NSUInteger j = 0; j < kSize; j += 3)
        for (NSUInteger i = 0; i < kSize; i += 3) {
            double x = 63.0 - i, y = 63.0 - j;
            if ((x - 31) * (x - 31) + (y - 31) * (y - 31) <= 121) continue;   // sphere column
            double zTop = -1, zBottom = -1;
            for (double z = 0; z <= 63; z += 0.01)
                if (BKClipPlanesKeepPoint(planes, 6, N3VectorMake(x, y, z))) { if (zBottom < 0) zBottom = z; zTop = z; }
            float value = [r valueAtX:i y:j];
            if (zTop < 0) { XCTAssertEqual(value, miss); continue; }
            if (zTop - zBottom < 2) continue;   // grazing ray: too few samples to compare
            XCTAssertEqualWithAccuracy(value, -1000.0f + 10.0f * (float)zTop, 6.0f, @"column (%g, %g)", x, y);
            compared++;
        }
    XCTAssertGreaterThan(compared, 50u);
}

// The planes add to the axis-aligned crop box: a box column that the crop removes stays removed.
- (void)testClipPlanesCombineWithCropBox
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    N3Plane planes[6];
    BKBoxPlanes(31, 20, 20, 40, 0, 0, planes);
    [_renderer setClipPlanes:planes count:6];
    _renderer.cropMin = N3VectorMake(32, 0, 0);
    _renderer.cropMax = N3VectorMake(63, 63, 63);
    BKRenderResult *r = [self render];
    float miss = _renderer.volumeTexture.outOfBoundsValue;
    XCTAssertEqual([r valueAtX:63 - 25 y:32], miss);   // x = 25: cut by the crop box
    XCTAssertNotEqual([r valueAtX:63 - 40 y:32], miss); // x = 40: inside both
    XCTAssertEqual([r valueAtX:63 - 55 y:32], miss);   // x = 55: cut by the planes
}

// A custom missValue replaces the volume's outside value where rays miss (same
// cropped setup as above), and NAN restores the default. Why: the Boros 6 MPR bridge
// sets missValue to VTK's outside value so "outside the scan" pixels match exactly.
- (void)testMissValueOverridesOutOfBounds
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    _renderer.cropMin = N3VectorMake(50, 0, 0);
    _renderer.cropMax = N3VectorMake(63, 63, 63);
    _renderer.missValue = -1024.0f;
    BKRenderResult *r = [self render];
    XCTAssertEqual([r valueAtX:32 y:32], -1024.0f);                   // missed ray
    XCTAssertEqualWithAccuracy([r valueAtX:0 y:0], -372.5f, 0.5f);   // hits: unchanged
    _renderer.missValue = NAN;
    r = [self render];
    XCTAssertEqual([r valueAtX:32 y:32], _renderer.volumeTexture.outOfBoundsValue);
}

// Composite (3D) rendering: with an opacity ramp from 0 at 0 to 1 at 500 only the
// sphere is visible. The centre ray must be (nearly) opaque and coloured; the
// corner ray sees nothing.
- (void)testCompositeShowsSphere
{
    if (![self requireGPU]) return;
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    [tf addColorPointAtValue:0 red:1 green:0.9f blue:0.8f];
    [tf addColorPointAtValue:1000 red:1 green:0.9f blue:0.8f];
    [tf addOpacityPointAtValue:0 opacity:0];
    [tf addOpacityPointAtValue:500 opacity:1];
    _renderer.transferFunction = tf;
    _renderer.mode = BKRenderModeComposite;
    BKRenderResult *r = [self render];

    uint8_t centre[4], corner[4];
    [r getRGBA8:centre atX:32 y:32];
    [r getRGBA8:corner atX:0 y:0];
    XCTAssertGreaterThan([r valueAtX:32 y:32], 0.95f);
    XCTAssertGreaterThan(centre[0], 50);
    XCTAssertEqual(corner[3], 0);
    XCTAssertEqual([r valueAtX:0 y:0], 0.0f);

    CGImageRef image = [r newCGImage];
    XCTAssertTrue(image != NULL);
    XCTAssertEqual(CGImageGetWidth(image), kSize);
    CGImageRelease(image);
}

// Perspective camera: an eye 100 mm in front of the volume looking at the sphere
// centre must see the sphere in the middle of the image.
- (void)testPerspectiveMIP
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    _renderer.projection = BKProjectionPerspective;
    _renderer.cameraPosition = N3VectorMake(31, 31, -100);
    _renderer.fieldOfView = 20;
    BKRenderResult *r = [self render];
    XCTAssertEqualWithAccuracy([r valueAtX:32 y:32], 1000.0f, 0.5f);
}

// Transfer function: Horos-style CLUT + opacity curve are mapped across the window
// the same way VRView did (0-opacity point added at the window start, opacity 1 at
// the end when the curve stops short of 256).
- (void)testHorosStyleTransferFunction
{
    uint8_t ramp[256];
    for (int i = 0; i < 256; i++) ramp[i] = (uint8_t)i;
    CGPoint opacity[] = {{64, 0.0}, {128, 0.5}};
    BKTransferFunction *tf = [BKTransferFunction transferFunctionWithCLUTRed:ramp green:ramp blue:ramp
                                                                windowCenter:0 windowWidth:512
                                                               opacityPoints:opacity count:2];
    XCTAssertEqual(tf.minimumValue, -256.0f);
    XCTAssertEqual(tf.maximumValue, 256.0f);
    float rgba[4];
    [tf getRGBA:rgba atValue:-256];  XCTAssertEqualWithAccuracy(rgba[0], 0.0f, 1e-4); XCTAssertEqual(rgba[3], 0.0f);
    [tf getRGBA:rgba atValue:0];     XCTAssertEqualWithAccuracy(rgba[3], 0.5f, 1e-4);  // x = 128 -> value 0
    // VTK uses table entries 0..254 only, so the window end gets entry 254 (254/255), not 255.
    [tf getRGBA:rgba atValue:256];   XCTAssertEqualWithAccuracy(rgba[0], 254.0f / 255.0f, 1e-4); XCTAssertEqual(rgba[3], 1.0f);
    [tf getRGBA:rgba atValue:-128];  XCTAssertEqualWithAccuracy(rgba[3], 0.0f, 1e-4);  // x = 64, opacity 0
}

@end
