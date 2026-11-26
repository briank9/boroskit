// BorosKit Vulkan tests: milestone 1 part (a) - one flat-coloured triangle (step M7).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine".
//
// What: draws a lopsided triangle (so an upside-down picture would be caught) into a 64 x 48 RGBA8 target
// through the BKGPU.h interface on the Vulkan device, reads it back and compares it with the CPU expectation:
// every pixel whose centre lies more than 0.75 pixel inside the triangle must be EXACTLY the colour, every
// pixel more than 0.75 pixel outside exactly the clear colour; pixels within 0.75 pixel of an edge may be
// either (the edge rule, "+-1 at the edges"). Plus: zero validation-layer messages.
// The colour is 51/255, 102/255, 204/255, 1 so the 8-bit values are exact (no rounding question).

#include "BKVulkanTestSupport.h"
#include <cmath>

using namespace bktest;

int main()
{
    Messages messages;
    std::unique_ptr<Device> device = StartDevice(&messages);
    if (!device) return 1;
    const uint32_t W = 64, H = 48;
    const float corners[6] = { -0.8f, -0.7f, 0.6f, -0.5f, -0.2f, 0.9f };   // clip space, +y up (Metal convention)
    const float colour[4] = { 51.0f / 255.0f, 102.0f / 255.0f, 204.0f / 255.0f, 1.0f };
    int failures = 0;
    {
        Status s;
        TextureDesc td;
        td.format = Format::RGBA8Unorm;
        td.width = W;
        td.height = H;
        td.usage = UsageRenderTarget | UsageCopySource;
        td.label = "triangle target";
        std::unique_ptr<Texture> target = device->makeTexture(td, &s);
        std::unique_ptr<Buffer> cornerBuffer = device->makeBuffer(sizeof corners, Memory::DeviceOnly, UsageStorage, &s);
        SlotLayout slots[2] = { { SlotKind::StorageBuffer, 0, false, true, false }, { SlotKind::UniformBlock, 1, false, false, true } };
        RenderDesc rd;
        rd.vertex.name = "bk_triangle_vertex";
        rd.fragment.name = "bk_triangle_fragment";
        rd.color[0].format = Format::RGBA8Unorm;
        rd.colorCount = 1;
        rd.slots = slots;
        rd.slotCount = 2;
        std::unique_ptr<RenderPipeline> pipeline = device->makeRender(rd, &s);
        if (!target || !cornerBuffer || !pipeline) { std::printf("FAIL: could not make the resources (status %d)\n", (int)s); return 1; }
        std::unique_ptr<CommandList> list = device->begin(&s);
        list->upload(*cornerBuffer, 0, corners, sizeof corners);
        PassTargets pass;
        pass.color[0] = target.get();
        pass.colorCount = 1;
        list->beginPass(pass);
        Binding b[2];
        b[0].kind = SlotKind::StorageBuffer; b[0].slot = 0; b[0].buffer = cornerBuffer.get();
        b[1].kind = SlotKind::UniformBlock; b[1].slot = 1; b[1].bytes = colour; b[1].byteCount = sizeof colour;
        if (list->draw(*pipeline, b, 2, 3) != Status::Ok) failures++;
        list->endPass();
        if (device->submit(*list, true) != Status::Ok) { std::printf("FAIL: submit\n"); return 1; }
        std::vector<uint8_t> pixels;
        if (!ReadTexture(*device, *target, &pixels, 4)) { std::printf("FAIL: readback\n"); return 1; }

        // CPU expectation: signed distance (pixels) of each pixel centre to the three edges, y down.
        float px[3], py[3];
        for (int i = 0; i < 3; i++) { px[i] = (corners[2 * i] + 1.0f) * 0.5f * W; py[i] = (1.0f - corners[2 * i + 1]) * 0.5f * H; }
        int inside = 0, outside = 0, edge = 0, wrong = 0;
        for (uint32_t y = 0; y < H; y++)
            for (uint32_t x = 0; x < W; x++) {
                double cx = x + 0.5, cy = y + 0.5, d = 1e9;
                for (int i = 0; i < 3; i++) {
                    int j = (i + 1) % 3;
                    double ex = px[j] - px[i], ey = py[j] - py[i];
                    // y down: the counter-clockwise (y up) triangle runs clockwise here -> inside = negative cross
                    double cross = ex * (cy - py[i]) - ey * (cx - px[i]);
                    d = std::fmin(d, -cross / std::sqrt(ex * ex + ey * ey));
                }
                const uint8_t *p = &pixels[(y * W + x) * 4];
                bool isColour = p[0] == 51 && p[1] == 102 && p[2] == 204 && p[3] == 255;
                bool isClear = p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 0;
                if (d > 0.75) { inside++; if (!isColour) wrong++; }
                else if (d < -0.75) { outside++; if (!isClear) wrong++; }
                else { edge++; if (!isColour && !isClear) wrong++; }
            }
        std::printf("triangle: %d inside, %d outside, %d edge pixels; %d wrong\n", inside, outside, edge, wrong);
        if (wrong) failures++;
        if (inside < 400) { std::printf("FAIL: triangle unexpectedly small\n"); failures++; }
    }
    device.reset();   // destroy everything first, so messages from the clean-up are counted too
    std::printf("validation messages: %d errors, %d warnings\n", messages.errors, messages.warnings);
    if (messages.errors || messages.warnings) failures++;
    std::printf("%s milestone 1 (a): triangle\n", failures ? "FAILED" : "PASSED");
    return failures ? 1 : 0;
}
