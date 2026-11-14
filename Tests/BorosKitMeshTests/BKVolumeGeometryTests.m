// Tests for objects drawn INSIDE the volume picture (BKVolumeRenderer geometry textures,
// BKVolumeScene.geometryLayer, BKMeshGeometryLayer). Run on the real GPU; skip without one.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// The phantom (plain terms): a 64 mm cube of air with a 10 mm thick wall of bone across it
// (y from -5 to +5 mm). The front view looks along +y, so the viewer is on the -y side.
//  - a red ball in FRONT of the wall (y = -20) must be seen (red in the middle);
//  - a red ball BEHIND the wall (y = +20) must be hidden by the bone (white, no red);
//  - a ball outside the scan box must still be seen (objects are not cropped by the volume);
//  - empty object pictures must give exactly the picture without objects (same bytes);
//  - the slab cuts objects outside it (as VTK's clipping range does) and shows those inside;
//  - MIP lays objects over the picture (no depth);
//  - the scene draws objects only when asked (on-screen view yes, preset thumbnails no).
// Why: the 3D window's 3D point balls used to be painted over the volume, visible through the
// skull (user report 2026-11-14); this is the classic VTK behaviour, checked in numbers.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitMeshRender.h"
#import "BorosKitMesh.h"
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

@interface BKVolumeGeometryTests : XCTestCase
@end

@implementation BKVolumeGeometryTests {
    BKVolumeRenderer *_volume;
    BKMeshGeometryLayer *_layer;
    BKVolumeCamera *_camera;
}

static const NSUInteger kSize = 128;   // output picture, pixels

