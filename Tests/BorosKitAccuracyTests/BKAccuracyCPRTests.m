// BorosKit accuracy check, part 3: the curved MPR / panorex engine (CPRGenerator in
// BorosKitCore, computed on the CPU).
//
// What is checked, for a straight path and a curved (dental-arch-like) path through the
// phantom's 40 mm dot pair:
//   - The image's length along the path is right: pixels x pixel size = the true length
//     of the path in mm (worked out independently by this test).
//   - The two dots appear at the right places and are the right distance apart ALONG
//     the path (for the straight path that is 40.0 mm; for the curved path it is the
//     length of the curved piece between them).
//   - Every pixel equals what a simple CPU calculation gives at the patient point that
//     pixel is supposed to show (with linear interpolation; the app's default "cubic"
//     interpolation is checked for positions and lengths).
//
// How the engine lays out a CPR image (from CPRStraightenedOperation /
// CPRStretchedOperation; these tests confirm it):
//   - Column 0 is the START of the path; columns advance along the path in equal steps of
//     (path length / image width) mm. Column i shows the point i x step along the path.
//   - The middle row lies on the path. Rows run along "initialNormal" (straightened CPR)
//     or "projectionNormal" (stretched CPR = panorex): row 0 is on the side the normal
//     points away from. The app chooses these vectors; here they point to the feet, so
//     the head is at the top of the image.

#import <XCTest/XCTest.h>
#import "CPRVolumeData.h"
#import "CPRGenerator.h"
#import "CPRGeneratorRequest.h"
#import "N3BezierPath.h"
#import "BKPhantom.h"

static const NSUInteger kCPRHeight = 41;   // rows: 41 x 0.25 mm = 10 mm across the path

@interface BKAccuracyCPRTests : XCTestCase
@end

// An independent description of the test path: a dense list of points with the distance
// along the path at each point, so "the point at distance s" can be looked up.
@interface BKTestPath : NSObject
@property (nonatomic) NSMutableData *points;      // N3Vector[]
@property (nonatomic) NSMutableData *distances;   // double[]
@property (nonatomic) N3MutableBezierPath *bezier; // the same path for the engine
- (double)length;
- (N3Vector)pointAtDistance:(double)s;
@end

@implementation BKTestPath
- (instancetype)init
{
    if ((self = [super init])) {
        _points = [NSMutableData data];
        _distances = [NSMutableData data];
        _bezier = [N3MutableBezierPath bezierPath];
    }
    return self;
}
- (NSUInteger)count { return _points.length / sizeof(N3Vector); }
- (void)appendPoint:(N3Vector)p
{
    double d = 0;
    NSUInteger n = [self count];
    if (n) d = ((double *)_distances.bytes)[n - 1] + N3VectorDistance(((N3Vector *)_points.bytes)[n - 1], p);
    [_points appendBytes:&p length:sizeof(p)];
    [_distances appendBytes:&d length:sizeof(d)];
}
- (void)moveTo:(N3Vector)p { [self appendPoint:p]; [_bezier moveToVector:p]; }
- (void)lineTo:(N3Vector)p { [self appendPoint:p]; [_bezier lineToVector:p]; }
// A cubic Bezier curve, measured with 20,000 tiny straight steps (accurate to far
// better than a micrometre for curves this size).
- (void)curveTo:(N3Vector)p3 control1:(N3Vector)p1 control2:(N3Vector)p2
{
    N3Vector p0 = ((N3Vector *)_points.bytes)[[self count] - 1];
    for (int k = 1; k <= 20000; k++) {
        double t = k / 20000.0, u = 1 - t;
        double a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
        [self appendPoint:N3VectorMake(a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                                       a * p0.y + b * p1.y + c * p2.y + d * p3.y,
                                       a * p0.z + b * p1.z + c * p2.z + d * p3.z)];
    }
    [_bezier curveToVector:p3 controlVector1:p1 controlVector2:p2];
}
- (double)length { return ((double *)_distances.bytes)[[self count] - 1]; }
- (double)distanceAtPointIndex:(NSUInteger)i { return ((double *)_distances.bytes)[i]; }
- (N3Vector)pointAtDistance:(double)s
{
    const double *d = _distances.bytes;
    const N3Vector *p = _points.bytes;
    NSUInteger lo = 0, hi = [self count] - 1;
    if (s <= 0) return p[0];
    if (s >= d[hi]) return p[hi];
    while (hi - lo > 1) { NSUInteger mid = (lo + hi) / 2; if (d[mid] <= s) lo = mid; else hi = mid; }
    double f = (d[hi] > d[lo]) ? (s - d[lo]) / (d[hi] - d[lo]) : 0;
    return N3VectorLerp(p[lo], p[hi], f);
}
@end

