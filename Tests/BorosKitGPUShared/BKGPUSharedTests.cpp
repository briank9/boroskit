// BorosKit GPU tests shared by every backend - see BKGPUSharedTests.h.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan phase 2 / 3).

#include "BKGPUSharedTests.h"
#include "../BorosKitGoldenTests/BKGoldenCore.h"   // by path: this file is also compiled inside the XCTest target
#include "BKMeshDrawCore.h"
#include "BKMeshPass.h"
#include "BKMeshShaderTypes.h"
#include "BKSurfacePass.h"     // 2026-11-26: surface extraction on the shared interface
#include "BKRenderCore.h"      // the 16-bit storage of the scan (same as BKVolumeTexture)
// 2026-11-26 (7.1 #4): the ray caster - private headers of BorosKitRender, by path (also compiled in the XCTest target)
#include "../../Sources/BorosKitRender/BKRaycastPass.h"
#include "../../Sources/BorosKitRender/BKRenderParamsCore.h"
#include "../../Sources/BorosKitRender/BKReformatPass.h"   // 2026-11-26 (7.1 #5)
#include "../../Sources/BorosKitDisplay/BKDisplayPass.h"   // 2026-11-26 (7.1 #6)
#include "../../Sources/BorosKitDisplay/BKOverlayPass.h"
#include "BKDisplayGoldenScene.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <memory>

