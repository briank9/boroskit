// BorosKit accuracy check, part 1: MPR slices and slabs (BKVolumeRenderer on the GPU).
//
// What is checked: the flat images of the MPR windows (thin slices and thick MIP slabs)
// that Boros 6 now gets from the Metal engine instead of VTK.
//   - Each marker of the phantom appears exactly where its patient position says
//     (within half the smallest voxel, 0.15 mm), on the correct SIDE of the image, and
//     NOT at the mirrored position (the left/right mirror bug would put it there).
//   - The two dots that are 40.0 mm apart measure 40.0 mm in the image
//     (pixels x pixel size), within half a voxel.
//   - Every pixel of a thin slice equals a simple CPU calculation (trilinear
//     interpolation of the same voxels at the same patient point); the largest and
//     average difference are printed.
//
// Display convention (how Boros/Horos shows MPR images; the engine just follows the
// "right" and "down" directions the app gives it, the same way BorosMetalSlabRenderer
// does in Boros 6). These are the standard DICOM image orientations:
//   - AXIAL:    image right = patient LEFT, image top = ANTERIOR (front).
//               You look from the feet up, as radiologists do ("radiological convention").
//   - CORONAL:  image right = patient LEFT, image top = SUPERIOR (head).
//               You look at the patient's face ("radiological convention").
//   - SAGITTAL: image right = POSTERIOR (back), so the face/ANTERIOR is on the image LEFT,
//               image top = SUPERIOR. You look at the patient's left side.
// So the patient's left is always on the screen's right in axial and coronal views.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"
#import "BKPhantom.h"

// Image size for MPR renders: 256 x 256 pixels of 0.25 mm = a 64 mm square field,
// big enough to hold every marker.
static const NSUInteger kImageSize = 256;
static const double kPixelMM = 0.25;
// "Half a voxel": half of the smallest voxel side (0.3 mm). The accuracy goal.
static const double kHalfVoxelMM = 0.15;

@interface BKAccuracyMPRTests : XCTestCase
@end

@implementation BKAccuracyMPRTests {
    BKVolumeRenderer *_renderer;
    BKPhantom *_loadedPhantom;   // which phantom is on the GPU (avoids re-uploading per plane)
}

#pragma mark - Helpers

- (void)setUp
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    NSError *error = nil;
    _renderer = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(_renderer, @"%@", error);
}

// Skips the test on a machine without a GPU (e.g. a headless build server).
- (BOOL)requireGPU
{
    if (_renderer) return YES;
    XCTSkip(@"No Metal GPU available");
    return NO;
}

// A standard image plane through `centre`, with the DICOM/radiological directions
// described at the top of this file.
static BKImagePlane Plane(N3Vector centre, N3Vector right, N3Vector down)
{
    BKImagePlane p;
    p.centre = centre;
    p.right = N3VectorNormalize(right);
    p.down = N3VectorNormalize(down);
    p.spacing = kPixelMM;
    p.width = kImageSize;
    p.height = kImageSize;
    return p;
}
static BKImagePlane AxialPlane(N3Vector c)    { return Plane(c, N3VectorMake(1, 0, 0), N3VectorMake(0, 1, 0)); }
static BKImagePlane CoronalPlane(N3Vector c)  { return Plane(c, N3VectorMake(1, 0, 0), N3VectorMake(0, 0, -1)); }
static BKImagePlane SagittalPlane(N3Vector c) { return Plane(c, N3VectorMake(0, 1, 0), N3VectorMake(0, 0, -1)); }

