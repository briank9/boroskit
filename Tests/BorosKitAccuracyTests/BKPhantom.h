// BorosKit accuracy check: the synthetic "phantom" scan and the measuring tools.
//
// What a phantom is: in radiology, a phantom is a test object with known contents that
// is scanned to check that a scanner or viewer is accurate. Here the phantom is made in
// code (no patient data), so every marker's exact position in millimetres is known and
// every image the engine makes of it can be checked against that truth.
//
// Patient coordinates used everywhere in BorosKit (DICOM "LPS"), in millimetres:
//   +x = toward the patient's LEFT        (-x = patient's right)
//   +y = toward the patient's BACK (posterior)   (-y = front, anterior)
//   +z = toward the patient's HEAD (superior)    (-z = feet, inferior)
//
// What is inside the phantom (positions relative to its centre C, in mm):
//   - background "air": -1000
//   - LEFT sphere:      centre (+12,   0,   0), radius 3, value 1000  (patient's left side)
//   - ANTERIOR sphere:  centre (  0, -12,   0), radius 3, value  500  (front)
//   - SUPERIOR rod:     from (0, 0, +8) to (0, 0, +18), radius 1.5, value 200 (toward the head)
//   - dot pair 1:       (-20, 8, -10) and (+20, 8, -10): exactly 40.0 mm apart, left-right,
//                        small soft dots (Gaussian, 0.8 mm), peak value 2000
//   - dot pair 2:       (-8, -14.142, -14.142) and (-8, +14.142, +14.142): exactly 40.0 mm
//                        apart, diagonal front-bottom to back-top, peak value 1500
// Marker edges are smooth (not stair-stepped), so their centre can be measured to a small
// fraction of a voxel and any error found is the engine's, not the phantom's.
//
// The voxel grid is deliberately awkward: voxels of 0.3 x 0.4 x 0.5 mm (not cubes), an
// origin far from 0, and three different grid orientations (see BKPhantomGrid). The
// markers stay at the same PATIENT positions in all three, so every image must come out
// the same whichever way the scan was stored. A viewer that confuses voxel axes with
// patient axes (which is how left/right mirror bugs happen) fails these tests.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "N3Geometry.h"
#import "CPRVolumeData.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BKPhantomGrid) {
    // Voxel rows along +x (left), columns along +y (back), slices along +z (head):
    // the usual way an axial CT/CBCT is stored.
    BKPhantomGridAxisAligned = 0,
    // The whole voxel grid turned 17 degrees about a slanted axis (like a tilted gantry
    // or a re-oriented scan). Voxel axes no longer match patient axes at all.
    BKPhantomGridTilted,
    // Rows run toward the patient's RIGHT and slices toward the FEET (stored "backwards").
    // If anything used voxel order instead of patient geometry, this would mirror.
    BKPhantomGridReversed,
};

// One marker of the phantom (all positions in absolute patient mm).
@interface BKPhantomMarker : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) N3Vector centre;     // the point a measurement should find
@property (nonatomic) float value;         // the marker's peak value (HU)
@property (nonatomic) N3Vector boxMin;     // a box that surely contains the whole marker
@property (nonatomic) N3Vector boxMax;
@end

@interface BKPhantom : NSObject

// Returns the phantom for one grid type. Built once and reused (building takes a moment).
+ (BKPhantom *)phantomWithGrid:(BKPhantomGrid)grid;
+ (NSString *)nameOfGrid:(BKPhantomGrid)grid;

@property (nonatomic, readonly) BKPhantomGrid grid;
@property (nonatomic, readonly) CPRVolumeData *volume;
@property (nonatomic, readonly) N3Vector centre;              // C, patient mm
@property (nonatomic, readonly) float background;             // -1000
@property (nonatomic, readonly) double spacingX, spacingY, spacingZ;   // 0.3, 0.4, 0.5 mm

// Markers by name: "left", "anterior", "rod", "dotA1", "dotB1", "dotA2", "dotB2".
@property (nonatomic, readonly) NSDictionary<NSString *, BKPhantomMarker *> *markers;
- (BKPhantomMarker *)marker:(NSString *)name;

// The exact, ideal value at a patient point (what an infinitely fine scan would show).
- (float)analyticValueAt:(N3Vector)p;

// CPU reference sampler: plain trilinear interpolation of the stored voxels at a patient
// point, written independently of the engine (own patient->voxel math from origin,
// orientation and spacing). Returns NAN outside the voxel grid.
- (float)referenceTrilinearAt:(N3Vector)p;

// YES if p lies inside the voxel grid with at least `margin` voxels to spare on every side.
- (BOOL)containsPoint:(N3Vector)p marginVoxels:(double)margin;

@end

// ---- Measuring tools on rendered images ---------------------------------------------

// Where a flat image lies in the patient: pixel (i, j) has its CENTRE at
//   centre + (i + 0.5 - width/2) * spacing * right + (j + 0.5 - height/2) * spacing * down
// i.e. image x runs along `right`, image y runs down the screen along `down`.
typedef struct {
    N3Vector centre;     // patient point at the middle of the image
    N3Vector right;      // unit vector: patient direction of the image's left-to-right
    N3Vector down;       // unit vector: patient direction of the image's top-to-bottom
    double spacing;      // mm per pixel (square pixels)
    NSUInteger width, height;
} BKImagePlane;

// Patient point at the centre of pixel (i, j) (fractional i, j allowed).
N3Vector BKImagePlanePointAt(BKImagePlane plane, double i, double j);
// The (fractional) pixel coordinates of a patient point projected onto the image;
// pixel (i, j)'s centre has coordinates exactly (i, j).
CGPoint BKImagePlaneProject(BKImagePlane plane, N3Vector p);
// The pixel box (inclusive) covering a patient-space box projected onto the image.
CGRect BKImagePlaneProjectBox(BKImagePlane plane, N3Vector boxMin, N3Vector boxMax, double marginMM);

// The weighted centre ("centroid") of the bright spot inside `box` of an image of floats:
// each pixel counts with weight (value - background), negatives ignored. Gives the spot's
// position to a small fraction of a pixel. Also returns the highest value in the box.
CGPoint BKBrightSpotCentroid(const float *pixels, NSUInteger width, NSUInteger height,
                             CGRect box, float background, float *_Nullable peak);

// Running error statistics (largest and average absolute difference).
typedef struct {
    double maxError;
    double sumError;
    NSUInteger count;
} BKErrorStats;
void BKErrorStatsAdd(BKErrorStats *stats, double a, double b);
double BKErrorStatsMean(BKErrorStats stats);

// Prints one result line that ACCURACY.md collects. All lines start with "ACCURACY |".
void BKReport(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