namespace bkshared {

using namespace boroskit;
using namespace boroskit::gpu;

namespace {

// What: a device buffer filled with `bytes` (upload through a command list).
std::unique_ptr<Buffer> UploadBuffer(Device &device, const void *data, uint64_t bytes, uint32_t usage)
{
    Status s;
    std::unique_ptr<Buffer> b = device.makeBuffer(bytes, Memory::DeviceOnly, usage, &s);
    if (!b) return nullptr;
    std::unique_ptr<CommandList> list = device.begin(&s);
    if (!list || list->upload(*b, 0, data, bytes) != Status::Ok || device.submit(*list, true) != Status::Ok) return nullptr;
    return b;
}

// What: a texture's bytes read back to the CPU (tight rows).
bool Read(Device &device, Texture &texture, uint32_t bytesPerTexel, std::vector<uint8_t> *out)
{
    const TextureDesc &d = texture.desc();
    uint64_t bytes = (uint64_t)d.width * d.height * d.depth * bytesPerTexel;
    Status s;
    std::unique_ptr<Buffer> b = device.makeBuffer(bytes, Memory::Readback, UsageCopyDestination, &s);
    if (!b) return false;
    std::unique_ptr<CommandList> list = device.begin(&s);
    if (!list || list->readback(texture, *b) != Status::Ok || device.submit(*list, true) != Status::Ok) return false;
    out->resize((size_t)bytes);
    std::memcpy(out->data(), b->map(), (size_t)bytes);
    b->unmap();
    return true;
}

// What: RGBA8 colour + R32F ray-distance targets of one size.
struct Targets {
    std::unique_ptr<Texture> color, distance;
    bool make(Device &device, uint32_t w, uint32_t h)
    {
        TextureDesc cd;
        cd.format = Format::RGBA8Unorm; cd.width = w; cd.height = h; cd.usage = UsageRenderTarget | UsageCopySource;
        TextureDesc dd = cd;
        dd.format = Format::R32Float;
        color = device.makeTexture(cd, nullptr);
        distance = device.makeTexture(dd, nullptr);
        return color && distance;
    }
};

// What: renders `items` with a MeshPass and reads both targets back. Returns the pass result (0 = fine) or -1.
int RenderItems(Device &device, meshpass::MeshPass &pass, const BKMeshCamera &camera, uint32_t w, uint32_t h,
                const std::vector<meshpass::Item> &items, std::vector<uint8_t> *rgba, std::vector<float> *distance)
{
    Targets t;
    if (!t.make(device, w, h)) return -1;
    meshpass::Frame frame;
    frame.camera = camera;
    frame.lighting = { 0.2f, 0.8f, 0.2f, 10.0f };   // BKMeshRenderer's defaults
    frame.color = t.color.get();
    frame.distance = t.distance.get();
    Status s;
    std::unique_ptr<CommandList> list = device.begin(&s);
    if (!list) return -1;
    int32_t r = pass.encode(*list, frame, items.data(), items.size());
    if (r != meshpass::Ok) return r;
    if (device.submit(*list, true) != Status::Ok) return -1;
    std::vector<uint8_t> d;
    if (!Read(device, *t.color, 4, rgba) || !Read(device, *t.distance, 4, &d)) return -1;
    distance->resize((size_t)w * h);
    std::memcpy(distance->data(), d.data(), d.size());
    return 0;
}

// What: a mesh made of triangles from plain position / index lists (no normals, white vertex colours), its buffers
// kept alive by `keep`, described as a BKMeshPass item with identity placement.
meshpass::Item MeshItem(Device &device, const std::vector<float> &positions, const std::vector<uint32_t> &indices,
                        const float *normals, std::vector<std::unique_ptr<Buffer>> &keep)
{
    size_t n = positions.size() / 3;
    std::vector<BKMeshGPUVertex> v(n);
    meshpass::Item it;
    it.boundsMin = BKV3f(INFINITY, INFINITY, INFINITY);
    it.boundsMax = BKV3f(-INFINITY, -INFINITY, -INFINITY);
    for (size_t i = 0; i < n; i++) {
        for (int a = 0; a < 3; a++) {
            v[i].position[a] = positions[3 * i + a];
            v[i].normal[a] = normals ? normals[3 * i + a] : 0.0f;
        }
        for (int a = 0; a < 4; a++) v[i].color[a] = 1.0f;
        const float *p = &positions[3 * i];
        it.boundsMin = BKV3f(std::fmin(it.boundsMin.x, p[0]), std::fmin(it.boundsMin.y, p[1]), std::fmin(it.boundsMin.z, p[2]));
        it.boundsMax = BKV3f(std::fmax(it.boundsMax.x, p[0]), std::fmax(it.boundsMax.y, p[1]), std::fmax(it.boundsMax.z, p[2]));
    }
    keep.push_back(UploadBuffer(device, v.data(), v.size() * sizeof(BKMeshGPUVertex), UsageStorage));
    it.vertices = keep.back().get();
    keep.push_back(UploadBuffer(device, indices.data(), indices.size() * sizeof(uint32_t), UsageIndex));
    it.indices = keep.back().get();
    it.indexCount = (uint32_t)indices.size();
    it.kind = meshpass::ItemKind::Mesh;
    it.hasNormals = normals ? 1 : 0;
    return it;
}

}  // namespace

// ---- Triangle ------------------------------------------------------------------------------------------------------

int TestTriangle(Device &device)
{
    const uint32_t W = 64, H = 48;
    const float corners[6] = { -0.8f, -0.7f, 0.6f, -0.5f, -0.2f, 0.9f };   // clip space, +y up (Metal convention)
    const float colour[4] = { 51.0f / 255.0f, 102.0f / 255.0f, 204.0f / 255.0f, 1.0f };   // exact 8-bit values
    Status s;
    TextureDesc td;
    td.format = Format::RGBA8Unorm; td.width = W; td.height = H; td.usage = UsageRenderTarget | UsageCopySource;
    std::unique_ptr<Texture> target = device.makeTexture(td, &s);
    std::unique_ptr<Buffer> cornerBuffer = UploadBuffer(device, corners, sizeof corners, UsageStorage);
    SlotLayout slots[2] = { { SlotKind::StorageBuffer, 0, false, true, false }, { SlotKind::UniformBlock, 1, false, false, true } };
    RenderDesc rd;
    rd.vertex.name = "bk_triangle_vertex";
    rd.fragment.name = "bk_triangle_fragment";
    rd.color[0].format = Format::RGBA8Unorm;
    rd.colorCount = 1;
    rd.slots = slots;
    rd.slotCount = 2;
    std::unique_ptr<RenderPipeline> pipeline = device.makeRender(rd, &s);
    if (!target || !cornerBuffer || !pipeline) { std::printf("FAIL triangle: resources (status %d)\n", (int)s); return 1; }
    std::unique_ptr<CommandList> list = device.begin(&s);
    PassTargets pass;
    pass.color[0] = target.get();
    pass.colorCount = 1;
    list->beginPass(pass);
    Binding b[2];
    b[0].kind = SlotKind::StorageBuffer; b[0].slot = 0; b[0].buffer = cornerBuffer.get();
    b[1].kind = SlotKind::UniformBlock; b[1].slot = 1; b[1].bytes = colour; b[1].byteCount = sizeof colour;
    int failures = list->draw(*pipeline, b, 2, 3) == Status::Ok ? 0 : 1;
    list->endPass();
    if (device.submit(*list, true) != Status::Ok) { std::printf("FAIL triangle: submit\n"); return 1; }
    std::vector<uint8_t> pixels;
    if (!Read(device, *target, 4, &pixels)) { std::printf("FAIL triangle: readback\n"); return 1; }
    float px[3], py[3];
    for (int i = 0; i < 3; i++) { px[i] = (corners[2 * i] + 1.0f) * 0.5f * W; py[i] = (1.0f - corners[2 * i + 1]) * 0.5f * H; }
    int inside = 0, outside = 0, edge = 0, wrong = 0;
    for (uint32_t y = 0; y < H; y++)
        for (uint32_t x = 0; x < W; x++) {
            double cx = x + 0.5, cy = y + 0.5, d = 1e9;
            for (int i = 0; i < 3; i++) {
                int j = (i + 1) % 3;
                double ex = px[j] - px[i], ey = py[j] - py[i];
                double cross = ex * (cy - py[i]) - ey * (cx - px[i]);   // y down: inside = negative
                d = std::fmin(d, -cross / std::sqrt(ex * ex + ey * ey));
            }
            const uint8_t *p = &pixels[(y * W + x) * 4];
            bool isColour = p[0] == 51 && p[1] == 102 && p[2] == 204 && p[3] == 255;
            bool isClear = p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 0;
            if (d > 0.75) { inside++; if (!isColour) wrong++; }
            else if (d < -0.75) { outside++; if (!isClear) wrong++; }
            else { edge++; if (!isColour && !isClear) wrong++; }
        }
    std::printf("triangle (%s): %d inside, %d outside, %d edge pixels; %d wrong\n", device.name(), inside, outside, edge, wrong);
    if (wrong || inside < 400) failures++;
    return failures;
}

// ---- Golden meshes ------------------------------------------------------------------------------------------------------

int TestGoldenMeshes(Device &device, const char *referencesDir, const char *outDir, const char *label, bool strict)
{
    std::string refs = referencesDir;
    BKGoldenMesh mesh;
    std::memset(&mesh, 0, sizeof mesh);
    if (bk_golden_read_mesh((refs + "/surface_bone_300.bkmesh").c_str(), &mesh) != 0) { std::printf("FAIL: no bone mesh\n"); return 1; }
    meshpass::MeshPass pass(device);
    std::vector<std::unique_ptr<Buffer>> keep;
    std::vector<float> positions(mesh.positions, mesh.positions + 3 * mesh.vertexCount);
    std::vector<uint32_t> indices(mesh.indices, mesh.indices + 3 * mesh.triangleCount);
    meshpass::Item base = MeshItem(device, positions, indices, mesh.normals, keep);
    int failures = 0;
    for (uint32_t i = 0; i < kBKGoldenMeshRenderCaseCount; i++) {
        const BKGoldenMeshRenderCase &c = kBKGoldenMeshRenderCases[i];
        BKMeshCamera camera;
        camera.projection = c.projection;
        camera.position = BKV3d(c.cameraPosition[0], c.cameraPosition[1], c.cameraPosition[2]);
        camera.direction = BKV3d(c.cameraDirection[0], c.cameraDirection[1], c.cameraDirection[2]);
        camera.up = BKV3d(c.cameraUp[0], c.cameraUp[1], c.cameraUp[2]);
        camera.viewWidth = c.viewWidth;
        camera.viewHeight = c.viewHeight;
        camera.fieldOfView = c.fieldOfView;
        meshpass::Item it = base;   // BKMeshObject's defaults for the golden case (BKGoldenMetal.m)
        it.color[0] = c.color[0]; it.color[1] = c.color[1]; it.color[2] = c.color[2];
        it.opacity = c.opacity;
        it.useVertexColors = 0;
        it.solid = c.opacity >= 1 ? 1 : 0;
        std::vector<uint8_t> rgba;
        std::vector<float> dist;
        int r = RenderItems(device, pass, camera, c.width, c.height, { it }, &rgba, &dist);
        std::string name = c.name;
        if (r != 0) { std::printf("GOLDEN | %s | FAIL: could not render (%d)\n", name.c_str(), r); failures++; continue; }
        BKGoldenImage mine = { c.width, c.height, 4, BKGoldenFormatU8, rgba.data() };
        BKGoldenImage mineD = { c.width, c.height, 1, BKGoldenFormatF32, dist.data() };
        if (outDir) {
            bk_golden_write_pam((std::string(outDir) + "/" + name + "." + label + ".rgba.pam").c_str(), &mine);
            bk_golden_write_pfm((std::string(outDir) + "/" + name + "." + label + ".distance.pfm").c_str(), &mineD);
        }
        BKGoldenImage ref, refD;
        std::memset(&ref, 0, sizeof ref);
        std::memset(&refD, 0, sizeof refD);
        if (bk_golden_read_pam((refs + "/" + name + ".rgba.pam").c_str(), &ref) != 0 ||
            bk_golden_read_pfm((refs + "/" + name + ".distance.pfm").c_str(), &refD) != 0) {
            std::printf("GOLDEN | %s | FAIL: reference missing\n", name.c_str());
            failures++;
            continue;
        }
        BKGoldenImageTolerance tc = strict ? BKGoldenImageTolerance{ 0, 0 } : bk_golden_tolerance_u8();
        BKGoldenImageTolerance td = strict ? BKGoldenImageTolerance{ 0, 0 } : BKGoldenImageTolerance{ 0.01, 0.005 };
        BKGoldenImageReport rc = bk_golden_compare_images(&ref, &mine, tc), rd = bk_golden_compare_images(&refD, &mineD, td);
        char text[256];
        bk_golden_describe_image_report(&rc, text, sizeof text);
        std::printf("GOLDEN | %s.rgba.pam | %s (MeshPass) vs Metal reference: %s\n", name.c_str(), label, text);
        bk_golden_describe_image_report(&rd, text, sizeof text);
        std::printf("GOLDEN | %s.distance.pfm | %s (MeshPass) vs Metal reference: %s\n", name.c_str(), label, text);
        if (!rc.pass || !rd.pass) failures++;
        bk_golden_image_free(&ref);
        bk_golden_image_free(&refD);
    }
    bk_golden_mesh_free(&mesh);
    return failures;
}

// ---- Winding -------------------------------------------------------------------------------------------------------

int TestWinding(Device &device)
{
    // Camera: in front of the x-z plane looking along +y, up +z -> on screen x right = +x, y up = +z (BKMeshCameraAxes).
    BKMeshCamera camera;
    std::memset(&camera, 0, sizeof camera);
    camera.projection = 0;
    camera.position = BKV3d(0, -10, 0); camera.direction = BKV3d(0, 1, 0); camera.up = BKV3d(0, 0, 1);
    camera.viewWidth = 20; camera.viewHeight = 10;
    const uint32_t W = 64, H = 32;
    // Left square x -8..-2 listed counter-clockwise on screen; right square x 2..8 listed clockwise.
    std::vector<float> left = { -8, 0, -3,  -2, 0, -3,  -2, 0, 3,  -8, 0, 3 };
    std::vector<float> right = { 2, 0, -3,  8, 0, -3,  8, 0, 3,  2, 0, 3 };
    std::vector<uint32_t> ccw = { 0, 1, 2, 0, 2, 3 }, cw = { 0, 2, 1, 0, 3, 2 };
    meshpass::MeshPass pass(device);
    std::vector<std::unique_ptr<Buffer>> keep;
    meshpass::Item a = MeshItem(device, left, ccw, nullptr, keep), b = MeshItem(device, right, cw, nullptr, keep);
    a.lit = b.lit = 0;   // flat colours: red and green exactly
    a.color[0] = 1; a.color[1] = 0; a.color[2] = 0;
    b.color[0] = 0; b.color[1] = 1; b.color[2] = 0;
    // The plain-C rule on the screen positions (x right, y up) of the first triangle of each square.
    BKVec2f la = BKV2f(-8, -3), lb = BKV2f(-2, -3), lc = BKV2f(-2, 3);
    BKVec2f ra = BKV2f(2, -3), rb = BKV2f(8, 3), rc = BKV2f(8, -3);
    const gpu::CullMode modes[3] = { gpu::CullMode::None, gpu::CullMode::Back, gpu::CullMode::Front };
    const int32_t coreModes[3] = { BKMeshCullNone, BKMeshCullBack, BKMeshCullFront };
    const char *names[3] = { "none", "back", "front" };
    int failures = 0;
    for (int m = 0; m < 3; m++) {
        a.cull = b.cull = modes[m];
        std::vector<uint8_t> rgba;
        std::vector<float> dist;
        if (RenderItems(device, pass, camera, W, H, { a, b }, &rgba, &dist) != 0) { std::printf("FAIL winding: render\n"); return failures + 1; }
        // Pixel centres of the squares: x -5 -> column 16, x 5 -> column 48; z 0 -> row 16.
        const uint8_t *pl = &rgba[(16 * W + 16) * 4], *pr = &rgba[(16 * W + 48) * 4];
        bool leftShown = pl[0] == 255 && pl[3] == 255, rightShown = pr[1] == 255 && pr[3] == 255;
        bool leftExpected = !BKMeshTriangleIsCulled(coreModes[m], la, lb, lc);
        bool rightExpected = !BKMeshTriangleIsCulled(coreModes[m], ra, rb, rc);
        bool ok = leftShown == leftExpected && rightShown == rightExpected;
        std::printf("winding (%s) cull %-5s: anticlockwise square %s, clockwise square %s - %s\n", device.name(), names[m],
                    leftShown ? "drawn" : "culled", rightShown ? "drawn" : "culled", ok ? "matches BKMeshTriangleIsCulled" : "FAIL");
        if (!ok) failures++;
    }
    return failures;
}

// ---- Compute: prefix sum ---------------------------------------------------------------------------------------------

int TestComputeScan(Device &device)
{
    const uint32_t count = 100003;
    std::vector<uint32_t> values(count), expected(count);
    uint32_t state = 20261126u, sum = 0;
    for (uint32_t i = 0; i < count; i++) {
        state = state * 1664525u + 1013904223u;   // a fixed linear congruential sequence (exact, platform-independent)
        values[i] = state >> 22;                  // 0..1023
        expected[i] = sum;
        sum += values[i];
    }
    int failures = 0;
    const uint32_t sizes[2] = { 256, 64 };
    for (uint32_t n : sizes) {
        SlotLayout slots[5] = { { SlotKind::StorageBuffer, 0, false, false, false }, { SlotKind::StorageBuffer, 1, false, false, false },
                                { SlotKind::StorageBuffer, 2, true, false, false }, { SlotKind::StorageBuffer, 3, true, false, false },
                                { SlotKind::StorageBuffer, 4, true, false, false } };
        const char *names[3] = { "bk_test_scan_blocks", "bk_test_scan_sums", "bk_test_scan_add" };
        std::unique_ptr<ComputePipeline> k[3];
        Status s = Status::Ok;
        for (int i = 0; i < 3 && s == Status::Ok; i++) {
            ComputeDesc cd;
            cd.kernel.name = names[i];
            cd.workgroup[0] = n;
            cd.slots = slots;
            cd.slotCount = 5;
            k[i] = device.makeCompute(cd, &s);
        }
        if (s != Status::Ok) { std::printf("FAIL compute (%s, %u threads): pipelines (status %d)\n", device.name(), n, (int)s); failures++; continue; }
        uint32_t blocks = (count + n - 1) / n;
        std::unique_ptr<Buffer> in = UploadBuffer(device, values.data(), count * 4, UsageStorage);
        std::unique_ptr<Buffer> out = device.makeBuffer(count * 4, Memory::Readback, UsageStorage, nullptr);
        std::unique_ptr<Buffer> sums = device.makeBuffer(blocks * 4, Memory::DeviceOnly, UsageStorage, nullptr);
        std::unique_ptr<Buffer> starts = device.makeBuffer(blocks * 4, Memory::DeviceOnly, UsageStorage, nullptr);
        if (!in || !out || !sums || !starts) { std::printf("FAIL compute: buffers\n"); failures++; continue; }
        const uint32_t params[2] = { count, blocks };
        Binding b[5];
        b[0].kind = SlotKind::StorageBuffer; b[0].slot = 0; b[0].bytes = params; b[0].byteCount = sizeof params;
        Buffer *bufs[4] = { in.get(), out.get(), sums.get(), starts.get() };
        for (int i = 0; i < 4; i++) { b[i + 1].kind = SlotKind::StorageBuffer; b[i + 1].slot = (uint32_t)i + 1; b[i + 1].buffer = bufs[i]; }
        std::unique_ptr<CommandList> list = device.begin(&s);
        bool ok = list && list->dispatch(*k[0], b, 5, blocks, 1, 1) == Status::Ok &&
                  list->dispatch(*k[1], b, 5, 1, 1, 1) == Status::Ok &&
                  list->dispatch(*k[2], b, 5, blocks, 1, 1) == Status::Ok && device.submit(*list, true) == Status::Ok;
        if (!ok) { std::printf("FAIL compute (%s, %u threads): dispatch\n", device.name(), n); failures++; continue; }
        const uint32_t *got = (const uint32_t *)out->map();
        uint32_t wrong = 0, first = UINT32_MAX;
        for (uint32_t i = 0; i < count; i++) if (got[i] != expected[i]) { if (first == UINT32_MAX) first = i; wrong++; }
        out->unmap();
        std::printf("compute (%s) prefix sum of %u numbers, %u threads per group: %u wrong%s\n", device.name(), count, n, wrong,
                    wrong ? " - FAIL" : " (exact)");
        if (wrong) { std::printf("   first wrong at %u\n", first); failures++; }
    }
    return failures;
}

// ---- Feature scene (cross-backend) ---------------------------------------------------------------------------------

bool RenderFeatureScene(Device &device, std::vector<uint8_t> *rgba, std::vector<float> *distance, uint32_t parts)
{
    BKMeshCamera camera;
    std::memset(&camera, 0, sizeof camera);
    camera.projection = 1;   // perspective: exercises the line / point near-distance rules too
    camera.position = BKV3d(-20, -110, 25); camera.direction = BKV3d(20, 110, -25); camera.up = BKV3d(0, 0, 1);
    camera.fieldOfView = 30;
    meshpass::MeshPass pass(device);
    std::vector<std::unique_ptr<Buffer>> keep;
    std::vector<std::unique_ptr<Texture>> textures;
    std::vector<meshpass::Item> items;
    // Two textured quads: 2 x 2 texture (red, green / blue, white), nearest + repeat and linear + clamp.
    const uint8_t texels[16] = { 255, 0, 0, 255,  0, 255, 0, 255,  0, 0, 255, 255,  255, 255, 255, 255 };
    TextureDesc td;
    td.format = Format::RGBA8Unorm; td.width = 2; td.height = 2; td.usage = UsageSampled | UsageCopyDestination;
    textures.push_back(device.makeTexture(td, nullptr));
    if (!textures.back()) return false;
    {
        Status s;
        std::unique_ptr<CommandList> list = device.begin(&s);
        if (!list || list->upload(*textures.back(), texels, 8, 16, 0, 1) != Status::Ok || device.submit(*list, true) != Status::Ok) return false;
    }
    const float normalsY[12] = { 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0 };
    for (int q = 0; q < 2 && (parts & kFeatureTextured); q++) {
        float x0 = q ? 5.0f : -25.0f, x1 = x0 + 20.0f;
        std::vector<float> p = { x0, 0, 0,  x1, 0, 0,  x1, 0, 20,  x0, 0, 20 };
        meshpass::Item it = MeshItem(device, p, { 0, 1, 2, 0, 2, 3 }, normalsY, keep);
        const float st[8] = { q ? -0.5f : 0.0f, q ? -0.5f : 0.0f,  q ? 1.5f : 2.0f, q ? -0.5f : 0.0f,
                              q ? 1.5f : 2.0f, q ? 1.5f : 2.0f,  q ? -0.5f : 0.0f, q ? 1.5f : 2.0f };
        keep.push_back(UploadBuffer(device, st, sizeof st, UsageStorage));
        it.textureCoordinates = keep.back().get();
        it.texture = textures.back().get();
        it.samplerIndex = q ? 2 : 1;   // linear + clamp / nearest + repeat
        it.color[0] = 0.9f; it.color[1] = 0.9f; it.color[2] = 0.9f;
        items.push_back(it);
    }
    // A see-through blue quad behind (two-pass), a wireframe quad, and a back-culled clockwise square (hidden).
    if (parts & kFeatureMeshes) {
        std::vector<float> p = { -25, 10, -25,  25, 10, -25,  25, 10, -5,  -25, 10, -5 };
        meshpass::Item it = MeshItem(device, p, { 0, 1, 2, 0, 2, 3 }, normalsY, keep);
        it.color[0] = 0.2f; it.color[1] = 0.4f; it.color[2] = 1.0f; it.opacity = 0.5f; it.solid = 0;
        items.push_back(it);
        std::vector<float> w = { -10, -5, -20,  10, -5, -20,  10, -5, -10,  -10, -5, -10 };
        meshpass::Item wf = MeshItem(device, w, { 0, 1, 2, 0, 2, 3 }, normalsY, keep);
        wf.wireframe = 1; wf.lit = 0; wf.color[0] = 1; wf.color[1] = 0.5f; wf.color[2] = 0;
        items.push_back(wf);
        std::vector<float> c = { -4, -8, 22,  4, -8, 22,  4, -8, 28,  -4, -8, 28 };
        meshpass::Item cu = MeshItem(device, c, { 0, 2, 1, 0, 3, 2 }, nullptr, keep);
        cu.cull = gpu::CullMode::Back; cu.lit = 0;
        items.push_back(cu);
    }
    // Lines (solid yellow 3 px, see-through cyan 5 px) and points (6 px magenta, one behind the eye).
    auto pointsItem = [&](meshpass::ItemKind kind, std::vector<float> pts, float halfWidth, float r, float g, float b, float opacity) {
        meshpass::Item it;
        it.kind = kind;
        keep.push_back(UploadBuffer(device, pts.data(), pts.size() * sizeof(float), UsageStorage));
        it.vertices = keep.back().get();
        size_t n = pts.size() / 3;
        it.vertexCount = (uint32_t)(kind == meshpass::ItemKind::Lines ? n / 2 * 6 : n * 6);
        it.boundsMin = BKV3f(INFINITY, INFINITY, INFINITY);
        it.boundsMax = BKV3f(-INFINITY, -INFINITY, -INFINITY);
        for (size_t i = 0; i < n; i++) {
            it.boundsMin = BKV3f(std::fmin(it.boundsMin.x, pts[3 * i]), std::fmin(it.boundsMin.y, pts[3 * i + 1]), std::fmin(it.boundsMin.z, pts[3 * i + 2]));
            it.boundsMax = BKV3f(std::fmax(it.boundsMax.x, pts[3 * i]), std::fmax(it.boundsMax.y, pts[3 * i + 1]), std::fmax(it.boundsMax.z, pts[3 * i + 2]));
        }
        it.lineHalfWidth = halfWidth;
        it.color[0] = r; it.color[1] = g; it.color[2] = b;
        it.opacity = opacity;
        it.solid = opacity >= 1 ? 1 : 0;
        items.push_back(it);
    };
    if (parts & kFeatureLines) {
        pointsItem(meshpass::ItemKind::Lines, { -28, -5, -28,  28, -5, 28,  -28, -5, 28,  28, -5, -28 }, 1.5f, 1, 1, 0, 1);
        pointsItem(meshpass::ItemKind::Lines, { -20, -2, 0,  20, -200, 0 }, 2.5f, 0, 1, 1, 0.6f);   // reaches behind the eye
    }
    if (parts & kFeaturePoints)
        pointsItem(meshpass::ItemKind::Points, { -15, -6, 15,  0, -6, 0,  15, -6, -15,  0, -300, 0 }, 3, 1, 0, 1, 1);
    return RenderItems(device, pass, camera, 96, 80, items, rgba, distance) == 0;
}

// ---- Feature scene golden references (2026-11-26, phase 3/4 step 2) ------------------------------------------------

const FeatureGoldenCase kFeatureGoldenCases[kFeatureGoldenCaseCount] = {
    { "feature_textured", kFeatureTextured },
    { "feature_lines", kFeatureLines },
    { "feature_points", kFeaturePoints },
    { "feature_scene", kFeatureAll },
};

int TestGoldenFeatures(Device &device, const char *referencesDir, const char *outDir, const char *label, bool strict, bool record)
{
    int failures = 0;
    const std::string refs = referencesDir;
    for (uint32_t i = 0; i < kFeatureGoldenCaseCount; i++) {
        const FeatureGoldenCase &c = kFeatureGoldenCases[i];
        std::vector<uint8_t> rgba;
        std::vector<float> dist;
        if (!RenderFeatureScene(device, &rgba, &dist, c.parts)) { std::printf("GOLDEN | %s | FAIL: could not render\n", c.name); failures++; continue; }
        BKGoldenImage mine = { kFeatureWidth, kFeatureHeight, 4, BKGoldenFormatU8, rgba.data() };
        BKGoldenImage mineD = { kFeatureWidth, kFeatureHeight, 1, BKGoldenFormatF32, dist.data() };
        const std::string pam = refs + "/" + c.name + ".rgba.pam", pfm = refs + "/" + c.name + ".distance.pfm";
        if (record) {   // only ever from the Metal reference backend (XCTest with BK_GOLDEN_RECORD=1)
            if (bk_golden_write_pam(pam.c_str(), &mine) != 0 || bk_golden_write_pfm(pfm.c_str(), &mineD) != 0) failures++;
            std::printf("GOLDEN | %s | recorded from %s\n", c.name, label);
            continue;
        }
        if (outDir) {
            bk_golden_write_pam((std::string(outDir) + "/" + c.name + "." + label + ".rgba.pam").c_str(), &mine);
            bk_golden_write_pfm((std::string(outDir) + "/" + c.name + "." + label + ".distance.pfm").c_str(), &mineD);
        }
        BKGoldenImage ref, refD;
        std::memset(&ref, 0, sizeof ref);
        std::memset(&refD, 0, sizeof refD);
        if (bk_golden_read_pam(pam.c_str(), &ref) != 0 || bk_golden_read_pfm(pfm.c_str(), &refD) != 0) {
            std::printf("GOLDEN | %s | FAIL: reference missing (record with BK_GOLDEN_RECORD=1 on the Mac)\n", c.name);
            bk_golden_image_free(&ref);
            failures++;
            continue;
        }
        BKGoldenImageTolerance tc = strict ? BKGoldenImageTolerance{ 0, 0 } : bk_golden_tolerance_u8();
        BKGoldenImageTolerance td = strict ? BKGoldenImageTolerance{ 0, 0 } : BKGoldenImageTolerance{ 0.01, 0.005 };
        BKGoldenImageReport rc = bk_golden_compare_images(&ref, &mine, tc), rd = bk_golden_compare_images(&refD, &mineD, td);
        char text[256];
        bk_golden_describe_image_report(&rc, text, sizeof text);
        std::printf("GOLDEN | %s.rgba.pam | %s vs Metal reference: %s\n", c.name, label, text);
        bk_golden_describe_image_report(&rd, text, sizeof text);
        std::printf("GOLDEN | %s.distance.pfm | %s vs Metal reference: %s\n", c.name, label, text);
        if (!rc.pass || !rd.pass) failures++;
        bk_golden_image_free(&ref);
        bk_golden_image_free(&refD);
    }
    return failures;
}

// ---- Surface extraction (2026-11-26, phase 3/4 step 3) --------------------------------------------------------------

namespace {
struct SurfaceSink { BKGoldenMesh mesh; };
BKSurfaceStatus CopySurface(void *context, uint32_t, const boroskit::surface::MeshView &view)
{
    BKGoldenMesh &m = static_cast<SurfaceSink *>(context)->mesh;
    m.vertexCount = view.vertexCount;
    m.triangleCount = view.triangleCount;
    m.positions = (float *)std::malloc(12 * view.vertexCount + 4);
    m.normals = (float *)std::malloc(12 * view.vertexCount + 4);
    m.indices = (uint32_t *)std::malloc(12 * view.triangleCount + 4);
    if (!m.positions || !m.normals || !m.indices) return BKSurfaceStatusOutOfMemory;
    for (uint64_t v = 0; v < view.vertexCount; v++)
        for (int a = 0; a < 3; a++) {
            m.positions[3 * v + a] = view.positions[4 * v + a];
            m.normals[3 * v + a] = view.normals[4 * v + a];
        }
    if (view.triangleCount) std::memcpy(m.indices, view.indices, 12 * view.triangleCount);
    return BKSurfaceStatusOK;
}
}  // namespace

int TestSurfacePass(Device &device, const char *referencesDir, const char *label, bool strict)
{
    BKGoldenVolume vol;
    std::memset(&vol, 0, sizeof vol);
    if (bk_golden_make_head_phantom(&vol) != 0) { std::printf("FAIL surface: phantom\n"); return 1; }
    const size_t n = (size_t)vol.width * vol.height * vol.depth;
    float lo = INFINITY, hi = -INFINITY;
    for (size_t i = 0; i < n; i++) { lo = std::fmin(lo, vol.voxels[i]); hi = std::fmax(hi, vol.voxels[i]); }
    BKRenderQuantization q = BKRenderQuantizationForRange(lo, hi, BKRenderAllIntegral(vol.voxels, n));
    std::vector<uint16_t> steps(n);
    BKRenderQuantizeToSteps(vol.voxels, n, q, steps.data());
    std::vector<float> stepValues(steps.begin(), steps.end());   // for the CPU reference

    int failures = 0;
    TextureDesc td;
    td.type = TextureType::Texture3D;
    td.format = Format::R16Unorm;
    td.width = vol.width; td.height = vol.height; td.depth = vol.depth;
    td.usage = UsageSampled | UsageCopyDestination;
    td.label = "surface test scan";
    std::unique_ptr<Texture> scan = device.makeTexture(td, nullptr);
    Status s = Status::Ok;
    std::unique_ptr<CommandList> list = scan ? device.begin(&s) : nullptr;
    if (!list || list->upload(*scan, steps.data(), vol.width * 2, vol.width * vol.height * 2, 0, vol.depth) != Status::Ok ||
        device.submit(*list, true) != Status::Ok) {
        std::printf("FAIL surface (%s): scan upload\n", label);
        bk_golden_volume_free(&vol);
        return 1;
    }
    boroskit::surface::SurfacePass pass(device);
    BKSurfaceStatus st = pass.prepare();
    if (st != BKSurfaceStatusOK) { std::printf("FAIL surface (%s): prepare (%d)\n", label, (int)st); bk_golden_volume_free(&vol); return 1; }

    const std::string refs = referencesDir;
    for (uint32_t i = 0; i < kBKGoldenSurfaceCaseCount; i++) {
        const BKGoldenSurfaceCase &c = kBKGoldenSurfaceCases[i];
        BKSurfacePlanRequest rq;
        std::memset(&rq, 0, sizeof rq);
        rq.volumeWidth = vol.width; rq.volumeHeight = vol.height; rq.volumeDepth = vol.depth;
        rq.resolution = c.resolution;
        rq.smoothingSigma = c.smoothing;
        rq.sampling = c.manualSampling ? BK_SURFACE_SAMPLING_MANUAL : BK_SURFACE_SAMPLING_HARDWARE;
        std::memcpy(rq.voxelToOutput, vol.voxelToPatient, sizeof rq.voxelToOutput);
        float threshold = BKSurfaceThresholdToSteps(c.threshold, q.valueScale, q.valueOffset);
        SurfaceSink sink;
        std::memset(&sink, 0, sizeof sink);
        boroskit::surface::Stats stats;
        st = pass.extract(*scan, rq, &threshold, 1, CopySurface, &sink, &stats);
        if (st != BKSurfaceStatusOK) { std::printf("SURFACE | %s | %s: FAIL extract (%d)\n", c.name, label, (int)st); failures++; bk_golden_mesh_free(&sink.mesh); continue; }
        const BKGoldenMeshTolerance tol = { { vol.spacing[0], vol.spacing[1], vol.spacing[2] }, strict ? 0.0 : 1e-4, strict ? 0.0 : 1e-3 };
        char text[256];
        BKGoldenMesh ref;
        std::memset(&ref, 0, sizeof ref);
        if (bk_golden_read_mesh((refs + "/" + c.name + ".bkmesh").c_str(), &ref) != 0) {
            std::printf("SURFACE | %s | FAIL: reference missing\n", c.name);
            failures++;
        } else {
            BKGoldenMeshReport r = bk_golden_compare_meshes(&ref, &sink.mesh, tol);
            bk_golden_describe_mesh_report(&r, text, sizeof text);
            std::printf("SURFACE | %s | %s (SurfacePass, %llu vertices, %llu triangles) vs Metal reference: %s\n", c.name, label,
                        (unsigned long long)sink.mesh.vertexCount, (unsigned long long)sink.mesh.triangleCount, text);
            if (!r.pass) failures++;
        }
        bk_golden_mesh_free(&ref);
        // CPU reference (double precision, one thread) where it applies: the voxel grid itself, no smoothing.
        if (c.resolution == 1.0f && c.smoothing == 0.0f) {
            BKSurfaceMeshData cpu;
            std::memset(&cpu, 0, sizeof cpu);
            if (BKSurfaceReferenceExtract(stepValues.data(), vol.width, vol.height, vol.depth, threshold, vol.voxelToPatient, &cpu) != BKSurfaceStatusOK) {
                std::printf("SURFACE | %s | FAIL: CPU reference\n", c.name);
                failures++;
            } else {
                SurfaceSink cs;
                std::memset(&cs, 0, sizeof cs);
                boroskit::surface::MeshView v;
                v.positions = cpu.positions; v.normals = cpu.normals; v.indices = cpu.indices;
                v.vertexCount = cpu.vertexCount; v.triangleCount = cpu.triangleCount;
                CopySurface(&cs, 0, v);
                const BKGoldenMeshTolerance cpuTol = { { vol.spacing[0], vol.spacing[1], vol.spacing[2] }, 1e-4, 1e-3 };
                BKGoldenMeshReport r = bk_golden_compare_meshes(&cs.mesh, &sink.mesh, cpuTol);
                bk_golden_describe_mesh_report(&r, text, sizeof text);
                std::printf("SURFACE | %s | CPU reference vs %s: %s\n", c.name, label, text);
                if (!r.pass) failures++;
                bk_golden_mesh_free(&cs.mesh);
            }
            BKSurfaceMeshDataFree(&cpu);
        }
        bk_golden_mesh_free(&sink.mesh);
    }
    bk_golden_volume_free(&vol);
    return failures;
}

// ---- Volume ray casting (2026-11-26, Vulkan plan 7.1 #4c) ----------------------------------------------------------

bool RenderRaycastCases(Device &device, bool manualFiltering, std::vector<RaycastCaseOutput> *out)
{
    out->clear();
    BKGoldenVolume vol;
    std::memset(&vol, 0, sizeof vol);
    if (bk_golden_make_head_phantom(&vol) != 0) return false;
    const size_t n = (size_t)vol.width * vol.height * vol.depth;
    float lo = INFINITY, hi = -INFINITY;
    for (size_t i = 0; i < n; i++) { lo = std::fmin(lo, vol.voxels[i]); hi = std::fmax(hi, vol.voxels[i]); }
    // Stored exactly like BKVolumeTexture (the golden test testVolumeStorageMatchesCore proves it).
    BKRenderQuantization q = BKRenderQuantizationForRange(lo, hi, BKRenderAllIntegral(vol.voxels, n));
    std::vector<uint16_t> steps(n);
    BKRenderQuantizeToSteps(vol.voxels, n, q, steps.data());
    bool ok = false;
    do {
        TextureDesc td;
        td.type = TextureType::Texture3D;
        td.format = Format::R16Unorm;
        td.width = vol.width; td.height = vol.height; td.depth = vol.depth;
        td.usage = UsageSampled | UsageCopyDestination;
        td.label = "raycast test scan";
        std::unique_ptr<Texture> scan = device.makeTexture(td, nullptr);
        std::unique_ptr<CommandList> list = scan ? device.begin(nullptr) : nullptr;
        if (!list || list->upload(*scan, steps.data(), vol.width * 2, vol.width * vol.height * 2, 0, vol.depth) != Status::Ok ||
            device.submit(*list, true) != Status::Ok) break;
        boroskit::render::RaycastPass pass(device);
        if (pass.prepare() != Status::Ok) break;

        // The two tables: the golden "bone + soft tissue" function, and the default grey ramp over the scan's range.
        BKRenderTFPoint color[16], opacity[16];
        size_t nc = 0, no = 0;
        for (uint32_t i = 0; i < kBKGoldenColorPointCount; i++) {
            const BKGoldenColorPoint &c = kBKGoldenColorPoints[i];
            BKRenderTFPoint pt = { c.value, { c.red, c.green, c.blue } };
            nc = BKRenderTFInsertPoint(color, nc, 16, pt);
        }
        for (uint32_t i = 0; i < kBKGoldenOpacityPointCount; i++) {
            BKRenderTFPoint pt = { kBKGoldenOpacityPoints[i].value, { kBKGoldenOpacityPoints[i].opacity, 0, 0 } };
            no = BKRenderTFInsertPoint(opacity, no, 16, pt);
        }
        BKRenderTFPoint rampColor[2] = { { lo, { 0, 0, 0 } }, { hi, { 1, 1, 1 } } }, rampOpacity[2] = { { lo, { 0, 0, 0 } }, { hi, { 1, 0, 0 } } };
        std::vector<float> rgbaGolden(BK_TRANSFER_FUNCTION_ENTRIES * 4), rgbaRamp(BK_TRANSFER_FUNCTION_ENTRIES * 4);
        BKRenderTFBake(color, nc, opacity, no, rgbaGolden.data(), BK_TRANSFER_FUNCTION_ENTRIES);
        BKRenderTFBake(rampColor, 2, rampOpacity, 2, rgbaRamp.data(), BK_TRANSFER_FUNCTION_ENTRIES);
        std::unique_ptr<Texture> tableGolden, tableRamp;
        std::unique_ptr<Buffer> countGolden, countRamp;
        if (pass.makeTable(rgbaGolden.data(), &tableGolden, &countGolden) != Status::Ok ||
            pass.makeTable(rgbaRamp.data(), &tableRamp, &countRamp) != Status::Ok) break;
        uint32_t grid[3];
        BKRenderBrickGrid(vol.width, vol.height, vol.depth, BK_BRICK_SIZE, grid);
        std::unique_ptr<Buffer> ranges = pass.makeBrickRanges(*scan, grid, nullptr);
        if (!ranges) break;

        ok = true;
        for (uint32_t i = 0; i < kBKGoldenVolumeCaseCount && ok; i++) {
            const BKGoldenVolumeCase &c = kBKGoldenVolumeCases[i];
            // The settings exactly as the golden producer (BKGoldenMetal.m) gives them to BKVolumeRenderer.
            BKRenderSettings st;
            std::memset(&st, 0, sizeof st);
            st.volumeSize[0] = vol.width; st.volumeSize[1] = vol.height; st.volumeSize[2] = vol.depth;
            std::memcpy(st.patientToVoxel, vol.patientToVoxel, sizeof st.patientToVoxel);
            st.minPixelSpacing = vol.minSpacing;
            st.valueScale = q.valueScale; st.valueOffset = q.valueOffset; st.outOfBoundsValue = vol.outOfBoundsValue;
            st.mode = c.mode; st.projection = c.projection;
            for (int a = 0; a < 3; a++) {
                st.cameraPosition[a] = c.cameraPosition[a]; st.cameraDirection[a] = c.cameraDirection[a]; st.cameraUp[a] = c.cameraUp[a];
                st.slabPoint[a] = c.slabPoint[a]; st.slabNormal[a] = c.slabNormal[a];
                st.cropMax[a] = (double)st.volumeSize[a] - 1.0;   // a fresh volume: the whole scan
            }
            st.clipNormal[2] = 1.0;
            st.viewWidth = c.viewWidth; st.viewHeight = c.viewHeight; st.fieldOfView = c.fieldOfView;
            st.sampleSpacing = c.sampleSpacing;
            st.slabEnabled = c.slabEnabled; st.slabThickness = c.slabThickness;
            for (int32_t k = 0; k < c.clipPlaneCount && k < 2; k++) {   // BKClipPlanesPack: unit normal (double), w = -n.point
                const double *pl = c.clipPlanes[k];
                double len = std::sqrt(pl[3] * pl[3] + pl[4] * pl[4] + pl[5] * pl[5]);
                double nx = pl[3] / len, ny = pl[4] / len, nz = pl[5] / len;
                st.clipPlanes[4 * k + 0] = (float)nx; st.clipPlanes[4 * k + 1] = (float)ny; st.clipPlanes[4 * k + 2] = (float)nz;
                st.clipPlanes[4 * k + 3] = (float)(-(nx * pl[0] + ny * pl[1] + nz * pl[2]));
                st.clipPlaneCount++;
            }
            const bool golden = c.useTransferFunction != 0;
            st.tfMin = golden ? BKRenderTFMinimumValue(color, nc, opacity, no) : BKRenderTFMinimumValue(rampColor, 2, rampOpacity, 2);
            st.tfMax = golden ? BKRenderTFMaximumValue(color, nc, opacity, no) : BKRenderTFMaximumValue(rampColor, 2, rampOpacity, 2);
            st.windowCenter = c.windowCenter; st.windowWidth = c.windowWidth;
            st.missValue = NAN;
            st.opacityUnitDistance = c.opacityUnitDistance;
            st.shading = c.shading;
            st.ambient = 0.2f; st.diffuse = 0.8f; st.specular = 0.2f; st.specularPower = 10;   // BKVolumeRenderer defaults
            st.manualFiltering = manualFiltering ? 1 : 0;
            st.blendOpacityUnitDistance = 1;
            BKRenderParams p;
            if (BKRenderParamsFill(&st, c.width, c.height, &p) != BKRenderParamsOK) { ok = false; break; }

            boroskit::render::RaycastInputs in;
            in.volume = scan.get();
            in.table = golden ? tableGolden.get() : tableRamp.get();
            std::unique_ptr<CommandList> cl = device.begin(nullptr);
            if (!cl) { ok = false; break; }
            std::unique_ptr<Buffer> empty;
            if (c.skipEmptySpace && boroskit::render::RaycastPass::WantsSkipping(true, p)) {
                p.brickGrid = bk_make_float4((float)grid[0], (float)grid[1], (float)grid[2], 0.0f);
                if (p.mode == 0) {
                    empty = pass.encodeClassify(*cl, p, *ranges, golden ? *countGolden : *countRamp, nullptr);
                    if (!empty) { ok = false; break; }
                    in.brickEmpty = empty.get();
                }
                in.brickRange = ranges.get();
                p.skipEmptySpace = 1;
            }
            const uint32_t pixels = c.width * c.height;
            std::unique_ptr<Buffer> colors = device.makeBuffer(pixels * 4, Memory::Readback, UsageStorage, nullptr);
            std::unique_ptr<Buffer> values = device.makeBuffer(pixels * 4, Memory::Readback, UsageStorage, nullptr);
            if (!colors || !values || pass.encodeRaycast(*cl, p, in, *colors, *values) != Status::Ok ||
                device.submit(*cl, true) != Status::Ok) { ok = false; break; }
            // SlabPass (values-only path, 2026-11-26): the same parameters, values only - must equal the full render.
            std::unique_ptr<Buffer> slabValues = device.makeBuffer(pixels * 4, Memory::Readback, UsageStorage, nullptr);
            std::unique_ptr<CommandList> sl = device.begin(nullptr);
            if (!slabValues || !sl || pass.encodeValues(*sl, p, in, *slabValues) != Status::Ok || device.submit(*sl, true) != Status::Ok) {
                ok = false;
                break;
            }
            RaycastCaseOutput o;
            o.valuesOnlyIdentical = std::memcmp(slabValues->map(), values->map(), pixels * 4) == 0;
            slabValues->unmap();
            values->unmap();
            o.name = c.name;
            o.width = c.width; o.height = c.height; o.mode = c.mode;
            const uint8_t *rgba = (const uint8_t *)colors->map();
            const float *v = (const float *)values->map();
            o.rgba.assign(rgba, rgba + pixels * 4);
            o.values.assign(v, v + pixels);
            colors->unmap();
            values->unmap();
            out->push_back(std::move(o));
        }
    } while (false);
    bk_golden_volume_free(&vol);
    return ok;
}

int TestRaycastPass(Device &device, const char *referencesDir, const char *outDir, const char *label, bool strict)
{
    int failures = 0;
    const std::string refs = referencesDir;
    for (int manual = 0; manual < 2; manual++) {
        std::vector<RaycastCaseOutput> cases;
        if (!RenderRaycastCases(device, manual != 0, &cases)) {
            std::printf("RAYCAST | %s | FAIL: could not render\n", label);
            return failures + 1;
        }
        for (const RaycastCaseOutput &o : cases) {
            BKGoldenImage mine = { o.width, o.height, 4, BKGoldenFormatU8, (void *)o.rgba.data() };
            BKGoldenImage mineV = { o.width, o.height, 1, BKGoldenFormatF32, (void *)o.values.data() };
            if (outDir) {
                std::string stem = std::string(outDir) + "/" + o.name + "." + label + (manual ? ".manual" : "");
                bk_golden_write_pam((stem + ".rgba.pam").c_str(), &mine);
                bk_golden_write_pfm((stem + ".values.pfm").c_str(), &mineV);
            }
            BKGoldenImage ref, refV;
            std::memset(&ref, 0, sizeof ref);
            std::memset(&refV, 0, sizeof refV);
            if (bk_golden_read_pam((refs + "/" + o.name + ".rgba.pam").c_str(), &ref) != 0 ||
                bk_golden_read_pfm((refs + "/" + o.name + ".values.pfm").c_str(), &refV) != 0) {
                std::printf("RAYCAST | %s | FAIL: reference missing\n", o.name.c_str());
                bk_golden_image_free(&ref);
                failures++;
                continue;
            }
            // The golden tolerances: colour +-1 grey level (0.5 % outliers); values: composite one 8-bit step of
            // opacity, projections 1 HU. Manual filtering vs the (hardware-filtered) references: the "different
            // filter" allowance of testManualFilteringMatchesReferences (2 steps / 1/256 of the value range).
            float vlo = INFINITY, vhi = -INFINITY;
            const float *rv = (const float *)refV.data;
            for (uint32_t k = 0; k < o.width * o.height; k++) if (std::isfinite(rv[k])) { vlo = std::fmin(vlo, rv[k]); vhi = std::fmax(vhi, rv[k]); }
            double range = vhi > vlo ? (double)vhi - vlo : 1.0;
            BKGoldenImageTolerance vt = manual ? BKGoldenImageTolerance{ o.mode == 0 ? 2.0 / 255.0 : range / 256.0, 0.005 }
                                               : BKGoldenImageTolerance{ o.mode == 0 ? 1.0 / 255.0 : 1.0, 0.005 };
            if (strict && !manual) vt = BKGoldenImageTolerance{ 0, 0 };
            BKGoldenImageReport rc = bk_golden_compare_images(&ref, &mine, strict && !manual ? BKGoldenImageTolerance{ 0, 0 } : bk_golden_tolerance_u8());
            BKGoldenImageReport rd = bk_golden_compare_images(&refV, &mineV, vt);
            char a[256], b[256];
            bk_golden_describe_image_report(&rc, a, sizeof a);
            bk_golden_describe_image_report(&rd, b, sizeof b);
            std::printf("RAYCAST | %s | %s%s vs Metal reference: colour %s; values %s; values-only (slab) path %s\n", o.name.c_str(), label,
                        manual ? " (manual filtering)" : "", a, b, o.valuesOnlyIdentical ? "identical" : "DIFFERENT - FAIL");
            if (!rc.pass || !rd.pass || !o.valuesOnlyIdentical) failures++;
            bk_golden_image_free(&ref);
            bk_golden_image_free(&refV);
        }
    }
    return failures;
}

// ---- Curved reformat (2026-11-26, Vulkan plan 7.1 #5) --------------------------------------------------------------

bool RenderReformatCases(Device &device, std::vector<ReformatCaseOutput> *out)
{
    out->clear();
    BKGoldenVolume vol;
    std::memset(&vol, 0, sizeof vol);
    if (bk_golden_make_head_phantom(&vol) != 0) return false;
    const size_t n = (size_t)vol.width * vol.height * vol.depth;
    float lo = INFINITY, hi = -INFINITY;
    for (size_t i = 0; i < n; i++) { lo = std::fmin(lo, vol.voxels[i]); hi = std::fmax(hi, vol.voxels[i]); }
    BKRenderQuantization q = BKRenderQuantizationForRange(lo, hi, BKRenderAllIntegral(vol.voxels, n));
    std::vector<uint16_t> steps(n);
    BKRenderQuantizeToSteps(vol.voxels, n, q, steps.data());
    std::vector<float> stored(n);   // the stored scan as real values (CPU reference input)
    for (size_t i = 0; i < n; i++) stored[i] = steps[i] / 65535.0f * q.valueScale + q.valueOffset;
    bool ok = false;
    do {
        TextureDesc td;
        td.type = TextureType::Texture3D;
        td.format = Format::R16Unorm;
        td.width = vol.width; td.height = vol.height; td.depth = vol.depth;
        td.usage = UsageSampled | UsageCopyDestination;
        std::unique_ptr<Texture> scan = device.makeTexture(td, nullptr);
        std::unique_ptr<CommandList> list = scan ? device.begin(nullptr) : nullptr;
        if (!list || list->upload(*scan, steps.data(), vol.width * 2, vol.width * vol.height * 2, 0, vol.depth) != Status::Ok ||
            device.submit(*list, true) != Status::Ok) break;
        boroskit::render::ReformatPass pass(device);
        if (pass.prepare() != Status::Ok) break;
        ok = true;
        for (uint32_t i = 0; i < kBKGoldenReformatCaseCount && ok; i++) {
            const BKGoldenReformatCase &c = kBKGoldenReformatCases[i];
            std::vector<BKReformatFrame> frames(c.width);
            bk_golden_reformat_frames(&c, (float *)frames.data());
            BKReformatParams p;   // as BKGoldenTests.testCurvedReformats sets them
            std::memset(&p, 0, sizeof p);
            p.width = c.width; p.height = c.height; p.depth = c.depth;
            p.interpolation = c.interpolation; p.projection = c.projection;
            p.outOfBoundsValue = vol.outOfBoundsValue;
            p.radiographK = BKReformatRadiographK(0.75, 0.5);
            p.valueScale = q.valueScale; p.valueOffset = q.valueOffset;
            p.volumeWide = vol.width; p.volumeHigh = vol.height; p.volumeDeep = vol.depth;
            p.rowCentre = (c.height - 1) / 2.0f;
            p.slabCentre = (c.depth - 1) / 2.0f;
            p.bandEnabled = c.band ? 1u : 0u; p.bandLow = c.bandLow; p.bandHigh = c.bandHigh; p.bandOutsideValue = -3000.0f;
            p.clipEnabled = c.clip; p.clipNormalZ = 1.0f; p.clipLow = c.clipLow; p.clipHigh = c.clipHigh;
            std::unique_ptr<Buffer> fb = pass.makeFrames(frames.data(), c.width, nullptr);
            std::unique_ptr<Buffer> values = device.makeBuffer((uint64_t)c.width * c.height * 4, Memory::Readback, UsageStorage, nullptr);
            std::unique_ptr<CommandList> cl = device.begin(nullptr);
            if (!fb || !values || !cl || pass.encode(*cl, p, *fb, *scan, *values) != Status::Ok || device.submit(*cl, true) != Status::Ok) {
                ok = false;
                break;
            }
            ReformatCaseOutput o;
            o.name = c.name;
            o.width = c.width; o.height = c.height;
            const float *v = (const float *)values->map();
            o.values.assign(v, v + (size_t)c.width * c.height);
            values->unmap();
            o.cpu.resize(o.values.size());
            BKReformatComputeRows(&p, frames.data(), stored.data(), 0, c.height, o.cpu.data());
            out->push_back(std::move(o));
        }
    } while (false);
    bk_golden_volume_free(&vol);
    return ok;
}

int TestReformatPass(Device &device, const char *referencesDir, const char *label, bool strict)
{
    std::vector<ReformatCaseOutput> cases;
    if (!RenderReformatCases(device, &cases)) { std::printf("REFORMAT | %s | FAIL: could not render\n", label); return 1; }
    int failures = 0;
    const std::string refs = referencesDir;
    for (const ReformatCaseOutput &o : cases) {
        BKGoldenImage mine = { o.width, o.height, 1, BKGoldenFormatF32, (void *)o.values.data() };
        BKGoldenImage ref;
        std::memset(&ref, 0, sizeof ref);
        if (bk_golden_read_pfm((refs + "/" + o.name + ".values.pfm").c_str(), &ref) != 0) {
            std::printf("REFORMAT | %s | FAIL: reference missing\n", o.name.c_str());
            failures++;
            continue;
        }
        BKGoldenImageReport r = bk_golden_compare_images(&ref, &mine, strict ? BKGoldenImageTolerance{ 0, 0 } : BKGoldenImageTolerance{ 1.0, 0.005 });
        char text[256];
        bk_golden_describe_image_report(&r, text, sizeof text);
        double worst = 0;
        for (size_t k = 0; k < o.values.size(); k++) worst = std::fmax(worst, std::fabs((double)o.values[k] - o.cpu[k]));
        std::printf("REFORMAT | %s | %s (ReformatPass) vs Metal reference: %s; CPU reference vs %s: max %.4g HU\n", o.name.c_str(), label,
                    text, label, worst);
        if (!r.pass || !(worst < 0.5)) failures++;
        bk_golden_image_free(&ref);
    }
    return failures;
}

// ---- 2D display + overlay (2026-11-26, Vulkan plan 7.1 #6) ----------------------------------------------------------

namespace {
std::unique_ptr<Texture> Texture2D(Device &device, Format format, uint32_t w, uint32_t h, const void *data, uint32_t bytesPerTexel,
                                   uint32_t usage = UsageSampled | UsageCopyDestination)
{
    TextureDesc td;
    td.format = format;
    td.width = w;
    td.height = h;
    td.usage = usage;
    std::unique_ptr<Texture> t = device.makeTexture(td, nullptr);
    if (!t || !data) return t;
    std::unique_ptr<CommandList> list = device.begin(nullptr);
    if (!list || list->upload(*t, data, w * bytesPerTexel, w * h * bytesPerTexel, 0, 1) != Status::Ok || device.submit(*list, true) != Status::Ok)
        return nullptr;
    return t;
}

bool ReadTarget(Device &device, Texture &target, uint32_t w, uint32_t h, std::vector<uint8_t> *rgba)
{
    std::unique_ptr<Buffer> rb = device.makeBuffer((uint64_t)w * h * 4, Memory::Readback, UsageStorage, nullptr);
    std::unique_ptr<CommandList> list = rb ? device.begin(nullptr) : nullptr;
    if (!list || list->readback(target, *rb) != Status::Ok || device.submit(*list, true) != Status::Ok) return false;
    const uint8_t *p = (const uint8_t *)rb->map();
    rgba->assign(p, p + (size_t)w * h * 4);
    rb->unmap();
    return true;
}

BKDisplayParams FitParams()
{
    // BKViewTransformMakeFit(64, 48, 96, 80) at scale 1: zoom 1.5, the image centred vertically (4 px bands).
    BKDisplayParams p;
    std::memset(&p, 0, sizeof p);
    p.m_a = (float)(1.0 / 1.5); p.m_d = (float)(1.0 / 1.5); p.m_ty = (float)(-4.0 / 1.5);
    p.scale = 1;
    p.imageWidth = BKGoldenDisplayW; p.imageHeight = BKGoldenDisplayH;
    p.bgA = 1;
    return p;
}
}  // namespace

bool RenderDisplayCases(Device &device, std::vector<RenderedPicture> *out)
{
    out->clear();
    boroskit::display::DisplayPass pass(device);
    if (pass.prepare() != Status::Ok) return false;
    std::vector<float> grey(BKGoldenDisplayW * BKGoldenDisplayH);
    BKGoldenDisplayGrey(grey.data());
    std::vector<uint8_t> labels(BKGoldenDisplayW * BKGoldenDisplayH * 4);
    BKGoldenLabelPicture(labels.data(), BKGoldenDisplayW, BKGoldenDisplayH);
    uint8_t identity[256 * 4], table[256 * 4], rgb[768];
    bk_golden_color_table(rgb);
    for (int i = 0; i < 256; i++) {
        identity[4 * i] = identity[4 * i + 1] = identity[4 * i + 2] = (uint8_t)i; identity[4 * i + 3] = 255;
        table[4 * i] = rgb[3 * i]; table[4 * i + 1] = rgb[3 * i + 1]; table[4 * i + 2] = rgb[3 * i + 2]; table[4 * i + 3] = 255;
    }
    std::unique_ptr<Texture> greyTex = Texture2D(device, Format::R32Float, BKGoldenDisplayW, BKGoldenDisplayH, grey.data(), 4);
    std::unique_ptr<Texture> labelTex = Texture2D(device, Format::RGBA8Unorm, BKGoldenDisplayW, BKGoldenDisplayH, labels.data(), 4);
    std::unique_ptr<Texture> lutId = Texture2D(device, Format::RGBA8Unorm, 256, 1, identity, 4);
    std::unique_ptr<Texture> lutTable = Texture2D(device, Format::RGBA8Unorm, 256, 1, table, 4);
    if (!greyTex || !labelTex || !lutId || !lutTable) return false;
    for (int c = 0; c < 2; c++) {
        std::unique_ptr<Texture> target = Texture2D(device, Format::RGBA8Unorm, 96, 80, nullptr, 4, UsageRenderTarget | UsageCopySource);
        std::unique_ptr<CommandList> list = target ? device.begin(nullptr) : nullptr;
        if (!list) return false;
        PassTargets pt;
        pt.color[0] = target.get();
        pt.clearValue[0][3] = 1;   // opaque black background (as BKImageLayerRenderer clears)
        if (list->beginPass(pt) != Status::Ok) return false;
        BKDisplayParams base = FitParams();
        if (c == 0) {   // display_overlay_layer: linear grey + see-through colour layer (BKGoldenTests reference)
            base.windowLower = -800; base.windowWidth = 1600; base.interpolation = 1;
            BKDisplayParams layer = FitParams();
            layer.windowLower = -160; layer.windowWidth = 400;
            layer.colorImage = 1; layer.useImageAlpha = 1;
            layer.bgA = 0;
            if (pass.encode(*list, base, *greyTex, *lutId, Format::RGBA8Unorm, false) != Status::Ok ||
                pass.encode(*list, layer, *labelTex, *lutId, Format::RGBA8Unorm, true) != Status::Ok) return false;
        } else {         // display_lut_invert: nearest, colour table, inverted (live comparison only)
            base.windowLower = -500; base.windowWidth = 1200; base.useColorTable = 1; base.invert = 1;
            if (pass.encode(*list, base, *greyTex, *lutTable, Format::RGBA8Unorm, false) != Status::Ok) return false;
        }
        list->endPass();
        if (device.submit(*list, true) != Status::Ok) return false;
        RenderedPicture o;
        o.name = c == 0 ? "display_overlay_layer" : "display_lut_invert";
        o.width = 96; o.height = 80;
        if (!ReadTarget(device, *target, 96, 80, &o.rgba)) return false;
        out->push_back(std::move(o));
    }
    return true;
}

bool RenderOverlayScene(Device &device, RenderedPicture *out, uint32_t *cpuDiffering, float *cpuWorst)
{
    const uint32_t W = BKGoldenOverlayWidth, H = BKGoldenOverlayHeight;
    BKOverlayList *l = BKOverlayListCreate();
    BKGoldenOverlayScene(l);
    bool ok = false;
    do {
        boroskit::display::OverlayPass pass(device);
        if (pass.prepare() != Status::Ok) break;
        std::unique_ptr<Texture> target = Texture2D(device, Format::RGBA8Unorm, W, H, nullptr, 4, UsageRenderTarget | UsageCopySource);
        std::unique_ptr<Buffer> vertices = pass.makeVertices(l, nullptr);
        std::vector<std::unique_ptr<Texture>> images;
        std::unique_ptr<CommandList> up = device.begin(nullptr);
        if (!target || !vertices || !up || pass.makeImages(l, *up, &images) != Status::Ok || device.submit(*up, true) != Status::Ok) break;
        std::vector<Texture *> raw;
        for (auto &t : images) raw.push_back(t.get());
        std::unique_ptr<CommandList> list = device.begin(nullptr);
        PassTargets pt;
        pt.color[0] = target.get();
        pt.clearValue[0][3] = 1;   // opaque black, as the golden test's texture
        if (!list || list->beginPass(pt) != Status::Ok ||
            pass.encode(*list, l, *vertices, raw.data(), (uint32_t)raw.size(), Format::RGBA8Unorm, W, H) != Status::Ok) break;
        list->endPass();
        if (device.submit(*list, true) != Status::Ok) break;
        out->name = "overlay_scene";
        out->width = W; out->height = H;
        if (!ReadTarget(device, *target, W, H, &out->rgba)) break;
        // The CPU reference rasteriser (black, opaque background).
        std::vector<float> cpu((size_t)W * H * 4, 0.0f);
        for (uint32_t i = 0; i < W * H; i++) cpu[i * 4 + 3] = 1;
        BKOverlayRasterize(l, cpu.data(), W, H);
        uint32_t off = 0;
        float worst = 0;
        for (size_t i = 0; i < cpu.size(); i++) {
            float d = std::fabs(out->rgba[i] / 255.0f - std::fmin(std::fmax(cpu[i], 0.0f), 1.0f));
            if (d > 2.5f / 255.0f) off++;
            worst = std::fmax(worst, d);
        }
        *cpuDiffering = off;
        *cpuWorst = worst;
        ok = true;
    } while (false);
    BKOverlayListFree(l);
    return ok;
}

int Test2D(Device &device, const char *referencesDir, const char *label, bool strict)
{
    int failures = 0;
    const std::string refs = referencesDir;
    std::vector<RenderedPicture> pics;
    if (!RenderDisplayCases(device, &pics)) { std::printf("DISPLAY | %s | FAIL: could not render\n", label); return 1; }
    RenderedPicture ov;
    uint32_t off = 0;
    float worst = 0;
    if (!RenderOverlayScene(device, &ov, &off, &worst)) { std::printf("OVERLAY | %s | FAIL: could not render\n", label); return failures + 1; }
    std::printf("OVERLAY | overlay_scene | %s vs CPU rasteriser: %u of %u channel values beyond 2.5/255 (worst %.3f)\n", label, off,
                ov.width * ov.height * 4, worst);
    pics.push_back(ov);
    for (const RenderedPicture &p : pics) {
        BKGoldenImage ref;
        std::memset(&ref, 0, sizeof ref);
        if (bk_golden_read_pam((refs + "/" + p.name + ".rgba.pam").c_str(), &ref) != 0) continue;   // live-only case
        BKGoldenImage mine = { p.width, p.height, 4, BKGoldenFormatU8, (void *)p.rgba.data() };
        BKGoldenImageReport r = bk_golden_compare_images(&ref, &mine, strict ? BKGoldenImageTolerance{ 0, 0 } : bk_golden_tolerance_u8());
        char text[256];
        bk_golden_describe_image_report(&r, text, sizeof text);
        std::printf("2D | %s | %s vs Metal reference: %s\n", p.name.c_str(), label, text);
        if (!r.pass) failures++;
        bk_golden_image_free(&ref);
    }
    return failures;
}

}  // namespace bkshared
