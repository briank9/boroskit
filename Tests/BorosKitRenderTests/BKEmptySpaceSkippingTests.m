// Tests for empty-space skipping in the Metal volume renderer (BorosKitRender).
//
// What is checked (plain language): skipping is only allowed to make the 3D picture
// faster, never different. Every test below draws the same scene twice, once with
// skipping switched off (the original way) and once with it on, and compares the two
// pictures pixel by pixel. The rule is that no colour channel of any pixel may differ
// by more than 1 step out of 255; in practice they come out identical (0 difference).
//
// Test volumes (all made up in code, no patient data):
//   - "objects": air with a few dense objects (spheres, a metal block), CBCT-like noise
//   - "full":    a volume that is almost all soft tissue (little to skip)
//   - "thin":    one-voxel-thin plates, lines and single dots placed right on and
//                next to the 8-voxel brick borders, where a skipping mistake would show
//   - "phantom": a CT-like head: skin, skull shell, brain, dense "teeth", air around,
//                with non-square voxels
// Each is drawn with several colour/opacity rules (real Horos presets plus a bone
// rule, a soft-tissue rule and a very narrow one), several camera angles (including
// rays running exactly along an axis), both projections and odd window sizes, plus
// MIP / MinIP / average, slab, crop box and clipping plane.
//
// The last test is a benchmark (it only logs times, it never fails on speed).

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

@interface BKEmptySpaceSkippingTests : XCTestCase
@end

// A tiny repeatable random number generator, so the "noise" is the same every run.
static uint32_t BKTestRandom(uint32_t *state)
{
    *state = *state * 1664525u + 1013904223u;
    return *state >> 8;
}

// Noise between -amplitude and +amplitude, rounded to whole numbers like real CT.
static float BKTestNoise(uint32_t *state, float amplitude)
{
    return roundf(((float)(BKTestRandom(state) & 0xFFFF) / 65535.0f * 2.0f - 1.0f) * amplitude);
}

@implementation BKEmptySpaceSkippingTests {
    id<MTLDevice> _device;
    BKPresetLoader *_loader;
    NSURL *_presetsURL;
    float _worstDifference;   // largest channel difference seen in this test (0..255)
}

- (void)setUp
{
    _device = MTLCreateSystemDefaultDevice();
    NSURL *fixtures = [SWIFTPM_MODULE_BUNDLE URLForResource:@"Fixtures" withExtension:nil];
    _presetsURL = [fixtures URLByAppendingPathComponent:@"3DPRESETS"];
    _loader = [[BKPresetLoader alloc] init];
    _loader.clutDirectories = @[[fixtures URLByAppendingPathComponent:@"CLUTs"]];
    _worstDifference = 0;
}

// Skips the current test when no GPU is available.
- (BOOL)requireGPU
{
    if (_device) return YES;
    XCTSkip(@"No Metal GPU available");
    return NO;
}

#pragma mark - Test volumes

// Wraps a float array (freed by the volume) as a CT volume with the given voxel size.
- (CPRVolumeData *)volumeWithBytes:(float *)bytes w:(NSUInteger)w h:(NSUInteger)h d:(NSUInteger)d
                           spacing:(N3Vector)spacing
{
    double orientation[9] = {1,0,0, 0,1,0, 0,0,1};
    return [[CPRVolumeData alloc] initWithFloatBytesNoCopy:bytes pixelsWide:w pixelsHigh:h pixelsDeep:d
                                                     origin:N3VectorZero orientation:orientation
                                                   spacingX:spacing.x spacingY:spacing.y spacingZ:spacing.z
                                               freeWhenDone:YES];
}

