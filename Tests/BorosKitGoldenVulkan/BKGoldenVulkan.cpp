// BorosKit Vulkan tests: the golden runner for meshes - milestone 1 part (b) (steps M9 / M10).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine".
//
// What: renders the golden mesh cases (kBKGoldenMeshRenderCases, BKGoldenCore.c) with the Vulkan engine and
// compares them with the references Metal recorded (Tests/BorosKitGoldenTests/References), with the agreed
// tolerances and the same bk_golden_compare_* functions as the Mac XCTest runner:
//   - the bone surface is read from References/surface_bone_300.bkmesh (what the Mac renders too);
//   - the settings block is built by the SAME plain-C functions BKMeshRenderer (Metal) uses:
//     BKMeshBoxDepthExtent, BKMeshDepthRange, BKMeshUniformsFill, BKMeshUniformsSetModel / SetColor;
//   - the GPU programs are the GLSL entry points over the shared bodies (BKMeshShaderBodies.h);
//   - draw order and states mirror BKMeshRenderer: solid = colour + ray distance, depth LESS + write;
//     see-through = depth-only pass, then colour with LESS_OR_EQUAL, no depth / distance write.
// Case 0 (meshrender_bone_ortho) is milestone 1 and decides the exit code together with the validation
// messages (must be zero). Case 1 (perspective, see-through) is run and reported.
// Output (argument 1, default "."): <case>.vulkan.rgba.pam / .distance.pfm and a side-by-side PNG
// (Metal | Vulkan | difference x 40), 3x enlarged, composited over grey.
// Prints "GOLDEN | ..." lines like the XCTest runner.

#include "BKVulkanTestSupport.h"
#include "BKGoldenCore.h"
#include "BKMeshDrawCore.h"
#include "BKPNGWrite.h"
#include <cmath>
#include <string>

using namespace bktest;

