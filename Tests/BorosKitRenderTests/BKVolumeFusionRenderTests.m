// GPU tests for colour (RGB) scans and fusion in BKVolumeRenderer. Boros 6 (2026-11-24, vr-colour-fusion).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// Scenes (all orthographic, looking along +z, up +y, 1 mm voxels, identity orientation):
//  - grey scan: 32^3 voxels at the origin, a centred cube (voxels 8..23) of value 1000 in -1000 elsewhere;
//  - fused scan: 16^3 voxels of value 500 placed by its OWN transform, either inside the grey scan or beside it;
//  - colour scan: 16^3 voxels, all (R, G, B) = (200, 40, 0).
// The checks are behaviour, not exact pixels: fusion with an invisible fused scan leaves the picture as it was, a
// fused scan beside the first one shows on its own, colours keep their hue, MIP overlays the fused scan.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"

@interface BKVolumeFusionRenderTests : XCTestCase
@end

@implementation BKVolumeFusionRenderTests {
    id<MTLDevice> _device;
    BKVolumeRenderer *_renderer;
}

static void Identity(double m[16], double tx, double ty, double tz)
{
    for (int i = 0; i < 16; i++) m[i] = (i % 5 == 0) ? 1 : 0;
    // patient -> voxel: voxel = patient - origin
    m[12] = -tx; m[13] = -ty; m[14] = -tz;
}

- (BKVolumeTexture *)greyScan
{
    static float v[32 * 32 * 32];
    for (int z = 0; z < 32; z++) for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
        BOOL in = x >= 8 && x <= 23 && y >= 8 && y <= 23 && z >= 8 && z <= 23;
        v[(z * 32 + y) * 32 + x] = in ? 1000.0f : -1000.0f;
    }
    double m[16];
    Identity(m, 0, 0, 0);
    NSError *error = nil;
    BKVolumeTexture *t = [[BKVolumeTexture alloc] initWithFloatVoxels:v width:32 height:32 depth:32 patientToVoxel:m
                                                      minPixelSpacing:1 outOfBoundsValue:-1000 device:_device error:&error];
    XCTAssertNotNil(t, @"%@", error);
    return t;
}

// The fused scan, its first voxel at patient (ox, oy, oz).
- (BKVolumeTexture *)fusedScanAt:(double)ox :(double)oy :(double)oz
{
    static float v[16 * 16 * 16];
    for (int i = 0; i < 16 * 16 * 16; i++) v[i] = 500.0f;
    v[0] = 0.0f;   // a range for the 16-bit storage
    double m[16];
    Identity(m, ox, oy, oz);
    NSError *error = nil;
    BKVolumeTexture *t = [[BKVolumeTexture alloc] initWithFloatVoxels:v width:16 height:16 depth:16 patientToVoxel:m
                                                      minPixelSpacing:1 outOfBoundsValue:0 device:_device error:&error];
    XCTAssertNotNil(t, @"%@", error);
    return t;
}

- (void)setUp
{
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) return;
    NSError *error = nil;
    _renderer = [[BKVolumeRenderer alloc] initWithDevice:_device error:&error];
    XCTAssertNotNil(_renderer, @"%@", error);
    _renderer.volumeTexture = [self greyScan];
    _renderer.projection = BKProjectionOrthographic;
    _renderer.cameraDirection = N3VectorMake(0, 0, 1);
    _renderer.cameraUp = N3VectorMake(0, 1, 0);
    _renderer.cameraPosition = N3VectorMake(15.5, 15.5, 15.5);
    _renderer.viewWidth = 64;     // 64 x 64 pixels of 1 mm: the grey scan in the middle half
    _renderer.viewHeight = 64;
    _renderer.sampleSpacing = 0.5;
    _renderer.shadingEnabled = NO;
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];   // bone white and fairly opaque, background invisible
    [tf addColorPointAtValue:-1000 red:1 green:1 blue:1];
    [tf addColorPointAtValue:1000 red:1 green:1 blue:1];
    [tf addOpacityPointAtValue:0 opacity:0];
    [tf addOpacityPointAtValue:1000 opacity:0.3f];
    _renderer.transferFunction = tf;
}

- (BOOL)requireGPU
{
    if (_renderer) return YES;
    XCTSkip(@"No Metal GPU available");
    return NO;
}

- (BKRenderResult *)render
{
    NSError *error = nil;
    BKRenderResult *r = [_renderer renderWithWidth:64 height:64 error:&error];
    XCTAssertNotNil(r, @"%@", error);
    return r;
}

// The fused scan's look: a pure red colour table over its window 0..1000 with the given opacities.
- (void)setRedBlendOpacity:(float)opacity
{
    uint8_t r[256], g[256], b[256];
    float a[256];
    for (int i = 0; i < 256; i++) { r[i] = 255; g[i] = 0; b[i] = 0; a[i] = opacity; }
    [_renderer setBlendColorTableRed:r green:g blue:b opacities:a windowLow:0 windowHigh:1000];
}

