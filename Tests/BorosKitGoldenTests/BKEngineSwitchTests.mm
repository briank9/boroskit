// Boros 6 GPU engine switch (2026-11-26, agent "vulkan-engine"): every BorosKit renderer that has a Vulkan TEST path
// (BKGPUEngine.h) renders the golden cases twice - Metal (default) and the Vulkan test engine through MoltenVK - and the
// two must agree within the golden tolerances. Skipped (logged) when the Vulkan SDK is not installed.
// Original BorosKit code written for this project; contains no third-party code.
//
// Also proves the default stays Metal and that renderers made while Metal is chosen never touch Vulkan.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BKGoldenCore.h"
extern "C" {   // BKGoldenMetal.m is Objective-C: its C functions have unmangled names
#import "BKGoldenMetal.h"
}
#import "BorosKitRender.h"
#import "BorosKitMesh.h"
#import "BorosKitMeshRender.h"
#import "BorosKitSurface.h"
#import "BorosKitDisplay.h"
#import "BKGPUEngine.h"
#import "BKGPUVulkanTestEngine.h"
#include "../BorosKitGPUShared/BKDisplayGoldenScene.h"

@interface BKEngineSwitchTests : XCTestCase
@end

@implementation BKEngineSwitchTests {
    BKGoldenVolume _phantom;
    BKGoldenMetalProducer *_producer;
}

- (void)setUp
{
    BKGPUVulkanTestEngineInstall();
    memset(&_phantom, 0, sizeof _phantom);
    XCTAssertEqual(bk_golden_make_head_phantom(&_phantom), 0);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device) _producer = [[BKGoldenMetalProducer alloc] initWithDevice:device volume:&_phantom error:NULL];
}

- (void)tearDown
{
    [BKGPUEngine setPreferredEngine:BKGPUEngineMetal];   // never leave the test engine on for other tests
    bk_golden_volume_free(&_phantom);
}

// What: NO (and a log line) when this Mac cannot run the Vulkan test engine.
- (BOOL)vulkanAvailable
{
    NSString *reason = nil;
    if (!_producer) return NO;
    if ([BKGPUEngine vulkanTestEngineAvailable:&reason]) return YES;
    NSLog(@"BKEngineSwitchTests: Vulkan test engine not available (%@) - skipped", reason);
    return NO;
}

static void Compare(NSString *what, const BKGoldenImage *metal, const BKGoldenImage *vulkan, BKGoldenImageTolerance tol, BOOL *pass)
{
    BKGoldenImageReport r = bk_golden_compare_images(metal, vulkan, tol);
    char text[256];
    bk_golden_describe_image_report(&r, text, sizeof text);
    NSLog(@"ENGINE | %@ | Vulkan test engine vs Metal: %s", what, text);
    if (!r.pass) *pass = NO;
}

// The bottom-right marker ("Vulkan (MoltenVK)") of on-screen pictures: copied from the Metal picture before comparing.
static void UnmarkCorner(const BKGoldenImage *metal, BKGoldenImage *vulkan)
{
    uint8_t *v = (uint8_t *)vulkan->data;
    const uint8_t *m = (const uint8_t *)metal->data;
    for (uint32_t y = vulkan->height > 24 ? vulkan->height - 24 : 0; y < vulkan->height; y++)
        for (uint32_t x = vulkan->width > 140 ? vulkan->width - 140 : 0; x < vulkan->width; x++)
            memcpy(v + 4 * (y * vulkan->width + x), m + 4 * (y * vulkan->width + x), 4);
}

- (void)testDefaultIsMetal
{
    XCTAssertEqual([BKGPUEngine preferredEngine], BKGPUEngineMetal);
    XCTAssertEqualObjects([BKGPUEngine currentEngineDescription], @"Metal");
}

