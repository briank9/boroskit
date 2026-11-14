// BorosKitGoldenTests: BKGoldenCore (plain C, the backend-neutral half of the harness)
// Original BorosKit code written for this project; contains no third-party code.
//
// What it is: everything the "golden output" harness needs that does NOT depend on a
// graphics API:
//   - a fixed-seed random number generator and a 64-bit content hash (both written for
//     this project; the mixing constants are arbitrary odd numbers, chosen here);
//   - synthetic test scans ("phantoms") with known contents and repeatable noise;
//   - the exact settings of every test case (camera, colours, thresholds...), as plain
//     data, so every backend (Metal today, Vulkan later) renders the SAME request;
//   - simple image and mesh containers, reading/writing them as small open file formats
//     (Netpbm PAM for 8/16-bit images, PFM for float images, a tiny binary mesh format);
//   - the comparers with the agreed tolerances.
// The GPU half (BKGoldenMetal.m) only turns case settings into Metal calls and hands the
// results back in these containers.
//
// ---- PORTING NOTES (future Vulkan backend) -------------------------------------------
//  - Plain C99 + libc only: no Foundation, no Metal, no Apple simd, no N3 geometry, no
//    CPRVolumeData. Builds unchanged with CMake on Windows / Linux.
//  - A Vulkan test runner reuses this file as is, writes its own "producer" (the Vulkan
//    equivalent of BKGoldenMetal.m: one function per operation, filling BKGoldenImage /
//    BKGoldenMesh), then calls the bk_golden_compare_* functions against the reference
//    files recorded from Metal (Tests/BorosKitGoldenTests/References).
//  - The phantom must come out bit-identical on every platform (its hash is part of the
//    references and checked first). It uses only + - * / sqrt floor, which IEEE 754
//    defines exactly, and MUST be compiled with floating-point contraction off
//    (-ffp-contract=off; MSVC: /fp:precise, the default), because a fused multiply-add
//    rounds differently. No sin/cos/exp/pow (their results differ between C libraries).
//  - All files are little-endian; the readers/writers assemble bytes explicitly, so they
//    also work on a big-endian machine.
//  - Image rows are stored top row first in memory (like BKRenderResult). PFM files store
//    the bottom row first (that is the PFM rule); the reader/writer handle the flip.
// ---------------------------------------------------------------------------------------

#ifndef BK_GOLDEN_CORE_H
#define BK_GOLDEN_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Random numbers and hashing --------------------------------------------------------
// What: scrambles a 64-bit number (xor-shift / multiply rounds). Same input, same output,
// on every machine. Why: the basis of the noise generator and the content hash.
uint64_t bk_golden_mix64(uint64_t x);

// What: a uniform random number in [0, 1) for (seed, index). Counter-based: the value for
// voxel i does not depend on the order in which voxels are filled, so filling with any
// number of threads gives the same scan.
double bk_golden_uniform(uint64_t seed, uint64_t index);

// What: approximately normal ("Gaussian") noise with mean 0 and standard deviation 1,
// made from the sum of 4 uniform numbers (no log/sin, so it is exact on every platform).
double bk_golden_noise(uint64_t seed, uint64_t index);

// What: a 64-bit fingerprint of `size` bytes. Equal content -> equal hash. Not a
// cryptographic hash; only for spotting changes and naming reference contents.
uint64_t bk_golden_hash(const void *bytes, size_t size);

// ---- Phantoms ----------------------------------------------------------------------------
// A scan: voxels in real units (HU), x fastest, then y, then z. Patient mm position of
// voxel (i, j, k) = origin + (i * spacing[0], j * spacing[1], k * spacing[2]) (axis-aligned).
typedef struct {
    uint32_t width, height, depth;
    double spacing[3];
    double origin[3];
    float *voxels;              // malloc'ed; free with bk_golden_volume_free
    double patientToVoxel[16];  // column-major 4x4, voxel = M * (x, y, z, 1) for patient mm
    double voxelToPatient[16];  // the inverse (column-major)
    double minSpacing;          // smallest of spacing[]
    float outOfBoundsValue;     // value outside the scan (-1000 HU, air)
} BKGoldenVolume;