// Air (-1000 with noise) holding two bone spheres, a tooth-dense sphere and a metal
// block. Sizes are deliberately not multiples of 8, so the last bricks are partial.
- (CPRVolumeData *)objectsVolume
{
    const NSUInteger w = 90, h = 77, d = 70;
    float *v = malloc(sizeof(float) * w * h * d);
    uint32_t seed = 1;
    for (NSUInteger z = 0; z < d; z++)
        for (NSUInteger y = 0; y < h; y++)
            for (NSUInteger x = 0; x < w; x++) {
                float value = -1000.0f + BKTestNoise(&seed, 30);
                double ax = x - 30.0, ay = y - 35.0, az = z - 30.0;
                double bx = x - 62.0, by = y - 40.0, bz = z - 45.0;
                double cx = x - 45.0, cy = y - 20.0, cz = z - 15.0;
                if (ax * ax + ay * ay + az * az <= 12.0 * 12.0) value = 1200.0f + BKTestNoise(&seed, 80);
                if (bx * bx + by * by + bz * bz <= 9.0 * 9.0)   value = 700.0f + BKTestNoise(&seed, 80);
                if (cx * cx + cy * cy + cz * cz <= 5.0 * 5.0)   value = 2500.0f;
                if (x >= 70 && x <= 74 && y >= 60 && y <= 70 && z >= 10 && z <= 20) value = 3000.0f;
                v[(z * h + y) * w + x] = value;
            }
    return [self volumeWithBytes:v w:w h:h d:d spacing:N3VectorMake(1, 1, 1)];
}

// Almost all soft tissue (40 with noise) with a bone core and air only in one corner,
// so most bricks are NOT empty: checks that skipping costs nothing in quality there.
- (CPRVolumeData *)fullVolume
{
    const NSUInteger w = 64, h = 64, d = 64;
    float *v = malloc(sizeof(float) * w * h * d);
    uint32_t seed = 2;
    for (NSUInteger z = 0; z < d; z++)
        for (NSUInteger y = 0; y < h; y++)
            for (NSUInteger x = 0; x < w; x++) {
                float value = 40.0f + BKTestNoise(&seed, 60);
                if (x + y + z < 30) value = -1000.0f + BKTestNoise(&seed, 20);
                double cx = x - 32.0, cy = y - 32.0, cz = z - 32.0;
                if (cx * cx + cy * cy + cz * cz <= 15.0 * 15.0) value = 900.0f + 20.0f * (float)(z % 7);
                v[(z * h + y) * w + x] = value;
            }
    return [self volumeWithBytes:v w:w h:h d:d spacing:N3VectorMake(1, 1, 1)];
}

// Air with one-voxel-thin dense structures on and next to the brick borders (bricks
// are 8 voxels: borders at 0, 8, 16, ...). A voxel at index 7 or 8 sits right at a
// border; if the one-voxel safety margin were missing these would vanish or flicker.
- (CPRVolumeData *)thinVolume
{
    const NSUInteger w = 48, h = 41, d = 40;
    float *v = malloc(sizeof(float) * w * h * d);
    for (NSUInteger i = 0; i < w * h * d; i++) v[i] = -1000.0f;
    for (NSUInteger z = 0; z < d; z++)
        for (NSUInteger y = 0; y < h; y++)
            for (NSUInteger x = 0; x < w; x++) {
                float *p = &v[(z * h + y) * w + x];
                if (x == 15 && y > 4 && y < 36 && z > 4 && z < 36) *p = 1500.0f;  // plate just below a border
                if (y == 24 && x > 18 && x < 44 && z > 2 && z < 30) *p = 1500.0f;  // plate right on a border
                if (x == 32 && y == 7 && z > 0 && z < 39) *p = 2000.0f;           // line along z on a corner edge
                if (x == 40 && z == 16) *p = 1800.0f;                              // line along y on a border
            }
    // Single dense voxels on brick corners and next to them.
    NSUInteger dots[][3] = {{7,7,7}, {8,8,8}, {23,31,7}, {24,32,8}, {47,40,39}, {0,0,0}, {39,8,31}};
    for (NSUInteger i = 0; i < sizeof(dots) / sizeof(dots[0]); i++)
        v[(dots[i][2] * h + dots[i][1]) * w + dots[i][0]] = 2500.0f;
    return [self volumeWithBytes:v w:w h:h d:d spacing:N3VectorMake(1, 1, 1)];
}

