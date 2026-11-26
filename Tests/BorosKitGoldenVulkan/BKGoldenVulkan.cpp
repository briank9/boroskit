// BorosKit Vulkan tests: the golden mesh runner - milestone 1 part (b), since 2026-11-26 through BKMeshPass (the same
// drawing code Metal runs) and the shared test code (Tests/BorosKitGPUShared). Writes the Vulkan pictures and, for
// people, side-by-side PNGs (Metal reference | Vulkan | difference x 40) into the folder given as argument 1.
// Original BorosKit code written for this project; contains no third-party code. Agent "vulkan-engine".

#include "BKVulkanTestSupport.h"
#include "BKGPUSharedTests.h"
#include "BKGoldenCore.h"
#include "BKPNGWrite.h"
#include <cmath>
#include <string>

using namespace bktest;

// Side-by-side picture: Metal | Vulkan | |difference| x 40, premultiplied colours over grey, 3x enlarged.
static void WriteSideBySide(const std::string &path, const uint8_t *metal, const uint8_t *vulkan, uint32_t W, uint32_t H)
{
    const uint32_t scale = 3, gap = 6, OW = (3 * W) * scale + 2 * gap, OH = H * scale;
    std::vector<uint8_t> img((size_t)OW * OH * 4, 255);
    for (uint32_t panel = 0; panel < 3; panel++)
        for (uint32_t y = 0; y < H; y++)
            for (uint32_t x = 0; x < W; x++) {
                const uint8_t *a = &metal[(y * W + x) * 4], *v = &vulkan[(y * W + x) * 4];
                uint8_t px[3];
                for (int k = 0; k < 3; k++) {
                    if (panel == 2) { int d = std::abs((int)a[k] - (int)v[k]) * 40; px[k] = (uint8_t)(d > 255 ? 255 : d); }
                    else {
                        const uint8_t *p = panel == 0 ? a : v;
                        float c = p[k] / 255.0f + (1.0f - p[3] / 255.0f) * 0.35f;
                        px[k] = (uint8_t)std::lround(std::fmin(c, 1.0f) * 255.0f);
                    }
                }
                for (uint32_t sy = 0; sy < scale; sy++)
                    for (uint32_t sx = 0; sx < scale; sx++) {
                        uint8_t *o = &img[((size_t)(y * scale + sy) * OW + panel * (W * scale + gap) + x * scale + sx) * 4];
                        o[0] = px[0]; o[1] = px[1]; o[2] = px[2]; o[3] = 255;
                    }
            }
    if (bk_png_write_rgba8(path.c_str(), img.data(), OW, OH) == 0) std::printf("picture: %s\n", path.c_str());
}

int main(int argc, char **argv)
{
    std::string outDir = argc > 1 ? argv[1] : ".";
    const std::string refs = BK_GOLDEN_REFERENCES_DIR;
    Messages messages;
    int failures = 0;
    {
        std::unique_ptr<Device> device = StartDevice(&messages);
        if (!device) return 1;
        failures += bkshared::TestGoldenMeshes(*device, refs.c_str(), outDir.c_str(), "vulkan", false);
        failures += bkshared::TestGoldenFeatures(*device, refs.c_str(), outDir.c_str(), "vulkan", false, false);   // 2026-11-26
    }
    for (uint32_t i = 0; i < kBKGoldenMeshRenderCaseCount; i++) {
        std::string name = kBKGoldenMeshRenderCases[i].name;
        BKGoldenImage m, v;
        std::memset(&m, 0, sizeof m);
        std::memset(&v, 0, sizeof v);
        if (bk_golden_read_pam((refs + "/" + name + ".rgba.pam").c_str(), &m) == 0 &&
            bk_golden_read_pam((outDir + "/" + name + ".vulkan.rgba.pam").c_str(), &v) == 0 && m.width == v.width && m.height == v.height)
            WriteSideBySide(outDir + "/" + name + "_metal_vs_vulkan.png", (const uint8_t *)m.data, (const uint8_t *)v.data, m.width, m.height);
        bk_golden_image_free(&m);
        bk_golden_image_free(&v);
    }
    std::printf("validation messages: %d errors, %d warnings\n", messages.errors, messages.warnings);
    if (messages.errors || messages.warnings) failures++;
    std::printf("%s golden meshes on Vulkan (BKMeshPass)\n", failures ? "FAILED" : "PASSED");
    return failures ? 1 : 0;
}
