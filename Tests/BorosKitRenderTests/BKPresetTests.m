// Tests for the 3D preset loader (BKPresetLoader / BKPreset).
//
// Fixtures: all 29 built-in Horos/Boros 3D presets (Fixtures/3DPRESETS, copied
// unchanged from Horos/Resources/3DPRESETS) and the four colour tables they use
// (Fixtures/CLUTs). The expected numbers below come from how Horos' VRView feeds the
// same files to VTK, so passing tests mean the Metal engine gets the same colours and
// opacities as the VR window.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

@interface BKPresetTests : XCTestCase
@end

@implementation BKPresetTests {
    BKPresetLoader *_loader;
    NSURL *_presetsURL;
    NSURL *_clutsURL;
}

// Points the loader at the fixture CLUT folder, like the app points it at
// "Horos Data/CLUTs" + its built-in CLUTs folder.
- (void)setUp
{
    NSURL *fixtures = [SWIFTPM_MODULE_BUNDLE URLForResource:@"Fixtures" withExtension:nil];
    XCTAssertNotNil(fixtures, @"test fixtures missing from the test bundle");
    _presetsURL = [fixtures URLByAppendingPathComponent:@"3DPRESETS"];
    _clutsURL = [fixtures URLByAppendingPathComponent:@"CLUTs"];
    _loader = [[BKPresetLoader alloc] init];
    _loader.clutDirectories = @[_clutsURL];
}

// Loads one fixture preset by file name and fails the test if it doesn't load.
- (BKPreset *)preset:(NSString *)name
{
    NSError *error = nil;
    NSURL *url = [_presetsURL URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];
    BKPreset *preset = [_loader presetWithContentsOfURL:url error:&error];
    XCTAssertNotNil(preset, @"%@: %@", name, error);
    return preset;
}

// Reads entry i of a channel ("Red"/"Green"/"Blue") straight from a fixture CLUT file.
- (float)clut:(NSString *)name channel:(NSString *)channel entry:(int)i
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfURL:[_clutsURL URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]]];
    return [d[channel][i] floatValue] / 255.0f;
}

// Every built-in preset must load, with every CLUT / opacity / lighting name resolved
// (no fallbacks), and keep its name and group.
- (void)testAllBuiltInPresetsLoad
{
    NSDictionary *failures = nil;
    NSArray<BKPreset *> *presets = [_loader presetsInDirectoryAtURL:_presetsURL failures:&failures];
    XCTAssertEqual(presets.count, 29u);
    XCTAssertEqual(failures.count, 0u, @"%@", failures);
    for (BKPreset *p in presets) {
        XCTAssertEqual(p.warnings.count, 0u, @"%@: %@", p.name, p.warnings);
        XCTAssertTrue(p.name.length > 0);
        XCTAssertTrue(p.groupName.length > 0, @"%@", p.name);
        BKTransferFunction *tf = [p transferFunctionForVolumeMinimum:-1024 volumeMaximum:3071];
        XCTAssertGreaterThan(tf.opacityPointCount, 0u, @"%@", p.name);
        if (p.usesAdvancedCLUT) XCTAssertGreaterThan(p.advancedCurves.count, 0u, @"%@", p.name);
        else if (![p.clutName isEqualToString:@"No CLUT"]) XCTAssertEqual(p.clutRed.length, 256u, @"%@", p.name);
    }
}

