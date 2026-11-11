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