void bk_golden_volume_free(BKGoldenVolume *volume);

// The "head" phantom: 64 x 64 x 48 voxels of 1 x 1 x 1.25 mm, filled with (2x2x2
// sub-samples per voxel, so edges have realistic partial-volume values):
//   - air (-1000 HU) around a soft-tissue ellipsoid (40 HU), semi-axes 28 x 26 x 27 mm;
//   - a fat ball (-100 HU, r 5 mm), a bone ball (1000 HU, r 6 mm), a small dense
//     "metal" ball (2500 HU, r 2.5 mm);
//   - a vertical cylinder (400 HU, r 3.5 mm, 36 mm long);
//   - a step wedge of 5 blocks, 8 mm each: -500, 0, 250, 600, 1200 HU;
//   - a curved "jaw" tube (1500 HU, r 3 mm) along a parabola in one axial plane, with a
//     300 HU "nerve canal" (r 1.5 mm) inside;
// plus Gaussian noise (sigma 15 HU, fixed seed), rounded to whole HU like a CT.
// Returns 0 on success (out of memory: -1).
int bk_golden_make_head_phantom(BKGoldenVolume *out);

// Known numbers of the head phantom (used by tests as plain facts, not as references).
#define BK_GOLDEN_HEAD_SEED 20261113u
#define BK_GOLDEN_HEAD_NOISE_HU 15.0

// ---- Images ------------------------------------------------------------------------------
typedef enum {
    BKGoldenFormatU8 = 1,    // 8-bit unsigned per channel (RGBA8 renders)
    BKGoldenFormatU16 = 2,   // 16-bit unsigned per channel
    BKGoldenFormatF32 = 3,   // 32-bit float per channel (HU values, distances in mm)
} BKGoldenFormat;

typedef struct {
    uint32_t width, height, channels;   // channels 1...4
    BKGoldenFormat format;
    void *data;                          // malloc'ed, row 0 = top, channels interleaved
} BKGoldenImage;

// Allocates a zeroed image (data NULL on failure).
BKGoldenImage bk_golden_image_make(uint32_t width, uint32_t height, uint32_t channels, BKGoldenFormat format);
void bk_golden_image_free(BKGoldenImage *image);
size_t bk_golden_image_bytes(const BKGoldenImage *image);

// ---- Meshes ------------------------------------------------------------------------------
typedef struct {
    uint64_t vertexCount, triangleCount;
    float *positions;    // 3 floats per vertex (mm), malloc'ed
    float *normals;      // 3 floats per vertex or NULL
    uint32_t *indices;   // 3 per triangle
} BKGoldenMesh;

void bk_golden_mesh_free(BKGoldenMesh *mesh);

// Plain measurements of a mesh (for the report and as a quick cross-check).
typedef struct {
    uint64_t vertexCount, triangleCount;
    double boundsMin[3], boundsMax[3];
    double area;          // mm^2
    double volume;        // mm^3 (signed, divergence theorem)
    uint64_t quantizedHash;   // hash of positions rounded to 1e-3 mm + the triangle list
} BKGoldenMeshSummary;

BKGoldenMeshSummary bk_golden_mesh_summary(const BKGoldenMesh *mesh);

