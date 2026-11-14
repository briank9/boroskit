// BorosKitMesh: BKSceneExportCore (internal C++ header; the public API is BKSceneExport.h)
// Original BorosKit code written for this project; contains no third-party code.
// Written from the published file-format descriptions (Wavefront OBJ/MTL, the VRML 2.0
// / VRML97 specification, the Open Inventor 2.1 ASCII file format, the RenderMan
// Interface 3.2 bytestream). No code or tables were copied or translated from VTK or
// any other library.
//
// What it is: writers that save a whole 3D SCENE (several surfaces, each with its own
// placement, colour and shininess, plus outline lines, the camera, the background
// colour and the head light) into the four exchange formats the old VTK-based Surface
// Rendering window offered in its "Export" menu:
//   - Wavefront OBJ + MTL (.obj with a .mtl "material library" next to it);
//   - VRML 2.0 (.wrl), for web / VR viewers;
//   - Open Inventor 2.1 text (.iv);
//   - RenderMan RIB (.rib), a scene description for photo-realistic renderers.
// A single surface on its own is still saved with BKMeshIO (STL/PLY/OBJ).
//
// Why: the 3D surfaces are now drawn by Metal (BKMeshRenderer), not VTK, so the export
// must read the same objects Metal draws. Everything is written in WORLD (patient)
// millimetres: each object's placement matrix is applied to its points while writing,
// so other programs see exactly the scene on the screen without having to understand
// placement matrices.
//
// PORTING NOTES (Windows / Linux / a future Vulkan version)
//   - This header and BKSceneExportCore.cpp use only standard C++17 and the C stdio
//     library: no Foundation, no Objective-C, no Apple simd types, no N3* geometry.
//     Input is plain pointers to packed floats (x,y,z,x,y,z... ; colours r,g,b,a,...)
//     and uint32_t triangle corner numbers, so a Vulkan or other front end can fill a
//     Scene straight from its own buffers without copying.
//   - The scene does NOT own the arrays: the caller keeps them alive and unchanged
//     until WriteScene returns.
//   - Matrices are 16 doubles in COLUMN-MAJOR order, column-vector convention:
//     point' = M * point, translation in elements 12, 13, 14 (same as Apple simd).
//   - Number formatting: floats are written with 9 significant digits (enough to read
//     back exactly the same 32-bit value). On systems that have
//     std::to_chars for floating point it can be used (3x faster), but Apple's library
//     refuses it outright below macOS 13.3, so on Apple snprintf("%.9g") is used unless
//     built with -DBK_SCENE_EXPORT_USE_TO_CHARS=1. Both give byte-identical text (checked on 20 million
//     random values while writing this), so files do not depend on the OS version.
//     On other platforms with a complete C++17 library, std::to_chars is used directly.
//   - Speed: the text of large arrays is produced in fixed-size blocks on all cores
//     (BKParallelFor, BKParallel.h) and written to the file in the original order, so
//     the output is identical whatever the number of threads. Output goes through one
//     large buffer (no giant in-memory strings), so memory use stays small even for
//     10+ million triangles.
//   - Files are written to a temporary name next to the target and renamed into place
//     only when complete (std::rename), so a failed or cancelled export never leaves a
//     half-written file under the real name.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace boroskit {
namespace sceneexport {

// Called now and then (on the calling thread) with a fraction 0..1 of the work done.
// Return false to cancel.
typedef bool (*ProgressFunction)(double fraction, void *context);

// One surface of the scene (a bone, a scan, an implant...), as it is drawn.
struct MeshItem {
    std::string name;                    // shown in the file (cleaned up where a format needs it)
    const float *positions = nullptr;    // vertexCount * 3 floats (x,y,z), mm, OBJECT coordinates
    size_t vertexCount = 0;
    const uint32_t *indices = nullptr;   // triangleCount * 3 corner numbers, anticlockwise seen from outside
    size_t triangleCount = 0;
    const float *normals = nullptr;      // optional: vertexCount * 3 (outward unit directions)
    const float *colors = nullptr;       // optional: vertexCount * 4 (r,g,b,a 0..1)
    // Placement: object coordinates -> world (patient mm). Column-major, point' = M * p.
    double matrix[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    // Material, with the same meaning as BKMeshRenderer's lighting: the drawn colour is
    // ambient * color + diffuse * color * (light . normal) + specular * highlight^specularPower.
    float color[3] = {1, 1, 1};
    float opacity = 1.0f;                // 1 = solid, 0 = invisible
    float ambient = 0.2f;
    float diffuse = 0.8f;
    float specular = 0.2f;
    float specularPower = 10.0f;
    bool lit = true;                     // false = flat colour without lighting (labels)
};

// A set of straight line segments (outline box, wireframe, measurement lines).
struct LineItem {
    std::string name;
    const float *points = nullptr;       // segmentCount * 2 points * 3 floats (start, end), object coordinates
    size_t segmentCount = 0;
    double matrix[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    float color[3] = {1, 1, 1};
    float opacity = 1.0f;
    float width = 1.0f;                  // pixels of the image (only formats that have line widths use it)
};

enum class Projection { Perspective, Parallel };

// The viewer's camera, VTK-style (as BKVolumeCamera stores it).
struct Camera {
    bool present = false;                // false = let the viewing program choose
    double position[3] = {0, 0, 1};      // eye (mm)
    double focalPoint[3] = {0, 0, 0};    // the point looked at
    double viewUp[3] = {0, 1, 0};        // "up" on the screen (made perpendicular to the view)
    Projection projection = Projection::Perspective;
    double viewAngle = 30.0;             // perspective: vertical view angle, degrees
    double parallelScale = 100.0;        // parallel: half the visible image height, mm
};

struct Scene {
    std::vector<MeshItem> meshes;
    std::vector<LineItem> lines;
    Camera camera;
    bool hasBackground = false;
    float background[3] = {0, 0, 0};
    bool headlight = true;               // a light at the eye shining where the camera looks
    float headlightIntensity = 1.0f;
    unsigned imageWidth = 640;           // picture size: aspect ratio + RenderMan image size
    unsigned imageHeight = 480;
    std::string title;                   // free text written as a comment / title
};

enum class Format { OBJ, VRML2, Inventor, RIB };

enum class ErrorKind {
    None = 0,
    InvalidScene,     // bad numbers: index out of range, singular or non-affine matrix...
    FileWrite,        // the file could not be created / written / renamed
    Cancelled,        // the progress function returned false
};

struct Result {
    ErrorKind error = ErrorKind::None;
    std::string message;          // plain-language explanation (English)
    uint64_t bytesWritten = 0;    // all files together
    bool ok() const { return error == ErrorKind::None; }
};

// Writes `scene` to `path` in `format`.
//   OBJ: also writes the material library to MaterialPathForOBJ(path) and refers to it
//        by its file name from inside the .obj.
// Progress (optional) is reported between blocks of work, on the calling thread.
Result WriteScene(const Scene &scene, Format format, const std::string &path,
                  ProgressFunction progress, void *context);

// Where the OBJ writer puts the .mtl file for `objPath`: same folder, same name with
// ".mtl" instead of the extension, and spaces replaced by '_' (because the "mtllib"
// line of an OBJ file separates several file names with spaces, so a name with a space
// would be misread by other programs).
std::string MaterialPathForOBJ(const std::string &objPath);

// Writes a float as text with `precision` significant digits (like printf "%.*g") into
// `buffer` (at least 32 bytes) and returns the number of characters (no 0 written).
size_t FormatFloat(float value, int precision, char *buffer);

} // namespace sceneexport
} // namespace boroskit