// A CT-like head: air around an ellipsoid of skin/soft tissue, a skull shell, brain
// inside, and a row of very dense "teeth" at the front. Non-square voxels
// (0.4 x 0.4 x 0.6 mm) like many CBCT scans.
- (CPRVolumeData *)phantomVolume
{
    const NSUInteger w = 96, h = 96, d = 72;
    float *v = malloc(sizeof(float) * w * h * d);
    uint32_t seed = 3;
    for (NSUInteger z = 0; z < d; z++)
        for (NSUInteger y = 0; y < h; y++)
            for (NSUInteger x = 0; x < w; x++) {
                double ex = (x - 48.0) / 40.0, ey = (y - 50.0) / 44.0, ez = (z - 36.0) / 33.0;
                double r = sqrt(ex * ex + ey * ey + ez * ez);
                float value;
                if (r > 1.0) value = -1000.0f + BKTestNoise(&seed, 40);       // air
                else if (r > 0.93) value = 30.0f + BKTestNoise(&seed, 40);    // skin / soft tissue
                else if (r > 0.82) value = 1300.0f + BKTestNoise(&seed, 150); // skull
                else value = 35.0f + BKTestNoise(&seed, 25);                   // brain
                // Teeth: dense little cylinders in an arc at the front, lower half.
                for (int t = 0; t < 8; t++) {
                    double angle = -0.9 + t * (1.8 / 7.0);
                    double tx = 48.0 + 26.0 * sin(angle), ty = 50.0 - 30.0 * cos(angle);
                    double dx = x - tx, dy = y - ty;
                    if (dx * dx + dy * dy <= 9.0 && z >= 12 && z <= 26) value = 2600.0f + BKTestNoise(&seed, 100);
                }
                v[(z * h + y) * w + x] = value;
            }
    return [self volumeWithBytes:v w:w h:h d:d spacing:N3VectorMake(0.4, 0.4, 0.6)];
}

#pragma mark - Colour/opacity rules

// Bone: invisible below 200, ramping to fairly solid white bone at 1500.
- (BKTransferFunction *)boneFunction
{
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    [tf addColorPointAtValue:200 red:0.9 green:0.8 blue:0.6];
    [tf addColorPointAtValue:1500 red:1 green:1 blue:1];
    [tf addOpacityPointAtValue:-1024 opacity:0];
    [tf addOpacityPointAtValue:200 opacity:0];
    [tf addOpacityPointAtValue:1500 opacity:0.8];
    [tf addOpacityPointAtValue:3071 opacity:0.9];
    return tf;
}

// Soft tissue: air invisible, skin and soft tissue faint red, bone white and solid.
- (BKTransferFunction *)softTissueFunction
{
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    [tf addColorPointAtValue:-500 red:0.6 green:0.2 blue:0.1];
    [tf addColorPointAtValue:100 red:0.9 green:0.5 blue:0.4];
    [tf addColorPointAtValue:1000 red:1 green:1 blue:0.9];
    [tf addOpacityPointAtValue:-1024 opacity:0];
    [tf addOpacityPointAtValue:-300 opacity:0];
    [tf addOpacityPointAtValue:100 opacity:0.15];
    [tf addOpacityPointAtValue:1000 opacity:0.6];
    [tf addOpacityPointAtValue:3071 opacity:0.6];
    return tf;
}

// A very narrow window: only values 1480..1520 are visible at all (a thin shell
// inside smooth transitions). Hardest case for the "is this brick see-through?" test.
- (BKTransferFunction *)narrowFunction
{
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    [tf addColorPointAtValue:1480 red:0.2 green:0.6 blue:1];
    [tf addColorPointAtValue:1520 red:1 green:0.9 blue:0.3];
    [tf addOpacityPointAtValue:-1024 opacity:0];
    [tf addOpacityPointAtValue:1480 opacity:0];
    [tf addOpacityPointAtValue:1500 opacity:0.7];
    [tf addOpacityPointAtValue:1520 opacity:0];
    [tf addOpacityPointAtValue:3071 opacity:0];
    return tf;
}

// Loads a real Horos/Boros preset from the test fixtures.
- (BKPreset *)preset:(NSString *)name
{
    NSURL *url = [_presetsURL URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];
    NSError *error = nil;
    BKPreset *preset = [_loader presetWithContentsOfURL:url error:&error];
    XCTAssertNotNil(preset, @"%@: %@", name, error);
    return preset;
}