namespace {

struct Rendered { std::vector<uint8_t> rgba; std::vector<float> distance; };

bool RenderCase(Device &device, const BKGoldenMeshRenderCase &c, const BKGoldenMesh &mesh, Rendered *out)
{
    Status s;
    const uint32_t W = c.width, H = c.height;
    // Vertices as BKMeshGPUVertex (40 bytes): position, normal (0 without), colour (white without).
    std::vector<BKMeshGPUVertex> vertices((size_t)mesh.vertexCount);
    for (uint64_t i = 0; i < mesh.vertexCount; i++) {
        BKMeshGPUVertex &v = vertices[(size_t)i];
        for (int a = 0; a < 3; a++) {
            v.position[a] = mesh.positions[3 * i + a];
            v.normal[a] = mesh.normals ? mesh.normals[3 * i + a] : 0.0f;
        }
        for (int a = 0; a < 4; a++) v.color[a] = 1.0f;
    }
    uint64_t vertexBytes = vertices.size() * sizeof(BKMeshGPUVertex), indexBytes = mesh.triangleCount * 3 * sizeof(uint32_t);
    std::unique_ptr<Buffer> vb = device.makeBuffer(vertexBytes, Memory::DeviceOnly, UsageStorage, &s);
    std::unique_ptr<Buffer> ib = device.makeBuffer(indexBytes, Memory::DeviceOnly, UsageIndex, &s);

    // The settings block, exactly as BKMeshRenderer builds it.
    BKMeshCamera camera;
    camera.projection = c.projection;
    camera.position = BKV3d(c.cameraPosition[0], c.cameraPosition[1], c.cameraPosition[2]);
    camera.direction = BKV3d(c.cameraDirection[0], c.cameraDirection[1], c.cameraDirection[2]);
    camera.up = BKV3d(c.cameraUp[0], c.cameraUp[1], c.cameraUp[2]);
    camera.viewWidth = c.viewWidth;
    camera.viewHeight = c.viewHeight;
    camera.fieldOfView = c.fieldOfView;
    BKVec3d r, u, f;
    if (BKMeshCameraAxes(&camera, &r, &u, &f) != BKMeshCameraOK) return false;
    BKVec3f cameraF = BKV3f((float)camera.position.x, (float)camera.position.y, (float)camera.position.z);
    BKVec3f forwardF = BKV3f((float)f.x, (float)f.y, (float)f.z);
    BKVec3f lo = BKV3f(INFINITY, INFINITY, INFINITY), hi = BKV3f(-INFINITY, -INFINITY, -INFINITY);
    for (uint64_t i = 0; i < mesh.vertexCount; i++) {   // BKMesh boundsMin / boundsMax (identity placement)
        const float *p = &mesh.positions[3 * i];
        lo = BKV3f(std::fmin(lo.x, p[0]), std::fmin(lo.y, p[1]), std::fmin(lo.z, p[2]));
        hi = BKV3f(std::fmax(hi.x, p[0]), std::fmax(hi.y, p[1]), std::fmax(hi.z, p[2]));
    }
    float nearest = INFINITY, farthest = -INFINITY, nearDistance, farDistance;
    BKMeshBoxDepthExtent(lo, hi, cameraF, forwardF, &nearest, &farthest);
    BKMeshDepthRange(nearest, farthest, c.projection == 1, &nearDistance, &farDistance);
    BKMeshLighting lighting = { 0.2f, 0.8f, 0.2f, 10.0f };   // BKMeshRenderer's defaults
    BKMeshUniforms uniforms;
    if (BKMeshUniformsFill(&uniforms, &camera, (float)W, (float)H, nearDistance, farDistance, lighting) != BKMeshCameraOK) return false;
    const float identity[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    BKMeshUniformsSetModel(&uniforms, identity, 1);
    BKMeshUniformsSetColor(&uniforms, c.color[0], c.color[1], c.color[2], c.opacity);
    uniforms.useVertexColors = 0;                 // the mesh has no colours
    uniforms.hasNormals = mesh.normals ? 1 : 0;
    uniforms.lit = 1;

    // Targets: RGBA8 colour, R32F ray distance (cleared to +infinity), D32 depth.
    TextureDesc cd;
    cd.format = Format::RGBA8Unorm; cd.width = W; cd.height = H; cd.usage = UsageRenderTarget | UsageCopySource;
    TextureDesc dd = cd;
    dd.format = Format::R32Float;
    TextureDesc zd = cd;
    zd.format = Format::Depth32Float; zd.usage = UsageDepthTarget;
    std::unique_ptr<Texture> colour = device.makeTexture(cd, &s), distance = device.makeTexture(dd, &s), depth = device.makeTexture(zd, &s);

    // Pipelines (BKMeshRenderer: opaque / depth-only / see-through).
    SlotLayout slots[2] = { { SlotKind::StorageBuffer, 0, false, true, false }, { SlotKind::UniformBlock, 1, false, true, true } };
    RenderDesc rd;
    rd.vertex.name = "bk_mesh_vertex";
    rd.fragment.name = "bk_mesh_fragment_distance";
    rd.color[0].format = Format::RGBA8Unorm;
    rd.color[0].premultipliedOver = true;
    rd.color[1].format = Format::R32Float;
    rd.colorCount = 2;
    rd.hasDepth = true;
    rd.depthFormat = Format::Depth32Float;
    rd.invariantPosition = true;
    rd.slots = slots;
    rd.slotCount = 2;
    RenderDesc opaqueDesc = rd, depthOnlyDesc = rd, seeDesc = rd;
    depthOnlyDesc.color[0].writeEnabled = depthOnlyDesc.color[1].writeEnabled = false;
    seeDesc.color[1].writeEnabled = false;
    seeDesc.depthCompare = DepthCompare::LessOrEqual;
    seeDesc.depthWrite = false;
    std::unique_ptr<RenderPipeline> opaque = device.makeRender(opaqueDesc, &s), depthOnly = device.makeRender(depthOnlyDesc, &s),
                                    see = device.makeRender(seeDesc, &s);
    if (!vb || !ib || !colour || !distance || !depth || !opaque || !depthOnly || !see) {
        std::printf("FAIL: could not make the resources (status %d)\n", (int)s);
        return false;
    }

    std::unique_ptr<CommandList> list = device.begin(&s);
    list->upload(*vb, 0, vertices.data(), vertexBytes);
    list->upload(*ib, 0, mesh.indices, indexBytes);
    PassTargets pass;
    pass.color[0] = colour.get();
    pass.color[1] = distance.get();
    pass.colorCount = 2;
    pass.depth = depth.get();
    pass.clearValue[1][0] = INFINITY;   // "no surface" in the ray-distance picture
    pass.clearDepth = 1.0f;
    list->beginPass(pass);
    Binding b[2];
    b[0].kind = SlotKind::StorageBuffer; b[0].slot = 0; b[0].buffer = vb.get();
    b[1].kind = SlotKind::UniformBlock; b[1].slot = 1; b[1].bytes = &uniforms; b[1].byteCount = sizeof uniforms;
    uint32_t indexCount = (uint32_t)(mesh.triangleCount * 3);
    bool solid = c.opacity >= 1;
    if (solid) {
        list->draw(*opaque, b, 2, 0, 0, ib.get(), indexCount);
    } else {
        list->draw(*depthOnly, b, 2, 0, 0, ib.get(), indexCount);   // nearest surface into the depth buffer
        list->draw(*see, b, 2, 0, 0, ib.get(), indexCount);         // colour only there
    }
    list->endPass();
    if (device.submit(*list, true) != Status::Ok) return false;
    std::vector<uint8_t> d;
    if (!ReadTexture(device, *colour, &out->rgba, 4) || !ReadTexture(device, *distance, &d, 4)) return false;
    out->distance.resize((size_t)W * H);
    std::memcpy(out->distance.data(), d.data(), d.size());
    return true;
}

// Side-by-side picture for people: Metal | Vulkan | |difference| x 40, premultiplied colours over grey, 3x.
void WriteSideBySide(const std::string &path, const uint8_t *metal, const uint8_t *vulkan, uint32_t W, uint32_t H)
{
    const uint32_t scale = 3, gap = 6, OW = (3 * W) * scale + 2 * gap, OH = H * scale;
    std::vector<uint8_t> img((size_t)OW * OH * 4, 255);
    const float grey = 0.35f;
    for (uint32_t panel = 0; panel < 3; panel++)
        for (uint32_t y = 0; y < H; y++)
            for (uint32_t x = 0; x < W; x++) {
                const uint8_t *a = &metal[(y * W + x) * 4], *v = &vulkan[(y * W + x) * 4];
                uint8_t px[3];
                for (int k = 0; k < 3; k++) {
                    if (panel == 2) {
                        int diff = std::abs((int)a[k] - (int)v[k]) * 40;
                        px[k] = (uint8_t)(diff > 255 ? 255 : diff);
                    } else {
                        const uint8_t *p = panel == 0 ? a : v;
                        float c = p[k] / 255.0f + (1.0f - p[3] / 255.0f) * grey;   // premultiplied "over" grey
                        px[k] = (uint8_t)std::lround(std::fmin(c, 1.0f) * 255.0f);
                    }
                }
                for (uint32_t sy = 0; sy < scale; sy++)
                    for (uint32_t sx = 0; sx < scale; sx++) {
                        uint32_t ox = panel * (W * scale + gap) + x * scale + sx, oy = y * scale + sy;
                        uint8_t *o = &img[((size_t)oy * OW + ox) * 4];
                        o[0] = px[0]; o[1] = px[1]; o[2] = px[2]; o[3] = 255;
                    }
            }
    if (bk_png_write_rgba8(path.c_str(), img.data(), OW, OH) == 0) std::printf("picture: %s (Metal | Vulkan | difference x 40)\n", path.c_str());
    else std::printf("could not write %s\n", path.c_str());
}

}  // namespace

int main(int argc, char **argv)
{
    std::string outDir = argc > 1 ? argv[1] : ".";
    const std::string refs = BK_GOLDEN_REFERENCES_DIR;
    Messages messages;
    int milestoneFailures = 0;
    {
        std::unique_ptr<Device> device = StartDevice(&messages);
        if (!device) return 1;
        BKGoldenMesh mesh;
        std::memset(&mesh, 0, sizeof mesh);
        if (bk_golden_read_mesh((refs + "/surface_bone_300.bkmesh").c_str(), &mesh) != 0) { std::printf("FAIL: no bone mesh\n"); return 1; }
        for (uint32_t i = 0; i < kBKGoldenMeshRenderCaseCount; i++) {
            const BKGoldenMeshRenderCase &c = kBKGoldenMeshRenderCases[i];
            Rendered r;
            bool ok = RenderCase(*device, c, mesh, &r);
            std::string name = c.name;
            if (!ok) {
                std::printf("GOLDEN | %s | FAIL: could not render on Vulkan\n", name.c_str());
                if (i == 0) milestoneFailures++;
                continue;
            }
            BKGoldenImage vRGBA = { c.width, c.height, 4, BKGoldenFormatU8, r.rgba.data() };
            BKGoldenImage vDist = { c.width, c.height, 1, BKGoldenFormatF32, r.distance.data() };
            bk_golden_write_pam((outDir + "/" + name + ".vulkan.rgba.pam").c_str(), &vRGBA);
            bk_golden_write_pfm((outDir + "/" + name + ".vulkan.distance.pfm").c_str(), &vDist);
            BKGoldenImage mRGBA, mDist;
            std::memset(&mRGBA, 0, sizeof mRGBA);
            std::memset(&mDist, 0, sizeof mDist);
            if (bk_golden_read_pam((refs + "/" + name + ".rgba.pam").c_str(), &mRGBA) != 0 ||
                bk_golden_read_pfm((refs + "/" + name + ".distance.pfm").c_str(), &mDist) != 0) {
                std::printf("GOLDEN | %s | FAIL: reference missing\n", name.c_str());
                if (i == 0) milestoneFailures++;
                continue;
            }
            BKGoldenImageReport rc = bk_golden_compare_images(&mRGBA, &vRGBA, bk_golden_tolerance_u8());
            BKGoldenImageReport rd = bk_golden_compare_images(&mDist, &vDist, BKGoldenImageTolerance{ 0.01, 0.005 });
            char text[256];
            bk_golden_describe_image_report(&rc, text, sizeof text);
            std::printf("GOLDEN | %s.rgba.pam | Vulkan vs Metal reference: %s\n", name.c_str(), text);
            bk_golden_describe_image_report(&rd, text, sizeof text);
            std::printf("GOLDEN | %s.distance.pfm | Vulkan vs Metal reference: %s\n", name.c_str(), text);
            if (i == 0 && (!rc.pass || !rd.pass)) milestoneFailures++;
            if (i != 0) std::printf("(case %s: attempted and reported, not part of milestone 1)\n", name.c_str());
            if (!rc.sizeMismatch)
                WriteSideBySide(outDir + "/" + name + "_metal_vs_vulkan.png", (const uint8_t *)mRGBA.data, r.rgba.data(), c.width, c.height);
            bk_golden_image_free(&mRGBA);
            bk_golden_image_free(&mDist);
        }
        bk_golden_mesh_free(&mesh);
    }
    std::printf("validation messages: %d errors, %d warnings\n", messages.errors, messages.warnings);
    if (messages.errors || messages.warnings) milestoneFailures++;
    std::printf("%s milestone 1 (b): golden meshrender_bone_ortho on Vulkan\n", milestoneFailures ? "FAILED" : "PASSED");
    return milestoneFailures ? 1 : 0;
}