// Sets up the renderer camera for an image plane EXACTLY the way Boros 6's MPR bridge
// (BorosMetalSlabRenderer.m, -newSlabImageForVRView:...) does it: from the position of
// pixel (0,0), the image's right and down directions and the pixel size. So this test
// checks the same math the app runs. thickness 0 = a thin slice; > 0 = a MIP slab.
- (void)configureForPlane:(BKImagePlane)plane thickness:(double)thickness phantom:(BKPhantom *)phantom
{
    NSError *error = nil;
    if (_loadedPhantom != phantom) {
        XCTAssertTrue([_renderer setVolumeData:phantom.volume error:&error], @"%@", error);
        _loadedPhantom = phantom;
    }
    long width = plane.width, height = plane.height;
    double spacing = plane.spacing;
    N3Vector right = plane.right, down = plane.down;
    N3Vector pixel0 = BKImagePlanePointAt(plane, 0, 0);

    // --- same lines as the app ---
    N3Vector viewDirection = N3VectorNormalize(N3VectorCrossProduct(right, down));
    N3Vector centre = N3VectorAdd(pixel0, N3VectorAdd(N3VectorScalarMultiply(right, 0.5 * (width - 1) * spacing),
                                                     N3VectorScalarMultiply(down, 0.5 * (height - 1) * spacing)));
    _renderer.mode = BKRenderModeMIP;
    _renderer.projection = BKProjectionOrthographic;
    _renderer.cameraPosition = centre;
    _renderer.cameraDirection = viewDirection;
    _renderer.cameraUp = N3VectorInvert(down);
    _renderer.viewWidth = width * spacing;
    _renderer.viewHeight = height * spacing;
    _renderer.sampleSpacing = 0;
    _renderer.slabEnabled = YES;
    _renderer.slabPlane = N3PlaneMake(pixel0, viewDirection);
    _renderer.slabThickness = thickness;
    // --- end of app lines ---
}

// Renders the configured image and returns its float values (row 0 = top).
- (NSData *)renderFloats
{
    NSError *error = nil;
    BKRenderResult *r = [_renderer renderWithWidth:kImageSize height:kImageSize error:&error];
    XCTAssertNotNil(r, @"%@", error);
    return r.floatData;
}

// Measures one marker in an image: finds the bright spot inside the marker's projected
// box, and checks that it sits where the patient geometry says (within half a voxel)
// with the right brightness. Returns the measured centre in pixels.
- (CGPoint)checkMarker:(NSString *)name inImage:(NSData *)floats plane:(BKImagePlane)plane
               phantom:(BKPhantom *)phantom label:(NSString *)label
{
    BKPhantomMarker *m = [phantom marker:name];
    CGPoint expected = BKImagePlaneProject(plane, m.centre);
    CGRect box = BKImagePlaneProjectBox(plane, m.boxMin, m.boxMax, 0.5);
    float peak = 0;
    CGPoint found = BKBrightSpotCentroid(floats.bytes, plane.width, plane.height, box, phantom.background, &peak);
    double errorMM = hypot(found.x - expected.x, found.y - expected.y) * plane.spacing;
    XCTAssertLessThanOrEqual(errorMM, kHalfVoxelMM, @"%@: %@ is %.3f mm away from where it belongs (expected pixel %.2f,%.2f, found %.2f,%.2f)",
                             label, name, errorMM, expected.x, expected.y, found.x, found.y);
    // Expected brightness. The spheres and the rod have flat tops, so the image must show
    // their exact value. The small dots are soft peaks only a few voxels wide: any correct
    // viewer shows their top somewhat lower, because a pixel centre rarely falls exactly
    // on the dot's centre and the voxels around it are blended (interpolation). For the
    // dots this check only confirms WHICH marker it is (within 15 % of its height); the
    // exact pixel values are checked against the CPU reference in the thin-slice test.
    BOOL isDot = [name hasPrefix:@"dot"];
    float tolerance = isDot ? 0.15f * (m.value - phantom.background) : 20.0f;   // spheres/rod: 20 HU
    XCTAssertEqualWithAccuracy(peak, m.value, tolerance, @"%@: %@ brightness", label, name);
    BKReport(@"MPR %@ | marker %-8@ position error %.3f mm | peak %.0f (marker value %.0f)", label, name, errorMM, peak, m.value);
    return found;
}

// The value at a pixel position (rounded to the nearest pixel).
static float ValueAt(NSData *floats, CGPoint p)
{
    long x = lround(p.x), y = lround(p.y);
    if (x < 0 || y < 0 || x >= (long)kImageSize || y >= (long)kImageSize) return NAN;
    return ((const float *)floats.bytes)[y * kImageSize + x];
}

