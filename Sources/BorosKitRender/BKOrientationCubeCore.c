// BorosKitRender: the orientation cube in plain C (geometry, letters, corner camera).
// Original BorosKit code written for this project; contains no third-party code.
// See include/BKOrientationCubeCore.h for what each function does and the porting notes.

#include "BKOrientationCubeCore.h"
#include <math.h>
#include <stddef.h>

// --- Faces ---

static const char *const kBKCubeLabels[BKCubeFaceCount] = { "L", "R", "P", "A", "S", "I" };

const char *BKOrientationCubeDefaultLabel(int32_t face)
{
    return (face >= 0 && face < BKCubeFaceCount) ? kBKCubeLabels[face] : "";
}

BKVec3f BKOrientationCubeDefaultLetterColor(int32_t face)
{
    // Classic cube: x faces (L/R) blue, y faces (P/A) green, z faces (S/I) red.
    switch (face) {
        case BKCubeFaceXPlus: case BKCubeFaceXMinus: return BKV3f(0, 0, 1);
        case BKCubeFaceYPlus: case BKCubeFaceYMinus: return BKV3f(0, 1, 0);
        case BKCubeFaceZPlus: case BKCubeFaceZMinus: return BKV3f(1, 0, 0);
        default: return BKV3f(1, 1, 1);
    }
}

BKVec3f BKOrientationCubeDefaultCubeColor(void) { return BKV3f(1, 1, 1); }
BKVec3f BKOrientationCubeDefaultOutlineColor(void) { return BKV3f(0.5f, 0.5f, 0.5f); }

void BKOrientationCubeFaceFrame(int32_t face, BKVec3d *normal, BKVec3d *up, BKVec3d *right)
{
    BKVec3d n, u;
    switch (face) {
        case BKCubeFaceXPlus:  n = BKV3d(1, 0, 0);  u = BKV3d(0, 0, 1); break;
        case BKCubeFaceXMinus: n = BKV3d(-1, 0, 0); u = BKV3d(0, 0, 1); break;
        case BKCubeFaceYPlus:  n = BKV3d(0, 1, 0);  u = BKV3d(0, 0, 1); break;
        case BKCubeFaceYMinus: n = BKV3d(0, -1, 0); u = BKV3d(0, 0, 1); break;
        case BKCubeFaceZPlus:  n = BKV3d(0, 0, 1);  u = BKV3d(1, 0, 0); break;
        case BKCubeFaceZMinus: n = BKV3d(0, 0, -1); u = BKV3d(1, 0, 0); break;
        default:               n = BKV3d(0, 0, 1);  u = BKV3d(0, 1, 0); break;
    }
    // Seen from outside (looking along -n with "up" = u), the viewer's right is u x n, so the
    // letters are not mirrored.
    if (normal) *normal = n;
    if (up) *up = u;
    if (right) *right = BKV3dCross(u, n);
}

// --- Letters (drawn by hand for BorosKit, 1 unit high) ---

// Each letter: convex fill pieces (anticlockwise) + outline loops (outer anticlockwise, holes
// clockwise). Stroke width 0.2. Checked by the tests: pieces convex and anticlockwise, fill area
// == outline area, every piece inside the outline.

// L: a stem and a foot.
static const uint8_t kL_pieces[] = { 4, 4 };
static const BKVec2f kL_pv[] = {
    {0, 0}, {0.2f, 0}, {0.2f, 1}, {0, 1},
    {0.2f, 0}, {0.6f, 0}, {0.6f, 0.2f}, {0.2f, 0.2f},
};
static const uint8_t kL_contours[] = { 6 };
static const BKVec2f kL_cv[] = { {0, 0}, {0.6f, 0}, {0.6f, 0.2f}, {0.2f, 0.2f}, {0.2f, 1}, {0, 1} };

// I: a stem with a bar at the top and the bottom.
static const uint8_t kI_pieces[] = { 4, 4, 4 };
static const BKVec2f kI_pv[] = {
    {0, 0}, {0.5f, 0}, {0.5f, 0.2f}, {0, 0.2f},
    {0.15f, 0.2f}, {0.35f, 0.2f}, {0.35f, 0.8f}, {0.15f, 0.8f},
    {0, 0.8f}, {0.5f, 0.8f}, {0.5f, 1}, {0, 1},
};
static const uint8_t kI_contours[] = { 12 };
static const BKVec2f kI_cv[] = {
    {0, 0}, {0.5f, 0}, {0.5f, 0.2f}, {0.35f, 0.2f}, {0.35f, 0.8f}, {0.5f, 0.8f},
    {0.5f, 1}, {0, 1}, {0, 0.8f}, {0.15f, 0.8f}, {0.15f, 0.2f}, {0, 0.2f},
};

