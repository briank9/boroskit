// BorosKitRenderTests: BKMPRGeometryCore - linked MPR planes and panoramic columns, plus an accuracy check on
// the GPU: a marker at a known patient position must appear at the pixel the geometry predicts, in the
// axial, coronal, sagittal and an oblique (tilted) plane, through the slab renderer and the curved reformat.
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BKMPRGeometryCore.h"
#import "BKVolumeRenderer.h"
#import "BKVolumeTexture.h"
#import "BKCurvedReformat.h"

@interface BKMPRGeometryCoreTests : XCTestCase
@end

#define XCTAssertVec(a, b, tol, what) do { BKVec3d _a = (a), _b = (b); \
    XCTAssertEqualWithAccuracy(_a.x, _b.x, tol, @"%@ x", what); XCTAssertEqualWithAccuracy(_a.y, _b.y, tol, @"%@ y", what); \
    XCTAssertEqualWithAccuracy(_a.z, _b.z, tol, @"%@ z", what); } while (0)

@implementation BKMPRGeometryCoreTests

- (void)testViewConventions
{
    BKMPRFrame f = BKMPRFrameMake(BKV3d(1, 2, 3));
    BKVec3d r, d, n;
    BKMPRViewAxes(&f, BKMPRViewAxial, &r, &d, &n);
    XCTAssertVec(r, BKV3d(1, 0, 0), 1e-12, @"axial right = patient left");
    XCTAssertVec(d, BKV3d(0, 1, 0), 1e-12, @"axial down = posterior");
    XCTAssertVec(BKV3dCross(r, d), n, 1e-12, @"axial right x down");
    BKMPRViewAxes(&f, BKMPRViewCoronal, &r, &d, &n);
    XCTAssertVec(r, BKV3d(1, 0, 0), 1e-12, @"coronal right = patient left");
    XCTAssertVec(d, BKV3d(0, 0, -1), 1e-12, @"coronal down = feet");
    XCTAssertVec(BKV3dCross(r, d), n, 1e-12, @"coronal right x down");
    BKMPRViewAxes(&f, BKMPRViewSagittal, &r, &d, &n);
    XCTAssertVec(r, BKV3d(0, 1, 0), 1e-12, @"sagittal right = posterior");
    XCTAssertVec(BKV3dCross(r, d), n, 1e-12, @"sagittal right x down");
}

- (void)testRotationTiltsOtherPlanesOnly
{
    BKMPRFrame f = BKMPRFrameMake(BKV3d(0, 0, 0));
    BKVec3d n0, r0;
    BKMPRViewAxes(&f, BKMPRViewAxial, &r0, NULL, &n0);
    BKMPRRotateInView(&f, BKMPRViewAxial, 30);
    BKVec3d n1, r1, d1;
    BKMPRViewAxes(&f, BKMPRViewAxial, &r1, &d1, &n1);
    XCTAssertVec(n1, n0, 1e-12, @"own plane unchanged");
    // Clockwise on screen: right turns towards down (+y in the axial view).
    XCTAssertEqualWithAccuracy(r1.x, cos(M_PI / 6), 1e-12);
    XCTAssertEqualWithAccuracy(r1.y, sin(M_PI / 6), 1e-12);
    // Coronal now looks along the turned y axis (oblique).
    BKVec3d nc;
    BKMPRViewAxes(&f, BKMPRViewCoronal, NULL, NULL, &nc);
    XCTAssertEqualWithAccuracy(nc.x, -sin(M_PI / 6), 1e-12);
    for (int i = 0; i < 1000; i++) BKMPRRotateInView(&f, (BKMPRView)(i % 3), 7.3);
    for (int i = 0; i < 3; i++) XCTAssertEqualWithAccuracy(BKV3dLength(f.axis[i]), 1, 1e-12);
    XCTAssertEqualWithAccuracy(BKV3dDot(f.axis[0], f.axis[1]), 0, 1e-12);
    XCTAssertVec(BKV3dCross(f.axis[0], f.axis[1]), f.axis[2], 1e-12, @"right-handed");
}