// ---- Files -------------------------------------------------------------------------------
// All return 0 on success, -1 on failure (cannot open, malformed, unsupported).
// PAM (Netpbm "P7"): U8 or U16, 1-4 channels. PFM ("Pf"/"PF"): F32, 1 or 3 channels.
int bk_golden_write_pam(const char *path, const BKGoldenImage *image);
int bk_golden_read_pam(const char *path, BKGoldenImage *out);
int bk_golden_write_pfm(const char *path, const BKGoldenImage *image);
int bk_golden_read_pfm(const char *path, BKGoldenImage *out);
// Binary mesh: "BKMESH1\n", u64 vertexCount, u64 triangleCount, u32 hasNormals,
// u32 reserved, positions (f32 x3), [normals (f32 x3)], indices (u32 x3). Little-endian.
int bk_golden_write_mesh(const char *path, const BKGoldenMesh *mesh);
int bk_golden_read_mesh(const char *path, BKGoldenMesh *out);
// Whole file as bytes (malloc'ed) / write bytes.
int bk_golden_read_file(const char *path, uint8_t **bytes, size_t *size);
int bk_golden_write_file(const char *path, const void *bytes, size_t size);

// Named numbers ("name value" per line, values written with 17 significant digits so
// they read back exactly). Names: no spaces, at most 63 characters.
typedef struct {
    char name[64];
    double value;
} BKGoldenNumber;
int bk_golden_write_numbers(const char *path, const BKGoldenNumber *numbers, size_t count);
// *numbers is malloc'ed (free it); returns 0 on success.
int bk_golden_read_numbers(const char *path, BKGoldenNumber **numbers, size_t *count);

// ---- Comparers ---------------------------------------------------------------------------
// Images: a pixel channel "fails" when |test - reference| > maxAbsDiff (units of the
// image: grey levels for U8/U16, HU or mm for F32; two infinities of the same sign and
// two NaNs count as equal). The image passes when the fraction of failing channels is at
// most maxOutlierFraction (edge pixels may differ more after a change of GPU or API,
// because rasterisation / filtering rounding differs at sharp edges).
typedef struct {
    double maxAbsDiff;
    double maxOutlierFraction;
} BKGoldenImageTolerance;

typedef struct {
    int pass;                 // 1 = within tolerance
    int sizeMismatch;         // 1 = different width/height/channels/format (always a fail)
    double maxDiff;           // largest difference over all channels (finite ones)
    uint64_t outlierCount;    // channels beyond maxAbsDiff
    double outlierFraction;
    uint64_t identicalCount;  // channels exactly equal
} BKGoldenImageReport;

// The agreed defaults: 8-bit images within +-1 grey level, at most 0.5% of channels
// beyond that.
BKGoldenImageTolerance bk_golden_tolerance_u8(void);
BKGoldenImageReport bk_golden_compare_images(const BKGoldenImage *reference, const BKGoldenImage *test,
                                             BKGoldenImageTolerance tolerance);

// Meshes: vertex and triangle counts must match and the triangle lists must be identical
// (the extraction order is defined by the algorithm, not by the GPU). Positions must
// agree within maxPositionVoxels after dividing each axis difference by voxelSize (the
// agreed 1e-4 voxel), normals within maxNormalDiff (length of the difference vector).
typedef struct {
    double voxelSize[3];
    double maxPositionVoxels;
    double maxNormalDiff;
} BKGoldenMeshTolerance;

typedef struct {
    int pass;
    int countMismatch;
    int triangleMismatch;     // index lists differ
    uint64_t firstBadTriangle;
    double maxPositionVoxels;
    double maxNormalDiff;
    int normalsMissing;       // one has normals, the other not
} BKGoldenMeshReport;

BKGoldenMeshReport bk_golden_compare_meshes(const BKGoldenMesh *reference, const BKGoldenMesh *test,
                                            BKGoldenMeshTolerance tolerance);

// Numbers: |a - b| <= absTol + relTol * |b|.
int bk_golden_numbers_close(double test, double reference, double absTol, double relTol);

// Human-readable one-line summaries (for test logs). Write at most `size` bytes.
void bk_golden_describe_image_report(const BKGoldenImageReport *r, char *text, size_t size);
void bk_golden_describe_mesh_report(const BKGoldenMeshReport *r, char *text, size_t size);

