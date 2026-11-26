// BorosKit core tests: the CPU cores built by CMake give EXACTLY the numbers and meshes the Mac (SwiftPM)
// build recorded in Tests/BorosKitGoldenTests/References - proof that the pinned floating-point rule
// (-ffp-contract=off, no fast-math, user decision D3 2026-11-25) makes both builds compute the same bits.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine".
//
// Same inputs as BKGoldenTests.m (testNumbers, testMeshProcessing); zero tolerance everywhere:
//   - transfer-function bake (BKRenderCore): table hash + probe entries vs numbers_core.txt;
//   - surface plan (BKSurfaceCore) vs numbers_core.txt;
//   - Taubin smoothing x10 and 50 % decimation (BKMeshProcessingCore, C++) of the recorded bone surface,
//     normals by AreaWeightedNormals, vs mesh_smooth_taubin10.bkmesh / mesh_decimate_50.bkmesh
//     (1 thread and all threads).
// (The camera numbers come from the Objective-C BKVolumeCamera and the scene export needs BKMesh's
// Objective-C primitives; they are not reproduced here.)

#include "BKCoreTest.h"
#include "BKGoldenCore.h"
#include "BKRenderCore.h"
#include "BKSurfaceCore.h"
#include "BKMeshProcessingCore.h"
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using namespace boroskit;

namespace {

struct Named { std::string name; double value; };

// The recorded value of `name` in numbers_core.txt (NaN when missing -> the check fails).
double Recorded(const BKGoldenNumber *ref, size_t count, const char *name)
{
    for (size_t i = 0; i < count; i++) if (std::strcmp(ref[i].name, name) == 0) return ref[i].value;
    return NAN;
}

}  // namespace

extern "C" void bk_test_golden_cpu_numbers(void)
{
    BKGoldenNumber *ref = nullptr;
    size_t refCount = 0;
    BK_CHECK(bk_golden_read_numbers(BK_GOLDEN_REFERENCES_DIR "/numbers_core.txt", &ref, &refCount) == 0);
    if (!ref) return;
    std::vector<Named> mine;

    // Transfer function: points as BKTransferFunction stores them (sorted by value; the golden lists are).
    std::vector<BKRenderTFPoint> color, opacity;
    for (uint32_t i = 0; i < kBKGoldenColorPointCount; i++)
        color.push_back({ kBKGoldenColorPoints[i].value,
                          { kBKGoldenColorPoints[i].red, kBKGoldenColorPoints[i].green, kBKGoldenColorPoints[i].blue } });
    for (uint32_t i = 0; i < kBKGoldenOpacityPointCount; i++)
        opacity.push_back({ kBKGoldenOpacityPoints[i].value, { kBKGoldenOpacityPoints[i].opacity, 0, 0 } });
    std::vector<float> table(4096 * 4);
    BKRenderTFBake(color.data(), color.size(), opacity.data(), opacity.size(), table.data(), 4096);
    uint64_t hash = bk_golden_hash(table.data(), table.size() * sizeof(float));
    mine.push_back({ "tf_table_hash_low32", (double)(hash & 0xFFFFFFFFu) });
    mine.push_back({ "tf_table_hash_high32", (double)(hash >> 32) });
    const int probes[] = { 0, 1000, 2047, 2600, 3000, 4095 };
    for (int p : probes)
        for (int ch = 0; ch < 4; ch++)
            mine.push_back({ "tf_entry_" + std::to_string(p) + "_ch" + std::to_string(ch), table[4 * p + ch] });

    // Surface plan for the smoothed half-resolution case.
    BKGoldenVolume v;
    BK_CHECK(bk_golden_make_head_phantom(&v) == 0);
    BKSurfacePlanRequest request;
    std::memset(&request, 0, sizeof request);
    request.volumeWidth = v.width;
    request.volumeHeight = v.height;
    request.volumeDepth = v.depth;
    request.resolution = 0.5f;
    request.smoothingSigma = 1.0f;
    std::memcpy(request.voxelToOutput, v.voxelToPatient, sizeof request.voxelToOutput);
    request.sampling = BK_SURFACE_SAMPLING_MANUAL;
    BKSurfacePlan plan;
    BK_CHECK(BKSurfacePlanMake(&request, &plan) == BKSurfaceStatusOK);
    mine.push_back({ "plan_grid_width", (double)plan.gridWidth });
    mine.push_back({ "plan_grid_height", (double)plan.gridHeight });
    mine.push_back({ "plan_grid_depth", (double)plan.gridDepth });
    mine.push_back({ "plan_row_stride", (double)plan.rowStride });
    mine.push_back({ "plan_blur_radius_x", (double)plan.blurRadius[0] });
    mine.push_back({ "plan_blur_radius_z", (double)plan.blurRadius[2] });
    mine.push_back({ "plan_blur_weight_x0", plan.blurWeights[0][0] });
    mine.push_back({ "plan_blur_weight_x1", plan.blurWeights[0][1] });
    mine.push_back({ "plan_blur_weight_z0", plan.blurWeights[2][0] });
    mine.push_back({ "plan_peak_bytes", (double)plan.peakTemporaryBytes });
    bk_golden_volume_free(&v);

    for (const Named &n : mine) {
        double r = Recorded(ref, refCount, n.name.c_str());
        bk_test_checks++;
        if (!(n.value == r)) {
            char msg[200];
            std::snprintf(msg, sizeof msg, "%s = %.17g, Mac recorded %.17g", n.name.c_str(), n.value, r);
            bk_test_fail(__FILE__, __LINE__, msg);
        }
    }
    std::free(ref);
}