- (void)testPictureCoversScanAndRoundTrips
{
    double v2p[16] = { 0.5, 0, 0, 0,  0, 0.5, 0, 0,  0, 0, 1, 0,  -10, -20, 30, 1 };
    BKVec3d corners[8];
    BKMPRScanCorners(v2p, 40, 30, 20, corners);
    BKMPRPicture pic;
    XCTAssertTrue(BKMPRPictureForPlane(corners, BKV3d(0, 0, 35), BKV3d(1, 0, 0), BKV3d(0, 1, 0), 0.5, 4096, &pic));
    XCTAssertEqual(pic.width, 40u);
    XCTAssertEqual(pic.height, 30u);
    // Pixel (i, j) centre = voxel (i, j) of the slice at z = 35.
    XCTAssertVec(BKMPRPictureImageToPatient(&pic, 3.5, 7.5), BKV3d(-10 + 1.5, -20 + 3.5, 35), 1e-9, @"pixel centre");
    double x, y;
    BKMPRPicturePatientToImage(&pic, BKV3d(-7, -11, 35), &x, &y);
    XCTAssertVec(BKMPRPictureImageToPatient(&pic, x, y), BKV3d(-7, -11, 35), 1e-9, @"round trip");
    // Too many pixels: the spacing grows.
    XCTAssertTrue(BKMPRPictureForPlane(corners, BKV3d(0, 0, 35), BKV3d(1, 0, 0), BKV3d(0, 1, 0), 0.01, 100, &pic));
    XCTAssertLessThanOrEqual(pic.width, 100u);
    XCTAssertEqualWithAccuracy(pic.spacing, 0.2, 1e-9);
    // Clamp.
    double p2v[16] = { 2, 0, 0, 0,  0, 2, 0, 0,  0, 0, 1, 0,  20, 40, -30, 1 };
    BKVec3d c = BKMPRClampToScan(BKV3d(1000, -1000, 40), p2v, v2p, 40, 30, 20);
    XCTAssertVec(c, BKV3d(-10 + 39 * 0.5, -20, 40), 1e-9, @"clamped");
}

- (void)testPanoramicDirectionsPointToTheCheek
{
    // A U-shaped arch in the axial plane opening towards +y (posterior), centroid inside.
    BKVec3d pos[3] = { BKV3d(-20, 10, 0), BKV3d(0, -15, 0), BKV3d(20, 10, 0) };
    BKVec3d tan[3] = { BKV3d(0.3, -1, 0), BKV3d(1, 0, 0), BKV3d(0.3, 1, 0) };
    BKVec3d downs[3], slabs[3];
    XCTAssertTrue(BKMPRPanoramicDirections(pos, tan, 3, BKV3d(0, 0, -1), BKV3d(0, 0, 0), downs, slabs));
    XCTAssertLessThan(slabs[0].x, 0);   // patient right side: cheek towards -x
    XCTAssertLessThan(slabs[1].y, 0);   // front: lips towards anterior (-y)
    XCTAssertGreaterThan(slabs[2].x, 0);
    XCTAssertEqual(BKMPRSlabDepth(0, 0.3), 1u);
    XCTAssertEqual(BKMPRSlabDepth(3, 0.3), 11u);
}

// ---- GPU accuracy: markers land where the geometry says -------------------------------------------------

static const uint32_t kW = 40, kH = 30, kD = 20;

- (BKVolumeTexture *)markerVolume:(id<MTLDevice>)device voxelToPatient:(double *)v2p patientToVoxel:(double *)p2v
{
    // 0.5 x 0.5 x 1 mm voxels at an offset origin; one bright voxel block at voxel (25, 9, 13).
    double a[16] = { 0.5, 0, 0, 0,  0, 0.5, 0, 0,  0, 0, 1, 0,  -10, -20, 30, 1 };
    double b[16] = { 2, 0, 0, 0,  0, 2, 0, 0,  0, 0, 1, 0,  20, 40, -30, 1 };
    memcpy(v2p, a, sizeof(a)); memcpy(p2v, b, sizeof(b));
    float *v = calloc(kW * kH * kD, sizeof(float));
    for (size_t i = 0; i < kW * kH * kD; i++) v[i] = -1000;
    v[(13 * kH + 9) * kW + 25] = 3000;
    NSError *error = nil;
    BKVolumeTexture *t = [[BKVolumeTexture alloc] initWithFloatVoxels:v width:kW height:kH depth:kD patientToVoxel:p2v
                                                      minPixelSpacing:0.5 outOfBoundsValue:-1000 device:device error:&error];
    free(v);
    XCTAssertNotNil(t, @"%@", error);
    return t;
}

static void BKBrightest(const float *img, uint32_t w, uint32_t h, double *x, double *y)
{
    float best = -INFINITY;
    for (uint32_t j = 0; j < h; j++) for (uint32_t i = 0; i < w; i++) if (img[j * w + i] > best) { best = img[j * w + i]; *x = i + 0.5; *y = j + 0.5; }
}