// Distance in mm between two measured spots: pixels x pixel size.
static double DistanceMM(CGPoint a, CGPoint b, double spacing)
{
    return hypot(a.x - b.x, a.y - b.y) * spacing;
}

#pragma mark - Tests

// THICK MIP SLAB through the whole phantom, in the three standard planes, for the three
// grid layouts. A thick MIP shows every marker at once, so one image checks them all.
//
// Plain words: on the axial and coronal images the LEFT sphere must be on the RIGHT half
// of the image (and nothing at the mirrored spot), the front (anterior) sphere at the top
// of the axial image, the rod (toward the head) at the top of coronal and sagittal images,
// and the anterior sphere on the LEFT of the sagittal image. The 40 mm dots must measure
// 40 mm.
- (void)testSlabMIPMarkersAndDistances
{
    if (![self requireGPU]) return;
    for (BKPhantomGrid grid = BKPhantomGridAxisAligned; grid <= BKPhantomGridReversed; grid++) {
        BKPhantom *ph = [BKPhantom phantomWithGrid:grid];
        NSString *gridName = [BKPhantom nameOfGrid:grid];
        double pair2InPlane = 40.0 / sqrt(2.0);   // pair 2 seen from above or the front: 28.284 mm

        // -- Axial (seen from the feet; patient left = image right, front = image top) --
        {
            BKImagePlane plane = AxialPlane(ph.centre);
            [self configureForPlane:plane thickness:80 phantom:ph];
            NSData *img = [self renderFloats];
            NSString *label = [NSString stringWithFormat:@"axial slab, %@ grid", gridName];
            CGPoint left = [self checkMarker:@"left" inImage:img plane:plane phantom:ph label:label];
            CGPoint ant = [self checkMarker:@"anterior" inImage:img plane:plane phantom:ph label:label];
            [self checkMarker:@"rod" inImage:img plane:plane phantom:ph label:label];
            CGPoint a1 = [self checkMarker:@"dotA1" inImage:img plane:plane phantom:ph label:label];
            CGPoint b1 = [self checkMarker:@"dotB1" inImage:img plane:plane phantom:ph label:label];
            CGPoint a2 = [self checkMarker:@"dotA2" inImage:img plane:plane phantom:ph label:label];
            CGPoint b2 = [self checkMarker:@"dotB2" inImage:img plane:plane phantom:ph label:label];

            XCTAssertGreaterThan(left.x, kImageSize / 2.0, @"%@: patient's LEFT must be on the image's RIGHT", label);
            XCTAssertLessThan(ant.y, kImageSize / 2.0, @"%@: ANTERIOR (front) must be at the image TOP", label);
            // Mirror check: where a left/right (or up/down) mirrored image would show the
            // marker, there must be only background.
            XCTAssertLessThan(ValueAt(img, CGPointMake(kImageSize - 1 - left.x, left.y)), ph.background + 50, @"%@: mirrored left marker", label);
            XCTAssertLessThan(ValueAt(img, CGPointMake(ant.x, kImageSize - 1 - ant.y)), ph.background + 50, @"%@: mirrored anterior marker", label);

            double d1 = DistanceMM(a1, b1, plane.spacing), d2 = DistanceMM(a2, b2, plane.spacing);
            XCTAssertEqualWithAccuracy(d1, 40.0, kHalfVoxelMM, @"%@: 40 mm dot pair", label);
            XCTAssertEqualWithAccuracy(d2, pair2InPlane, kHalfVoxelMM, @"%@: dot pair 2 seen from below", label);
            BKReport(@"MPR %@ | dot pair 1 measures %.3f mm (true 40.000), pair 2 %.3f mm (true %.3f)", label, d1, d2, pair2InPlane);
        }
        // -- Coronal (seen from the front; patient left = image right, head = image top) --
        {
            BKImagePlane plane = CoronalPlane(ph.centre);
            [self configureForPlane:plane thickness:80 phantom:ph];
            NSData *img = [self renderFloats];
            NSString *label = [NSString stringWithFormat:@"coronal slab, %@ grid", gridName];
            CGPoint left = [self checkMarker:@"left" inImage:img plane:plane phantom:ph label:label];
            CGPoint rod = [self checkMarker:@"rod" inImage:img plane:plane phantom:ph label:label];
            [self checkMarker:@"anterior" inImage:img plane:plane phantom:ph label:label];
            CGPoint a1 = [self checkMarker:@"dotA1" inImage:img plane:plane phantom:ph label:label];
            CGPoint b1 = [self checkMarker:@"dotB1" inImage:img plane:plane phantom:ph label:label];
            CGPoint a2 = [self checkMarker:@"dotA2" inImage:img plane:plane phantom:ph label:label];
            CGPoint b2 = [self checkMarker:@"dotB2" inImage:img plane:plane phantom:ph label:label];

            XCTAssertGreaterThan(left.x, kImageSize / 2.0, @"%@: patient's LEFT must be on the image's RIGHT", label);
            XCTAssertLessThan(rod.y, kImageSize / 2.0, @"%@: SUPERIOR (head) must be at the image TOP", label);
            XCTAssertLessThan(ValueAt(img, CGPointMake(kImageSize - 1 - left.x, left.y)), ph.background + 50, @"%@: mirrored left marker", label);
            XCTAssertLessThan(ValueAt(img, CGPointMake(rod.x, kImageSize - 1 - rod.y)), ph.background + 50, @"%@: mirrored rod", label);

            double d1 = DistanceMM(a1, b1, plane.spacing), d2 = DistanceMM(a2, b2, plane.spacing);
            XCTAssertEqualWithAccuracy(d1, 40.0, kHalfVoxelMM, @"%@: 40 mm dot pair", label);
            XCTAssertEqualWithAccuracy(d2, pair2InPlane, kHalfVoxelMM, @"%@: dot pair 2 seen from the front", label);
            BKReport(@"MPR %@ | dot pair 1 measures %.3f mm (true 40.000), pair 2 %.3f mm (true %.3f)", label, d1, d2, pair2InPlane);
        }
        // -- Sagittal (seen from the patient's left; face = image left, head = image top) --
        {
            BKImagePlane plane = SagittalPlane(ph.centre);
            [self configureForPlane:plane thickness:80 phantom:ph];
            NSData *img = [self renderFloats];
            NSString *label = [NSString stringWithFormat:@"sagittal slab, %@ grid", gridName];
            CGPoint ant = [self checkMarker:@"anterior" inImage:img plane:plane phantom:ph label:label];
            CGPoint rod = [self checkMarker:@"rod" inImage:img plane:plane phantom:ph label:label];
            [self checkMarker:@"left" inImage:img plane:plane phantom:ph label:label];
            CGPoint a2 = [self checkMarker:@"dotA2" inImage:img plane:plane phantom:ph label:label];
            CGPoint b2 = [self checkMarker:@"dotB2" inImage:img plane:plane phantom:ph label:label];

            XCTAssertLessThan(ant.x, kImageSize / 2.0, @"%@: ANTERIOR (face) must be on the image's LEFT", label);
            XCTAssertLessThan(rod.y, kImageSize / 2.0, @"%@: SUPERIOR (head) must be at the image TOP", label);
            XCTAssertLessThan(ValueAt(img, CGPointMake(kImageSize - 1 - ant.x, ant.y)), ph.background + 50, @"%@: mirrored anterior marker", label);
            XCTAssertLessThan(ValueAt(img, CGPointMake(rod.x, kImageSize - 1 - rod.y)), ph.background + 50, @"%@: mirrored rod", label);

            double d2 = DistanceMM(a2, b2, plane.spacing);
            XCTAssertEqualWithAccuracy(d2, 40.0, kHalfVoxelMM, @"%@: 40 mm dot pair 2", label);
            BKReport(@"MPR %@ | dot pair 2 measures %.3f mm (true 40.000)", label, d2);
        }
    }
}