#pragma mark - Comparing

// Points an orthographic or perspective camera at the volume centre from `direction`,
// framing the whole volume.
- (void)aimRenderer:(BKVolumeRenderer *)r direction:(N3Vector)direction up:(N3Vector)up perspective:(BOOL)perspective
{
    BKVolumeTexture *vt = r.volumeTexture;
    N3AffineTransform voxelToPatient = N3AffineTransformInvert(vt.volumeTransform);
    N3Vector centre = N3VectorApplyTransform(N3VectorMake((vt.pixelsWide - 1) / 2.0, (vt.pixelsHigh - 1) / 2.0,
                                                          (vt.pixelsDeep - 1) / 2.0), voxelToPatient);
    N3Vector corner = N3VectorApplyTransform(N3VectorMake(vt.pixelsWide - 1, vt.pixelsHigh - 1, vt.pixelsDeep - 1), voxelToPatient);
    N3Vector origin = N3VectorApplyTransform(N3VectorZero, voxelToPatient);
    CGFloat diagonal = N3VectorDistance(corner, origin);
    r.cameraDirection = direction;
    r.cameraUp = up;
    if (perspective) {
        r.projection = BKProjectionPerspective;
        r.fieldOfView = 30;
        r.cameraPosition = N3VectorAdd(centre, N3VectorScalarMultiply(N3VectorNormalize(direction), -1.6 * diagonal));
    } else {
        r.projection = BKProjectionOrthographic;
        r.cameraPosition = centre;
        r.viewWidth = r.viewHeight = diagonal;
    }
}

// Renders the current settings with skipping off and on and returns the largest
// difference of any colour channel of any pixel (0..255). Also checks the full-
// precision values (projection modes: the CT value; 3D mode: opacity).
- (int)differenceForRenderer:(BKVolumeRenderer *)r width:(NSUInteger)w height:(NSUInteger)h label:(NSString *)label
{
    NSError *error = nil;
    r.skipsEmptySpace = NO;
    BKRenderResult *off = [r renderWithWidth:w height:h error:&error];
    XCTAssertNotNil(off, @"%@", error);
    r.skipsEmptySpace = YES;
    BKRenderResult *on = [r renderWithWidth:w height:h error:&error];
    XCTAssertNotNil(on, @"%@", error);
    if (!off || !on) return 255;

    const uint8_t *a = off.rgba8Data.bytes, *b = on.rgba8Data.bytes;
    int worst = 0;
    NSUInteger differing = 0;
    for (NSUInteger i = 0; i < w * h * 4; i++) {
        int diff = abs((int)a[i] - (int)b[i]);
        if (diff) differing++;
        worst = MAX(worst, diff);
    }
    const float *fa = off.floatData.bytes, *fb = on.floatData.bytes;
    float worstValue = 0;
    for (NSUInteger i = 0; i < w * h; i++) {
        if (isnan(fa[i]) && isnan(fb[i])) continue;
        worstValue = fmaxf(worstValue, fabsf(fa[i] - fb[i]));
    }
    XCTAssertLessThanOrEqual(worst, 1, @"%@: skipping changed the picture (max %d/255, %lu channels differ)",
                             label, worst, (unsigned long)differing);
    // 3D mode: opacity 0..1, allow the same 1/255; projection modes: CT values must match.
    XCTAssertLessThanOrEqual(worstValue, r.mode == BKRenderModeComposite ? 1.0f / 255.0f : 0.0f,
                             @"%@: full-precision values differ by %g", label, worstValue);
    if (worst > 0 || worstValue > 0)
        NSLog(@"[skipping] %@: max diff %d/255 (%lu channels), value diff %g", label, worst, (unsigned long)differing, worstValue);
    _worstDifference = MAX(_worstDifference, (float)worst);
    return worst;
}