@implementation BKAccuracyCPRTests

// Reads the CPR result as a plain array of floats (row 0 = top).
static NSData *Pixels(CPRVolumeData *v)
{
    NSMutableData *data = [NSMutableData dataWithLength:v.pixelsWide * v.pixelsHigh * sizeof(float)];
    float *f = data.mutableBytes;
    for (NSUInteger y = 0; y < v.pixelsHigh; y++)
        [v getFloatRun:f + y * v.pixelsWide atPixelCoordinateX:0 y:y z:0 length:v.pixelsWide];
    return data;
}

// The path used by both tests: 5 mm straight in, then (if curved) an arch that bulges
// 15 mm toward the front between the two 40 mm dots, then 5 mm straight out. It lies in
// the horizontal plane of dot pair 1, like a dental arch drawn on an axial slice.
// `dotDistances` receives the distance along the path of dot A1 and dot B1.
static BKTestPath *MakePath(BKPhantom *ph, BOOL curved, double dotDistances[2])
{
    N3Vector a = [ph marker:@"dotA1"].centre, b = [ph marker:@"dotB1"].centre;
    BKTestPath *path = [[BKTestPath alloc] init];
    [path moveTo:N3VectorAdd(a, N3VectorMake(-5, 0, 0))];
    [path lineTo:a];
    dotDistances[0] = [path length];
    if (curved)
        [path curveTo:b control1:N3VectorAdd(a, N3VectorMake(10, -20, 0)) control2:N3VectorAdd(b, N3VectorMake(-10, -20, 0))];
    else
        [path lineTo:b];
    dotDistances[1] = [path length];
    [path lineTo:N3VectorAdd(b, N3VectorMake(5, 0, 0))];
    return path;
}