// P: a stem and a bowl with 45-degree corners (the bowl = 5 quads between its outer and inner
// outline).
#define BK_BOWL_PIECES \
    {0.2f, 0.4f}, {0.45f, 0.4f}, {0.38f, 0.58f}, {0.2f, 0.58f}, \
    {0.45f, 0.4f}, {0.6f, 0.55f}, {0.42f, 0.62f}, {0.38f, 0.58f}, \
    {0.6f, 0.55f}, {0.6f, 0.85f}, {0.42f, 0.78f}, {0.42f, 0.62f}, \
    {0.6f, 0.85f}, {0.45f, 1}, {0.38f, 0.82f}, {0.42f, 0.78f}, \
    {0.45f, 1}, {0.2f, 1}, {0.2f, 0.82f}, {0.38f, 0.82f}
#define BK_BOWL_HOLE \
    {0.2f, 0.58f}, {0.2f, 0.82f}, {0.38f, 0.82f}, {0.42f, 0.78f}, {0.42f, 0.62f}, {0.38f, 0.58f}
static const uint8_t kP_pieces[] = { 4, 4, 4, 4, 4, 4 };
static const BKVec2f kP_pv[] = {
    {0, 0}, {0.2f, 0}, {0.2f, 1}, {0, 1},
    BK_BOWL_PIECES,
};
static const uint8_t kP_contours[] = { 8, 6 };
static const BKVec2f kP_cv[] = {
    {0, 0}, {0.2f, 0}, {0.2f, 0.4f}, {0.45f, 0.4f}, {0.6f, 0.55f}, {0.6f, 0.85f}, {0.45f, 1}, {0, 1},
    BK_BOWL_HOLE,
};

// R: the P plus a slanted leg from the bowl to the bottom right.
static const uint8_t kR_pieces[] = { 4, 4, 4, 4, 4, 4, 4 };
static const BKVec2f kR_pv[] = {
    {0, 0}, {0.2f, 0}, {0.2f, 1}, {0, 1},
    BK_BOWL_PIECES,
    {0.4f, 0}, {0.6f, 0}, {0.42f, 0.4f}, {0.22f, 0.4f},
};
static const uint8_t kR_contours[] = { 12, 6 };
static const BKVec2f kR_cv[] = {
    {0, 0}, {0.2f, 0}, {0.2f, 0.4f}, {0.22f, 0.4f}, {0.4f, 0}, {0.6f, 0}, {0.42f, 0.4f}, {0.45f, 0.4f},
    {0.6f, 0.55f}, {0.6f, 0.85f}, {0.45f, 1}, {0, 1},
    BK_BOWL_HOLE,
};

// A: two slanted legs (slope 1/4) with a flat top, a crossbar and a small triangular hole.
static const uint8_t kA_pieces[] = { 4, 4, 4, 4, 4, 4 };
static const BKVec2f kA_pv[] = {
    {0, 0}, {0.2f, 0}, {0.2625f, 0.25f}, {0.0625f, 0.25f},                 // left leg, below the bar
    {0.5f, 0}, {0.7f, 0}, {0.6375f, 0.25f}, {0.4375f, 0.25f},              // right leg, below the bar
    {0.0625f, 0.25f}, {0.6375f, 0.25f}, {0.595f, 0.42f}, {0.105f, 0.42f},  // crossbar
    {0.105f, 0.42f}, {0.305f, 0.42f}, {0.35f, 0.6f}, {0.15f, 0.6f},        // left leg, above the bar
    {0.395f, 0.42f}, {0.595f, 0.42f}, {0.55f, 0.6f}, {0.35f, 0.6f},        // right leg, above the bar
    {0.15f, 0.6f}, {0.55f, 0.6f}, {0.45f, 1}, {0.25f, 1},                  // top
};
static const uint8_t kA_contours[] = { 8, 3 };
static const BKVec2f kA_cv[] = {
    {0, 0}, {0.2f, 0}, {0.2625f, 0.25f}, {0.4375f, 0.25f}, {0.5f, 0}, {0.7f, 0}, {0.45f, 1}, {0.25f, 1},
    {0.305f, 0.42f}, {0.35f, 0.6f}, {0.395f, 0.42f},
};

