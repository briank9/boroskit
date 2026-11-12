// BorosKitMesh: BKMesh
//
// What it is: a surface mesh, i.e. a 3D shape described by its skin only: a list of
// corner points ("vertices") and a list of triangles that connect them. This is how
// bone surfaces extracted from a CT, intraoral (optical) scans, implants and surgical
// guides are stored and exchanged (STL / PLY / OBJ files, see BKMeshIO.h).
//
// Why it exists: the old Horos 3D surface views kept meshes inside VTK, which draws
// with OpenGL. Boros 6 removes OpenGL, so meshes need their own home that has no
// drawing code at all: this class only holds the shape and does the geometry (size,
// moving it, checking it is closed, area, volume). Drawing is BKMeshRenderer's job
// (BorosKitMeshRender). Works on macOS and iOS.
//
// Coordinates: patient (DICOM) millimetres, like the rest of BorosKit: x to the
// patient's left, y to the back (posterior), z to the head.
//
// What a mesh holds:
//   - vertices: one 3D point (mm) per corner;
//   - triangles: three vertex numbers per triangle (counted from 0). The order of the
//     three corners matters: seen from OUTSIDE the shape they go anticlockwise (the
//     usual convention), so the computer knows which side is the outside;
//   - optional normals: one unit "outward" direction per vertex, used for lighting;
//   - optional colours: one RGBA colour (0..1) per vertex (e.g. a coloured intraoral scan).

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#import "N3Geometry.h"

NS_ASSUME_NONNULL_BEGIN

// Errors from BKMesh and BKMeshIO (file reading/writing) use this domain.
extern NSErrorDomain const BKMeshErrorDomain;

typedef NS_ERROR_ENUM(BKMeshErrorDomain, BKMeshErrorCode) {
    BKMeshErrorInvalidGeometry  = 1,  // bad numbers: index out of range, NaN coordinates...
    BKMeshErrorUnreadableFile   = 2,  // the file could not be opened / written
    BKMeshErrorUnknownFormat    = 3,  // not an STL, PLY or OBJ file (or unknown extension)
    BKMeshErrorMalformedFile    = 4,  // the file is damaged, truncated or not as the format says
    BKMeshErrorUnsupportedFile  = 5,  // a valid file using a feature we do not read
};

// The result of the "is it a closed, clean surface?" check (-edgeReport).
// Every triangle edge should be shared by exactly two triangles, running in opposite
// directions, for the surface to be closed (watertight) and consistently oriented.
typedef struct {
    NSUInteger edgeCount;              // number of distinct edges
    NSUInteger boundaryEdgeCount;      // edges used by only ONE triangle = holes / open borders
    NSUInteger nonManifoldEdgeCount;   // edges used by 3 or more triangles = fins, T-junctions
    NSUInteger misorientedEdgeCount;   // edges whose two triangles disagree on inside/outside
    NSUInteger degenerateTriangleCount;// triangles that use the same vertex twice
} BKMeshEdgeReport;

@interface BKMesh : NSObject <NSCopying>

// Creates a mesh by COPYING the given arrays. `indices` holds 3 numbers per triangle
// (indexCount must be a multiple of 3, every number < vertexCount). `normals` and
// `colors` are optional (NULL), and if given have vertexCount entries.
// Returns nil + error (BKMeshErrorInvalidGeometry) for bad input instead of crashing,
// because the arrays usually come from files that may be damaged.
- (nullable instancetype)initWithVertices:(const simd_float3 *)vertices
                              vertexCount:(NSUInteger)vertexCount
                                  indices:(const uint32_t *)indices
                               indexCount:(NSUInteger)indexCount
                                  normals:(nullable const simd_float3 *)normals
                                   colors:(nullable const simd_float4 *)colors
                                    error:(NSError * _Nullable * _Nullable)error;

// An empty mesh (no vertices, no triangles).
- (instancetype)init;

// --- The data (read-only views; valid until the mesh is next changed) --------------
@property (nonatomic, readonly) NSUInteger vertexCount;
@property (nonatomic, readonly) NSUInteger triangleCount;
@property (nonatomic, readonly) const simd_float3 *vertices;               // vertexCount points, mm
@property (nonatomic, readonly) const uint32_t *indices;                   // 3 * triangleCount
@property (nonatomic, readonly, nullable) const simd_float3 *normals;      // NULL if none
@property (nonatomic, readonly, nullable) const simd_float4 *colors;       // NULL if none