- (void)testVolumeAndSurfacesAndMeshes
{
    if (![self vulkanAvailable]) return;
    BOOL pass = YES;
    // Metal pictures first (the producer's renderers were made with Metal).
    BKGoldenImage mr[16] = {{0}}, mv[16] = {{0}}, vr[16] = {{0}}, vv[16] = {{0}};
    for (uint32_t i = 0; i < kBKGoldenVolumeCaseCount; i++)
        XCTAssertTrue([_producer renderVolumeCase:&kBKGoldenVolumeCases[i] rgba:&mr[i] values:&mv[i] error:NULL]);
    BKMesh *metalBone = [_producer extractSurfaceCase:&kBKGoldenSurfaceCases[0] error:NULL];
    BKGoldenImage mm = {0}, md = {0}, vm = {0}, vd = {0};
    XCTAssertTrue([_producer renderMeshCase:&kBKGoldenMeshRenderCases[1] mesh:metalBone rgba:&mm distance:&md error:NULL]);
    // The same with the Vulkan test engine.
    [BKGPUEngine setPreferredEngine:BKGPUEngineVulkanTest];
    XCTAssertTrue([_producer reloadRenderers]);
    for (uint32_t i = 0; i < kBKGoldenVolumeCaseCount; i++) {
        const BKGoldenVolumeCase *c = &kBKGoldenVolumeCases[i];
        XCTAssertTrue([_producer renderVolumeCase:c rgba:&vr[i] values:&vv[i] error:NULL], @"%s", c->name);
        if (!vr[i].data) { pass = NO; continue; }
        Compare([NSString stringWithFormat:@"%s rgba", c->name], &mr[i], &vr[i], bk_golden_tolerance_u8(), &pass);
        Compare([NSString stringWithFormat:@"%s values", c->name], &mv[i], &vv[i], (BKGoldenImageTolerance){c->mode == 0 ? 1.0 / 255.0 : 1.0, 0.005}, &pass);
    }
    for (uint32_t i = 0; i < kBKGoldenSurfaceCaseCount; i++) {
        BKMesh *vk = [_producer extractSurfaceCase:&kBKGoldenSurfaceCases[i] error:NULL];
        [BKGPUEngine setPreferredEngine:BKGPUEngineMetal];
        XCTAssertTrue([_producer reloadRenderers]);
        BKMesh *metal = [_producer extractSurfaceCase:&kBKGoldenSurfaceCases[i] error:NULL];
        [BKGPUEngine setPreferredEngine:BKGPUEngineVulkanTest];
        XCTAssertTrue([_producer reloadRenderers]);
        BKGoldenMesh a = BKGoldenMeshFromBKMesh(metal), b = BKGoldenMeshFromBKMesh(vk);
        BKGoldenMeshReport r = bk_golden_compare_meshes(&a, &b, (BKGoldenMeshTolerance){{_phantom.spacing[0], _phantom.spacing[1], _phantom.spacing[2]}, 1e-4, 1e-3});
        char text[256];
        bk_golden_describe_mesh_report(&r, text, sizeof text);
        NSLog(@"ENGINE | %s | Vulkan test engine vs Metal: %s", kBKGoldenSurfaceCases[i].name, text);
        if (!r.pass) pass = NO;
        bk_golden_mesh_free(&a);
        bk_golden_mesh_free(&b);
    }
    XCTAssertTrue([_producer renderMeshCase:&kBKGoldenMeshRenderCases[1] mesh:metalBone rgba:&vm distance:&vd error:NULL]);
    if (vm.data && mm.data) {
        UnmarkCorner(&mm, &vm);
        Compare(@"meshrender_bone_persp_seethrough rgba", &mm, &vm, bk_golden_tolerance_u8(), &pass);
        Compare(@"meshrender_bone_persp_seethrough distance", &md, &vd, (BKGoldenImageTolerance){0.01, 0.005}, &pass);
    }
    for (int i = 0; i < 16; i++) { bk_golden_image_free(&mr[i]); bk_golden_image_free(&mv[i]); bk_golden_image_free(&vr[i]); bk_golden_image_free(&vv[i]); }
    bk_golden_image_free(&mm); bk_golden_image_free(&md); bk_golden_image_free(&vm); bk_golden_image_free(&vd);
    [BKGPUEngine setPreferredEngine:BKGPUEngineMetal];
    [_producer reloadRenderers];
    XCTAssertTrue(pass, @"see the ENGINE lines");
}

