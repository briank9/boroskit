// BorosKitMesh: BKSceneExportCore implementation (see BKSceneExportCore.h).
// Original BorosKit code written for this project; contains no third-party code.
// Plain portable C++17 (no Objective-C, no Apple types).

/* BOROS OVERVIEW (plain language)
 * A "scene" is what the 3D surface window shows: several surfaces (bone, scan, implant),
 * each with its own position, colour and shininess, plus outline lines, the camera,
 * the background colour and the light. This file saves such a scene as text files
 * that other 3D programs can open (OBJ+MTL, VRML 2.0, Open Inventor 2.1, RenderMan RIB).
 *
 * All four formats are text, so the work is mostly turning millions of numbers into
 * characters. To make that fast for 10+ million triangles:
 *   - the list of points / triangles is cut into fixed blocks of 16384 entries; groups
 *     of 64 blocks are turned into text on all cores at once, then written to the file
 *     in their original order (so the file is identical whatever the number of cores);
 *   - the text goes through one 8 MB buffer to the disk (never one gigantic string);
 *   - numbers are formatted with std::to_chars where available (about 3x faster than
 *     printf, and gives exactly the same characters).
 *
 * Every object is written in WORLD (patient) millimetres: its placement matrix is
 * applied to each point on the way out. Directions (normals) are turned with the
 * "inverse transpose" of the matrix, which keeps them perpendicular to the surface even
 * when the matrix stretches the object unevenly. If the matrix MIRRORS the object (like
 * a left/right flip), the corner order of every triangle is reversed so that "outside"
 * stays outside in the exported file.
 */

#include "BKSceneExportCore.h"
#include "BKParallel.h"

#include <algorithm>
#include <atomic>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <set>
#include <cctype>

namespace boroskit {
namespace sceneexport {

#pragma mark - Numbers as text

// What: a float as text, 9 (or `precision`) significant digits, like printf("%.9g").
// Why 9: that is the smallest number of digits that always reads back as exactly the
// same 32-bit float, so nothing is lost by exporting. -0 is written as 0 and anything
// that is not a finite number (which BKMesh never contains) as 0, so files stay valid.
size_t FormatFloat(float value, int precision, char *buffer)
{
    if (!std::isfinite(value) || value == 0.0f) value = 0.0f;
#if defined(__APPLE__) && !BK_SCENE_EXPORT_USE_TO_CHARS
    // Apple's C++ library marks floating-point std::to_chars "unavailable" (not just
    // "newer") below macOS 13.3 / iOS 16.3, so it cannot even be called behind a runtime
    // check while BorosKit supports macOS 12. snprintf gives the same characters; the
    // speed comes from formatting blocks on all cores. When the minimum system is raised,
    // build with -DBK_SCENE_EXPORT_USE_TO_CHARS=1 (about 3x faster per number).
    int n = snprintf(buffer, 32, "%.*g", precision, (double)value);
    return n > 0 ? (size_t)n : 0;
#else
    std::to_chars_result r = std::to_chars(buffer, buffer + 32, value, std::chars_format::general, precision);
    return (size_t)(r.ptr - buffer);
#endif
}

// What: a growing piece of text with quick "append a number" helpers.
// Why: each block of the parallel work builds its text in one of these.
struct Text {
    std::string s;
    void add(const char *c) { s.append(c); }
    void add(const std::string &c) { s.append(c); }
    void ch(char c) { s.push_back(c); }
    void flt(float v, int precision = 9)
    {
        char b[32];
        s.append(b, FormatFloat(v, precision, b));
    }
    void uint(uint64_t v)
    {
        char b[24];
        std::to_chars_result r = std::to_chars(b, b + sizeof b, v);
        s.append(b, (size_t)(r.ptr - b));
    }
    // Three numbers separated by spaces (a point, a direction or an RGB colour).
    void three(const float v[3], int precision = 9)
    {
        flt(v[0], precision); ch(' ');
        flt(v[1], precision); ch(' ');
        flt(v[2], precision);
    }
};

#pragma mark - Output file

// What: a file written through a large buffer, first under a temporary name and moved
// to its real name only at the end (commit). Why: fast writing (few, big disk writes),
// and a failed or cancelled export never leaves a broken file with the real name.
class Output {
public:
    explicit Output(const std::string &path) : finalPath_(path), tempPath_(path + ".boroskit-partial") {}
    ~Output() { abandon(); }

    bool open()
    {
        file_ = std::fopen(tempPath_.c_str(), "wb");
        buffer_.reserve(kFlushSize + (1 << 20));
        return file_ != nullptr;
    }
    void write(const char *p, size_t n)
    {
        if (failed_) return;
        buffer_.append(p, n);
        if (buffer_.size() >= kFlushSize) flush();
    }
    void write(const std::string &s) { write(s.data(), s.size()); }
    void write(const char *s) { write(s, std::strlen(s)); }
    bool failed() const { return failed_; }
    uint64_t bytes() const { return bytes_; }

    // Writes what is left, closes the file. Returns false if anything went wrong.
    bool finish()
    {
        flush();
        if (file_) {
            if (std::fclose(file_) != 0) failed_ = true;
            file_ = nullptr;
        }
        return !failed_;
    }
    // Moves the finished temporary file to the real name (replacing an older file).
    bool commit()
    {
        if (failed_ || file_) return false;
        if (std::rename(tempPath_.c_str(), finalPath_.c_str()) != 0) { failed_ = true; return false; }
        committed_ = true;
        return true;
    }
    // Closes and deletes the temporary file (nothing happens after a commit).
    void abandon()
    {
        if (file_) { std::fclose(file_); file_ = nullptr; }
        if (!committed_) std::remove(tempPath_.c_str());
        committed_ = true;
    }
    const std::string &path() const { return finalPath_; }

private:
    static const size_t kFlushSize = 8 << 20;
    void flush()
    {
        if (failed_ || buffer_.empty()) return;
        if (!file_ || std::fwrite(buffer_.data(), 1, buffer_.size(), file_) != buffer_.size()) failed_ = true;
        else bytes_ += buffer_.size();
        buffer_.clear();
    }
    std::string finalPath_, tempPath_, buffer_;
    std::FILE *file_ = nullptr;
    bool failed_ = false, committed_ = false;
    uint64_t bytes_ = 0;
};

#pragma mark - Progress

// What: counts finished work units and calls the caller's progress function.
struct Progress {
    ProgressFunction function = nullptr;
    void *context = nullptr;
    double total = 1, done = 0;
    bool cancelled = false;
    bool advance(double units)
    {
        done += units;
        if (function && !cancelled && !function(std::min(1.0, done / std::max(1.0, total)), context)) cancelled = true;
        return !cancelled;
    }
};

#pragma mark - Parallel text blocks

static const size_t kBlockItems = 16384;    // entries (points, triangles...) per block
static const size_t kBlocksPerGroup = 64;   // blocks turned into text at the same time

// What: produces the text for entries 0..count-1 in fixed blocks, several blocks at once
// on all cores, and writes the blocks to `out` in order. fn(text, begin, end) appends
// the text for entries begin..end-1 and must only depend on those entries (it may use
// the entry number, e.g. for line breaks). Returns false if cancelled or writing failed.
// Why fixed blocks: the file must not depend on how many cores the computer has.
template <typename Fn>
static bool EmitBlocks(Output &out, Progress &progress, size_t count, const Fn &fn)
{
    std::vector<Text> texts(std::min(kBlocksPerGroup, (count + kBlockItems - 1) / kBlockItems));
    for (size_t groupStart = 0; groupStart < count; groupStart += kBlockItems * kBlocksPerGroup) {
        size_t groupEnd = std::min(count, groupStart + kBlockItems * kBlocksPerGroup);
        size_t blocks = (groupEnd - groupStart + kBlockItems - 1) / kBlockItems;
        BKParallelFor(blocks, 1, [&](size_t b0, size_t b1) {
            for (size_t b = b0; b < b1; b++) {
                size_t begin = groupStart + b * kBlockItems;
                size_t end = std::min(groupEnd, begin + kBlockItems);
                texts[b].s.clear();
                fn(texts[b], begin, end);
            }
        });
        for (size_t b = 0; b < blocks; b++) out.write(texts[b].s);
        if (out.failed() || !progress.advance((double)(groupEnd - groupStart))) return false;
    }
    return true;
}

#pragma mark - Geometry helpers

// What: an object's placement prepared for writing: the matrix itself, the matrix for
// directions (normals), and whether it mirrors.
struct Placement {
    double m[16];
    double n[9];        // normal matrix, column-major 3x3 (inverse transpose, sign-corrected)
    bool mirror = false;