// "Standard": VR Muscles-Bones colours + Logarithmic Inverse opacity across
// WL 199.64 / WW 243.73, Default lighting, parallel projection.
- (void)testStandardPreset
{
    BKPreset *p = [self preset:@"Standard"];
    XCTAssertFalse(p.usesAdvancedCLUT);
    XCTAssertEqualObjects(p.clutName, @"VR Muscles-Bones");
    XCTAssertEqualWithAccuracy(p.windowCenter, 199.6426f, 1e-3);
    XCTAssertEqualWithAccuracy(p.windowWidth, 243.7324f, 1e-3);
    XCTAssertTrue(p.shadingEnabled);
    XCTAssertEqualWithAccuracy(p.diffuse, 0.9f, 1e-6);
    XCTAssertEqual(p.projection, BKProjectionOrthographic);
    XCTAssertEqual(p.opacityPoints.length / sizeof(CGPoint), 256u);

    float start = p.windowCenter - p.windowWidth / 2, end = p.windowCenter + p.windowWidth / 2;
    BKTransferFunction *tf = p.transferFunction;
    float rgba[4];

    // Window start: table entry 0, opacity 0 (curve starts at x = 0).
    [tf getRGBA:rgba atValue:start];
    XCTAssertEqualWithAccuracy(rgba[0], [self clut:@"VR Muscles-Bones" channel:@"Red" entry:0], 1e-4);
    XCTAssertEqualWithAccuracy(rgba[3], 0.0f, 1e-6);

    // Window end and beyond (e.g. dense bone): table entry 254, opacity 1.
    [tf getRGBA:rgba atValue:2000];
    XCTAssertEqualWithAccuracy(rgba[0], [self clut:@"VR Muscles-Bones" channel:@"Red" entry:254], 1e-4);
    XCTAssertEqualWithAccuracy(rgba[1], [self clut:@"VR Muscles-Bones" channel:@"Green" entry:254], 1e-4);
    XCTAssertEqualWithAccuracy(rgba[2], [self clut:@"VR Muscles-Bones" channel:@"Blue" entry:254], 1e-4);
    XCTAssertEqualWithAccuracy(rgba[3], 1.0f, 1e-6);

    // Colour entry 100 sits exactly at start + 100/254 of the window (VTK spacing).
    [tf getRGBA:rgba atValue:start + (end - start) * 100.0f / 254.0f];
    XCTAssertEqualWithAccuracy(rgba[1], [self clut:@"VR Muscles-Bones" channel:@"Green" entry:100], 1e-4);

    // Opacity point 128 sits at start + 128/256 of the window: 1 - log10(1 + 127/255 * 9).
    [tf getRGBA:rgba atValue:start + (end - start) * 128.0f / 256.0f];
    XCTAssertEqualWithAccuracy(rgba[3], 1.0 - log10(1.0 + (127.0 / 255.0) * 9.0), 1e-4);

    // Air is fully transparent.
    [tf getRGBA:rgba atValue:-1000];
    XCTAssertEqual(rgba[3], 0.0f);
}

// Dragging WL/WW in the VR window moves a simple preset's whole colour/opacity ramp.
- (void)testWindowLevelMovesSimplePreset
{
    BKPreset *p = [self preset:@"Standard"];
    BKTransferFunction *tf = [p transferFunctionWithWindowCenter:500 windowWidth:200];
    float rgba[4];
    [tf getRGBA:rgba atValue:400];
    XCTAssertEqualWithAccuracy(rgba[0], [self clut:@"VR Muscles-Bones" channel:@"Red" entry:0], 1e-4);
    XCTAssertEqual(rgba[3], 0.0f);
    [tf getRGBA:rgba atValue:600];
    XCTAssertEqualWithAccuracy(rgba[3], 1.0f, 1e-6);
}

// "Glossy II": Smooth Table = a single point at x = 180 with opacity 0.05, so Horos
// adds 0 at the window start and 1 at the window end. Endoscopy lighting.
- (void)testSmoothTableAndEndoscopyLighting
{
    BKPreset *p = [self preset:@"Glossy II"];
    XCTAssertEqualObjects(p.opacityName, @"Smooth Table");
    XCTAssertEqual(p.opacityPoints.length / sizeof(CGPoint), 1u);
    float start = p.windowCenter - p.windowWidth / 2, end = p.windowCenter + p.windowWidth / 2;
    float x180 = start + (end - start) * 180.0f / 256.0f;
    float rgba[4];
    [p.transferFunction getRGBA:rgba atValue:x180];
    XCTAssertEqualWithAccuracy(rgba[3], 0.05f, 1e-5);
    [p.transferFunction getRGBA:rgba atValue:(x180 + end) / 2];
    XCTAssertEqualWithAccuracy(rgba[3], (0.05f + 1.0f) / 2, 1e-4);

    XCTAssertEqualObjects(p.shadingName, @"Endoscopy");
    XCTAssertEqualWithAccuracy(p.ambient, 0.12f, 1e-6);
    XCTAssertEqualWithAccuracy(p.diffuse, 0.64f, 1e-6);
    XCTAssertEqualWithAccuracy(p.specular, 0.73f, 1e-6);
    XCTAssertEqualWithAccuracy(p.specularPower, 50.0f, 1e-6);
}

