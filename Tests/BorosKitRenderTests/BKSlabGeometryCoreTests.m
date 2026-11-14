// Tests for the plain-C MPR slab picture geometry (BKSlabGeometryCore.h).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// The expected numbers below were RECORDED FROM THE CLASSIC ENGINE (2026-11-14): a scratch
// harness built the same VTK 8.2 objects Boros 6's hidden 3D view builds for the MPR windows
// (scan box with slices 1..n-2, world = mm * factor, camera set like -[VRView setCamera:] with the
// clipping-range slab), ran the fixed-point mapper's geometry step (what -renderGeometryOnly runs),
// and printed what -getFullDepthImageWidth:height:, -getOrigin:windowCentered:YES sliceMiddle:YES,
// -getOrientation:, -getResolution and -imageSampleDistance return. Eight cases: axial / coronal /
// sagittal / oblique views, slabs 0.3 - 400 mm, zoomed in and out, odd window sizes, sample
// distances 1 - 2.5, a shifted window centre, a Retina-style frame, a tilted anisotropic scan,
// the camera outside the scan, a scan off to the side of the view, and two "thick slab contains the whole scan" cases where only part
// of the view is covered. BorosKit must reproduce them: sizes exactly, mm to 0.0002.
// (The values are plain numbers - no VTK code or data is part of BorosKit.)

#import <XCTest/XCTest.h>
#import "BKSlabGeometryCore.h"

@interface BKSlabGeometryCoreTests : XCTestCase
@end

// What: a scan description (as Boros 6's classic 3D view sees it).
typedef struct { int w, h, n; double ps[3]; double origin[3]; double cos[9]; } BKTestScan;
// What: a view description (camera in mm, view on screen).
typedef struct { double pos[3]; double dop[3]; double up[3]; double ps; double wc[2]; double thick; double sampleDistance; int W, H; double frameW, frameH; } BKTestView;
// What: the numbers the classic engine produced.
typedef struct { int width, height, gridOriginX, gridOriginY; double isd, resolution; double origin[3]; double orientation[9]; } BKTestExpected;

static BKSlabGeometryInput BKTestInput(BKTestScan s, BKTestView v)
{
    BKSlabGeometryInput in;
    in.position = BKV3d(v.pos[0], v.pos[1], v.pos[2]);
    in.focalPoint = BKV3dAddScaled(in.position, BKV3d(v.dop[0], v.dop[1], v.dop[2]), 40.0);
    in.viewUp = BKV3d(v.up[0], v.up[1], v.up[2]);
    in.parallelScale = v.ps;
    in.windowCenterX = v.wc[0];
    in.windowCenterY = v.wc[1];
    in.slabThickness = v.thick;
    in.renderWidth = v.W;
    in.renderHeight = v.H;
    in.frameWidth = v.frameW;
    in.frameHeight = v.frameH;
    in.sampleDistance = v.sampleDistance;
    in.volumeOrigin = BKV3d(s.origin[0], s.origin[1], s.origin[2]);
    in.volumeAxes[0] = BKV3d(s.cos[0], s.cos[1], s.cos[2]);
    in.volumeAxes[1] = BKV3d(s.cos[3], s.cos[4], s.cos[5]);
    in.volumeAxes[2] = BKV3d(s.cos[6], s.cos[7], s.cos[8]);
    in.voxelSpacing = BKV3d(s.ps[0], s.ps[1], s.ps[2]);
    in.indexMin[0] = 0; in.indexMax[0] = s.w - 1;
    in.indexMin[1] = 0; in.indexMax[1] = s.h - 1;
    in.indexMin[2] = 1; in.indexMax[2] = s.n - 2;   // Boros 6's classic 3D view leaves out the first/last slice
    return in;
}

static BKTestScan BKTestScanA(void)
{
    BKTestScan s = { 400, 400, 300, { 0.3, 0.3, 0.3 }, { -60.0, -55.5, -40.25 }, { 1,0,0, 0,1,0, 0,0,1 } };
    return s;
}

