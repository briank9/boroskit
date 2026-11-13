// BorosKitMesh: BKMeshProcessing (smoothing and decimation of surface meshes)
// Original BorosKit code written for this project; contains no third-party code.
//
// What it is: two optional clean-up steps for surfaces made from a scan (e.g. the bone
// surface of the Surface Rendering window), as methods on BKMesh:
//
//   - Smoothing that does NOT shrink the shape (Taubin's lambda/mu method). The old VTK
//     smoothing (Laplacian) made a bone tenths of a millimetre smaller, which matters for
//     surgical measurements; this method removes the noise while keeping the size.
//   - Decimation: fewer triangles, same shape (quadric error edge collapse). Big scans
//     have millions of tiny triangles; halving them makes drawing, saving and exporting
//     faster with no visible change. Unlike the old VTK step it really reaches the
//     requested reduction, and it is many times faster.
//
// Both return a NEW mesh (the original is not changed), with fresh area-weighted
// normals. Colours are carried over. Both work on vertex NUMBERS: weld STL meshes first
// (-weldVerticesWithTolerance:) so neighbouring triangles share their corners.
//
// The algorithms are plain portable C++ (BKMeshProcessingCore); these methods only
// convert to and from BKMesh. Results are identical whatever the number of threads.

#import "BKMesh.h"

NS_ASSUME_NONNULL_BEGIN

// Called from time to time on the CALLING thread with the fraction done (0...1).
// Return YES to continue, NO to cancel (the method then returns nil).
typedef BOOL (^BKMeshProgressHandler)(double fraction);

// What happened, for logging and for the user interface.
typedef struct {
    double milliseconds;              // total time of the call
    NSUInteger inputTriangleCount;
    NSUInteger outputTriangleCount;
    double requestedReduction;        // decimation: what was asked (0...1)
    double achievedReduction;         // decimation: 1 - output/input triangles
    NSUInteger iterations;            // smoothing: rounds done; decimation: passes
    NSUInteger fixedVertexCount;      // vertices kept in place (open border, non-manifold)
    BOOL reachedTarget;               // decimation: NO if no safe merge was left earlier
    BOOL cancelled;
} BKMeshProcessingReport;

// Defaults matching the old Surface Rendering window.
extern const NSUInteger BKMeshSmoothingDefaultIterations;   // 20
extern const float BKMeshSmoothingDefaultPassBand;          // 0.1

@interface BKMesh (BKMeshProcessing)

// --- Smoothing --------------------------------------------------------------------------
// Non-shrinking smoothing. `iterations`: number of rounds (old UI default 20; each round
// is one smoothing step plus one "re-inflating" step). `passBand`: 0.01...0.2, default
// 0.1: lower = only the broadest shapes are kept (smoother); values are clamped.
// Vertices on an open border (where the surface meets the edge of the scan) and on
// non-manifold edges keep their position. Triangles are unchanged.
- (nullable BKMesh *)meshBySmoothingWithIterations:(NSUInteger)iterations
                                          passBand:(float)passBand
                                          progress:(nullable BKMeshProgressHandler)progress
                                            report:(nullable BKMeshProcessingReport *)report;

// The same with explicit factors: each round moves vertices `lambda` (> 0) of the way
// to their neighbours' average, then `mu` (< 0) of the way. mu = 0 is plain Laplacian
// smoothing (it shrinks; offered for comparison and tests).
- (nullable BKMesh *)meshBySmoothingWithIterations:(NSUInteger)iterations
                                            lambda:(float)lambda
                                                mu:(float)mu
                                          progress:(nullable BKMeshProgressHandler)progress
                                            report:(nullable BKMeshProcessingReport *)report;

// The lambda/mu factors used for a pass band (lambda = 0.5, 1/lambda + 1/mu = passBand).
+ (void)getTaubinLambda:(float *)lambda mu:(float *)mu forPassBand:(float)passBand;

// --- Decimation --------------------------------------------------------------------------
// Removes `targetReduction` (0...1) of the triangles: 0.5 = half, 0.9 = nine tenths.
// The merges that change the shape least go first. Guarantees: the result is as clean
// as the input (closed stays closed, no edge shared by 3+ triangles, consistent
// inside/outside), no triangle turns over, and open borders keep exactly their points.
// The target is reached exactly (to within 1 triangle) unless no safe merge is left
// (then report.reachedTarget is NO).
- (nullable BKMesh *)meshByDecimatingWithTargetReduction:(double)targetReduction
                                                progress:(nullable BKMeshProgressHandler)progress
                                                  report:(nullable BKMeshProcessingReport *)report;

// --- Threads -----------------------------------------------------------------------------
// The most threads the processing may use: 0 = all cores (default), 1 = single thread.
// Results are identical either way (this is tested); meant for tests and debugging.
@property (class, nonatomic) NSUInteger processingMaxThreads;

@end

NS_ASSUME_NONNULL_END