// Camera directions: straight on (rays exactly along axes, where the "does not move
// along this axis" case in the skipping code is used), oblique, and from behind/below.
- (NSArray<NSArray<NSValue *> *> *)cameraDirections
{
    N3Vector dirs[][2] = {
        {{0, 1, 0},       {0, 0, 1}},    // front
        {{1, 0, 0},       {0, 0, 1}},    // side
        {{0, 0, -1},      {0, 1, 0}},    // from above
        {{0.6, 0.7, 0.3}, {0, 0, 1}},    // oblique
        {{-0.4, -0.5, 0.75}, {0, 1, 0}}, // oblique from below/behind
        {{1, 1, 1},       {0, 0, 1}},    // exact diagonal (rays hit brick corners)
    };
    NSMutableArray *out = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++)
        [out addObject:@[[NSValue valueWithBytes:&dirs[i][0] objCType:@encode(N3Vector)],
                         [NSValue valueWithBytes:&dirs[i][1] objCType:@encode(N3Vector)]]];
    return out;
}

// Runs the comparison for one volume over all colour rules, camera angles, both
// projections and a few window sizes, in 3D (composite) mode.
- (void)checkCompositeForVolume:(CPRVolumeData *)volume name:(NSString *)name
{
    NSError *error = nil;
    BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:_device error:&error];
    XCTAssertNotNil(r, @"%@", error);
    XCTAssertTrue([r setVolumeData:volume error:&error], @"%@", error);
    r.mode = BKRenderModeComposite;

    // Each entry: a label and a block that sets up the colour rule (and lighting).
    NSArray *rules = @[
        @[@"bone",   ^{ r.transferFunction = [self boneFunction]; r.shadingEnabled = YES; }],
        @[@"soft",   ^{ r.transferFunction = [self softTissueFunction]; r.shadingEnabled = YES; }],
        @[@"narrow", ^{ r.transferFunction = [self narrowFunction]; r.shadingEnabled = NO; }],
        @[@"preset Bone + Skin", ^{ [[self preset:@"Bone + Skin"] applyToRenderer:r]; }],
        @[@"preset Standard",    ^{ [[self preset:@"Standard"] applyToRenderer:r]; }],
        @[@"preset Dark Bone",   ^{ [[self preset:@"Dark Bone"] applyToRenderer:r]; }],
    ];
    NSUInteger sizes[][2] = {{97, 61}, {160, 160}, {211, 127}};
    NSUInteger s = 0;
    for (NSArray *rule in rules) {
        ((void (^)(void))rule[1])();
        for (NSArray<NSValue *> *pair in [self cameraDirections]) {
            N3Vector dir, up;
            [pair[0] getValue:&dir];
            [pair[1] getValue:&up];
            for (int perspective = 0; perspective < 2; perspective++) {
                [self aimRenderer:r direction:dir up:up perspective:perspective];
                NSUInteger *size = sizes[s++ % 3];
                NSString *label = [NSString stringWithFormat:@"%@ / %@ / dir (%.2f %.2f %.2f) / %@ / %lux%lu", name, rule[0],
                                   dir.x, dir.y, dir.z, perspective ? @"perspective" : @"ortho",
                                   (unsigned long)size[0], (unsigned long)size[1]];
                [self differenceForRenderer:r width:size[0] height:size[1] label:label];
            }
        }
    }
    NSLog(@"[skipping] %@ composite: worst difference %.0f/255", name, _worstDifference);
}

#pragma mark - Image-equality tests (3D mode)

- (void)testObjectsInAirLookIdentical
{
    if (![self requireGPU]) return;
    [self checkCompositeForVolume:[self objectsVolume] name:@"objects"];
}

- (void)testMostlyFullVolumeLooksIdentical
{
    if (![self requireGPU]) return;
    [self checkCompositeForVolume:[self fullVolume] name:@"full"];
}

- (void)testThinStructuresAtBrickBordersLookIdentical
{
    if (![self requireGPU]) return;
    [self checkCompositeForVolume:[self thinVolume] name:@"thin"];
}

- (void)testHeadPhantomLooksIdentical
{
    if (![self requireGPU]) return;
    [self checkCompositeForVolume:[self phantomVolume] name:@"phantom"];
}