// "Mid Contrast": Linear Table = no points; opacity ramps 0 -> 1 across the window.
- (void)testLinearTable
{
    BKPreset *p = [self preset:@"Mid Contrast"];
    XCTAssertEqual(p.opacityPoints.length, 0u);
    float rgba[4];
    [p.transferFunction getRGBA:rgba atValue:p.windowCenter];
    XCTAssertEqualWithAccuracy(rgba[3], 0.5f, 1e-4);
}

// "Pencil": No CLUT = Horos' own black-to-white ramp. Glossy Bone lighting.
- (void)testNoCLUTIsGrayRamp
{
    BKPreset *p = [self preset:@"Pencil"];
    XCTAssertNil(p.clutRed);
    float rgba[4];
    [p.transferFunction getRGBA:rgba atValue:p.windowCenter - p.windowWidth / 2];
    XCTAssertEqualWithAccuracy(rgba[0], 0.0f, 1e-6);
    [p.transferFunction getRGBA:rgba atValue:p.windowCenter + p.windowWidth / 2];
    XCTAssertEqualWithAccuracy(rgba[0], 254.0f / 255.0f, 1e-4);
    XCTAssertEqualWithAccuracy(rgba[1], rgba[2], 1e-6);
    XCTAssertEqualWithAccuracy(p.diffuse, 0.24f, 1e-6);
    XCTAssertEqualWithAccuracy(p.specularPower, 6.98f, 1e-5);
}

// "Bone + Skin": advanced 16-bit CLUT with a skin curve (~ -700..-540 HU, green) and
// a bone curve (~ 70..330 HU, black -> red -> yellow -> white). Opacity = level^2,
// placed directly at HU; with the volume range, opacity falls to 0 at the volume's
// minimum and maximum like VTK's AddSegment(min, 0, max, 0).
- (void)testAdvancedBoneAndSkin
{
    BKPreset *p = [self preset:@"Bone + Skin"];
    XCTAssertTrue(p.usesAdvancedCLUT);
    XCTAssertFalse(p.shadingEnabled);
    XCTAssertEqual(p.advancedCurves.count, 2u);
    XCTAssertEqual(p.advancedCurves[0].pointCount, 5u);
    XCTAssertEqualObjects(p.convolutionFilterNames, @[@"Basic Smooth 5x5"]);
    XCTAssertEqualWithAccuracy(p.windowCenter, -629.2458f, 1e-2);   // = the stored wl
    XCTAssertEqualWithAccuracy(p.windowWidth, 169.1964f, 1e-2);     // = the stored ww

    BKTransferFunction *tf = [p transferFunctionForVolumeMinimum:-1024 volumeMaximum:3071];
    float rgba[4];
    [tf getRGBA:rgba atValue:-653.980712890625f];              // skin point 1
    XCTAssertEqualWithAccuracy(rgba[3], 0.2089998424053192f * 0.2089998424053192f, 1e-6);
    XCTAssertEqualWithAccuracy(rgba[1], 0.4280155599117279f, 1e-6);
    [tf getRGBA:rgba atValue:164.5727691650391f];              // bone point 1: red
    XCTAssertEqualWithAccuracy(rgba[0], 1.0f, 1e-6);
    XCTAssertEqualWithAccuracy(rgba[1], 0.0f, 1e-6);
    XCTAssertEqualWithAccuracy(rgba[3], 0.3339997828006744f * 0.3339997828006744f, 1e-6);
    [tf getRGBA:rgba atValue:-1024];                           // volume minimum
    XCTAssertEqual(rgba[3], 0.0f);
    [tf getRGBA:rgba atValue:3071];                            // volume maximum
    XCTAssertEqual(rgba[3], 0.0f);
    [tf getRGBA:rgba atValue:(333.1015319824219f + 3071) / 2]; // halfway down the ramp
    XCTAssertEqualWithAccuracy(rgba[3], 0.3339997828006744f * 0.3339997828006744f / 2, 1e-5);
    [tf getRGBA:rgba atValue:2000];                            // colour clamps to the last point
    XCTAssertEqualWithAccuracy(rgba[0], 1.0f, 1e-6);
    XCTAssertEqualWithAccuracy(rgba[2], 1.0f, 1e-6);
}