    // object point -> world point (mm)
    inline void point(const float *p, float o[3]) const
    {
        double x = p[0], y = p[1], z = p[2];
        o[0] = (float)(m[0] * x + m[4] * y + m[8] * z + m[12]);
        o[1] = (float)(m[1] * x + m[5] * y + m[9] * z + m[13]);
        o[2] = (float)(m[2] * x + m[6] * y + m[10] * z + m[14]);
    }
    // object normal -> world normal (unit length; a zero normal stays zero)
    inline void normal(const float *p, float o[3]) const
    {
        double x = p[0], y = p[1], z = p[2];
        double a = n[0] * x + n[3] * y + n[6] * z;
        double b = n[1] * x + n[4] * y + n[7] * z;
        double c = n[2] * x + n[5] * y + n[8] * z;
        double len = std::sqrt(a * a + b * b + c * c);
        if (len > 0) { a /= len; b /= len; c /= len; }
        o[0] = (float)a; o[1] = (float)b; o[2] = (float)c;
    }
};

// What: checks a placement matrix and prepares it. Refuses matrices with non-numbers,
// a perspective part (bottom row not 0 0 0 1) or that squash the object flat (no
// inverse), because none of these can describe where a real object is.
// Why the normal matrix is the inverse transpose: a surface direction must stay
// perpendicular to the surface after stretching; for a pure rotation it is just the
// rotation. The columns of the inverse transpose of A (columns c0, c1, c2) are
// (c1 x c2, c2 x c0, c0 x c1) / det(A); we drop the size of 1/det (normals are made unit
// length anyway) but keep its SIGN, so outward normals stay outward when mirrored.
static bool MakePlacement(const double m[16], Placement &p, std::string &why)
{
    for (int i = 0; i < 16; i++) {
        if (!std::isfinite(m[i])) { why = "contains a value that is not a number"; return false; }
        p.m[i] = m[i];
    }
    if (std::fabs(m[3]) > 1e-9 || std::fabs(m[7]) > 1e-9 || std::fabs(m[11]) > 1e-9 || std::fabs(m[15] - 1.0) > 1e-9) {
        why = "is not a placement (its bottom row is not 0 0 0 1)";
        return false;
    }
    const double c0[3] = {m[0], m[1], m[2]}, c1[3] = {m[4], m[5], m[6]}, c2[3] = {m[8], m[9], m[10]};
    auto cross = [](const double a[3], const double b[3], double *o) {
        o[0] = a[1] * b[2] - a[2] * b[1];
        o[1] = a[2] * b[0] - a[0] * b[2];
        o[2] = a[0] * b[1] - a[1] * b[0];
    };
    cross(c1, c2, p.n + 0);
    cross(c2, c0, p.n + 3);
    cross(c0, c1, p.n + 6);
    double det = c0[0] * p.n[0] + c0[1] * p.n[1] + c0[2] * p.n[2];
    if (!(std::fabs(det) > 0) || !std::isfinite(det)) { why = "flattens the object (it cannot be undone)"; return false; }
    p.mirror = det < 0;
    if (p.mirror) for (double &v : p.n) v = -v;
    return true;
}

static inline void Sub(const double a[3], const double b[3], double o[3]) { o[0] = a[0] - b[0]; o[1] = a[1] - b[1]; o[2] = a[2] - b[2]; }
static inline double Dot(const double a[3], const double b[3]) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
static inline void Cross(const double a[3], const double b[3], double o[3])
{
    o[0] = a[1] * b[2] - a[2] * b[1];
    o[1] = a[2] * b[0] - a[0] * b[2];
    o[2] = a[0] * b[1] - a[1] * b[0];
}
static inline bool Normalize(double v[3])
{
    double l = std::sqrt(Dot(v, v));
    if (!(l > 1e-12) || !std::isfinite(l)) return false;
    v[0] /= l; v[1] /= l; v[2] /= l;
    return true;
}

// What: the camera as an orthonormal frame (right, up, forward) plus its settings.
struct Frame {
    double eye[3], focal[3], right[3], up[3], dir[3];
    double distance = 1;
    bool parallel = false;
    double viewAngle = 30;        // degrees, vertical
    double parallelScale = 100;   // mm, half height
    bool fitted = false;          // true = made up from the scene's size (no camera given)
};

// What: turns the VTK-style camera into a frame. Odd input (eye on the focal point, "up"
// along the view) is repaired instead of refused, since a camera can't be "wrong" enough
// to make an export useless.
static Frame MakeFrame(const Camera &c)
{
    Frame f;
    for (int i = 0; i < 3; i++) { f.eye[i] = c.position[i]; f.focal[i] = c.focalPoint[i]; }
    Sub(f.focal, f.eye, f.dir);
    f.distance = std::sqrt(Dot(f.dir, f.dir));
    if (!Normalize(f.dir)) { f.dir[0] = 0; f.dir[1] = 0; f.dir[2] = -1; f.distance = 1; }
    double up[3] = {c.viewUp[0], c.viewUp[1], c.viewUp[2]};
    double along = Dot(up, f.dir);
    for (int i = 0; i < 3; i++) up[i] -= along * f.dir[i];
    if (!Normalize(up)) {
        // "up" was along the view: take any direction perpendicular to it.
        double helper[3] = {std::fabs(f.dir[0]) < 0.9 ? 1.0 : 0.0, std::fabs(f.dir[0]) < 0.9 ? 0.0 : 1.0, 0};
        Cross(f.dir, helper, up);
        Normalize(up);
    }
    for (int i = 0; i < 3; i++) f.up[i] = up[i];
    Cross(f.dir, f.up, f.right);
    f.parallel = c.projection == Projection::Parallel;
    f.viewAngle = (c.viewAngle > 0.01 && c.viewAngle < 179) ? c.viewAngle : 30.0;
    f.parallelScale = c.parallelScale > 0 ? c.parallelScale : 100.0;
    return f;
}

// What: the full view angle (radians) of the SMALLER side of the picture. VRML's
// fieldOfView and RenderMan's "fov" are defined that way, while BorosKit/VTK store the
// vertical angle. A parallel camera is described by the angle that shows the same
// image height at the focal point.
static double SmallerSideAngle(const Frame &f, unsigned width, unsigned height)
{
    const double pi = 3.14159265358979323846;
    double halfTan = f.parallel ? f.parallelScale / std::max(f.distance, 1e-6) : std::tan(f.viewAngle * pi / 360.0);
    if (width < height && height > 0) halfTan *= (double)width / (double)height;
    return 2.0 * std::atan(halfTan);
}

// What: the rotation that turns the standard VRML / Inventor camera (looking along -z
// with +y up) into our camera, as an axis and an angle (radians).
// How: the rotation matrix has the columns right, up, -forward. It is converted to a
// unit quaternion (the usual numerically safe method that starts from the largest
// diagonal term), then to axis + angle.
static void CameraOrientation(const Frame &f, double axis[3], double &angle)
{
    double R[3][3];
    for (int i = 0; i < 3; i++) { R[i][0] = f.right[i]; R[i][1] = f.up[i]; R[i][2] = -f.dir[i]; }
    double w, x, y, z, trace = R[0][0] + R[1][1] + R[2][2];
    if (trace > 0) {
        double s = std::sqrt(trace + 1.0) * 2;
        w = 0.25 * s; x = (R[2][1] - R[1][2]) / s; y = (R[0][2] - R[2][0]) / s; z = (R[1][0] - R[0][1]) / s;
    } else if (R[0][0] > R[1][1] && R[0][0] > R[2][2]) {
        double s = std::sqrt(1.0 + R[0][0] - R[1][1] - R[2][2]) * 2;
        w = (R[2][1] - R[1][2]) / s; x = 0.25 * s; y = (R[0][1] + R[1][0]) / s; z = (R[0][2] + R[2][0]) / s;
    } else if (R[1][1] > R[2][2]) {
        double s = std::sqrt(1.0 + R[1][1] - R[0][0] - R[2][2]) * 2;
        w = (R[0][2] - R[2][0]) / s; x = (R[0][1] + R[1][0]) / s; y = 0.25 * s; z = (R[1][2] + R[2][1]) / s;
    } else {
        double s = std::sqrt(1.0 + R[2][2] - R[0][0] - R[1][1]) * 2;
        w = (R[1][0] - R[0][1]) / s; x = (R[0][2] + R[2][0]) / s; y = (R[1][2] + R[2][1]) / s; z = 0.25 * s;
    }
    if (w < 0) { w = -w; x = -x; y = -y; z = -z; }
    double len = std::sqrt(x * x + y * y + z * z);
    angle = 2.0 * std::atan2(len, w);
    if (len > 1e-12) { axis[0] = x / len; axis[1] = y / len; axis[2] = z / len; }
    else { axis[0] = 0; axis[1] = 0; axis[2] = 1; angle = 0; }
}

static inline float Clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

#pragma mark - Names and strings

// What: a name made only of letters, digits and '_', starting with a letter, and not
// used by any earlier object. Why: VRML / Inventor names (DEF) and OBJ group / material
// names may not contain spaces or punctuation, and two objects with the same name
// would be merged or confused by other programs.
static std::string UniqueSafeName(const std::string &name, const char *fallback, std::set<std::string> &used)
{
    std::string s;
    for (unsigned char c : name) s.push_back(std::isalnum(c) && c < 128 ? (char)c : '_');
    if (s.empty() || !std::isalpha((unsigned char)s[0])) s = std::string(fallback) + (s.empty() ? "" : "_") + s;
    std::string candidate = s;
    for (unsigned n = 2; used.count(candidate); n++) candidate = s + "_" + std::to_string(n);
    used.insert(candidate);
    return candidate;
}

// What: text that can sit safely inside "double quotes" (VRML, Inventor, RenderMan
// strings): quotes and backslashes get a backslash, line breaks become spaces.
static std::string Quoted(const std::string &text)
{
    std::string s = "\"";
    for (char c : text) {
        if (c == '"' || c == '\\') { s.push_back('\\'); s.push_back(c); }
        else if (c == '\n' || c == '\r') s.push_back(' ');
        else s.push_back(c);
    }
    s.push_back('"');
    return s;
}

// What: text for a "# comment" line (no line breaks inside).
static std::string CommentText(const std::string &text)
{
    std::string s = text;
    for (char &c : s) if (c == '\n' || c == '\r') c = ' ';
    return s;
}

// What: the file name part of a path (after the last '/' or '\').
static std::string FileName(const std::string &path)
{
    size_t slash = path.find_last_of("/\\");
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

// What: the path without its extension (".obj" etc.).
static std::string WithoutExtension(const std::string &path)
{
    size_t slash = path.find_last_of("/\\");
    size_t dot = path.find_last_of('.');
    if (dot == std::string::npos || (slash != std::string::npos && dot < slash) || dot == (slash == std::string::npos ? 0 : slash + 1))
        return path;
    return path.substr(0, dot);
}

std::string MaterialPathForOBJ(const std::string &objPath)
{
    std::string base = WithoutExtension(objPath);
    size_t slash = base.find_last_of("/\\");
    size_t start = slash == std::string::npos ? 0 : slash + 1;
    for (size_t i = start; i < base.size(); i++) if (base[i] == ' ') base[i] = '_';
    return base + ".mtl";
}

#pragma mark - Preparation

// Everything the writers need besides the scene: checked placements, safe names, the
// camera frame (made up from the scene size when the scene has no camera).
struct Prepared {
    std::vector<Placement> meshPlacement, linePlacement;
    std::vector<std::string> meshName, lineName;
    std::vector<bool> meshAlphaVaries;   // per-vertex colours with some alpha < 1
    Frame frame;
    bool hasCamera = false;
};

// What: the box around everything in world mm. Used to place a camera when none is given.
static void WorldBounds(const Scene &scene, const Prepared &prep, double lo[3], double hi[3], bool &any)
{
    any = false;
    for (int i = 0; i < 3; i++) { lo[i] = 1e300; hi[i] = -1e300; }
    auto take = [&](const float w[3]) {
        for (int i = 0; i < 3; i++) { lo[i] = std::min(lo[i], (double)w[i]); hi[i] = std::max(hi[i], (double)w[i]); }
        any = true;
    };
    for (size_t k = 0; k < scene.meshes.size(); k++) {
        const MeshItem &m = scene.meshes[k];
        for (size_t v = 0; v < m.vertexCount; v++) { float w[3]; prep.meshPlacement[k].point(m.positions + 3 * v, w); take(w); }
    }
    for (size_t k = 0; k < scene.lines.size(); k++) {
        const LineItem &l = scene.lines[k];
        for (size_t v = 0; v < 2 * l.segmentCount; v++) { float w[3]; prep.linePlacement[k].point(l.points + 3 * v, w); take(w); }
    }
}

// What: checks the whole scene before anything is written and prepares it.
// Why check first: a mistake found half-way would leave the user waiting for nothing.
static Result Prepare(const Scene &scene, Prepared &prep)
{
    Result r;
    auto fail = [&](const std::string &message) { r.error = ErrorKind::InvalidScene; r.message = message; return r; };
    std::set<std::string> used;
    for (size_t k = 0; k < scene.meshes.size(); k++) {
        const MeshItem &m = scene.meshes[k];
        std::string label = m.name.empty() ? "surface " + std::to_string(k + 1) : "'" + m.name + "'";
        if (m.vertexCount && !m.positions) return fail("The " + label + " has no points.");
        if (m.triangleCount && !m.indices) return fail("The " + label + " has no triangle list.");
        if (m.vertexCount > 0xFFFFFFFFull) return fail("The " + label + " has too many points.");
        // Every triangle corner must be a real point (checked on all cores).
        std::atomic<bool> bad(false);
        const uint32_t *idx = m.indices;
        const size_t vc = m.vertexCount;
        BKParallelFor(m.triangleCount * 3, 1 << 16, [&](size_t b, size_t e) {
            for (size_t i = b; i < e; i++) if (idx[i] >= vc) { bad = true; return; }
        });
        if (bad) return fail("A triangle of the " + label + " refers to a point that does not exist.");
        Placement p;
        std::string why;
        if (!MakePlacement(m.matrix, p, why)) return fail("The placement of the " + label + " " + why + ".");
        prep.meshPlacement.push_back(p);
        prep.meshName.push_back(UniqueSafeName(m.name, "Surface", used));
        bool varies = false;
        if (m.colors) for (size_t v = 0; v < m.vertexCount && !varies; v++) varies = m.colors[4 * v + 3] < 1.0f;
        prep.meshAlphaVaries.push_back(varies);
    }
    for (size_t k = 0; k < scene.lines.size(); k++) {
        const LineItem &l = scene.lines[k];
        std::string label = l.name.empty() ? "line set " + std::to_string(k + 1) : "'" + l.name + "'";
        if (l.segmentCount && !l.points) return fail("The " + label + " has no points.");
        Placement p;
        std::string why;
        if (!MakePlacement(l.matrix, p, why)) return fail("The placement of the " + label + " " + why + ".");
        prep.linePlacement.push_back(p);
        prep.lineName.push_back(UniqueSafeName(l.name, "Lines", used));
    }
    prep.hasCamera = scene.camera.present;
    if (prep.hasCamera) {
        prep.frame = MakeFrame(scene.camera);
    } else {
        // No camera: look at the scene from the front (from the patient's face towards
        // the back of the head, head up), far enough back to see all of it.
        double lo[3], hi[3];
        bool any;
        WorldBounds(scene, prep, lo, hi, any);
        if (!any) for (int i = 0; i < 3; i++) { lo[i] = -1; hi[i] = 1; }
        double center[3], d[3];
        for (int i = 0; i < 3; i++) { center[i] = 0.5 * (lo[i] + hi[i]); d[i] = hi[i] - lo[i]; }
        double radius = std::max(1e-3, 0.5 * std::sqrt(Dot(d, d)));
        Camera c;
        c.present = true;
        c.projection = Projection::Perspective;
        c.viewAngle = 30;
        double distance = radius / std::sin(15.0 * 3.14159265358979323846 / 180.0);
        for (int i = 0; i < 3; i++) { c.focalPoint[i] = center[i]; c.position[i] = center[i]; c.viewUp[i] = 0; }
        c.position[1] -= distance;   // patient y points to the back, so the front is -y
        c.viewUp[2] = 1;
        c.parallelScale = radius;
        prep.frame = MakeFrame(c);
        prep.frame.fitted = true;
    }
    return r;
}

// What: the colour an object shows at a vertex: the vertex colour times the object
// colour (exactly how BKMeshRenderer mixes them), alpha times the object opacity.
static inline void DrawnColor(const MeshItem &m, size_t v, float o[4])
{
    const float *c = m.colors + 4 * v;
    o[0] = Clamp01(c[0] * m.color[0]);
    o[1] = Clamp01(c[1] * m.color[1]);
    o[2] = Clamp01(c[2] * m.color[2]);
    o[3] = Clamp01(c[3] * m.opacity);
}

// What: triangle t's three corners, in an order that keeps "outside" outside
// (reversed when the placement mirrors).
static inline void Corners(const MeshItem &m, const Placement &p, size_t t, uint32_t c[3])
{
    const uint32_t *i = m.indices + 3 * t;
    c[0] = i[0];
    c[1] = p.mirror ? i[2] : i[1];
    c[2] = p.mirror ? i[1] : i[2];
}

static void Scale3(const float in[3], float s, float out[3]) { for (int i = 0; i < 3; i++) out[i] = Clamp01(in[i] * s); }

#pragma mark - Wavefront OBJ + MTL

// OBJ is a list of lines: "v x y z" (a point), "vn x y z" (a normal), "f a b c" (a face
// using point numbers counted from 1 across the WHOLE file), "l a b" (a line), "o"/"g"
// (object / group name) and "usemtl" (switch material). Colours and shininess live in
// the separate .mtl file ("newmtl" blocks with Ka/Kd/Ks ambient/diffuse/specular
// colours, Ns shininess exponent, d opacity, illum lighting model).
static Result WriteOBJ(const Scene &scene, const Prepared &prep, const std::string &path, Progress &progress)
{
    Result r;
    std::string mtlPath = MaterialPathForOBJ(path);
    Output mtl(mtlPath), obj(path);
    if (!mtl.open() || !obj.open()) {
        r.error = ErrorKind::FileWrite;
        r.message = "The file " + FileName(mtl.failed() || !obj.path().empty() ? path : mtlPath) + " could not be created.";
        return r;
    }

    // --- Material library ---
    Text t;
    t.add("# Material library written by BorosKit for "); t.add(CommentText(FileName(path))); t.ch('\n');
    for (size_t k = 0; k < scene.meshes.size(); k++) {
        const MeshItem &m = scene.meshes[k];
        float c[3];
        t.add("\nnewmtl "); t.add(prep.meshName[k]); t.add("_material\n");
        if (m.lit) {
            Scale3(m.color, m.ambient, c); t.add("Ka "); t.three(c, 6); t.ch('\n');
            Scale3(m.color, m.diffuse, c); t.add("Kd "); t.three(c, 6); t.ch('\n');
            float s = Clamp01(m.specular);
            t.add("Ks "); t.flt(s, 6); t.ch(' '); t.flt(s, 6); t.ch(' '); t.flt(s, 6); t.ch('\n');
            t.add("Ns "); t.flt(std::max(0.0f, m.specularPower), 6); t.ch('\n');
            t.add("illum 2\n");          // colour + ambient + highlights
        } else {
            t.add("Ka 0 0 0\n");
            t.add("Kd "); t.three(m.color, 6); t.ch('\n');
            t.add("Ks 0 0 0\n");
            t.add("illum 0\n");          // plain colour, no lighting
        }
        t.add("d "); t.flt(Clamp01(m.opacity), 6); t.ch('\n');
    }
    for (size_t k = 0; k < scene.lines.size(); k++) {
        const LineItem &l = scene.lines[k];
        t.add("\nnewmtl "); t.add(prep.lineName[k]); t.add("_material\n");
        t.add("Ka 0 0 0\nKd "); t.three(l.color, 6); t.add("\nKs 0 0 0\nillum 0\nd ");
        t.flt(Clamp01(l.opacity), 6); t.ch('\n');
    }
    mtl.write(t.s);

    // --- Geometry ---
    t.s.clear();
    t.add("# Wavefront OBJ written by BorosKit\n");
    t.add("# Units: millimetres, patient coordinates (x to the left, y to the back, z to the head).\n");
    if (!scene.title.empty()) { t.add("# "); t.add(CommentText(scene.title)); t.ch('\n'); }
    t.add("# "); t.uint(scene.meshes.size()); t.add(" surface(s), "); t.uint(scene.lines.size()); t.add(" line set(s)\n");
    t.add("mtllib "); t.add(FileName(mtlPath)); t.ch('\n');
    obj.write(t.s);

    uint64_t vBase = 1, vnBase = 1;   // OBJ numbers points and normals from 1, across all objects
    for (size_t k = 0; k < scene.meshes.size(); k++) {
        const MeshItem &m = scene.meshes[k];
        const Placement &p = prep.meshPlacement[k];
        t.s.clear();
        t.add("\no "); t.add(prep.meshName[k]); t.add("\ng "); t.add(prep.meshName[k]);
        t.add("\nusemtl "); t.add(prep.meshName[k]); t.add("_material\n");
        obj.write(t.s);
        // Points, with the drawn colour after them when the mesh has vertex colours
        // (the common "v x y z r g b" extension; BKMeshIO reads it back).
        if (!EmitBlocks(obj, progress, m.vertexCount, [&](Text &o, size_t b, size_t e) {
                for (size_t v = b; v < e; v++) {
                    float w[3];
                    p.point(m.positions + 3 * v, w);
                    o.add("v "); o.three(w);
                    if (m.colors) { float c[4]; DrawnColor(m, v, c); o.ch(' '); o.three(c, 6); }
                    o.ch('\n');
                }
            })) goto stopped;
        if (m.normals && !EmitBlocks(obj, progress, m.vertexCount, [&](Text &o, size_t b, size_t e) {
                for (size_t v = b; v < e; v++) {
                    float w[3];
                    p.normal(m.normals + 3 * v, w);
                    o.add("vn "); o.three(w, 7); o.ch('\n');
                }
            })) goto stopped;
        if (!EmitBlocks(obj, progress, m.triangleCount, [&](Text &o, size_t b, size_t e) {
                for (size_t f = b; f < e; f++) {
                    uint32_t c[3];
                    Corners(m, p, f, c);
                    o.ch('f');
                    for (int j = 0; j < 3; j++) {
                        o.ch(' '); o.uint(vBase + c[j]);
                        if (m.normals) { o.add("//"); o.uint(vnBase + c[j]); }
                    }
                    o.ch('\n');
                }
            })) goto stopped;
        vBase += m.vertexCount;
        if (m.normals) vnBase += m.vertexCount;
    }
    for (size_t k = 0; k < scene.lines.size(); k++) {
        const LineItem &l = scene.lines[k];
        const Placement &p = prep.linePlacement[k];
        t.s.clear();
        t.add("\no "); t.add(prep.lineName[k]); t.add("\ng "); t.add(prep.lineName[k]);
        t.add("\nusemtl "); t.add(prep.lineName[k]); t.add("_material\n");
        t.add("# line width "); t.flt(l.width, 6); t.add(" pixels (OBJ has no line width)\n");
        obj.write(t.s);
        if (!EmitBlocks(obj, progress, 2 * l.segmentCount, [&](Text &o, size_t b, size_t e) {
                for (size_t v = b; v < e; v++) { float w[3]; p.point(l.points + 3 * v, w); o.add("v "); o.three(w); o.ch('\n'); }
            })) goto stopped;
        if (!EmitBlocks(obj, progress, l.segmentCount, [&](Text &o, size_t b, size_t e) {
                for (size_t s = b; s < e; s++) { o.add("l "); o.uint(vBase + 2 * s); o.ch(' '); o.uint(vBase + 2 * s + 1); o.ch('\n'); }
            })) goto stopped;
        vBase += 2 * l.segmentCount;
    }

    if (!mtl.finish() || !obj.finish() || !mtl.commit() || !obj.commit()) {
        r.error = ErrorKind::FileWrite;
        r.message = "The file " + FileName(path) + " (or its material file " + FileName(mtlPath) + ") could not be written. Is the disk full or the folder read-only?";
        return r;
    }
    r.bytesWritten = mtl.bytes() + obj.bytes();
    return r;

stopped:
    r.error = progress.cancelled ? ErrorKind::Cancelled : ErrorKind::FileWrite;
    r.message = progress.cancelled ? "The export was cancelled." : "The file " + FileName(path) + " could not be written. Is the disk full?";
    return r;
}

#pragma mark - VRML 2.0 and Open Inventor 2.1

// Both formats describe a tree of "nodes" in braces with named fields; lists of numbers
// go in [ ]. They differ in node names and in how materials and per-vertex values are
// attached, so one writer handles both:
//   VRML:     Shape { appearance Appearance { material Material {...} }
//                     geometry IndexedFaceSet { coord Coordinate { point [...] }
//                                               normal Normal { vector [...] }
//                                               color Color { color [...] }
//                                               coordIndex [ a, b, c, -1, ... ] } }
//   Inventor: Separator { Material {...}  Coordinate3 { point [...] }
//                         Normal { vector [...] }  NormalBinding / MaterialBinding
//                         IndexedFaceSet { coordIndex [...] } }
// In coordIndex, -1 ends a face (or a line in IndexedLineSet).
// Shininess in both is 0..1, standing for a highlight exponent of 128 * shininess.

// What: the point list "x y z,\n" of an object in world mm.
template <typename PointFn>
static bool EmitPointList(Output &out, Progress &progress, size_t count, const PointFn &pointAt)
{
    return EmitBlocks(out, progress, count, [&](Text &o, size_t b, size_t e) {
        for (size_t v = b; v < e; v++) { float w[3]; pointAt(v, w); o.three(w); o.add(",\n"); }
    });
}

static Result WriteVRMLOrInventor(const Scene &scene, const Prepared &prep, const std::string &path,
                                  Progress &progress, bool vrml)
{
    Result r;
    Output out(path);
    if (!out.open()) { r.error = ErrorKind::FileWrite; r.message = "The file " + FileName(path) + " could not be created."; return r; }
    const double pi = 3.14159265358979323846;
    const Frame &f = prep.frame;
    Text t;
    if (vrml) {
        t.add("#VRML V2.0 utf8\n");
        t.add("# Written by BorosKit. Units: millimetres, patient coordinates (x to the left, y to the back, z to the head).\n\n");
        t.add("WorldInfo {\n  title "); t.add(Quoted(scene.title.empty() ? "BorosKit scene" : scene.title));
        t.add("\n  info [ \"Written by BorosKit\", \"Units: millimetres\" ]\n}\n");
        if (scene.hasBackground) { t.add("Background { skyColor [ "); t.three(scene.background, 6); t.add(" ] }\n"); }
        // VRML's head light has a fixed strength, so only on/off is kept.
        t.add("NavigationInfo { headlight "); t.add(scene.headlight ? "TRUE" : "FALSE"); t.add(" type [ \"EXAMINE\", \"ANY\" ] }\n");
        if (prep.hasCamera) {
            double axis[3], angle;
            CameraOrientation(f, axis, angle);
            float pos[3] = {(float)f.eye[0], (float)f.eye[1], (float)f.eye[2]};
            float ax[3] = {(float)axis[0], (float)axis[1], (float)axis[2]};
            if (f.parallel) t.add("# The camera is parallel (orthographic); VRML 2.0 only has perspective, so the same view size is shown at the focal point.\n");
            t.add("Viewpoint {\n  position "); t.three(pos);
            t.add("\n  orientation "); t.three(ax); t.ch(' '); t.flt((float)angle);
            t.add("\n  fieldOfView "); t.flt((float)SmallerSideAngle(f, scene.imageWidth, scene.imageHeight));
            t.add("\n  description \"BorosKit view\"\n}\n");
        }
    } else {
        t.add("#Inventor V2.1 ascii\n\n");
        t.add("# Written by BorosKit. Units: millimetres, patient coordinates (x to the left, y to the back, z to the head).\n");
        if (scene.hasBackground) {
            t.add("# Background colour: "); t.three(scene.background, 6); t.add(" (Inventor files have no background setting)\n");
        }
        t.add("Separator {\n  Info { string "); t.add(Quoted(scene.title.empty() ? "BorosKit scene" : scene.title)); t.add(" }\n");
        if (prep.hasCamera) {
            double axis[3], angle;
            CameraOrientation(f, axis, angle);
            float pos[3] = {(float)f.eye[0], (float)f.eye[1], (float)f.eye[2]};
            float ax[3] = {(float)axis[0], (float)axis[1], (float)axis[2]};
            t.add(f.parallel ? "  OrthographicCamera {\n" : "  PerspectiveCamera {\n");
            t.add("    viewportMapping ADJUST_CAMERA\n    position "); t.three(pos);
            t.add("\n    orientation "); t.three(ax); t.ch(' '); t.flt((float)angle);
            t.add("\n    aspectRatio "); t.flt((float)scene.imageWidth / (float)std::max(1u, scene.imageHeight));
            t.add("\n    focalDistance "); t.flt((float)f.distance);
            if (f.parallel) { t.add("\n    height "); t.flt((float)(2.0 * f.parallelScale)); }
            else { t.add("\n    heightAngle "); t.flt((float)(f.viewAngle * pi / 180.0)); }
            t.add("\n  }\n");
            if (scene.headlight) {
                // A light shining from the camera along the view, like the screen's head light.
                float d[3] = {(float)f.dir[0], (float)f.dir[1], (float)f.dir[2]};
                t.add("  DirectionalLight { on TRUE intensity "); t.flt(scene.headlightIntensity, 6);
                t.add(" color 1 1 1 direction "); t.three(d, 7); t.add(" }\n");
            }
        }
    }
    out.write(t.s);

    for (size_t k = 0; k < scene.meshes.size(); k++) {
        const MeshItem &m = scene.meshes[k];
        const Placement &p = prep.meshPlacement[k];
        float amb[3], dif[3];
        Scale3(m.color, m.ambient, amb);
        Scale3(m.color, m.diffuse, dif);
        float spec = Clamp01(m.specular), shininess = Clamp01(m.specularPower / 128.0f), transparency = Clamp01(1.0f - m.opacity);
        t.s.clear();
        t.add("\n# "); t.add(CommentText(m.name.empty() ? prep.meshName[k] : m.name)); t.add(": ");
        t.uint(m.vertexCount); t.add(" points, "); t.uint(m.triangleCount); t.add(" triangles\n");
        if (vrml) {
            t.add("DEF "); t.add(prep.meshName[k]); t.add(" Shape {\n  appearance Appearance {\n");
            if (m.lit) {
                // VRML's ambient part is a fraction of the diffuse colour.
                float ambientIntensity = m.diffuse > 0 ? Clamp01(m.ambient / m.diffuse) : 0.0f;
                t.add("    material Material {\n      ambientIntensity "); t.flt(ambientIntensity, 6);
                t.add("\n      diffuseColor "); t.three(dif, 6);
                t.add("\n      specularColor "); t.flt(spec, 6); t.ch(' '); t.flt(spec, 6); t.ch(' '); t.flt(spec, 6);
                t.add("\n      shininess "); t.flt(shininess, 6);
                t.add("\n      transparency "); t.flt(transparency, 6); t.add("\n    }\n");
            } else if (!m.colors) {
                // Unlit: the colour is "emitted", nothing is reflected.
                t.add("    material Material {\n      diffuseColor 0 0 0\n      specularColor 0 0 0\n      emissiveColor ");
                t.three(m.color, 6); t.add("\n      transparency "); t.flt(transparency, 6); t.add("\n    }\n");
            }
            // (unlit with vertex colours: no Material at all = VRML's "unlit, use the colours")
            t.add("  }\n  geometry IndexedFaceSet {\n    solid FALSE\n    ccw TRUE\n    coord Coordinate { point [\n");
        } else {
            t.add("  DEF "); t.add(prep.meshName[k]); t.add(" Separator {\n");
            if (!m.lit) t.add("    LightModel { model BASE_COLOR }\n");
            t.add("    Material {\n      ambientColor "); t.three(m.lit ? amb : m.color, 6);
            t.add("\n      specularColor "); if (m.lit) { t.flt(spec, 6); t.ch(' '); t.flt(spec, 6); t.ch(' '); t.flt(spec, 6); } else t.add("0 0 0");
            t.add("\n      shininess "); t.flt(shininess, 6);
            t.add("\n      transparency "); t.flt(transparency, 6);
            t.add("\n      diffuseColor ");
            out.write(t.s);
            t.s.clear();
            if (m.colors) {
                // One colour per vertex, picked by the face's corner numbers.
                out.write("[\n");
                if (!EmitBlocks(out, progress, m.vertexCount, [&](Text &o, size_t b, size_t e) {
                        for (size_t v = b; v < e; v++) { float c[4]; DrawnColor(m, v, c); o.three(c, 6); o.add(",\n"); }
                    })) goto stopped;
                t.add("      ]\n    }\n    MaterialBinding { value PER_VERTEX_INDEXED }\n");
            } else {
                t.three(m.lit ? dif : m.color, 6); t.add("\n    }\n");
            }
            t.add("    ShapeHints { vertexOrdering COUNTERCLOCKWISE shapeType UNKNOWN_SHAPE_TYPE faceType CONVEX }\n");
            t.add("    Coordinate3 { point [\n");
        }
        out.write(t.s);
        if (!EmitPointList(out, progress, m.vertexCount, [&](size_t v, float w[3]) { p.point(m.positions + 3 * v, w); })) goto stopped;
        out.write(vrml ? "    ] }\n" : "    ] }\n");
        if (m.normals) {
            out.write(vrml ? "    normal Normal { vector [\n" : "    Normal { vector [\n");
            if (!EmitBlocks(out, progress, m.vertexCount, [&](Text &o, size_t b, size_t e) {
                    for (size_t v = b; v < e; v++) { float w[3]; p.normal(m.normals + 3 * v, w); o.three(w, 7); o.add(",\n"); }
                })) goto stopped;
            out.write(vrml ? "    ] }\n    normalPerVertex TRUE\n" : "    ] }\n    NormalBinding { value PER_VERTEX_INDEXED }\n");
        }
        if (vrml && m.colors) {
            out.write("    color Color { color [\n");
            if (!EmitBlocks(out, progress, m.vertexCount, [&](Text &o, size_t b, size_t e) {
                    for (size_t v = b; v < e; v++) { float c[4]; DrawnColor(m, v, c); o.three(c, 6); o.add(",\n"); }
                })) goto stopped;
            out.write("    ] }\n    colorPerVertex TRUE\n");
        }
        out.write(vrml ? "    coordIndex [\n" : "    IndexedFaceSet { coordIndex [\n");
        if (!EmitBlocks(out, progress, m.triangleCount, [&](Text &o, size_t b, size_t e) {
                for (size_t tri = b; tri < e; tri++) {
                    uint32_t c[3];
                    Corners(m, p, tri, c);
                    o.uint(c[0]); o.add(", "); o.uint(c[1]); o.add(", "); o.uint(c[2]); o.add(", -1,\n");
                }
            })) goto stopped;
        out.write(vrml ? "    ]\n  }\n}\n" : "    ] }\n  }\n");
    }

    for (size_t k = 0; k < scene.lines.size(); k++) {
        const LineItem &l = scene.lines[k];
        const Placement &p = prep.linePlacement[k];
        float transparency = Clamp01(1.0f - l.opacity);
        t.s.clear();
        t.add("\n# "); t.add(CommentText(l.name.empty() ? prep.lineName[k] : l.name)); t.add(": ");
        t.uint(l.segmentCount); t.add(" line segments\n");
        if (vrml) {
            // VRML lines are always unlit and use the emissive colour; VRML has no line width.
            t.add("DEF "); t.add(prep.lineName[k]); t.add(" Shape {\n  appearance Appearance {\n");
            t.add("    material Material { diffuseColor 0 0 0 emissiveColor "); t.three(l.color, 6);
            t.add(" transparency "); t.flt(transparency, 6); t.add(" }\n  }\n");
            t.add("  geometry IndexedLineSet {\n    coord Coordinate { point [\n");
        } else {
            t.add("  DEF "); t.add(prep.lineName[k]); t.add(" Separator {\n");
            t.add("    LightModel { model BASE_COLOR }\n    DrawStyle { lineWidth "); t.flt(l.width, 6); t.add(" }\n");
            t.add("    Material { diffuseColor "); t.three(l.color, 6); t.add(" transparency "); t.flt(transparency, 6); t.add(" }\n");
            t.add("    Coordinate3 { point [\n");
        }
        out.write(t.s);
        if (!EmitPointList(out, progress, 2 * l.segmentCount, [&](size_t v, float w[3]) { p.point(l.points + 3 * v, w); })) goto stopped;
        out.write(vrml ? "    ] }\n    coordIndex [\n" : "    ] }\n    IndexedLineSet { coordIndex [\n");
        if (!EmitBlocks(out, progress, l.segmentCount, [&](Text &o, size_t b, size_t e) {
                for (size_t s = b; s < e; s++) { o.uint(2 * s); o.add(", "); o.uint(2 * s + 1); o.add(", -1,\n"); }
            })) goto stopped;
        out.write(vrml ? "    ]\n  }\n}\n" : "    ] }\n  }\n");
    }
    if (!vrml) out.write("}\n");

    if (!out.finish() || !out.commit()) {
        r.error = ErrorKind::FileWrite;
        r.message = "The file " + FileName(path) + " could not be written. Is the disk full or the folder read-only?";
        return r;
    }
    r.bytesWritten = out.bytes();
    return r;

stopped:
    r.error = progress.cancelled ? ErrorKind::Cancelled : ErrorKind::FileWrite;
    r.message = progress.cancelled ? "The export was cancelled." : "The file " + FileName(path) + " could not be written. Is the disk full?";
    return r;
}

#pragma mark - RenderMan RIB

// A RIB file is a list of requests for a RenderMan renderer:
//   options (image size, projection, camera placement) before WorldBegin,
//   then lights and objects between WorldBegin and WorldEnd.
// RenderMan's camera looks along +z with +y up and +x to the right (a "left-handed"
// space). The "Transform" request before WorldBegin gives the matrix from world to
// camera; RenderMan writes points as rows (p' = p * M), so the 16 numbers of our
// column-vector matrix appear in column order.
// Surfaces: "PointsPolygons [corners per face] [corner numbers] "P" [points] "N" [normals]
// "Cs" [colours] "Os" [opacities]", with the standard "plastic" shader (Ka, Kd, Ks,
// roughness; roughness ~ 1 / highlight exponent) or "constant" for unlit objects.
// Lines: "Curves "linear"" with a constant width in world mm.
static Result WriteRIB(const Scene &scene, const Prepared &prep, const std::string &path, Progress &progress)
{
    Result r;
    Output out(path);
    if (!out.open()) { r.error = ErrorKind::FileWrite; r.message = "The file " + FileName(path) + " could not be created."; return r; }
    const double pi = 3.14159265358979323846;
    const Frame &f = prep.frame;
    unsigned W = std::max(1u, scene.imageWidth), H = std::max(1u, scene.imageHeight);
    double aspect = (double)W / (double)H;
    Text t;
    t.add("##RenderMan RIB\n##Creator BorosKit\n");
    if (!scene.title.empty()) { t.add("##Title "); t.add(CommentText(scene.title)); t.ch('\n'); }
    t.add("# Units: millimetres, patient coordinates (x to the left, y to the back, z to the head).\n");
    if (f.fitted) t.add("# No camera was given: front view fitted to the whole scene.\n");
    t.add("version 3.03\nFrameBegin 1\n");
    t.add("Display "); t.add(Quoted(FileName(WithoutExtension(path)) + ".tif")); t.add(" \"file\" \"rgba\"\n");
    t.add("Format "); t.uint(W); t.ch(' '); t.uint(H); t.add(" 1\n");
    if (f.parallel) {
        double s = f.parallelScale;
        t.add("Projection \"orthographic\"\nScreenWindow ");
        t.flt((float)(-s * aspect)); t.ch(' '); t.flt((float)(s * aspect)); t.ch(' '); t.flt((float)-s); t.ch(' '); t.flt((float)s); t.ch('\n');
    } else {
        t.add("Projection \"perspective\" \"fov\" [ "); t.flt((float)(SmallerSideAngle(f, W, H) * 180.0 / pi)); t.add(" ]\n");
    }
    if (scene.hasBackground) { t.add("Imager \"background\" \"color\" [ "); t.three(scene.background, 6); t.add(" ]\n"); }
    // World -> camera: rows are right, up, forward; translation moves the eye to 0.
    {
        double V[4][4] = {
            {f.right[0], f.right[1], f.right[2], -Dot(f.right, f.eye)},
            {f.up[0], f.up[1], f.up[2], -Dot(f.up, f.eye)},
            {f.dir[0], f.dir[1], f.dir[2], -Dot(f.dir, f.eye)},
            {0, 0, 0, 1},
        };
        t.add("# Camera: eye at "); for (int i = 0; i < 3; i++) { t.flt((float)f.eye[i]); t.ch(i < 2 ? ' ' : '\n'); }
        t.add("Transform [");
        for (int c = 0; c < 4; c++) for (int row = 0; row < 4; row++) { t.ch(' '); t.flt((float)V[row][c]); }
        t.add(" ]\n");
    }
    t.add("WorldBegin\n");
    t.add("LightSource \"ambientlight\" 1 \"intensity\" [ 1 ] \"lightcolor\" [ 1 1 1 ]\n");
    if (scene.headlight) {
        float eye[3] = {(float)f.eye[0], (float)f.eye[1], (float)f.eye[2]};
        float to[3] = {(float)(f.eye[0] + f.dir[0]), (float)(f.eye[1] + f.dir[1]), (float)(f.eye[2] + f.dir[2])};
        t.add("# Head light: from the eye along the view\n");
        t.add("LightSource \"distantlight\" 2 \"intensity\" [ "); t.flt(scene.headlightIntensity, 6);
        t.add(" ] \"lightcolor\" [ 1 1 1 ] \"from\" [ "); t.three(eye); t.add(" ] \"to\" [ "); t.three(to); t.add(" ]\n");
    }
    out.write(t.s);

    for (size_t k = 0; k < scene.meshes.size(); k++) {
        const MeshItem &m = scene.meshes[k];
        const Placement &p = prep.meshPlacement[k];
        if (m.triangleCount == 0) continue;   // PointsPolygons needs at least one face
        float o = Clamp01(m.opacity);
        t.s.clear();
        t.add("\nAttributeBegin\n  Attribute \"identifier\" \"name\" [ "); t.add(Quoted(m.name.empty() ? prep.meshName[k] : m.name)); t.add(" ]\n");
        t.add("  Color [ "); t.three(m.color, 6); t.add(" ]\n");
        t.add("  Opacity [ "); t.flt(o, 6); t.ch(' '); t.flt(o, 6); t.ch(' '); t.flt(o, 6); t.add(" ]\n");
        t.add("  Sides 2\n");
        if (m.lit) {
            t.add("  Surface \"plastic\" \"Ka\" [ "); t.flt(m.ambient, 6); t.add(" ] \"Kd\" [ "); t.flt(m.diffuse, 6);
            t.add(" ] \"Ks\" [ "); t.flt(m.specular, 6); t.add(" ] \"roughness\" [ "); t.flt(1.0f / std::max(1.0f, m.specularPower), 6);
            t.add(" ] \"specularcolor\" [ 1 1 1 ]\n");
        } else {
            t.add("  Surface \"constant\"\n");
        }
        t.add("  PointsPolygons [\n");
        out.write(t.s);
        // Every face has 3 corners.
        if (!EmitBlocks(out, progress, m.triangleCount, [&](Text &o2, size_t b, size_t e) {
                for (size_t i = b; i < e; i++) o2.add((i % 32) == 31 ? "3\n" : "3 ");
            })) goto stopped;
        out.write("\n  ] [\n");
        if (!EmitBlocks(out, progress, m.triangleCount, [&](Text &o2, size_t b, size_t e) {
                for (size_t tri = b; tri < e; tri++) {
                    uint32_t c[3];
                    Corners(m, p, tri, c);
                    o2.uint(c[0]); o2.ch(' '); o2.uint(c[1]); o2.ch(' '); o2.uint(c[2]); o2.ch('\n');
                }
            })) goto stopped;
        out.write("  ] \"P\" [\n");
        if (!EmitBlocks(out, progress, m.vertexCount, [&](Text &o2, size_t b, size_t e) {
                for (size_t v = b; v < e; v++) { float w[3]; p.point(m.positions + 3 * v, w); o2.three(w); o2.ch('\n'); }
            })) goto stopped;
        if (m.normals) {
            out.write("  ] \"N\" [\n");
            if (!EmitBlocks(out, progress, m.vertexCount, [&](Text &o2, size_t b, size_t e) {
                    for (size_t v = b; v < e; v++) { float w[3]; p.normal(m.normals + 3 * v, w); o2.three(w, 7); o2.ch('\n'); }
                })) goto stopped;
        }
        if (m.colors) {
            out.write("  ] \"Cs\" [\n");
            if (!EmitBlocks(out, progress, m.vertexCount, [&](Text &o2, size_t b, size_t e) {
                    for (size_t v = b; v < e; v++) { float c[4]; DrawnColor(m, v, c); o2.three(c, 6); o2.ch('\n'); }
                })) goto stopped;
            if (prep.meshAlphaVaries[k]) {
                out.write("  ] \"Os\" [\n");
                if (!EmitBlocks(out, progress, m.vertexCount, [&](Text &o2, size_t b, size_t e) {
                        for (size_t v = b; v < e; v++) {
                            float c[4]; DrawnColor(m, v, c);
                            o2.flt(c[3], 6); o2.ch(' '); o2.flt(c[3], 6); o2.ch(' '); o2.flt(c[3], 6); o2.ch('\n');
                        }
                    })) goto stopped;
            }
        }
        out.write("  ]\nAttributeEnd\n");
    }

    // Line width: RenderMan curves are as wide as given in world mm, so the width in
    // pixels is turned into mm at the focal point (where the picture is sharpest).
    {
        double mmPerPixel = (f.parallel ? 2.0 * f.parallelScale : 2.0 * f.distance * std::tan(f.viewAngle * pi / 360.0)) / (double)H;
        for (size_t k = 0; k < scene.lines.size(); k++) {
            const LineItem &l = scene.lines[k];
            const Placement &p = prep.linePlacement[k];
            if (l.segmentCount == 0) continue;
            float o = Clamp01(l.opacity);
            t.s.clear();
            t.add("\nAttributeBegin\n  Attribute \"identifier\" \"name\" [ "); t.add(Quoted(l.name.empty() ? prep.lineName[k] : l.name)); t.add(" ]\n");
            t.add("  Color [ "); t.three(l.color, 6); t.add(" ]\n");
            t.add("  Opacity [ "); t.flt(o, 6); t.ch(' '); t.flt(o, 6); t.ch(' '); t.flt(o, 6); t.add(" ]\n");
            t.add("  Surface \"constant\"\n");
            t.add("  # "); t.flt(l.width, 6); t.add(" pixel(s) wide\n");
            t.add("  Curves \"linear\" [\n");
            out.write(t.s);
            if (!EmitBlocks(out, progress, l.segmentCount, [&](Text &o2, size_t b, size_t e) {
                    for (size_t i = b; i < e; i++) o2.add((i % 32) == 31 ? "2\n" : "2 ");
                })) goto stopped;
            out.write("\n  ] \"nonperiodic\" \"P\" [\n");
            if (!EmitBlocks(out, progress, 2 * l.segmentCount, [&](Text &o2, size_t b, size_t e) {
                    for (size_t v = b; v < e; v++) { float w[3]; p.point(l.points + 3 * v, w); o2.three(w); o2.ch('\n'); }
                })) goto stopped;
            t.s.clear();
            t.add("  ] \"constantwidth\" [ "); t.flt((float)(std::max(0.0f, l.width) * mmPerPixel), 6); t.add(" ]\nAttributeEnd\n");
            out.write(t.s);
        }
    }
    out.write("\nWorldEnd\nFrameEnd\n");

    if (!out.finish() || !out.commit()) {
        r.error = ErrorKind::FileWrite;
        r.message = "The file " + FileName(path) + " could not be written. Is the disk full or the folder read-only?";
        return r;
    }
    r.bytesWritten = out.bytes();
    return r;

stopped:
    r.error = progress.cancelled ? ErrorKind::Cancelled : ErrorKind::FileWrite;
    r.message = progress.cancelled ? "The export was cancelled." : "The file " + FileName(path) + " could not be written. Is the disk full?";
    return r;
}

#pragma mark - Entry point

// What: how many entries the writer for `format` will turn into text in total, so the
// progress fraction moves evenly from 0 to 1.
static double PlannedWork(const Scene &scene, const Prepared &prep, Format format)
{
    double total = 0;
    for (size_t k = 0; k < scene.meshes.size(); k++) {
        const MeshItem &m = scene.meshes[k];
        double V = (double)m.vertexCount, T = (double)m.triangleCount;
        double perVertex = 1 + (m.normals ? 1 : 0);
        switch (format) {
            case Format::OBJ: total += V * perVertex + T; break;
            case Format::VRML2:
            case Format::Inventor: total += V * (perVertex + (m.colors ? 1 : 0)) + T; break;
            case Format::RIB:
                if (T > 0) total += V * (perVertex + (m.colors ? 1 : 0) + (prep.meshAlphaVaries[k] ? 1 : 0)) + 2 * T;
                break;
        }
    }
    for (const LineItem &l : scene.lines) total += 3.0 * (double)l.segmentCount;
    return total;
}

Result WriteScene(const Scene &scene, Format format, const std::string &path, ProgressFunction progressFunction, void *context)
{
    Prepared prep;
    Result r = Prepare(scene, prep);
    if (!r.ok()) return r;
    Progress progress;
    progress.function = progressFunction;
    progress.context = context;
    progress.total = PlannedWork(scene, prep, format);
    switch (format) {
        case Format::OBJ: r = WriteOBJ(scene, prep, path, progress); break;
        case Format::VRML2: r = WriteVRMLOrInventor(scene, prep, path, progress, true); break;
        case Format::Inventor: r = WriteVRMLOrInventor(scene, prep, path, progress, false); break;
        case Format::RIB: r = WriteRIB(scene, prep, path, progress); break;
    }
    if (r.ok() && progressFunction) progressFunction(1.0, context);
    return r;
}

} // namespace sceneexport
} // namespace boroskit