// Crop box, clipping plane, slab and a fine sample step change where rays start and
// stop; skipping must still give the same picture.
- (void)testCropClipSlabAndStepLookIdentical
{
    if (![self requireGPU]) return;
    NSError *error = nil;
    BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:_device error:&error];
    XCTAssertTrue([r setVolumeData:[self phantomVolume] error:&error], @"%@", error);
    r.transferFunction = [self boneFunction];
    [self aimRenderer:r direction:N3VectorMake(0.3, 1, 0.2) up:N3VectorMake(0, 0, 1) perspective:NO];

    r.cropMin = N3VectorMake(5, 9, 3);
    r.cropMax = N3VectorMake(83, 70, 61);
    [self differenceForRenderer:r width:150 height:120 label:@"crop box"];

    r.clipPlaneEnabled = YES;
    r.clipPlane = N3PlaneMake(N3VectorMake(19, 20, 21), N3VectorMake(0.2, -1, 0.4));
    [self differenceForRenderer:r width:150 height:120 label:@"crop + clip plane"];

    r.slabEnabled = YES;
    r.slabPlane = N3PlaneMake(N3VectorMake(19, 20, 21), N3VectorMake(0.3, 1, 0.2));
    r.slabThickness = 9;
    [self differenceForRenderer:r width:150 height:120 label:@"crop + clip + slab"];

    // Rotated crop box as 6 extra planes (the VR window's crop box in Metal).
    r.slabEnabled = NO;
    r.clipPlaneEnabled = NO;
    N3Plane box[6] = {
        N3PlaneMake(N3VectorMake(60, 40, 30), N3VectorNormalize(N3VectorMake(1, 0.3, 0.1))),
        N3PlaneMake(N3VectorMake(15, 30, 30), N3VectorNormalize(N3VectorMake(-1, -0.3, -0.1))),
        N3PlaneMake(N3VectorMake(40, 60, 30), N3VectorNormalize(N3VectorMake(-0.3, 1, 0.2))),
        N3PlaneMake(N3VectorMake(40, 12, 30), N3VectorNormalize(N3VectorMake(0.3, -1, -0.2))),
        N3PlaneMake(N3VectorMake(40, 40, 50), N3VectorMake(0, 0, 1)),
        N3PlaneMake(N3VectorMake(40, 40, 8), N3VectorMake(0, 0, -1)) };
    [r setClipPlanes:box count:6];
    [self differenceForRenderer:r width:150 height:120 label:@"crop + rotated box planes"];
    [r setClipPlanes:NULL count:0];

    r.clipPlaneEnabled = NO;
    r.sampleSpacing = 0.07;   // many samples per voxel
    [self differenceForRenderer:r width:150 height:120 label:@"fine step"];
    r.sampleSpacing = 1.3;    // more than a voxel between samples
    [self differenceForRenderer:r width:150 height:120 label:@"coarse step"];
}

// Changing the colour rule on the same renderer must re-decide which bricks are
// see-through (an out-of-date decision would hide newly visible tissue).
- (void)testChangingTheTransferFunctionUpdatesSkipping
{
    if (![self requireGPU]) return;
    NSError *error = nil;
    BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:_device error:&error];
    XCTAssertTrue([r setVolumeData:[self phantomVolume] error:&error], @"%@", error);
    [self aimRenderer:r direction:N3VectorMake(0, 1, 0) up:N3VectorMake(0, 0, 1) perspective:NO];
    NSArray *functions = @[[self narrowFunction], [self boneFunction], [self softTissueFunction], [self narrowFunction]];
    for (BKTransferFunction *tf in functions) {
        r.transferFunction = tf;
        // Render with skipping first, so the brick decision is made for this function
        // before the comparison render.
        r.skipsEmptySpace = YES;
        XCTAssertNotNil([r renderWithWidth:64 height:64 error:&error]);
        [self differenceForRenderer:r width:128 height:128 label:@"after transfer function change"];
    }
    // Same for switching to another volume on the same renderer.
    XCTAssertTrue([r setVolumeData:[self objectsVolume] error:&error], @"%@", error);
    [self aimRenderer:r direction:N3VectorMake(0, 1, 0) up:N3VectorMake(0, 0, 1) perspective:YES];
    [self differenceForRenderer:r width:128 height:128 label:@"after volume change"];
}