// S: three bars joined by a left (upper) and a right (lower) stem, outer bends cut at 45 degrees.
static const uint8_t kS_pieces[] = { 5, 4, 6, 4, 5 };
static const BKVec2f kS_pv[] = {
    {0, 0}, {0.5f, 0}, {0.6f, 0.1f}, {0.6f, 0.2f}, {0, 0.2f},                         // bottom bar
    {0.4f, 0.2f}, {0.6f, 0.2f}, {0.6f, 0.4f}, {0.4f, 0.4f},                           // right stem
    {0.1f, 0.4f}, {0.6f, 0.4f}, {0.6f, 0.5f}, {0.5f, 0.6f}, {0, 0.6f}, {0, 0.5f},     // middle bar
    {0, 0.6f}, {0.2f, 0.6f}, {0.2f, 0.8f}, {0, 0.8f},                                 // left stem
    {0, 0.8f}, {0.6f, 0.8f}, {0.6f, 1}, {0.1f, 1}, {0, 0.9f},                         // top bar
};
static const uint8_t kS_contours[] = { 16 };
static const BKVec2f kS_cv[] = {
    {0, 0}, {0.5f, 0}, {0.6f, 0.1f}, {0.6f, 0.5f}, {0.5f, 0.6f}, {0.2f, 0.6f}, {0.2f, 0.8f}, {0.6f, 0.8f},
    {0.6f, 1}, {0.1f, 1}, {0, 0.9f}, {0, 0.5f}, {0.1f, 0.4f}, {0.4f, 0.4f}, {0.4f, 0.2f}, {0, 0.2f},
};