// Tilted acquisition: axes turned 0.35 rad about z, then the column axis tilted 0.2 rad; anisotropic.
static BKTestScan BKTestScanB(void)
{
    double a = 0.35, b = 0.2;
    double rx[3] = { cos(a), sin(a), 0 };
    double ry[3] = { -sin(a), cos(a) * cos(b), cos(a) * sin(b) };
    double rz[3] = { rx[1]*ry[2]-rx[2]*ry[1], rx[2]*ry[0]-rx[0]*ry[2], rx[0]*ry[1]-rx[1]*ry[0] };
    BKTestScan s = { 256, 200, 120, { 0.5, 0.45, 1.25 }, { 12.5, -30.0, 100.0 },
                     { rx[0],rx[1],rx[2], ry[0],ry[1],ry[2], rz[0],rz[1],rz[2] } };
    return s;
}

static void BKTestNormalize(double d[3])
{
    double L = sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]);
    d[0] /= L; d[1] /= L; d[2] /= L;
}

@implementation BKSlabGeometryCoreTests

// What: compares one case with the recorded classic-engine numbers.
- (void)checkCase:(const char *)name scan:(BKTestScan)scan view:(BKTestView)view expected:(BKTestExpected)e
{
    BKSlabGeometryInput in = BKTestInput(scan, view);
    BKSlabGeometry g;
    BKSlabGeometryStatus status = BKSlabGeometryCompute(&in, &g);
    XCTAssertEqual(status, BKSlabGeometryOK, @"%s", name);
    XCTAssertEqual(g.width, e.width, @"%s width", name);
    XCTAssertEqual(g.height, e.height, @"%s height", name);
    XCTAssertEqual(g.gridOriginX, e.gridOriginX, @"%s grid origin x", name);
    XCTAssertEqual(g.gridOriginY, e.gridOriginY, @"%s grid origin y", name);
    XCTAssertEqualWithAccuracy(g.sampleDistance, e.isd, 1e-7, @"%s sample distance", name);
    XCTAssertEqualWithAccuracy(g.resolution, e.resolution, 1e-9 * e.resolution, @"%s resolution", name);
    XCTAssertEqualWithAccuracy(g.pixelSpacing, e.resolution * e.isd, 1e-6 * e.resolution, @"%s pixel spacing", name);
    double o[3] = { g.origin.x, g.origin.y, g.origin.z };
    double maxOrigin = 0, maxOrient = 0;
    for (int i = 0; i < 3; i++) maxOrigin = fmax(maxOrigin, fabs(o[i] - e.origin[i]));
    double orient[9];
    BKSlabGeometryOrientation(&g, orient);
    for (int i = 0; i < 9; i++) maxOrient = fmax(maxOrient, fabs(orient[i] - e.orientation[i]));
    XCTAssertLessThan(maxOrigin, 2e-4, @"%s origin (mm)", name);
    XCTAssertLessThan(maxOrient, 1e-6, @"%s orientation", name);
    // One line per case so the measured agreement is visible in the test log.
    printf("SLAB GEOMETRY | %s | %dx%d (grid start %d,%d) | origin diff %.2e mm | orientation diff %.2e\n",
           name, g.width, g.height, g.gridOriginX, g.gridOriginY, maxOrigin, maxOrient);
}