extern "C" void bk_test_golden_cpu_meshes(void)
{
    BKGoldenMesh bone;
    std::memset(&bone, 0, sizeof bone);
    BK_CHECK(bk_golden_read_mesh(BK_GOLDEN_REFERENCES_DIR "/surface_bone_300.bkmesh", &bone) == 0);
    if (!bone.positions) return;
    const char *files[2] = { "/mesh_smooth_taubin10.bkmesh", "/mesh_decimate_50.bkmesh" };
    for (int threads = 0; threads < 2; threads++) {
        meshcore::SetMaxThreads(threads ? 0 : 1);   // pass 0: one thread, pass 1: all cores
        for (int k = 0; k < 2; k++) {
            std::vector<float> xyz(bone.positions, bone.positions + 3 * bone.vertexCount);
            std::vector<uint32_t> indices(bone.indices, bone.indices + 3 * bone.triangleCount);
            if (k == 0) {
                float lambda, mu;
                meshcore::TaubinFactorsForPassBand(BK_GOLDEN_SMOOTH_PASSBAND, lambda, mu);
                meshcore::SmoothLambdaMu(xyz, indices, BK_GOLDEN_SMOOTH_ITERATIONS, lambda, mu, nullptr, nullptr);
            } else {
                std::vector<uint32_t> source;
                meshcore::Decimate(xyz, indices, BK_GOLDEN_DECIMATE_REDUCTION, &source, nullptr, nullptr);
            }
            std::vector<float> normals;
            meshcore::AreaWeightedNormals(xyz, indices, normals);
            BKGoldenMesh mine = { xyz.size() / 3, indices.size() / 3, xyz.data(), normals.data(), indices.data() };
            BKGoldenMesh recorded;
            std::memset(&recorded, 0, sizeof recorded);
            std::string path = std::string(BK_GOLDEN_REFERENCES_DIR) + files[k];
            BK_CHECK(bk_golden_read_mesh(path.c_str(), &recorded) == 0);
            if (!recorded.positions) continue;
            BKGoldenMeshReport report = bk_golden_compare_meshes(&recorded, &mine, BKGoldenMeshTolerance{ { 1, 1, 1 }, 0, 0 });
            BK_CHECK(report.pass);
            // Zero tolerance means bit for bit: also compare the raw bytes.
            BK_CHECK(recorded.vertexCount == mine.vertexCount && recorded.triangleCount == mine.triangleCount);
            if (recorded.vertexCount == mine.vertexCount && recorded.triangleCount == mine.triangleCount) {
                BK_CHECK(std::memcmp(recorded.positions, mine.positions, 12 * mine.vertexCount) == 0);
                BK_CHECK(recorded.normals && std::memcmp(recorded.normals, mine.normals, 12 * mine.vertexCount) == 0);
                BK_CHECK(std::memcmp(recorded.indices, mine.indices, 12 * mine.triangleCount) == 0);
            }
            bk_golden_mesh_free(&recorded);
        }
    }
    meshcore::SetMaxThreads(0);
    bk_golden_mesh_free(&bone);
}