#define BK_COUNT(a) ((uint32_t)(sizeof(a) / sizeof((a)[0])))
#define BK_GLYPH(ch, w, name) { ch, w, BK_COUNT(name##_pieces), name##_pieces, name##_pv, \
                                BK_COUNT(name##_contours), name##_contours, name##_cv }

static const BKOrientationGlyph kBKGlyphs[] = {
    BK_GLYPH('A', 0.7f, kA),
    BK_GLYPH('I', 0.5f, kI),
    BK_GLYPH('L', 0.6f, kL),
    BK_GLYPH('P', 0.6f, kP),
    BK_GLYPH('R', 0.6f, kR),
    BK_GLYPH('S', 0.6f, kS),
};

// Space between two letters of one label, and the width of a space character (letter units).
#define BK_LETTER_GAP 0.15f
#define BK_SPACE_WIDTH 0.4f

uint32_t BKOrientationGlyphCount(void) { return BK_COUNT(kBKGlyphs); }

const BKOrientationGlyph *BKOrientationGlyphAtIndex(uint32_t index)
{
    return index < BK_COUNT(kBKGlyphs) ? &kBKGlyphs[index] : NULL;
}

const BKOrientationGlyph *BKOrientationGlyphFor(char character)
{
    if (character >= 'a' && character <= 'z') character = (char)(character - 'a' + 'A');
    for (uint32_t i = 0; i < BK_COUNT(kBKGlyphs); i++)
        if (kBKGlyphs[i].character == character) return &kBKGlyphs[i];
    return NULL;
}

// Signed area of a polygon (anticlockwise > 0), shoelace formula.
static double BKPolygonSignedArea(const BKVec2f *v, uint32_t n)
{
    double a = 0;
    for (uint32_t i = 0; i < n; i++) {
        const BKVec2f p = v[i], q = v[(i + 1) % n];
        a += (double)p.x * q.y - (double)q.x * p.y;
    }
    return 0.5 * a;
}

double BKOrientationGlyphFillArea(const BKOrientationGlyph *g)
{
    if (g == NULL) return 0;
    double a = 0;
    const BKVec2f *v = g->pieceVertices;
    for (uint32_t i = 0; i < g->pieceCount; i++) {
        a += BKPolygonSignedArea(v, g->pieceSizes[i]);
        v += g->pieceSizes[i];
    }
    return a;
}

double BKOrientationGlyphOutlineArea(const BKOrientationGlyph *g)
{
    if (g == NULL) return 0;
    double a = 0;
    const BKVec2f *v = g->contourVertices;
    for (uint32_t i = 0; i < g->contourCount; i++) {
        a += BKPolygonSignedArea(v, g->contourSizes[i]);   // holes are clockwise: they subtract
        v += g->contourSizes[i];
    }
    return a;
}

// --- Labels on faces ---

// Corners / triangles / outline segments of one letter.
static void BKGlyphSizes(const BKOrientationGlyph *g, uint32_t *vertices, uint32_t *triangles, uint32_t *segments)
{
    uint32_t v = 0, t = 0, s = 0;
    for (uint32_t i = 0; i < g->pieceCount; i++) { v += g->pieceSizes[i]; t += g->pieceSizes[i] - 2u; }
    for (uint32_t i = 0; i < g->contourCount; i++) s += g->contourSizes[i];
    *vertices = v; *triangles = t; *segments = s;
}

// Total width of the drawable characters of `label` (letter units), and the sizes.
static double BKLabelMeasure(const char *label, BKOrientationLabelSize *size)
{
    BKOrientationLabelSize z = { 0, 0, 0, 0 };
    double width = 0;
    int first = 1;
    if (label) {
        for (const char *c = label; *c; c++) {
            if (*c == ' ') { width += BK_SPACE_WIDTH; continue; }
            const BKOrientationGlyph *g = ((unsigned char)*c < 128) ? BKOrientationGlyphFor(*c) : NULL;
            if (g == NULL) { z.skippedCount++; continue; }
            uint32_t v, t, s;
            BKGlyphSizes(g, &v, &t, &s);
            z.vertexCount += v; z.triangleCount += t; z.segmentCount += s;
            if (!first) width += BK_LETTER_GAP;
            width += g->width;
            first = 0;
        }
    }
    if (size) *size = z;
    return width;
}

BKOrientationLabelSize BKOrientationCubeLabelSize(const char *label)
{
    BKOrientationLabelSize size;
    BKLabelMeasure(label, &size);
    return size;
}

BKOrientationLabelSize BKOrientationCubeFillLabel(int32_t face, const char *label, double textScale, double offset,
                                                  float *vertices, uint32_t *triangles, float *segmentPoints)
{
    BKOrientationLabelSize written = { 0, 0, 0, 0 };
    BKOrientationLabelSize size;
    double width = BKLabelMeasure(label, &size);
    written.skippedCount = size.skippedCount;
    if (label == NULL || width <= 0 || textScale <= 0) return written;

    // Letter height = textScale, unless the block would be wider than the face allows.
    double s = textScale;
    if (s * width > BK_ORIENTATION_CUBE_MAX_TEXT_WIDTH) s = BK_ORIENTATION_CUBE_MAX_TEXT_WIDTH / width;
    BKVec3d n, u, r;
    BKOrientationCubeFaceFrame(face, &n, &u, &r);
    BKVec3d centre = BKV3dScale(n, offset);

    double penX = 0;   // left edge of the next letter, letter units from the block's left
    int first = 1;
    for (const char *c = label; *c; c++) {
        if (*c == ' ') { penX += BK_SPACE_WIDTH; continue; }
        const BKOrientationGlyph *g = ((unsigned char)*c < 128) ? BKOrientationGlyphFor(*c) : NULL;
        if (g == NULL) continue;
        if (!first) penX += BK_LETTER_GAP;
        first = 0;
#define BK_PLACE(p) BKV3dAdd(centre, BKV3dAdd(BKV3dScale(r, s * ((penX + (p).x) - 0.5 * width)), \
                                              BKV3dScale(u, s * ((p).y - 0.5))))
        // Fill: each convex piece as a triangle fan.
        const BKVec2f *pv = g->pieceVertices;
        for (uint32_t i = 0; i < g->pieceCount; i++) {
            uint32_t base = written.vertexCount, k = g->pieceSizes[i];
            for (uint32_t j = 0; j < k; j++) {
                BKVec3d p = BK_PLACE(pv[j]);
                if (vertices) {
                    vertices[3 * written.vertexCount + 0] = (float)p.x;
                    vertices[3 * written.vertexCount + 1] = (float)p.y;
                    vertices[3 * written.vertexCount + 2] = (float)p.z;
                }
                written.vertexCount++;
            }
            for (uint32_t j = 1; j + 1 < k; j++) {
                if (triangles) {
                    triangles[3 * written.triangleCount + 0] = base;
                    triangles[3 * written.triangleCount + 1] = base + j;
                    triangles[3 * written.triangleCount + 2] = base + j + 1;
                }
                written.triangleCount++;
            }
            pv += k;
        }
        // Outline: each loop closed, as point pairs.
        const BKVec2f *cv = g->contourVertices;
        for (uint32_t i = 0; i < g->contourCount; i++) {
            uint32_t k = g->contourSizes[i];
            for (uint32_t j = 0; j < k; j++) {
                BKVec3d a = BK_PLACE(cv[j]), b = BK_PLACE(cv[(j + 1) % k]);
                if (segmentPoints) {
                    float *o = segmentPoints + 6 * written.segmentCount;
                    o[0] = (float)a.x; o[1] = (float)a.y; o[2] = (float)a.z;
                    o[3] = (float)b.x; o[4] = (float)b.y; o[5] = (float)b.z;
                }
                written.segmentCount++;
            }
            cv += k;
        }
#undef BK_PLACE
        penX += g->width;
    }
    return written;
}