- (void)testMarkerLandsOnPredictedPixelInSlabRenderer
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    double v2p[16], p2v[16];
    BKVolumeTexture *tex = [self markerVolume:device voxelToPatient:v2p patientToVoxel:p2v];
    BKVec3d marker = BKV3d(-10 + 25 * 0.5, -20 + 9 * 0.5, 30 + 13);
    BKVec3d corners[8];
    BKMPRScanCorners(v2p, kW, kH, kD, corners);
    NSError *error = nil;
    BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    r.volumeTexture = tex;
    r.mode = BKRenderModeMIP;
    r.projection = BKProjectionOrthographic;
    for (int tilt = 0; tilt < 2; tilt++) {
        BKMPRFrame frame = BKMPRFrameMake(marker);
        if (tilt) { BKMPRRotateInView(&frame, BKMPRViewAxial, 25); BKMPRRotateInView(&frame, BKMPRViewCoronal, -15); }
        for (int view = 0; view < 3; view++) {
            BKVec3d right, down, normal;
            BKMPRViewAxes(&frame, (BKMPRView)view, &right, &down, &normal);
            BKMPRPicture pic;
            XCTAssertTrue(BKMPRPictureForPlane(corners, frame.centre, right, down, 0.25, 2048, &pic));
            BKVec3d pos, dir, up; double vw, vh;
            BKMPRPictureCamera(&pic, &pos, &dir, &up, &vw, &vh);
            r.cameraPosition = N3VectorMake(pos.x, pos.y, pos.z);
            r.cameraDirection = N3VectorMake(dir.x, dir.y, dir.z);
            r.cameraUp = N3VectorMake(up.x, up.y, up.z);
            r.viewWidth = vw; r.viewHeight = vh;
            r.slabEnabled = YES;
            r.slabPlane = N3PlaneMake(N3VectorMake(marker.x, marker.y, marker.z), N3VectorMake(normal.x, normal.y, normal.z));
            r.slabThickness = 2.0;
            size_t page = (size_t)getpagesize(), bytes = (size_t)pic.width * pic.height * 4, cap = (bytes + page - 1) / page * page;
            float *img = NULL;
            posix_memalign((void **)&img, page, cap);
            XCTAssertTrue([r renderValuesInto:img capacity:cap width:pic.width height:pic.height error:&error], @"%@", error);
            double bx = 0, by = 0, ex, ey;
            BKBrightest(img, pic.width, pic.height, &bx, &by);
            BKMPRPicturePatientToImage(&pic, marker, &ex, &ey);
            // The marker voxel is 0.5 mm wide = 2 picture pixels; its trilinear blob is centred on the voxel.
            XCTAssertEqualWithAccuracy(bx, ex, 1.01, @"view %d tilt %d x", view, tilt);
            XCTAssertEqualWithAccuracy(by, ey, 1.01, @"view %d tilt %d y", view, tilt);
            free(img);
        }
    }
}

- (void)testStraightColumnsInCurvedReformatMatchThePlane
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    double v2p[16], p2v[16];
    BKVolumeTexture *tex = [self markerVolume:device voxelToPatient:v2p patientToVoxel:p2v];
    BKVec3d marker = BKV3d(-10 + 25 * 0.5, -20 + 9 * 0.5, 30 + 13);
    // A coronal picture as columns: 60 columns along +x every 0.25 mm, rows down (-z), slab along +y.
    const uint32_t W = 60, H = 40;
    BKVec3d centres[W], downs[W], slabs[W];
    for (uint32_t i = 0; i < W; i++) {
        centres[i] = BKV3d(marker.x + (i - 30.0) * 0.25, marker.y, marker.z);
        downs[i] = BKV3d(0, 0, -1);
        slabs[i] = BKV3d(0, 1, 0);
    }
    BKReformatFrame frames[W];
    BKMPRColumnFrames(p2v, centres, downs, slabs, W, 0.25, 0.25, frames);
    BKReformatParams p;
    memset(&p, 0, sizeof(p));
    p.width = W; p.height = H; p.depth = BKMPRSlabDepth(1.0, 0.25);
    p.interpolation = BKReformatLinear; p.projection = BKReformatMIP;
    p.outOfBoundsValue = -1000;
    p.rowCentre = (H - 1) / 2.0f; p.slabCentre = (p.depth - 1) / 2.0f;
    NSError *error = nil;
    BKCurvedReformat *gen = [[BKCurvedReformat alloc] initWithDevice:device error:&error];
    float img[W * H];
    XCTAssertTrue([gen renderParams:p frames:frames volume:tex into:img capacity:sizeof(img) error:&error], @"%@", error);
    double bx = 0, by = 0;
    BKBrightest(img, W, H, &bx, &by);
    // Column 30 is at the marker, row centre (19.5) is at its height.
    XCTAssertEqualWithAccuracy(bx, 30.5, 1.01);
    XCTAssertEqualWithAccuracy(by, 20.0, 1.01);
}

@end