// Pixel (x, y) of the 64 x 64 picture: its ray runs along z through patient (47 - x, 47 - y).
static void Pixel(BKRenderResult *r, NSUInteger x, NSUInteger y, uint8_t out[4]) { [r getRGBA8:out atX:x y:y]; }

// An invisible fused scan (opacity 0) must leave the 3D picture as it was (within 1 grey level: the fusion path
// composites in a different order of multiplications).
- (void)testInvisibleFusionLeavesPictureUnchanged
{
    if (![self requireGPU]) return;
    BKRenderResult *before = [self render];
    _renderer.blendVolumeTexture = [self fusedScanAt:8 :8 :8];
    [self setRedBlendOpacity:0];
    BKRenderResult *after = [self render];
    const uint8_t *a = before.rgba8Data.bytes, *b = after.rgba8Data.bytes;
    int worst = 0;
    for (NSUInteger i = 0; i < 64 * 64 * 4; i++) worst = MAX(worst, abs((int)a[i] - (int)b[i]));
    XCTAssertLessThanOrEqual(worst, 1);
}

// A visible fused scan inside the bone cube tints it red; turning fusion off again gives the plain picture back.
- (void)testFusionInsideTintsRed
{
    if (![self requireGPU]) return;
    uint8_t plain[4], fused[4];
    Pixel([self render], 32, 32, plain);
    XCTAssertEqual(plain[0], plain[2]);                         // white bone: R == B
    _renderer.blendVolumeTexture = [self fusedScanAt:8 :8 :8];
    [self setRedBlendOpacity:0.5f];
    Pixel([self render], 32, 32, fused);
    XCTAssertGreaterThan((int)fused[0], (int)fused[2] + 20);   // red now dominates
    _renderer.blendVolumeTexture = nil;
    uint8_t back[4];
    Pixel([self render], 32, 32, back);
    for (int k = 0; k < 4; k++) XCTAssertEqual(back[k], plain[k]);
}

// A fused scan BESIDE the first scan (x from 40 to 55 mm) shows on its own where the first scan is absent.
- (void)testFusionOutsideFirstScanIsVisible
{
    if (![self requireGPU]) return;
    // right = forward x up = (0,0,1) x (0,1,0) = (-1, 0, 0): pixel column x shows patient x = 47 - x, row y patient y = 47 - y.
    BKRenderResult *plain = [self render];
    _renderer.blendVolumeTexture = [self fusedScanAt:36 :8 :8];   // patient x 36..51, inside the 64 mm view
    [self setRedBlendOpacity:0.5f];
    BKRenderResult *fused = [self render];
    // Patient x = 44 -> pixel column 3; row 32 -> patient y = 15.
    uint8_t p0[4], p1[4];
    Pixel(plain, 3, 32, p0);
    Pixel(fused, 3, 32, p1);
    XCTAssertEqual(p0[3], 0);                                   // nothing there before (transparent)
    XCTAssertGreaterThan((int)p1[0], 100);                      // the fused scan's red
    XCTAssertEqual(p1[1], 0);
    // The bone cube in the middle keeps its plain look (the fused scan does not cover it).
    uint8_t c0[4], c1[4];
    Pixel(plain, 32, 32, c0);
    Pixel(fused, 32, 32, c1);
    for (int k = 0; k < 4; k++) XCTAssertLessThanOrEqual(abs((int)c0[k] - (int)c1[k]), 1);
}

// MIP: the value output is the first scan's only; the fused scan is laid over the grey picture.
- (void)testMIPOverlayKeepsValues
{
    if (![self requireGPU]) return;
    _renderer.mode = BKRenderModeMIP;
    _renderer.windowCenter = 0;
    _renderer.windowWidth = 2000;
    BKRenderResult *plain = [self render];
    _renderer.blendVolumeTexture = [self fusedScanAt:8 :8 :8];
    [self setRedBlendOpacity:0.5f];
    BKRenderResult *fused = [self render];
    XCTAssertEqualWithAccuracy([fused valueAtX:32 y:32], [plain valueAtX:32 y:32], 0.5f);   // 1000
    uint8_t g[4], f[4];
    Pixel(plain, 32, 32, g);
    Pixel(fused, 32, 32, f);
    XCTAssertGreaterThan(g[0], 250);                             // white (value 1000 at the top of the window)
    // 0.5 red over white: R = 0.5 + 0.5 = 1, G = B = 0.5.
    XCTAssertGreaterThan(f[0], 250);
    XCTAssertEqualWithAccuracy((double)f[1], 128.0, 2.0);
}

