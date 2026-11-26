// BorosKit accuracy phantoms for meshes (precision follow-up, 2026-11-26, agent "vulkan-engine"): surface area
// and enclosed volume of shapes with exact answers, through the C++ core the Mac BKMesh class also uses.
// Original BorosKit code written for this project; contains no third-party code.
// REQ-MESH-VOLUME: volume shown to 0.01 mm3 (relative 1e-9); REQ-MESH-AREA: area to 0.01 mm2 (relative 1e-9).

#include "BKCoreTest.h"
#include "BKMeshProcessingCore.h"
#include <cmath>
#include <vector>

using namespace boroskit;

// A closed axis-aligned box from (x0,y0,z0) to (x1,y1,z1), outward triangles.
static void Box(double x0, double y0, double z0, double x1, double y1, double z1,
                std::vector<float> &xyz, std::vector<uint32_t> &idx)
{
    xyz.clear();
    idx.clear();
    for (int i = 0; i < 8; i++) {
        xyz.push_back((float)((i & 1) ? x1 : x0));
        xyz.push_back((float)((i & 2) ? y1 : y0));
        xyz.push_back((float)((i & 4) ? z1 : z0));
    }
    const uint32_t q[6][4] = { { 0, 2, 3, 1 }, { 4, 5, 7, 6 }, { 0, 1, 5, 4 }, { 2, 6, 7, 3 }, { 0, 4, 6, 2 }, { 1, 3, 7, 5 } };
    for (const auto &f : q) {
        idx.insert(idx.end(), { f[0], f[1], f[2] });
        idx.insert(idx.end(), { f[0], f[2], f[3] });
    }
}

extern "C" void bk_test_mesh_accuracy_box(void)
{
    std::vector<float> xyz;
    std::vector<uint32_t> idx;
    Box(-1, -1.5, -2, 1, 1.5, 2, xyz, idx);                    // 2 x 3 x 4 mm
    BK_CHECK_SAME(meshcore::EnclosedVolume(xyz, idx), 24.0);
    BK_CHECK_SAME(meshcore::SurfaceArea(xyz, idx), 52.0);
    // Far from the origin (the volume formula sums signed pyramids from the origin: cancellation).
    Box(100.25, 200.5, -300.75, 102.25, 203.5, -296.75, xyz, idx);
    BK_CHECK_NEAR(meshcore::EnclosedVolume(xyz, idx), 24.0, 1e-9 * 24.0);
    BK_CHECK_NEAR(meshcore::SurfaceArea(xyz, idx), 52.0, 1e-12 * 52.0);
}