// The eight recorded cases (see the file header).
- (void)testMatchesClassicEngineRecordings
{
    BKTestScan A = BKTestScanA(), B = BKTestScanB();

    [self checkCase:"case1 axial thin slab" scan:A
               view:(BKTestView){ { 0, 4.5, 4.6 }, { 0, 0, 1 }, { 0, -1, 0 }, 40.0, { 0, 0 }, 0.3, 1.0, 800, 600, 800, 600 }
           expected:(BKTestExpected){ 800, 600, 0, 0, 1, 0.133333333333, { -53.3333321, -35.5, 4.75 },
                                      { 1, 0, 0, -0, 1, -0, 0, 0, -1 } }];

    [self checkCase:"case2 coronal 20 mm zoomed, odd window, LOD 1.7" scan:A
               view:(BKTestView){ { 5, 0, -10 }, { 0, 1, 0 }, { 0, 0, 1 }, 15.0, { 0, 0 }, 20.0, 1.7, 1013, 677, 1013, 677 }
           expected:(BKTestExpected){ 595, 398, 0, 0, 1.70000005, 0.0443131462334, { -17.4446087, 10, 5 },
                                      { 1, 0, 0, -0, -0, -1, 0, -1, 0 } }];

    {
        double d[3] = { 0.3, 0.5, 0.81 }; BKTestNormalize(d);
        [self checkCase:"case3 oblique 5 mm, window centre, render 2x frame" scan:A
                   view:(BKTestView){ { -3, 2, 7 }, { d[0], d[1], d[2] }, { 0.2, -1, 0.1 }, 70.0, { 0.1, -0.05 }, 5.0, 1.3, 1200, 900, 600, 450 }
               expected:(BKTestExpected){ 923, 692, 0, 0, 1.29999995, 0.155555555556, { -59.959774, -67.2832565, 73.9440536 },
                                          { 0.898065686, 0.13784264, -0.41770497, -0.321131855, 0.854412436, -0.408477366, -0.30058673, -0.500977874, -0.811584115 } }];
    }

    [self checkCase:"case4 sagittal 250 mm slab contains scan, zoomed out" scan:A
               view:(BKTestView){ { -130, 0, 4 }, { 1, 0, 0 }, { 0, 0, 1 }, 150.0, { 0, 0 }, 250.0, 1.0, 700, 500, 700, 500 }
           expected:(BKTestExpected){ 204, 153, 241, 174, 1, 0.6, { -5, 65.4000015, 49.5999985 },
                                      { 0, -1, 0, -0, -0, -1, -1, 0, 0 } }];

    [self checkCase:"case5 tilted scan, 2 mm, LOD 2.5" scan:B
               view:(BKTestView){ { 70, 10, 140 }, { 0, 0, 1 }, { 0, -1, 0 }, 60.0, { 0, 0 }, 2.0, 2.5, 640, 480, 640, 480 }
           expected:(BKTestExpected){ 256, 192, 0, 0, 2.5, 0.25, { -10, -50, 141 },
                                      { 1, 0, 0, -0, 1, -0, 0, 0, -1 } }];

    {
        double d[3] = { -0.4, 0.7, -0.2 }; BKTestNormalize(d);
        [self checkCase:"case6 tilted scan, oblique 400 mm slab contains scan, window centre" scan:B
                   view:(BKTestView){ { 160, -160, 170 }, { d[0], d[1], d[2] }, { 0, 0, 1 }, 260.0, { -0.2, 0.15 }, 400.0, 1.0, 900, 700, 900, 700 }
               expected:(BKTestExpected){ 199, 240, 446, 258, 1, 0.742857142857, { -9.75964069, -3.66463041, 226.030685 },
                                          { 0.868243158, 0.49613893, 0, 0.119456217, -0.209048375, -0.97058177, 0.481543422, -0.842700958, 0.240771711 } }];
    }

    [self checkCase:"case7 camera outside the scan, thin slab" scan:A
               view:(BKTestView){ { 0, 0, 80 }, { 0, 0, 1 }, { 0, -1, 0 }, 40.0, { 0, 0 }, 0.3, 1.0, 512, 512, 512, 512 }
           expected:(BKTestExpected){ 512, 512, 0, 0, 1, 0.15625, { -40, -40, 80.1500015 },
                                      { 1, 0, 0, -0, 1, -0, 0, 0, -1 } }];

    // A thick slab containing the scan, but the scan far off to the side of the view: the classic
    // engine still makes a 3-pixel-wide sliver at the view's middle (its min/max start values).
    [self checkCase:"case8 scan off to the side inside a thick slab" scan:A
               view:(BKTestView){ { 500, 0, -200 }, { 0, 0, 1 }, { 0, -1, 0 }, 20.0, { 0, 0 }, 1000.0, 1.0, 200, 200, 200, 200 }
           expected:(BKTestExpected){ 3, 200, 0, 0, 1, 0.2, { 480, -20, 300 },
                                      { 1, 0, 0, -0, 1, -0, 0, 0, -1 } }];
}

