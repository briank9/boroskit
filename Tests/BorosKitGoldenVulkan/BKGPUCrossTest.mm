// BorosKit GPU tests: Metal and Vulkan in ONE program on this Mac (VULKAN-ENGINE-KICKOFF.md section 6, point 3: a
// live cross-check that does not depend on a stored reference). Apple only (CMake, needs the Vulkan SDK).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
//
// What: the shared tests (triangle, golden meshes, winding) on BOTH devices - Metal against the references in STRICT
// mode (BKMeshPass on MetalDevice must reproduce the hand-written renderer's pictures bit for bit) - then the feature
// scene (lines, points, textures, see-through, wireframe, culling) rendered by both and compared with each other
// (agreed tolerances), with a side-by-side PNG. Zero Vulkan validation messages required.

#import <Foundation/Foundation.h>
#include "BKVulkanTestSupport.h"
#include "BKGPUSharedTests.h"
#include "BKGPUTestMetal.h"
#include "BKGoldenCore.h"
#include "BKPNGWrite.h"
#include <cmath>
#include <string>

using namespace bktest;

int main(int argc, char **argv)
{
    @autoreleasepool {
        std::string outDir = argc > 1 ? argv[1] : ".";
        const char *refs = BK_GOLDEN_REFERENCES_DIR;
        int failures = 0;
        std::unique_ptr<Device> metal = bkshared::MakeTestMetalDevice();
        if (!metal) { std::printf("FAIL: no Metal device\n"); return 1; }
        std::printf("== Metal (%s)\n", metal->name());
        failures += bkshared::TestTriangle(*metal);
        failures += bkshared::TestGoldenMeshes(*metal, refs, nullptr, "metal", true);
        failures += bkshared::TestWinding(*metal);
        failures += bkshared::TestComputeScan(*metal);
        failures += bkshared::TestGoldenFeatures(*metal, refs, nullptr, "metal", true, false);   // Metal: strict
        std::vector<uint8_t> mRGBA, vRGBA;
        std::vector<float> mDist, vDist;
        if (!bkshared::RenderFeatureScene(*metal, &mRGBA, &mDist)) { std::printf("FAIL: feature scene on Metal\n"); failures++; }

        Messages messages;
        {
            std::unique_ptr<Device> vulkan = StartDevice(&messages);
            if (!vulkan) return 1;
            std::printf("== Vulkan (%s, %s)\n", vulkan->name(), vulkanDriverName(*vulkan));
            failures += bkshared::TestTriangle(*vulkan);
            failures += bkshared::TestGoldenMeshes(*vulkan, refs, nullptr, "vulkan", false);
            failures += bkshared::TestWinding(*vulkan);
            failures += bkshared::TestComputeScan(*vulkan);
            if (!bkshared::RenderFeatureScene(*vulkan, &vRGBA, &vDist)) { std::printf("FAIL: feature scene on Vulkan\n"); failures++; }
        }
        if (mRGBA.size() == vRGBA.size() && !mRGBA.empty()) {
            const uint32_t W = 96, H = 80;
            BKGoldenImage a = { W, H, 4, BKGoldenFormatU8, mRGBA.data() }, b = { W, H, 4, BKGoldenFormatU8, vRGBA.data() };
            BKGoldenImage ad = { W, H, 1, BKGoldenFormatF32, mDist.data() }, bd = { W, H, 1, BKGoldenFormatF32, vDist.data() };
            BKGoldenImageReport rc = bk_golden_compare_images(&a, &b, bk_golden_tolerance_u8());
            BKGoldenImageReport rd = bk_golden_compare_images(&ad, &bd, BKGoldenImageTolerance{ 0.01, 0.005 });
            char text[256];
            bk_golden_describe_image_report(&rc, text, sizeof text);
            std::printf("CROSS | feature scene rgba | Vulkan vs Metal: %s\n", text);
            bk_golden_describe_image_report(&rd, text, sizeof text);
            std::printf("CROSS | feature scene distance | Vulkan vs Metal: %s\n", text);
            if (!rc.pass || !rd.pass) failures++;
            bk_golden_write_pam((outDir + "/feature_scene.metal.rgba.pam").c_str(), &a);
            bk_golden_write_pam((outDir + "/feature_scene.vulkan.rgba.pam").c_str(), &b);
            // Side by side: Metal | Vulkan | difference x 40 (3x).
            const uint32_t s = 3, gap = 6, OW = 3 * W * s + 2 * gap, OH = H * s;
            std::vector<uint8_t> img((size_t)OW * OH * 4, 255);
            for (uint32_t panel = 0; panel < 3; panel++)
                for (uint32_t y = 0; y < H; y++)
                    for (uint32_t x = 0; x < W; x++) {
                        const uint8_t *p = &mRGBA[(y * W + x) * 4], *q = &vRGBA[(y * W + x) * 4];
                        for (uint32_t sy = 0; sy < s; sy++)
                            for (uint32_t sx = 0; sx < s; sx++) {
                                uint8_t *o = &img[((size_t)(y * s + sy) * OW + panel * (W * s + gap) + x * s + sx) * 4];
                                for (int k = 0; k < 3; k++) {
                                    if (panel == 2) { int d = std::abs((int)p[k] - (int)q[k]) * 40; o[k] = (uint8_t)(d > 255 ? 255 : d); }
                                    else { const uint8_t *c = panel ? q : p; o[k] = (uint8_t)std::lround(std::fmin(c[k] / 255.0f + (1 - c[3] / 255.0f) * 0.35f, 1.0f) * 255); }
                                }
                                o[3] = 255;
                            }
                    }
            std::string png = outDir + "/feature_scene_metal_vs_vulkan.png";
            if (bk_png_write_rgba8(png.c_str(), img.data(), OW, OH) == 0) std::printf("picture: %s\n", png.c_str());
        } else {
            failures++;
        }
        std::printf("validation messages: %d errors, %d warnings\n", messages.errors, messages.warnings);
        if (messages.errors || messages.warnings) failures++;
        std::printf("%s Metal + Vulkan cross test\n", failures ? "FAILED" : "PASSED");
        return failures ? 1 : 0;
    }
}