#pragma mark - Image-equality tests (projection modes)

// MIP / MinIP / average must give exactly the same CT values with skipping on.
- (void)testProjectionModesAreIdentical
{
    if (![self requireGPU]) return;
    NSArray<CPRVolumeData *> *volumes = @[[self objectsVolume], [self thinVolume], [self phantomVolume], [self fullVolume]];
    NSArray<NSNumber *> *modes = @[@(BKRenderModeMIP), @(BKRenderModeMinIP), @(BKRenderModeAverage)];
    NSError *error = nil;
    for (CPRVolumeData *volume in volumes) {
        BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:_device error:&error];
        XCTAssertTrue([r setVolumeData:volume error:&error], @"%@", error);
        r.windowCenter = 500;
        r.windowWidth = 3000;
        for (NSNumber *mode in modes) {
            r.mode = (BKRenderMode)mode.intValue;
            for (NSArray<NSValue *> *pair in [self cameraDirections]) {
                N3Vector dir, up;
                [pair[0] getValue:&dir];
                [pair[1] getValue:&up];
                for (int perspective = 0; perspective < 2; perspective++) {
                    [self aimRenderer:r direction:dir up:up perspective:perspective];
                    NSString *label = [NSString stringWithFormat:@"mode %d / dir (%.2f %.2f %.2f) / %@", mode.intValue,
                                       dir.x, dir.y, dir.z, perspective ? @"perspective" : @"ortho"];
                    [self differenceForRenderer:r width:113 height:89 label:label];
                }
            }
            // Thick MPR-style slab (how the MPR views use MIP).
            [self aimRenderer:r direction:N3VectorMake(0, 0, 1) up:N3VectorMake(0, 1, 0) perspective:NO];
            r.slabEnabled = YES;
            r.slabPlane = N3PlaneMake(r.cameraPosition, N3VectorMake(0, 0, 1));
            r.slabThickness = 12;
            [self differenceForRenderer:r width:113 height:89 label:[NSString stringWithFormat:@"mode %d / slab", mode.intValue]];
            r.slabEnabled = NO;
        }
    }
}

// The scene passes the switch through to its renderer.
- (void)testSceneSwitchReachesRenderer
{
    if (![self requireGPU]) return;
    NSError *error = nil;
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:_device error:&error];
    XCTAssertNotNil(scene, @"%@", error);
    XCTAssertTrue(scene.skipsEmptySpace, @"skipping should be on by default");
    scene.skipsEmptySpace = NO;
    XCTAssertFalse(scene.renderer.skipsEmptySpace);
    scene.skipsEmptySpace = YES;
    XCTAssertTrue(scene.renderer.skipsEmptySpace);
}

#pragma mark - Benchmark