- (void)testReformatDisplayOverlay
{
    if (![self vulkanAvailable]) return;
    BOOL pass = YES;
    // Curved reformat: the five golden cases.
    BKVolumeTexture *volume = _producer.volumeTexture;
    BKCurvedReformat *metal = [[BKCurvedReformat alloc] initWithDevice:_producer.device error:NULL];
    [BKGPUEngine setPreferredEngine:BKGPUEngineVulkanTest];
    BKCurvedReformat *vk = [[BKCurvedReformat alloc] initWithDevice:_producer.device error:NULL];
    [BKGPUEngine setPreferredEngine:BKGPUEngineMetal];
    for (uint32_t i = 0; i < kBKGoldenReformatCaseCount; i++) {
        const BKGoldenReformatCase *c = &kBKGoldenReformatCases[i];
        BKReformatFrame *frames = (BKReformatFrame *)malloc(sizeof(BKReformatFrame) * c->width);
        bk_golden_reformat_frames(c, (float *)frames);
        BKReformatParams p;
        memset(&p, 0, sizeof p);
        p.width = c->width; p.height = c->height; p.depth = c->depth;
        p.interpolation = c->interpolation; p.projection = c->projection;
        p.outOfBoundsValue = volume.outOfBoundsValue; p.radiographK = BKReformatRadiographK(0.75, 0.5);
        p.rowCentre = (c->height - 1) / 2.0f; p.slabCentre = (c->depth - 1) / 2.0f;
        p.bandEnabled = c->band ? 1u : 0u; p.bandLow = c->bandLow; p.bandHigh = c->bandHigh; p.bandOutsideValue = -3000.0f;
        p.clipEnabled = c->clip; p.clipNormalZ = 1.0f; p.clipLow = c->clipLow; p.clipHigh = c->clipHigh;
        size_t bytes = sizeof(float) * c->width * c->height;
        float *a = (float *)malloc(bytes), *b = (float *)malloc(bytes);
        XCTAssertTrue([metal renderParams:p frames:frames volume:volume into:a capacity:bytes error:NULL]);
        XCTAssertTrue([vk renderParams:p frames:frames volume:volume into:b capacity:bytes error:NULL]);
        BKGoldenImage ia = {c->width, c->height, 1, BKGoldenFormatF32, a}, ib = {c->width, c->height, 1, BKGoldenFormatF32, b};
        Compare(@(c->name), &ia, &ib, (BKGoldenImageTolerance){1.0, 0.005}, &pass);
        free(a); free(b); free(frames);
    }
    // 2D display: the golden image cases (a renderer per call: the engine chosen at that moment).
    for (uint32_t i = 0; i < kBKGoldenImageCaseCount; i++) {
        BKGoldenImage a = {0}, b = {0};
        XCTAssertTrue([_producer renderImageCase:&kBKGoldenImageCases[i] volume:&_phantom rgba:&a error:NULL]);
        [BKGPUEngine setPreferredEngine:BKGPUEngineVulkanTest];
        XCTAssertTrue([_producer renderImageCase:&kBKGoldenImageCases[i] volume:&_phantom rgba:&b error:NULL]);
        [BKGPUEngine setPreferredEngine:BKGPUEngineMetal];
        if (a.data && b.data) {
            UnmarkCorner(&a, &b);
            Compare(@(kBKGoldenImageCases[i].name), &a, &b, bk_golden_tolerance_u8(), &pass);
        }
        bk_golden_image_free(&a);
        bk_golden_image_free(&b);
    }
    // 2D overlay engine: the golden overlay scene over black, drawn into a caller's encoder.
    const uint32_t W = BKGoldenOverlayWidth, H = BKGoldenOverlayHeight;
    NSMutableData *pics[2];
    for (int engine = 0; engine < 2; engine++) {
        [BKGPUEngine setPreferredEngine:engine ? BKGPUEngineVulkanTest : BKGPUEngineMetal];
        BKOverlayRenderer *r = [[BKOverlayRenderer alloc] initWithDevice:_producer.device error:NULL];
        [BKGPUEngine setPreferredEngine:BKGPUEngineMetal];
        BKOverlayList *l = BKOverlayListCreate();
        BKGoldenOverlayScene(l);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [_producer.device newTextureWithDescriptor:td];
        pics[engine] = [NSMutableData dataWithLength:W * H * 4];
        for (uint32_t i = 0; i < W * H; i++) ((uint8_t *)pics[engine].mutableBytes)[i * 4 + 3] = 255;
        [tex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:pics[engine].bytes bytesPerRow:W * 4];
        id<MTLCommandBuffer> cb = [[_producer.device newCommandQueue] commandBuffer];
        XCTAssertTrue([r renderList:l intoTexture:tex commandBuffer:cb error:NULL]);
        [cb commit];
        [cb waitUntilCompleted];
        [tex getBytes:pics[engine].mutableBytes bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        BKOverlayListFree(l);
    }
    BKGoldenImage a = {W, H, 4, BKGoldenFormatU8, pics[0].mutableBytes}, b = {W, H, 4, BKGoldenFormatU8, pics[1].mutableBytes};
    Compare(@"overlay_scene", &a, &b, bk_golden_tolerance_u8(), &pass);
    XCTAssertTrue(pass, @"see the ENGINE lines");
}

// The on-screen path of the 3D window: -encodeRenderToTexture: into a BGRA8 texture (what a drawable is), Metal vs the
// Vulkan test engine (colour composed on the CPU from the 8-bit picture, marker in the corner).
- (void)testVolumeOnScreenPath
{
    if (![self vulkanAvailable]) return;
    const BKGoldenVolumeCase *c = &kBKGoldenVolumeCases[1];   // vr_persp_oblique
    NSMutableData *pics[2];
    for (int engine = 0; engine < 2; engine++) {
        [BKGPUEngine setPreferredEngine:engine ? BKGPUEngineVulkanTest : BKGPUEngineMetal];
        XCTAssertTrue([_producer reloadRenderers]);
        BKGoldenImage rgba = {0}, values = {0};   // configures the producer's renderer for the case
        XCTAssertTrue([_producer renderVolumeCase:c rgba:&rgba values:&values error:NULL]);
        bk_golden_image_free(&rgba);
        bk_golden_image_free(&values);
        BKVolumeRenderer *r = [_producer valueForKey:@"volumeRenderer"];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:c->width height:c->height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [_producer.device newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [r.commandQueue commandBuffer];
        NSError *error = nil;
        XCTAssertTrue([r encodeRenderToTexture:tex commandBuffer:cb backgroundColor:simd_make_float4(0.1f, 0.2f, 0.3f, 1) error:&error], @"%@", error);
        [cb commit];
        [cb waitUntilCompleted];
        pics[engine] = [NSMutableData dataWithLength:c->width * c->height * 4];
        [tex getBytes:pics[engine].mutableBytes bytesPerRow:c->width * 4 fromRegion:MTLRegionMake2D(0, 0, c->width, c->height) mipmapLevel:0];
    }
    [BKGPUEngine setPreferredEngine:BKGPUEngineMetal];
    [_producer reloadRenderers];
    BKGoldenImage a = {c->width, c->height, 4, BKGoldenFormatU8, pics[0].mutableBytes}, b = {c->width, c->height, 4, BKGoldenFormatU8, pics[1].mutableBytes};
    size_t marked = 0;
    for (size_t i = 0; i < pics[0].length; i++) marked += ((uint8_t *)a.data)[i] != ((uint8_t *)b.data)[i];
    XCTAssertGreaterThan(marked, (size_t)0, @"the Vulkan picture carries the marker");
    UnmarkCorner(&a, &b);
    BOOL pass = YES;
    Compare(@"vr_persp_oblique on-screen (BGRA8)", &a, &b, bk_golden_tolerance_u8(), &pass);
    XCTAssertTrue(pass);
}

@end