// THIN SLICES (thickness 0 = the normal MPR image) compared pixel by pixel with a CPU
// reference: for every pixel, the test works out the patient point it shows and
// interpolates the stored voxels there itself. The GPU must give the same value.
// Also measures the 40 mm dot pairs in slices that cut through both dots, including a
// slanted (oblique) slice, because oblique MPR is used for implant planning.
//
// Tolerance: 10 HU. The GPU stores the volume as 16-bit (steps of 0.05 HU here) and its
// interpolation hardware uses a limited number of position steps between voxels, so tiny
// differences at steep edges are expected; 10 HU is invisible on screen and far below
// anything that changes a measurement. The actual largest and average differences are printed.
- (void)testThinSlicesMatchCPUReferenceAndMeasure40mm
{
    if (![self requireGPU]) return;
    for (BKPhantomGrid grid = BKPhantomGridAxisAligned; grid <= BKPhantomGridReversed; grid++) {
        BKPhantom *ph = [BKPhantom phantomWithGrid:grid];
        NSString *gridName = [BKPhantom nameOfGrid:grid];
        N3Vector C = ph.centre;
        N3Vector pair1Middle = N3VectorAdd(C, N3VectorMake(0, 8, -10));
        // A slice tilted 30 degrees about the left-right axis that still contains dot pair 1.
        double t = 30.0 * M_PI / 180.0;
        N3Vector obliqueDown = N3VectorMake(0, cos(t), sin(t));

        struct { NSString *name; BKImagePlane plane; NSString *dotA, *dotB; } cases[] = {
            { @"axial through spheres", AxialPlane(C), nil, nil },
            { @"axial through pair 1", AxialPlane(pair1Middle), @"dotA1", @"dotB1" },
            { @"coronal through pair 1", CoronalPlane(pair1Middle), @"dotA1", @"dotB1" },
            { @"sagittal through pair 2", SagittalPlane(N3VectorAdd(C, N3VectorMake(-8, 0, 0))), @"dotA2", @"dotB2" },
            { @"oblique 30deg through pair 1", Plane(pair1Middle, N3VectorMake(1, 0, 0), obliqueDown), @"dotA1", @"dotB1" },
        };
        for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
            BKImagePlane plane = cases[c].plane;
            NSString *label = [NSString stringWithFormat:@"thin %@, %@ grid", cases[c].name, gridName];
            [self configureForPlane:plane thickness:0 phantom:ph];
            NSData *img = [self renderFloats];
            const float *gpu = img.bytes;

            // Pixel-by-pixel comparison with the CPU reference (pixels at least one voxel
            // inside the scan; at the very edge "inside or outside" is a coin toss).
            BKErrorStats vsCPU = {0}, vsIdeal = {0};
            for (NSUInteger j = 0; j < plane.height; j++)
                for (NSUInteger i = 0; i < plane.width; i++) {
                    N3Vector p = BKImagePlanePointAt(plane, i, j);
                    if (![ph containsPoint:p marginVoxels:1.0]) continue;
                    float ref = [ph referenceTrilinearAt:p];
                    BKErrorStatsAdd(&vsCPU, gpu[j * plane.width + i], ref);
                    BKErrorStatsAdd(&vsIdeal, gpu[j * plane.width + i], [ph analyticValueAt:p]);
                }
            XCTAssertGreaterThan(vsCPU.count, 10000u, @"%@: too few pixels inside the scan", label);
            XCTAssertLessThanOrEqual(vsCPU.maxError, 10.0, @"%@: GPU differs from the CPU reference", label);
            BKReport(@"MPR %@ | GPU vs CPU trilinear: max %.2f HU, mean %.3f HU over %lu px | vs ideal phantom: max %.1f HU, mean %.2f HU",
                     label, vsCPU.maxError, BKErrorStatsMean(vsCPU), (unsigned long)vsCPU.count, vsIdeal.maxError, BKErrorStatsMean(vsIdeal));

            if (cases[c].dotA) {
                CGPoint a = [self checkMarker:cases[c].dotA inImage:img plane:plane phantom:ph label:label];
                CGPoint b = [self checkMarker:cases[c].dotB inImage:img plane:plane phantom:ph label:label];
                double d = DistanceMM(a, b, plane.spacing);
                XCTAssertEqualWithAccuracy(d, 40.0, kHalfVoxelMM, @"%@: 40 mm dot pair", label);
                BKReport(@"MPR %@ | dot pair measures %.3f mm (true 40.000)", label, d);
            }
        }
    }
}

@end