// Times one frame drawn straight into a GPU texture (like the on-screen 3D view),
// measured on the GPU itself. Returns milliseconds.
- (double)gpuMillisecondsForRenderer:(BKVolumeRenderer *)r target:(id<MTLTexture>)target
{
    id<MTLCommandBuffer> cb = [r.commandQueue commandBuffer];
    NSError *error = nil;
    XCTAssertTrue([r encodeRenderToTexture:target commandBuffer:cb backgroundColor:simd_make_float4(0, 0, 0, 1) error:&error], @"%@", error);
    [cb commit];
    [cb waitUntilCompleted];
    return (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
}

// Not a pass/fail test: logs milliseconds per frame with skipping off and on for a
// CBCT-sized volume (512 x 512 x 700) drawn at a big-screen size (3400 x 1900), for
// a few colour rules and angles, and the speed-up. Look for "[benchmark]" in the log.
- (void)testBenchmarkLargeVolume
{
    if (![self requireGPU]) return;
    const NSUInteger w = 512, h = 512, d = 700;
    float *v = malloc(sizeof(float) * w * h * d);
    if (!v) { XCTSkip(@"Not enough memory for the benchmark volume"); return; }
    // Head-like phantom, as in -phantomVolume but at full CBCT size (0.3 mm voxels).
    uint32_t seed = 4;
    for (NSUInteger z = 0; z < d; z++)
        for (NSUInteger y = 0; y < h; y++)
            for (NSUInteger x = 0; x < w; x++) {
                double ex = (x - 256.0) / 215.0, ey = (y - 256.0) / 235.0, ez = (z - 350.0) / 330.0;
                double r2 = ex * ex + ey * ey + ez * ez;
                float value;
                if (r2 > 1.0) value = -1000.0f + BKTestNoise(&seed, 40);
                else if (r2 > 0.93 * 0.93) value = 30.0f + BKTestNoise(&seed, 40);
                else if (r2 > 0.82 * 0.82) value = 1300.0f + BKTestNoise(&seed, 150);
                else value = 35.0f + BKTestNoise(&seed, 25);
                // Teeth: a ring of dense cylinders in the lower part.
                if (z >= 120 && z <= 200) {
                    double dx = x - 256.0, dy = y - 256.0;
                    double rr = sqrt(dx * dx + dy * dy);
                    if (rr > 120 && rr < 150 && dy < 0) value = 2600.0f + BKTestNoise(&seed, 100);
                }
                v[(z * h + y) * w + x] = value;
            }
    CPRVolumeData *volume = [self volumeWithBytes:v w:w h:h d:d spacing:N3VectorMake(0.3, 0.3, 0.3)];

    NSError *error = nil;
    BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:_device error:&error];
    XCTAssertTrue([r setVolumeData:volume error:&error], @"%@", error);

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:3400 height:1900 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [_device newTextureWithDescriptor:desc];

    // One-time cost of measuring the bricks (first render with skipping on).
    [self aimRenderer:r direction:N3VectorMake(0, 1, 0) up:N3VectorMake(0, 0, 1) perspective:NO];
    r.transferFunction = [self boneFunction];
    r.skipsEmptySpace = YES;
    NSDate *start = [NSDate date];
    [self gpuMillisecondsForRenderer:r target:target];
    NSLog(@"[benchmark] first frame with skipping (includes measuring the bricks once): %.1f ms",
          -start.timeIntervalSinceNow * 1000.0);

    NSArray *rules = @[
        @[@"bone",               ^{ r.mode = BKRenderModeComposite; r.transferFunction = [self boneFunction]; }],
        @[@"soft tissue",        ^{ r.mode = BKRenderModeComposite; r.transferFunction = [self softTissueFunction]; }],
        @[@"preset Bone + Skin", ^{ r.mode = BKRenderModeComposite; [[self preset:@"Bone + Skin"] applyToRenderer:r]; }],
        @[@"MIP",                ^{ r.mode = BKRenderModeMIP; }],
    ];
    N3Vector directions[] = {{0, 1, 0}, {0.6, 0.7, 0.3}, {1, 0, 0}};
    const int frames = 3;
    for (NSArray *rule in rules) {
        ((void (^)(void))rule[1])();
        double totalOff = 0, totalOn = 0;
        for (size_t k = 0; k < sizeof(directions) / sizeof(directions[0]); k++) {
            [self aimRenderer:r direction:directions[k] up:N3VectorMake(0, 0, 1) perspective:NO];
            r.skipsEmptySpace = NO;
            [self gpuMillisecondsForRenderer:r target:target];   // warm-up
            for (int f = 0; f < frames; f++) totalOff += [self gpuMillisecondsForRenderer:r target:target];
            r.skipsEmptySpace = YES;
            [self gpuMillisecondsForRenderer:r target:target];   // warm-up
            for (int f = 0; f < frames; f++) totalOn += [self gpuMillisecondsForRenderer:r target:target];
        }
        double n = frames * (double)(sizeof(directions) / sizeof(directions[0]));
        NSLog(@"[benchmark] 512x512x700 at 3400x1900, %@: off %.1f ms/frame, on %.1f ms/frame, speed-up x%.2f",
              rule[0], totalOff / n, totalOn / n, totalOff / MAX(totalOn, 1e-6));
    }
}

@end