// Horos' projection numbers: 0 = perspective 30°, 1 = parallel, 2 = perspective 60°.
- (void)testProjectionModes
{
    NSDictionary *base = @{@"name": @"x", @"CLUT": @"No CLUT", @"opacity": @"Linear Table", @"wl": @0, @"ww": @100};
    for (NSArray *c in @[@[@0, @(BKProjectionPerspective), @30], @[@1, @(BKProjectionOrthographic), @30], @[@2, @(BKProjectionPerspective), @60]]) {
        NSMutableDictionary *d = [base mutableCopy];
        d[@"projection"] = c[0];
        BKPreset *p = [_loader presetWithDictionary:d error:NULL];
        XCTAssertEqual(p.projection, [c[1] intValue]);
        XCTAssertEqualWithAccuracy(p.fieldOfView, [c[2] doubleValue], 1e-9);
    }
}

// Unknown names fall back exactly like Horos (No CLUT, Linear Table, Default
// lighting) and are reported in `warnings` instead of failing.
- (void)testUnknownNamesFallBackLikeHoros
{
    NSDictionary *d = @{@"name": @"Odd", @"CLUT": @"Missing CLUT", @"opacity": @"Missing Table",
                        @"useShading": @YES, @"shading": @"Missing Light", @"wl": @0, @"ww": @100};
    BKPreset *p = [_loader presetWithDictionary:d error:NULL];
    XCTAssertNotNil(p);
    XCTAssertEqual(p.warnings.count, 3u, @"%@", p.warnings);
    XCTAssertNil(p.clutRed);
    XCTAssertEqual(p.opacityPoints.length, 0u);
    XCTAssertEqualWithAccuracy(p.diffuse, 0.9f, 1e-6);   // Default lighting

    NSError *error = nil;
    NSDictionary *empty = @{@"name": @"Empty", @"advancedCLUT": @YES, @"CLUT": @"16-bit CLUT"};
    XCTAssertNil([_loader presetWithDictionary:empty error:&error]);
    XCTAssertNotNil(error);
}

// The user's own opacity tables (the "OPACITY" user default) are used and can
// replace built-in ones.
- (void)testUserOpacityTables
{
    [_loader addOpacityTables:@{@"Mine": @{@"Points": @[@"{1128, 0.25}"]}}];
    NSDictionary *d = @{@"name": @"U", @"CLUT": @"No CLUT", @"opacity": @"Mine", @"wl": @0, @"ww": @256};
    BKPreset *p = [_loader presetWithDictionary:d error:NULL];
    XCTAssertEqual(p.warnings.count, 0u);
    float rgba[4];
    [p.transferFunction getRGBA:rgba atValue:0];   // x = 128 of 256 -> window centre
    XCTAssertEqualWithAccuracy(rgba[3], 0.25f, 1e-6);
}

// A saved 16-bit CLUT file (named in the preset instead of "16-bit CLUT") is read
// from the CLUT folders, with the same "curves"/"colors" format.
- (void)testNamedSixteenBitCLUTFile
{
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *file = @{@"curves": @[@[@{@"x": @100, @"y": @0}, @{@"x": @200, @"y": @1}]],
                           @"colors": @[@[@{@"red": @1, @"green": @0, @"blue": @0}, @{@"red": @0, @"green": @0, @"blue": @1}]]};
    XCTAssertTrue([file writeToURL:[dir URLByAppendingPathComponent:@"My Bone.plist"] atomically:YES]);
    _loader.clutDirectories = @[dir, _clutsURL];
    BKPreset *p = [_loader presetWithDictionary:@{@"name": @"N", @"advancedCLUT": @YES, @"CLUT": @"My Bone"} error:NULL];
    XCTAssertNotNil(p);
    float rgba[4];
    [p.transferFunction getRGBA:rgba atValue:150];
    XCTAssertEqualWithAccuracy(rgba[0], 0.5f, 1e-6);
    XCTAssertEqualWithAccuracy(rgba[2], 0.5f, 1e-6);
    // Opacity points are level^2 = 0 and 1; VTK interpolates linearly BETWEEN those, so 0.5.
    XCTAssertEqualWithAccuracy(rgba[3], 0.5f, 1e-6);
    [p.transferFunction getRGBA:rgba atValue:200];
    XCTAssertEqualWithAccuracy(rgba[3], 1.0f, 1e-6);
    [[NSFileManager defaultManager] removeItemAtURL:dir error:NULL];
}