// What: the phantom volume, an opaque-bone transfer function, a front-view camera and an empty
// geometry layer on the same GPU. NO (test skipped) without a GPU.
- (BOOL)makeScene
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) return NO;
    const NSUInteger n = 64;
    float *voxels = malloc(sizeof(float) * n * n * n);
    for (NSUInteger z = 0; z < n; z++)
        for (NSUInteger y = 0; y < n; y++)
            for (NSUInteger x = 0; x < n; x++) {
                float py = -32.0f + y;
                voxels[(z * n + y) * n + x] = (py >= -5.0f && py <= 5.0f) ? 1000.0f : -1000.0f;
            }
    double orientation[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    CPRVolumeData *data = [[CPRVolumeData alloc] initWithFloatBytesNoCopy:voxels pixelsWide:n pixelsHigh:n pixelsDeep:n
                                                                    origin:N3VectorMake(-32, -32, -32) orientation:orientation
                                                                  spacingX:1 spacingY:1 spacingZ:1 freeWhenDone:YES];
    NSError *error = nil;
    _volume = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(_volume, @"%@", error);
    XCTAssertTrue([_volume setVolumeData:data error:&error], @"%@", error);
    _volume.sampleSpacing = 0.25;
    _volume.shadingEnabled = NO;   // flat white bone: easy to tell from the red balls
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    [tf addColorPointAtValue:-1000 red:1 green:1 blue:1];
    [tf addColorPointAtValue:1000 red:1 green:1 blue:1];
    [tf addOpacityPointAtValue:-1000 opacity:0];
    [tf addOpacityPointAtValue:-1 opacity:0];
    [tf addOpacityPointAtValue:1 opacity:1];
    [tf addOpacityPointAtValue:1000 opacity:1];
    _volume.transferFunction = tf;

    _layer = [[BKMeshGeometryLayer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(_layer, @"%@", error);
    _camera = [[BKVolumeCamera alloc] init];
    [_camera resetToBoxMin:N3VectorMake(-32, -32, -32) max:N3VectorMake(31, 31, 31)];
    [_camera showStandardView:BKStandardViewAnterior];   // looks along +y
    return _volume != nil && _layer != nil;
}

// What: a red ball (unlit, so its colour is exactly red) of `radius` mm at `centre`.
static BKMeshObject *BKRedBall(simd_float3 centre, float radius)
{
    BKMeshObject *o = [[BKMeshObject alloc] initWithMesh:[BKMesh sphereMeshWithCenter:centre radius:radius subdivisions:4]];
    o.color = simd_make_float3(1, 0, 0);
    o.lit = NO;
    return o;
}

// What: renders the volume (CPU-readable) with the layer's objects drawn first, exactly as the
// scene does it (objects encoded, then the ray-cast reads them). useLayer NO = no objects.
- (BKRenderResult *)renderWithLayer:(BOOL)useLayer
{
    [_camera applyToRenderer:_volume aspectRatio:1];
    _volume.geometryColorTexture = nil;
    _volume.geometryRayDistanceTexture = nil;
    if (useLayer) {
        id<MTLCommandBuffer> cb = [_volume.commandQueue commandBuffer];
        id<MTLTexture> color = nil, distance = nil;
        if ([_layer encodeGeometryWithCamera:_camera width:kSize height:kSize commandBuffer:cb
                                colorTexture:&color rayDistanceTexture:&distance]) {
            _volume.geometryColorTexture = color;
            _volume.geometryRayDistanceTexture = distance;
        }
        [cb commit];
        [cb waitUntilCompleted];
    }
    NSError *error = nil;
    BKRenderResult *r = [_volume renderWithWidth:kSize height:kSize error:&error];
    XCTAssertNotNil(r, @"%@", error);
    _volume.geometryColorTexture = nil;
    _volume.geometryRayDistanceTexture = nil;
    return r;
}

// What: is the pixel where the patient point `p` appears clearly red / clearly white?
- (void)pixelOf:(simd_float3)p x:(NSUInteger *)x y:(NSUInteger *)y
{
    // Front view (see BKMeshRendererTests): image right = patient left (+x), image up = head (+z).
    // Orthographic, parallelScale = half the picture height in mm, centred on the focal point.
    N3Vector f = _camera.focalPoint;
    double mmPerPixel = 2.0 * _camera.parallelScale / kSize;
    *x = (NSUInteger)llround(kSize / 2.0 + (p.x - f.x) / mmPerPixel - 0.5);
    *y = (NSUInteger)llround(kSize / 2.0 - (p.z - f.z) / mmPerPixel - 0.5);
}
- (BOOL)isRed:(BKRenderResult *)r at:(simd_float3)p
{
    NSUInteger x, y; uint8_t c[4];
    [self pixelOf:p x:&x y:&y];
    [r getRGBA8:c atX:x y:y];
    return c[0] > 200 && c[1] < 60 && c[2] < 60;
}
- (BOOL)isWhite:(BKRenderResult *)r at:(simd_float3)p
{
    NSUInteger x, y; uint8_t c[4];
    [self pixelOf:p x:&x y:&y];
    [r getRGBA8:c atX:x y:y];
    return c[0] > 200 && c[1] > 200 && c[2] > 200;
}

- (void)testBallInFrontSeenBallBehindHidden
{
    if (![self makeScene]) return;
    simd_float3 front = simd_make_float3(-12, -20, 0), behind = simd_make_float3(12, 20, 0);
    _layer.objects = @[BKRedBall(front, 5), BKRedBall(behind, 5)];
    BKRenderResult *r = [self renderWithLayer:YES];
    XCTAssertTrue([self isRed:r at:front], @"ball in front of the bone must be seen");
    XCTAssertTrue([self isWhite:r at:behind], @"ball behind the bone must be hidden by it");
    // Without objects both places are plain bone.
    BKRenderResult *plain = [self renderWithLayer:NO];
    XCTAssertTrue([self isWhite:plain at:front]);
    XCTAssertTrue([self isWhite:plain at:behind]);
}

- (void)testBallHalfInBoneShowsOnlyItsFront
{
    if (![self makeScene]) return;
    // Centre on the wall's front face: the front half sticks out (seen), the back half is in bone.
    simd_float3 c = simd_make_float3(0, -5, 0);
    _layer.objects = @[BKRedBall(c, 6)];
    BKRenderResult *r = [self renderWithLayer:YES];
    XCTAssertTrue([self isRed:r at:c], @"the half sticking out of the bone is seen");
}

- (void)testBallOutsideTheScanStillSeen
{
    if (![self makeScene]) return;
    // y = -45 is outside the volume box (-32..31) on the viewer's side; x inside the picture.
    simd_float3 c = simd_make_float3(20, -45, 10);
    _layer.objects = @[BKRedBall(c, 5)];
    BKRenderResult *r = [self renderWithLayer:YES];
    XCTAssertTrue([self isRed:r at:c]);
}

- (void)testEmptyObjectPicturesChangeNothing
{
    if (![self makeScene]) return;
    BKRenderResult *plain = [self renderWithLayer:NO];
    // Object pictures that hold nothing (all transparent, all +infinity): a ball far off screen.
    _layer.objects = @[BKRedBall(simd_make_float3(500, 0, 500), 1)];
    BKRenderResult *empty = [self renderWithLayer:YES];
    XCTAssertEqualObjects(empty.rgba8Data, plain.rgba8Data, @"empty object pictures must not change a single pixel");
    XCTAssertEqualObjects(empty.floatData, plain.floatData);
    // No visible objects at all: the layer declines (volume alone).
    _layer.objects = @[];
    XCTAssertFalse(_layer.hasVisibleObjects);
}

- (void)testSlabCutsObjectsOutsideIt
{
    if (![self makeScene]) return;
    simd_float3 front = simd_make_float3(-12, -20, 0), behind = simd_make_float3(12, 20, 0);
    _layer.objects = @[BKRedBall(front, 5), BKRedBall(behind, 5)];
    // Slab 16 mm thick around y = 20: the wall and the front ball are outside it.
    _volume.slabEnabled = YES;
    _volume.slabPlane = N3PlaneMake(N3VectorMake(0, 20, 0), N3VectorMake(0, 1, 0));
    _volume.slabThickness = 16;
    BKRenderResult *r = [self renderWithLayer:YES];
    XCTAssertFalse([self isRed:r at:front], @"ball outside the slab is cut away");
    XCTAssertTrue([self isRed:r at:behind], @"ball inside the slab is seen (the wall is outside the slab)");
}

- (void)testMIPLaysObjectsOver
{
    if (![self makeScene]) return;
    simd_float3 behind = simd_make_float3(12, 20, 0);
    _layer.objects = @[BKRedBall(behind, 5)];
    _volume.mode = BKRenderModeMIP;
    _volume.windowCenter = 0;
    _volume.windowWidth = 2000;
    BKRenderResult *r = [self renderWithLayer:YES];
    XCTAssertTrue([self isRed:r at:behind], @"MIP has no depth: objects are laid over");
    BKRenderResult *plain = [self renderWithLayer:NO];
    XCTAssertEqualObjects(r.floatData, plain.floatData, @"objects never change the exported values");
}

// The scene: objects only with includeGeometry YES (on-screen / captures), never in thumbnails.
- (void)testSceneDrawsObjectsOnlyWhenAsked
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil || ![self makeScene]) return;
    NSError *error = nil;
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(scene, @"%@", error);
    scene.renderer.volumeTexture = _volume.volumeTexture;
    scene.renderer.transferFunction = _volume.transferFunction;
    scene.renderer.shadingEnabled = NO;
    [scene.camera resetToBoxMin:N3VectorMake(-32, -32, -32) max:N3VectorMake(31, 31, 31)];
    [scene.camera showStandardView:BKStandardViewAnterior];
    _camera = scene.camera;   // pixelOf: uses it
    simd_float3 front = simd_make_float3(-12, -20, 0);
    _layer.objects = @[BKRedBall(front, 5)];
    scene.geometryLayer = _layer;

    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:kSize height:kSize mipmapped:NO];
    d.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    for (NSNumber *include in @[@YES, @NO]) {
        id<MTLTexture> target = [device newTextureWithDescriptor:d];
        id<MTLCommandBuffer> cb = [scene.renderer.commandQueue commandBuffer];
        XCTAssertTrue([scene encodeFrameToTexture:target commandBuffer:cb includeGeometry:include.boolValue error:&error], @"%@", error);
        [cb commit];
        [cb waitUntilCompleted];
        NSMutableData *bytes = [NSMutableData dataWithLength:kSize * kSize * 4];
        [target getBytes:bytes.mutableBytes bytesPerRow:kSize * 4 fromRegion:MTLRegionMake2D(0, 0, kSize, kSize) mipmapLevel:0];
        NSUInteger x, y;
        [self pixelOf:front x:&x y:&y];
        const uint8_t *c = (const uint8_t *)bytes.bytes + (y * kSize + x) * 4;
        BOOL red = c[0] > 200 && c[1] < 60 && c[2] < 60;
        XCTAssertEqual(red, include.boolValue, @"includeGeometry %@", include);
        // Objects must not stay attached to the shared renderer after the frame.
        XCTAssertNil(scene.renderer.geometryColorTexture);
    }
}

@end