// --- Cube, camera, corner ---

void BKOrientationCubeFillBox(float positions[3 * BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT],
                              float normals[3 * BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT],
                              uint32_t triangles[3 * BK_ORIENTATION_CUBE_BOX_TRIANGLE_COUNT])
{
    // Corner order per face, seen from outside: bottom-left, bottom-right, top-right, top-left
    // (in the face's own right/up directions) = anticlockwise.
    static const double corner[4][2] = { { -0.5, -0.5 }, { 0.5, -0.5 }, { 0.5, 0.5 }, { -0.5, 0.5 } };
    for (int32_t f = 0; f < BKCubeFaceCount; f++) {
        BKVec3d n, u, r;
        BKOrientationCubeFaceFrame(f, &n, &u, &r);
        for (int k = 0; k < 4; k++) {
            BKVec3d p = BKV3dAdd(BKV3dScale(n, 0.5), BKV3dAdd(BKV3dScale(r, corner[k][0]), BKV3dScale(u, corner[k][1])));
            int i = 4 * f + k;
            if (positions) { positions[3 * i] = (float)p.x; positions[3 * i + 1] = (float)p.y; positions[3 * i + 2] = (float)p.z; }
            if (normals) { normals[3 * i] = (float)n.x; normals[3 * i + 1] = (float)n.y; normals[3 * i + 2] = (float)n.z; }
        }
        if (triangles) {
            uint32_t b = (uint32_t)(4 * f);
            uint32_t *t = triangles + 6 * f;
            t[0] = b; t[1] = b + 1; t[2] = b + 2;
            t[3] = b; t[4] = b + 2; t[5] = b + 3;
        }
    }
}

double BKOrientationCubeBoundingRadius(void)
{
    // Box -0.501 .. 0.501 on every axis (the letters lie 0.001 outside the faces).
    return BK_ORIENTATION_CUBE_TEXT_OFFSET * sqrt(3.0);
}

bool BKOrientationCubeCamera(BKCameraFrame mainCamera, double cornerAspect, BKCameraFrame *out)
{
    if (out == NULL) return false;
    double dl = BKV3dLength(mainCamera.direction);
    if (!(dl > 1e-12)) return false;
    BKVec3d d = BKV3dScale(mainCamera.direction, 1.0 / dl);
    // Up made perpendicular to the direction (only the rotation of the main camera matters).
    BKVec3d up = BKV3dSub(mainCamera.up, BKV3dScale(d, BKV3dDot(mainCamera.up, d)));
    double ul = BKV3dLength(up);
    if (!(ul > 1e-9)) return false;
    up = BKV3dScale(up, 1.0 / ul);

    // Fit the bounding sphere: vertically with the 30-degree opening; for a corner taller than
    // wide, the narrower horizontal opening decides.
    const double pi = 3.14159265358979323846;
    double half = 0.5 * BK_ORIENTATION_CUBE_VIEW_ANGLE * pi / 180.0;
    if (cornerAspect > 0 && cornerAspect < 1) half = atan(tan(half) * cornerAspect);
    double distance = BKOrientationCubeBoundingRadius() / sin(half);

    BKCameraFrame f;
    f.direction = d;
    f.up = up;
    f.position = BKV3dScale(d, -distance);   // looking at the cube's centre (0, 0, 0)
    f.parallelScale = BKOrientationCubeBoundingRadius();
    f.viewAngle = BK_ORIENTATION_CUBE_VIEW_ANGLE;
    f.perspective = true;
    *out = f;
    return true;
}

bool BKOrientationCubeCornerRect(double viewWidth, double viewHeight, const double vp[4], BKOrientationRect *out)
{
    if (out == NULL || vp == NULL || !(viewWidth > 0) || !(viewHeight > 0)) return false;
    BKOrientationRect r;
    r.x = round(vp[0] * viewWidth);
    r.y = round((1.0 - vp[3]) * viewHeight);           // y up (VTK) -> y down
    r.width = round((vp[2] - vp[0]) * viewWidth);
    r.height = round((vp[3] - vp[1]) * viewHeight);
    if (r.width < 1 || r.height < 1) return false;
    *out = r;
    return true;
}

void BKOrientationCubeClassicViewport(double vp[4])
{
    if (vp == NULL) return;
    vp[0] = 0.90; vp[1] = 0.90; vp[2] = 1.0; vp[3] = 1.0;
}