// Whole-view picture: pixel (0,0) sits at the top-left corner of the view in the slab middle, and
// the last pixel at the opposite corner minus one pixel - i.e. the picture really spans the view.
- (void)testWholeViewSpansTheView
{
    BKTestView v = { { 0, 0, 0 }, { 0, 0, 1 }, { 0, -1, 0 }, 50.0, { 0, 0 }, 10.0, 2.0, 400, 200, 400, 200 };
    BKSlabGeometryInput in = BKTestInput(BKTestScanA(), v);
    BKSlabGeometry g;
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g), BKSlabGeometryOK);
    XCTAssertEqual(g.coversWholeView, 1);
    XCTAssertEqual(g.width, 200);
    XCTAssertEqual(g.height, 100);
    XCTAssertEqualWithAccuracy(g.pixelSpacing, 1.0, 1e-12);          // 100 mm high / 100 pixels
    // up = -y (screen up), so down = +y; right = dir x up = +z x -y = +x.
    XCTAssertEqualWithAccuracy(g.origin.x, -100.0, 1e-9);
    XCTAssertEqualWithAccuracy(g.origin.y, -50.0, 1e-9);
    XCTAssertEqualWithAccuracy(g.origin.z, 5.0, 1e-9);               // middle of the 10 mm slab
    XCTAssertEqualWithAccuracy(g.down.y, 1.0, 1e-12);
    XCTAssertEqualWithAccuracy(g.right.x, 1.0, 1e-12);
    XCTAssertEqualWithAccuracy(g.towardViewer.z, -1.0, 1e-12);
}

// The view up need not be perpendicular to the view direction (it is made so), and the result
// does not depend on how far the focal point is.
- (void)testUpIsOrthogonalisedAndFocalDistanceIgnored
{
    BKTestView v = { { 1, 2, 3 }, { 0, 0.6, 0.8 }, { 0.1, 0.9, -0.2 }, 30.0, { 0, 0 }, 3.0, 1.0, 300, 300, 300, 300 };
    BKSlabGeometryInput in = BKTestInput(BKTestScanA(), v);
    BKSlabGeometry g1, g2;
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g1), BKSlabGeometryOK);
    in.focalPoint = BKV3dAddScaled(in.position, BKV3d(0, 0.6, 0.8), 987.0);
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g2), BKSlabGeometryOK);
    XCTAssertEqualWithAccuracy(BKV3dDot(g1.down, g1.viewDirection), 0.0, 1e-12);
    XCTAssertEqualWithAccuracy(BKV3dDot(g1.right, g1.down), 0.0, 1e-12);
    XCTAssertEqualWithAccuracy(BKV3dDistance(g1.origin, g2.origin), 0.0, 1e-9);
}

// Unusable input is refused and leaves the output untouched.
- (void)testBadInput
{
    BKTestView v = { { 0, 0, 0 }, { 0, 0, 1 }, { 0, -1, 0 }, 50.0, { 0, 0 }, 10.0, 1.0, 400, 200, 400, 200 };
    BKSlabGeometry g; g.width = -7;
    BKSlabGeometryInput in;

    in = BKTestInput(BKTestScanA(), v); in.slabThickness = 0;
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g), BKSlabGeometryBadInput);
    in = BKTestInput(BKTestScanA(), v); in.parallelScale = NAN;
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g), BKSlabGeometryBadInput);
    in = BKTestInput(BKTestScanA(), v); in.renderWidth = 0;
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g), BKSlabGeometryBadInput);
    in = BKTestInput(BKTestScanA(), v); in.viewUp = BKV3d(0, 0, 2);     // parallel to the view
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g), BKSlabGeometryBadInput);
    in = BKTestInput(BKTestScanA(), v); in.focalPoint = in.position;
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g), BKSlabGeometryBadInput);
    in = BKTestInput(BKTestScanA(), v); in.voxelSpacing.z = 0;
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g), BKSlabGeometryBadInput);
    in = BKTestInput(BKTestScanA(), v); in.sampleDistance = 500;      // grid would be 0 pixels
    XCTAssertEqual(BKSlabGeometryCompute(&in, &g), BKSlabGeometryBadInput);
    XCTAssertEqual(BKSlabGeometryCompute(NULL, &g), BKSlabGeometryBadInput);
    XCTAssertEqual(g.width, -7);
    XCTAssertEqualWithAccuracy(BKSlabGeometryResolution(-1, 100), 0.0, 0);
}

@end
