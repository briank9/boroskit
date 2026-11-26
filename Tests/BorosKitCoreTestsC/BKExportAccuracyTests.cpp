// BorosKit accuracy phantom for exported geometry (precision follow-up, 2026-11-26, agent "vulkan-engine").
// Original BorosKit code written for this project; contains no third-party code.
// REQ-EXPORT-GEOMETRY: an exported vertex position is the DOUBLE result of its placement, written so that it
// reads back as exactly that double (no rounding back to float, which could move it by up to 1e-5 mm at
// 100 mm). Checked through the real OBJ writer of BKSceneExportCore.

#include "BKCoreTest.h"
#include "BKSceneExportCore.h"
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

#ifndef BK_TEST_OUTPUT_DIR
#error "BK_TEST_OUTPUT_DIR must name a writable folder of the build (set by CMakeLists.txt)"
#endif

using namespace boroskit;

extern "C" void bk_test_export_accuracy_geometry(void)
{
    // FormatDouble: shortest text that reads back as the same double.
    const double samples[] = { 0.1, 1.0 / 3.0, 1.6, -123.456789012345678, 1e-300, 2.5e15, 0.30000000000000004 };
    for (double v : samples) {
        char b[32];
        size_t n = sceneexport::FormatDouble(v, b);
        b[n] = 0;
        BK_CHECK_SAME(std::strtod(b, nullptr), v);
    }
    char b[32];
    b[sceneexport::FormatDouble(0.1, b)] = 0;
    BK_CHECK(std::strcmp(b, "0.1") == 0);

    // One triangle: float vertex x = 1.5 placed with a translation of 0.1 mm -> exactly the double 1.5 + 0.1.
    const float positions[9] = { 1.5f, 0, 0, 2.5f, 0, 0, 1.5f, 1, 0 };
    const uint32_t indices[3] = { 0, 1, 2 };
    sceneexport::Scene scene;
    sceneexport::MeshItem m;
    m.name = "triangle";
    m.positions = positions;
    m.vertexCount = 3;
    m.indices = indices;
    m.triangleCount = 1;
    m.matrix[12] = 0.1;
    m.matrix[13] = 200.3;
    scene.meshes.push_back(m);
    std::string path = std::string(BK_TEST_OUTPUT_DIR) + "/bk_export_accuracy.obj";
    sceneexport::Result r = sceneexport::WriteScene(scene, sceneexport::Format::OBJ, path, nullptr, nullptr);
    BK_CHECK(r.ok());
    std::ifstream in(path);
    std::stringstream text;
    text << in.rdbuf();
    std::string s = text.str();
    // Read the first vertex line back and compare with the double placement.
    size_t at = s.find("\nv ");
    BK_CHECK(at != std::string::npos);
    if (at == std::string::npos) return;
    double x = 0, y = 0, z = 0;
    BK_CHECK(std::sscanf(s.c_str() + at + 3, "%lf %lf %lf", &x, &y, &z) == 3);
    BK_CHECK_SAME(x, 1.5 + 0.1);
    BK_CHECK_SAME(y, 0.0 + 200.3);
    BK_CHECK_SAME(z, 0.0);
    // The float-rounded value (what the file held before 2026-11-26) differs from the double by ~1e-6 mm.
    BK_CHECK((double)(float)(0.0 + 200.3) != 200.3);
}