// Horos stores points as NSStringFromPoint text; parse it without AppKit.
- (void)testParsePointString
{
    CGPoint pt;
    XCTAssertTrue([BKPresetLoader parsePointString:@"{1000, 0.5}" point:&pt]);
    XCTAssertEqual(pt.x, 1000.0); XCTAssertEqual(pt.y, 0.5);
    XCTAssertTrue([BKPresetLoader parsePointString:@"{1.5e2,-3}" point:&pt]);
    XCTAssertEqual(pt.x, 150.0); XCTAssertEqual(pt.y, -3.0);
    XCTAssertFalse([BKPresetLoader parsePointString:@"1000, 0.5" point:&pt]);
}

// End to end on the GPU: a bone sphere (1000 HU) in air/soft tissue (<= -370 HU)
// rendered with "Standard" must come out bone-white and the air must stay
// transparent - i.e. the preset really drives the Metal renderer.
- (void)testRenderBoneWithStandardPreset
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return; }
    NSError *error = nil;
    BKVolumeRenderer *renderer = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(renderer, @"%@", error);

    const NSUInteger n = 64;
    float *bytes = malloc(sizeof(float) * n * n * n);
    for (NSUInteger z = 0; z < n; z++)
        for (NSUInteger y = 0; y < n; y++)
            for (NSUInteger x = 0; x < n; x++) {
                double dx = (double)x - 31, dy = (double)y - 31, dz = (double)z - 31;
                bytes[(z * n + y) * n + x] = (dx * dx + dy * dy + dz * dz <= 100.0) ? 1000.0f : -1000.0f + 10.0f * (float)z;
            }
    double orientation[9] = {1,0,0, 0,1,0, 0,0,1};
    CPRVolumeData *volume = [[CPRVolumeData alloc] initWithFloatBytesNoCopy:bytes pixelsWide:n pixelsHigh:n pixelsDeep:n
                                                                      origin:N3VectorZero orientation:orientation
                                                                    spacingX:1 spacingY:1 spacingZ:1 freeWhenDone:YES];
    XCTAssertTrue([renderer setVolumeData:volume error:&error], @"%@", error);

    [[self preset:@"Standard"] applyToRenderer:renderer];
    XCTAssertEqual(renderer.projection, BKProjectionOrthographic);
    XCTAssertTrue(renderer.shadingEnabled);
    XCTAssertEqualWithAccuracy(renderer.specularPower, 15.0f, 1e-6);

    renderer.mode = BKRenderModeComposite;
    renderer.cameraPosition = N3VectorMake(31.5, 31.5, 31.5);
    renderer.cameraDirection = N3VectorMake(0, 0, 1);
    renderer.cameraUp = N3VectorMake(0, 1, 0);
    renderer.viewWidth = n;
    renderer.viewHeight = n;
    BKRenderResult *r = [renderer renderWithWidth:n height:n error:&error];
    XCTAssertNotNil(r, @"%@", error);

    uint8_t centre[4], corner[4];
    [r getRGBA8:centre atX:32 y:32];
    [r getRGBA8:corner atX:0 y:0];
    XCTAssertGreaterThan([r valueAtX:32 y:32], 0.95f);             // bone is opaque
    XCTAssertGreaterThan(centre[0], 180);                          // and near-white
    XCTAssertGreaterThan(centre[1], 180);
    XCTAssertLessThan(abs((int)centre[0] - (int)centre[1]), 30);
    XCTAssertEqual(corner[3], 0);                                  // air: nothing drawn
    XCTAssertEqual([r valueAtX:0 y:0], 0.0f);
}

@end