// Runs one CPR request (straightened or stretched) and checks everything listed at the
// top of the file. Returns nothing; failures are reported through XCTest.
- (void)checkCPRCurved:(BOOL)curved stretched:(BOOL)stretched interpolation:(CPRInterpolationMode)interpolation
{
    BKPhantom *ph = [BKPhantom phantomWithGrid:BKPhantomGridTilted];
    double dotAt[2];
    BKTestPath *path = MakePath(ph, curved, dotAt);
    double trueLength = [path length];
    // About 0.25 mm per column, like a fine panorex.
    NSUInteger width = (NSUInteger)lround(trueLength / 0.25);
    N3Vector feet = N3VectorMake(0, 0, -1);   // rows run toward the feet: head at the top

    CPRVolumeData *out;
    if (stretched) {
        CPRStretchedGeneratorRequest *req = [[CPRStretchedGeneratorRequest alloc] init];
        req.pixelsWide = width; req.pixelsHigh = kCPRHeight;
        req.bezierPath = path.bezier;
        req.projectionNormal = feet;
        req.midHeightPoint = [ph marker:@"dotA1"].centre;
        req.interpolationMode = interpolation;
        out = [CPRGenerator synchronousRequestVolume:req volumeData:ph.volume];
    } else {
        CPRStraightenedGeneratorRequest *req = [[CPRStraightenedGeneratorRequest alloc] init];
        req.pixelsWide = width; req.pixelsHigh = kCPRHeight;
        req.bezierPath = path.bezier;
        req.initialNormal = feet;
        req.interpolationMode = interpolation;
        out = [CPRGenerator synchronousRequestVolume:req volumeData:ph.volume];
    }
    NSString *label = [NSString stringWithFormat:@"CPR %@ %@ path, %@ interpolation", stretched ? @"stretched (panorex)" : @"straightened",
                       curved ? @"curved" : @"straight", interpolation == CPRInterpolationModeLinear ? @"linear" : @"cubic"];
    XCTAssertNotNil(out, @"%@", label);
    if (!out) return;
    XCTAssertEqual(out.pixelsWide, width);
    XCTAssertEqual(out.pixelsHigh, kCPRHeight);

    // 1. Length along the path: columns x column size must be the true length.
    double step = out.pixelSpacingX;
    double measuredLength = step * width;
    XCTAssertEqualWithAccuracy(measuredLength, trueLength, 0.15, @"%@: image length along the path", label);
    XCTAssertEqualWithAccuracy(out.pixelSpacingY, step, 1e-9, @"%@: rows and columns must have the same mm size", label);

    // 2. Every pixel against the CPU reference at the point it should show:
    //    column i = the point at distance i x step along the path, row j moved
    //    (j - middle) x step toward the feet.
    NSData *pixels = Pixels(out);
    const float *px = pixels.bytes;
    BKErrorStats vsCPU = {0}, vsIdeal = {0};
    for (NSUInteger j = 0; j < kCPRHeight; j++)
        for (NSUInteger i = 0; i < width; i++) {
            N3Vector onPath = [path pointAtDistance:i * step];
            N3Vector p = N3VectorAdd(onPath, N3VectorScalarMultiply(feet, ((double)j - 0.5 * (kCPRHeight - 1)) * step));
            BKErrorStatsAdd(&vsCPU, px[j * width + i], [ph referenceTrilinearAt:p]);
            BKErrorStatsAdd(&vsIdeal, px[j * width + i], [ph analyticValueAt:p]);
        }
    // Tolerance. Straight path: the engine must match the CPU exactly (measured: 0.00 HU).
    // Curved path: the engine first cuts the curve into many short straight pieces (as
    // Horos always did), so its points along the path sit a few hundredths of a mm away
    // from the exact curve (measured: the whole 62.7 mm arch comes out 0.025 mm = 0.04 %
    // short). At the steepest edges of the phantom (about 1,500 HU per mm) such a tiny
    // shift changes a pixel by up to ~60 HU. 75 HU therefore means "less than about
    // 0.05 mm off", far below half a voxel (0.15 mm). Cubic interpolation (the app's
    // default) is a different, smoother formula, so its values are only reported here;
    // its positions and lengths are checked below like the others.
    double tolerance = curved ? 75.0 : 0.5;
    if (interpolation == CPRInterpolationModeLinear)
        XCTAssertLessThanOrEqual(vsCPU.maxError, tolerance, @"%@: pixels differ from the CPU reference", label);
    BKReport(@"%@ | vs CPU trilinear: max %.2f HU, mean %.3f HU | vs ideal phantom: max %.1f HU, mean %.2f HU",
             label, vsCPU.maxError, BKErrorStatsMean(vsCPU), vsIdeal.maxError, BKErrorStatsMean(vsIdeal));

    // 3. The dots: find each bright spot near its expected column on the middle row, and
    //    measure the distance between them along the path.
    double mid = 0.5 * (kCPRHeight - 1);
    CGPoint found[2];
    for (int k = 0; k < 2; k++) {
        double expectedColumn = dotAt[k] / step;
        CGRect box = CGRectMake(floor(expectedColumn - 12), floor(mid - 12), 24, 24);
        found[k] = BKBrightSpotCentroid(px, width, kCPRHeight, box, ph.background, NULL);
        double errorMM = hypot(found[k].x - expectedColumn, found[k].y - mid) * step;
        XCTAssertLessThanOrEqual(errorMM, 0.15, @"%@: dot %d is %.3f mm from where it belongs", label, k + 1, errorMM);
        BKReport(@"%@ | dot %d at column %.2f row %.2f (expected %.2f, %.2f), error %.3f mm",
                 label, k + 1, found[k].x, found[k].y, expectedColumn, mid, errorMM);
    }
    double alongPath = (found[1].x - found[0].x) * step;
    double trueAlong = dotAt[1] - dotAt[0];
    XCTAssertEqualWithAccuracy(alongPath, trueAlong, 0.15, @"%@: distance between the dots along the path", label);
    BKReport(@"%@ | path length %.3f mm (true %.3f) | dots %.3f mm apart along the path (true %.3f)",
             label, measuredLength, trueLength, alongPath, trueAlong);
}

// Straight path through the 40 mm dot pair, straightened CPR, linear interpolation:
// the dots must be exactly 40 mm apart in the image and every pixel must match the CPU.
- (void)testStraightPathLinear  { [self checkCPRCurved:NO stretched:NO interpolation:CPRInterpolationModeLinear]; }
// Same with cubic interpolation (the app's default for curved MPR / panorex).
- (void)testStraightPathCubic   { [self checkCPRCurved:NO stretched:NO interpolation:CPRInterpolationModeCubic]; }
// Curved arch through the dots, straightened CPR (the curved-MPR "straightened" view).
- (void)testCurvedPathLinear    { [self checkCPRCurved:YES stretched:NO interpolation:CPRInterpolationModeLinear]; }
- (void)testCurvedPathCubic     { [self checkCPRCurved:YES stretched:NO interpolation:CPRInterpolationModeCubic]; }
// Curved arch, stretched CPR = the panorex image.
- (void)testPanorexLinear       { [self checkCPRCurved:YES stretched:YES interpolation:CPRInterpolationModeLinear]; }
- (void)testPanorexCubic        { [self checkCPRCurved:YES stretched:YES interpolation:CPRInterpolationModeCubic]; }

@end