// ---- Test cases (identical settings for every backend) -----------------------------------
// Volume renders (BKVolumeRenderer / a Vulkan ray caster). Patient mm, angles in degrees.
typedef struct { float value, red, green, blue; } BKGoldenColorPoint;
typedef struct { float value, opacity; } BKGoldenOpacityPoint;

typedef struct {
    const char *name;            // also the reference file name stem
    int32_t mode;                // 0 composite, 1 MIP, 2 MinIP, 3 average (BKRenderMode)
    int32_t projection;          // 0 orthographic, 1 perspective (BKProjection)
    double cameraPosition[3], cameraDirection[3], cameraUp[3];
    double viewWidth, viewHeight;    // orthographic, mm
    double fieldOfView;              // perspective, degrees (vertical)
    double sampleSpacing;            // mm
    int32_t slabEnabled;
    double slabPoint[3], slabNormal[3], slabThickness;
    float windowCenter, windowWidth;
    int32_t shading;
    float opacityUnitDistance;
    int32_t useTransferFunction;     // 1 = the colour/opacity points below
    uint32_t width, height;          // output pixels
    int32_t skipEmptySpace;
    int32_t clipPlaneCount;          // extra clip planes (point + normal each), patient mm
    double clipPlanes[2][6];
} BKGoldenVolumeCase;

// The transfer function used by every composite case ("bone + soft tissue").
extern const BKGoldenColorPoint kBKGoldenColorPoints[];
extern const uint32_t kBKGoldenColorPointCount;
extern const BKGoldenOpacityPoint kBKGoldenOpacityPoints[];
extern const uint32_t kBKGoldenOpacityPointCount;

extern const BKGoldenVolumeCase kBKGoldenVolumeCases[];
extern const uint32_t kBKGoldenVolumeCaseCount;

// 2D image display (BKImageLayerRenderer): an axial slice of the phantom shown with
// window/level, interpolation, zoom/rotation/flip and an optional colour table.
typedef struct {
    const char *name;
    uint32_t sliceIndex;         // axial slice of the head phantom
    uint32_t outWidth, outHeight;
    double windowCenter, windowWidth;
    int32_t linear;              // 0 nearest, 1 bilinear
    int32_t invert;
    int32_t useColorTable;       // 1 = bk_golden_color_table()
    double zoom, panX, panY, rotationDegrees;
    int32_t flipHorizontal, flipVertical;
    float background[4];
} BKGoldenImageCase;

extern const BKGoldenImageCase kBKGoldenImageCases[];
extern const uint32_t kBKGoldenImageCaseCount;

// A 256-entry RGB colour table (768 bytes) made from simple ramps (no copied tables).
void bk_golden_color_table(uint8_t rgb[768]);

// Surface extraction (BKSurfaceExtractor) of the head phantom.
typedef struct {
    const char *name;
    float threshold;             // HU
    float resolution;            // (0, 1]
    float smoothing;             // sigma in voxels
    int32_t manualSampling;      // 1 = BK_SURFACE_SAMPLING_MANUAL
} BKGoldenSurfaceCase;

extern const BKGoldenSurfaceCase kBKGoldenSurfaceCases[];
extern const uint32_t kBKGoldenSurfaceCaseCount;

// Mesh post-processing settings applied to the first surface case's mesh.
#define BK_GOLDEN_SMOOTH_ITERATIONS 10
#define BK_GOLDEN_SMOOTH_PASSBAND 0.1f
#define BK_GOLDEN_DECIMATE_REDUCTION 0.5

// Mesh render (BKMeshRenderer) of the bone surface.
typedef struct {
    const char *name;
    int32_t projection;
    double cameraPosition[3], cameraDirection[3], cameraUp[3];
    double viewWidth, viewHeight, fieldOfView;
    uint32_t width, height;
    float color[3];
    float opacity;
} BKGoldenMeshRenderCase;

extern const BKGoldenMeshRenderCase kBKGoldenMeshRenderCases[];
extern const uint32_t kBKGoldenMeshRenderCaseCount;

#ifdef __cplusplus
}
#endif

#endif
