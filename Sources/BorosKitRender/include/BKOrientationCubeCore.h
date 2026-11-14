// BorosKitRender: BKOrientationCubeCore - the small orientation cube of the 3D windows, as
// plain C (geometry, letters, corner camera, corner rectangle). No GPU code.
//
// Original BorosKit code written for this project; contains no third-party code.
// The six letters (A, I, L, P, R, S) were drawn for BorosKit by hand on a 1-unit-high grid
// (straight strokes and 45-degree corners); no font file, font table or outline from anywhere
// else was used. The cube rules (white cube, coloured letters, grey letter outlines, letter
// 0.67 of the face, top-right corner, 30-degree corner camera) describe how the classic Horos
// 3D window looks (VRView -initAnnotatedCubeActor) so users see the same cube.
//
// PORTING NOTES (Vulkan / other backends):
// - Lives in BorosKitRender next to BKCameraMath (a plain-C file in another target cannot include
//   this module's headers without pulling in its Objective-C umbrella).
// - Pure C99 with BorosKit's own vector types (BKVec.h) and BKCameraFrame (BKCameraMath.h); no
//   Objective-C, Metal, VTK, Apple simd or Horos-derived (LGPL) types. Compiles unchanged on
//   Windows/Linux. The Apple class BKOrientationCube (BKOrientationCube.h) only turns these
//   arrays into BKMeshObject / BKLineObject; a Vulkan backend does the same with its own
//   drawables (plain triangle list + line list, one colour each).
// - Output arrays are plain floats / uint32 (positions x,y,z; flat normals; triangle indices
//   anticlockwise seen from outside; line segments as point pairs). Nothing here is a GPU
//   struct; upload them in whatever std430 layout the backend's mesh shader uses.
// - Deterministic: no randomness, no threads, same numbers on every platform.
//
// Plain language: the little cube in the top-right corner of the 3D window that shows which
// way the patient is turned. Each face carries a letter: L / R (patient's left / right),
// P / A (posterior / anterior), S / I (superior / inferior). It turns with the main view but
// stays the same size and always sits in its corner.
//
// Coordinates: the cube is 1 unit wide, centred on 0, with the patient axes (DICOM LPS):
// +x = patient's left, +y = posterior, +z = superior. Corner rectangles: view points (or pixels)
// with the origin at the TOP-LEFT, y down, like the rest of BorosKit.

#ifndef BK_ORIENTATION_CUBE_CORE_H
#define BK_ORIENTATION_CUBE_CORE_H

#include "BKVec.h"
#include "BKCameraMath.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The six faces, in this order everywhere (labels, colours, frames).
enum {
    BKCubeFaceXPlus = 0,    // patient's left        - "L"
    BKCubeFaceXMinus = 1,   // patient's right       - "R"
    BKCubeFaceYPlus = 2,    // posterior             - "P"
    BKCubeFaceYMinus = 3,   // anterior              - "A"
    BKCubeFaceZPlus = 4,    // superior (head)       - "S"
    BKCubeFaceZMinus = 5,   // inferior (feet)       - "I"
    BKCubeFaceCount = 6
};

// Classic look (VRView -initAnnotatedCubeActor): letters 0.67 of the face height, letters lie
// 0.001 outside the face (in front of it, so the depth test shows them), corner = the top-right
// 10 % of the view, corner camera = perspective with a 30-degree vertical opening.
#define BK_ORIENTATION_CUBE_TEXT_SCALE 0.67
#define BK_ORIENTATION_CUBE_TEXT_OFFSET 0.501
#define BK_ORIENTATION_CUBE_VIEW_ANGLE 30.0
// Largest letter-block width on a face (unit cube = 1); longer labels are shrunk to fit.
#define BK_ORIENTATION_CUBE_MAX_TEXT_WIDTH 0.9

// What: the default letter of each face ("L", "R", "P", "A", "S", "I").
const char *BKOrientationCubeDefaultLabel(int32_t face);

// What: the classic colour of each face's LETTER (RGB 0..1): L/R blue, P/A green, S/I red.
// The cube itself is white and the letter outlines grey (see below).
BKVec3f BKOrientationCubeDefaultLetterColor(int32_t face);
BKVec3f BKOrientationCubeDefaultCubeColor(void);      // white (1, 1, 1)
BKVec3f BKOrientationCubeDefaultOutlineColor(void);   // grey (0.5, 0.5, 0.5)

// What: the face's outward normal, the letter's "up" and its "right", as seen from outside.
// Letters read correctly (not mirrored) from outside: right = up x normal.
// Up: superior (+z) on the four side faces; the patient's left (+x) on the S and I faces
// (as in the classic cube).
void BKOrientationCubeFaceFrame(int32_t face, BKVec3d *normal, BKVec3d *up, BKVec3d *right);

// ---------------------------------------------------------------------------------------------
// Letters
// ---------------------------------------------------------------------------------------------