// A colour scan keeps its hue: (200, 40, 0) voxels with the pure channel ramps give a red-orange picture; with a grey
// colour table (table colours on) the same scan looks grey.
- (void)testColorScanHue
{
    if (![self requireGPU]) return;
    static uint8_t argb[16 * 16 * 16 * 4];
    for (int i = 0; i < 16 * 16 * 16; i++) { argb[4 * i] = 255; argb[4 * i + 1] = 200; argb[4 * i + 2] = 40; argb[4 * i + 3] = 0; }
    double m[16];
    Identity(m, 8, 8, 8);
    NSError *error = nil;
    BKVolumeTexture *colour = [[BKVolumeTexture alloc] initWithColorVoxels:argb bytesPerVoxel:4 redByte:1 greenByte:2 blueByte:3
                                                                     width:16 height:16 depth:16 patientToVoxel:m
                                                           minPixelSpacing:1 device:_device error:&error];
    XCTAssertNotNil(colour, @"%@", error);
    XCTAssertTrue(colour.color);
    XCTAssertEqual(colour.texture.pixelFormat, MTLPixelFormatRGBA8Unorm);
    _renderer.volumeTexture = colour;
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];   // window 0..255: grey ramp, opacity ramp
    [tf addColorPointAtValue:0 red:0 green:0 blue:0];
    [tf addColorPointAtValue:255 red:1 green:1 blue:1];
    [tf addOpacityPointAtValue:0 opacity:0];
    [tf addOpacityPointAtValue:255 opacity:0.2f];
    _renderer.transferFunction = tf;
    uint8_t px[4];
    Pixel([self render], 32, 32, px);
    XCTAssertGreaterThan(px[0], 120);                            // red strong
    XCTAssertLessThan(px[1], px[0] / 3);                         // green weak
    XCTAssertEqual(px[2], 0);                                    // no blue
    _renderer.colorChannelsUseTableColors = YES;
    Pixel([self render], 32, 32, px);
    XCTAssertLessThanOrEqual(abs((int)px[0] - (int)px[1]), 1);  // grey: R == G == B
    XCTAssertLessThanOrEqual(abs((int)px[1] - (int)px[2]), 1);
    // MIP of a colour scan: each channel windowed (0..255 window): (200, 40, 0) / 255; value = grey (200 + 40) / 3.
    _renderer.mode = BKRenderModeMIP;
    _renderer.windowCenter = 127.5f;
    _renderer.windowWidth = 255;
    BKRenderResult *mip = [self render];
    Pixel(mip, 32, 32, px);
    XCTAssertEqualWithAccuracy((double)px[0], 200.0, 2.0);
    XCTAssertEqualWithAccuracy((double)px[1], 40.0, 2.0);
    XCTAssertEqualWithAccuracy([mip valueAtX:32 y:32], 80.0f, 0.5f);
}

// The on-screen path (BKVolumeScene -> bk_raycast_texture) with a fused scan: same tint as the buffer path.
- (void)testSceneOnScreenPathDrawsFusion
{
    if (![self requireGPU]) return;
    NSError *error = nil;
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:_device error:&error];
    XCTAssertNotNil(scene, @"%@", error);
    scene.volumeTexture = [self greyScan];
    scene.renderer.transferFunction = _renderer.transferFunction;
    scene.renderer.shadingEnabled = NO;
    scene.renderer.blendVolumeTexture = [self fusedScanAt:8 :8 :8];
    uint8_t r[256], g[256], b[256]; float a[256];
    for (int i = 0; i < 256; i++) { r[i] = 255; g[i] = 0; b[i] = 0; a[i] = 0.5f; }
    [scene.renderer setBlendColorTableRed:r green:g blue:b opacities:a windowLow:0 windowHigh:1000];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:desc];
    id<MTLCommandBuffer> cb = [scene.renderer.commandQueue commandBuffer];
    XCTAssertTrue([scene encodeFrameToTexture:target commandBuffer:cb error:&error], @"%@", error);
    [cb commit];
    [cb waitUntilCompleted];
    XCTAssertNotEqual(cb.status, MTLCommandBufferStatusError);
    uint8_t px[4];
    [target getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(32, 32, 1, 1) mipmapLevel:0];
    XCTAssertGreaterThan((int)px[0], (int)px[2] + 20);   // the centre (the camera fits the scan) is tinted red
}

// Replacing the values (scissors, undo) or the texture (colour scans) keeps the crop planes (2026-11-24 fix).
- (void)testReplaceKeepsCropPlanes
{
    if (![self requireGPU]) return;
    NSError *error = nil;
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:_device error:&error];
    scene.volumeTexture = [self greyScan];
    simd_float4 plane = simd_make_float4(1, 0, 0, -10);
    [scene.renderer setPackedClipPlanes:&plane count:1];
    [scene replaceVolumeTexture:[self greyScan]];
    XCTAssertEqual(scene.renderer.clipPlaneCount, (NSUInteger)1);
    XCTAssertTrue(simd_equal([scene.renderer packedClipPlaneAtIndex:0], plane));
    [scene replaceVolumeTexture:[self fusedScanAt:0 :0 :0]];   // another size: a new scan, planes reset
    XCTAssertEqual(scene.renderer.clipPlaneCount, (NSUInteger)0);
}

// The parameter block is pinned at 592 bytes (std430, see BKShaderTypes.h) and the GPU agrees.
- (void)testParameterBlockSize
{
    if (![self requireGPU]) return;
    XCTAssertEqual([BKVolumeRenderer cpuParameterBlockSize], (NSUInteger)592);
    XCTAssertEqual([_renderer gpuParameterBlockSize], (NSUInteger)592);
}

@end