// Optional free-text name (e.g. the file name or "Mandible"). Not used for geometry.
@property (nonatomic, copy, nullable) NSString *name;

// Goes up by one every time the shape, normals or colours change. Why: the GPU
// renderer keeps its own copy of the mesh and uses this to know when to re-upload.
@property (nonatomic, readonly) NSUInteger version;

// --- Replacing parts ---------------------------------------------------------------
// Sets (or with NULL removes) the per-vertex normals / colours (vertexCount entries).
- (void)setNormals:(nullable const simd_float3 *)normals;
- (void)setColors:(nullable const simd_float4 *)colors;

// --- Size ----------------------------------------------------------------------------
// Smallest box (aligned with the patient axes) that contains every vertex, in mm.
// Both are zero for an empty mesh.
@property (nonatomic, readonly) simd_float3 boundsMin;
@property (nonatomic, readonly) simd_float3 boundsMax;

// --- Moving ---------------------------------------------------------------------------
// Moves/rotates/scales every vertex by a 4x4 matrix (simd convention: point' = M * point,
// translation in the 4th column). Normals are turned with it (and re-normalised). If the
// matrix mirrors the shape, the triangle corner order is flipped so "outside" stays
// outside. Why: placing an implant or registering a scan to the CT is a matrix.
- (void)transformByMatrix:(simd_float4x4)matrix;

// Same with BorosKit's usual N3AffineTransform (row-vector convention, as used by
// CPRVolumeData and the rest of the geometry code).
- (void)transformByN3AffineTransform:(N3AffineTransform)transform;

// Converts an N3AffineTransform to the equivalent simd matrix (point' = M * point).
+ (simd_float4x4)matrixFromN3AffineTransform:(N3AffineTransform)transform;

// --- Normals --------------------------------------------------------------------------
// Smooth normals: each vertex gets the average direction of the triangles around it
// (weighted by triangle size). Gives a rounded look; right for bone and scans.
- (void)computeSmoothNormals;

// Flat normals: every triangle gets its own three vertices carrying the triangle's own
// direction, so facets look sharp (right for implants/guides with hard edges). Note
// this triples the vertex count and the vertices are no longer shared.
- (void)computeFlatNormals;

// --- Cleaning -------------------------------------------------------------------------
// Merges vertices closer than `tolerance` mm into one (0 = only exactly equal points),
// drops triangles that collapse to a line or point, and removes vertices that no
// triangle uses. Returns how many vertices were removed.
// Why: STL files repeat every corner for every triangle, so without welding the
// triangles do not "know" they touch, and closed-surface checks or smooth shading fail.
// Merged normals are averaged; the colour of the first vertex of a group is kept.
- (NSUInteger)weldVerticesWithTolerance:(float)tolerance;

// --- Checks and measurements -----------------------------------------------------------
// Counts open edges, non-manifold edges, inconsistently oriented edges and degenerate
// triangles (see BKMeshEdgeReport). Works on the vertex NUMBERS: weld STL meshes first.
- (BKMeshEdgeReport)edgeReport;

// YES if the surface is closed: there is at least one triangle and every edge is
// shared by exactly two triangles (no holes, no fins). Why: a surgical guide or a
// model for 3D printing must be watertight, and the enclosed volume only means
// something for a closed surface.
@property (nonatomic, readonly, getter=isWatertight) BOOL watertight;

// YES if no edge is shared by more than two triangles (a "manifold" surface; it may
// still have holes).
@property (nonatomic, readonly, getter=isManifold) BOOL manifold;

// Total area of all triangles, mm^2.
@property (nonatomic, readonly) double surfaceArea;

// Volume enclosed by the surface, mm^3 (divergence theorem). Positive when the
// triangles face outward, negative when the whole mesh is inside-out. Only meaningful
// for a watertight, consistently oriented mesh.
@property (nonatomic, readonly) double enclosedVolume;

// --- Simple shapes (tests, markers, placeholders) ---------------------------------------
// A box from `min` to `max` (mm): 8 shared vertices, 12 outward-facing triangles.
+ (BKMesh *)boxMeshWithMin:(simd_float3)min max:(simd_float3)max;

// A closed sphere made from a subdivided icosahedron (20 * 4^subdivisions triangles;
// subdivisions is limited to 0...7). Outward-facing, with smooth normals.
+ (BKMesh *)sphereMeshWithCenter:(simd_float3)center radius:(float)radius subdivisions:(NSUInteger)subdivisions;

@end

NS_ASSUME_NONNULL_END