// One hand-drawn letter, 1 unit high, from x = 0 to x = width.
// Fill: convex pieces (each anticlockwise, drawn as a triangle fan), not overlapping, together
// covering the letter exactly. Outline: closed loops (outer outline anticlockwise, holes
// clockwise), used for the grey edges and to check the fill (equal areas, see the tests).
typedef struct {
    char character;
    float width;
    uint32_t pieceCount;
    const uint8_t *pieceSizes;          // corner count of each piece
    const BKVec2f *pieceVertices;       // all pieces' corners, piece after piece
    uint32_t contourCount;
    const uint8_t *contourSizes;        // corner count of each loop
    const BKVec2f *contourVertices;     // all loops' corners, loop after loop
} BKOrientationGlyph;

// What: the letter for `character` (upper or lower case), NULL when BorosKit has no drawing
// for it (only A, I, L, P, R, S exist: all the cube and the 3D windows need, in English and
// Japanese alike).
const BKOrientationGlyph *BKOrientationGlyphFor(char character);
// What: all letters (for tests): index 0 ..< BKOrientationGlyphCount().
uint32_t BKOrientationGlyphCount(void);
const BKOrientationGlyph *BKOrientationGlyphAtIndex(uint32_t index);
// What: area of the fill pieces, and the area enclosed by the outline (outer minus holes).
// Equal for a correct letter.
double BKOrientationGlyphFillArea(const BKOrientationGlyph *glyph);
double BKOrientationGlyphOutlineArea(const BKOrientationGlyph *glyph);

// What a face label needs, so the caller can allocate the arrays.
typedef struct {
    uint32_t vertexCount;      // letter fill corners (3 floats each)
    uint32_t triangleCount;    // fill triangles (3 indices each)
    uint32_t segmentCount;     // outline segments (2 points each)
    uint32_t skippedCount;     // characters without a BorosKit drawing (left out; spaces are not counted)
} BKOrientationLabelSize;

// What: sizes for `label` (UTF-8 / ASCII; NULL or "" = no letter). Non-ASCII bytes and letters
// without a drawing are counted in skippedCount and left out; spaces only add room.
BKOrientationLabelSize BKOrientationCubeLabelSize(const char *label);

// What: fills the arrays for `label` on `face`: letters centred on the face, textScale high
// (BK_ORIENTATION_CUBE_TEXT_SCALE for the classic cube; shrunk so the block is at most
// BK_ORIENTATION_CUBE_MAX_TEXT_WIDTH wide), lying `offset` from the centre along the normal
// (BK_ORIENTATION_CUBE_TEXT_OFFSET). Triangles are anticlockwise seen from outside, indices
// count from 0 within this label. Arrays sized by BKOrientationCubeLabelSize (any may be NULL
// to skip that part). Returns the sizes actually written.
BKOrientationLabelSize BKOrientationCubeFillLabel(int32_t face, const char *label, double textScale, double offset,
                                                  float *vertices, uint32_t *triangles, float *segmentPoints);

// ---------------------------------------------------------------------------------------------
// The cube
// ---------------------------------------------------------------------------------------------

#define BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT 24     // 4 corners per face (flat shading)
#define BK_ORIENTATION_CUBE_BOX_TRIANGLE_COUNT 12

// What: the unit cube (-0.5 .. 0.5): 24 positions and outward normals (3 floats each) and
// 12 triangles anticlockwise seen from outside. Face f uses vertices 4f .. 4f+3.
void BKOrientationCubeFillBox(float positions[3 * BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT],
                              float normals[3 * BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT],
                              uint32_t triangles[3 * BK_ORIENTATION_CUBE_BOX_TRIANGLE_COUNT]);

// What: radius of the sphere around the cube with its letters (half the diagonal of the box
// -0.501 .. 0.501): what the corner camera must fit.
double BKOrientationCubeBoundingRadius(void);

// What: the corner camera for the cube: it looks at the cube's centre from the main view's
// direction with the main view's up (only the main camera's ROTATION is used - its position,
// zoom and projection are ignored), perspective with a BK_ORIENTATION_CUBE_VIEW_ANGLE vertical
// opening, and far enough away that the whole cube fits the corner (aspect = corner width /
// height; a corner taller than wide moves the camera back so the cube fits sideways too).
// Returns false (out untouched) if the main direction / up are unusable (zero or parallel).
// Why: the cube must turn exactly like the patient in the main view, but always fill its corner.
bool BKOrientationCubeCamera(BKCameraFrame mainCamera, double cornerAspect, BKCameraFrame *out);

// A rectangle in view points or pixels, origin top-left, y down.
typedef struct {
    double x, y, width, height;
} BKOrientationRect;

// What: the corner rectangle of a view of viewWidth x viewHeight (points or pixels) for a
// normalised viewport given VTK-style (xmin, ymin, xmax, ymax in 0..1, y UP - the classic cube
// is 0.90, 0.90, 1, 1 = top-right 10 %). Edges are rounded to whole units (same rule the old
// VTK -> Metal mirror used). Returns false for an empty rectangle.
bool BKOrientationCubeCornerRect(double viewWidth, double viewHeight, const double normalizedViewport[4],
                                 BKOrientationRect *out);

// The classic corner (top-right 10 %): { 0.90, 0.90, 1.0, 1.0 }.
void BKOrientationCubeClassicViewport(double normalizedViewport[4]);

#ifdef __cplusplus
}
#endif

#endif
