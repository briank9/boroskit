// Tests for BKOverlayRenderer: the Metal drawing of a BKOverlayCore draw list must equal the CPU
// reference (BKOverlayRasterize) - the same check a Vulkan backend will have to pass.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BKOverlayRenderer.h"

@interface BKOverlayRendererTests : XCTestCase
@end

@implementation BKOverlayRendererTests

// What: a scene with every kind of item, drawn on black by the GPU and by the CPU reference.
- (void)testGPUMatchesCPUReference
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { NSLog(@"no Metal device - skipped"); return; }
    NSError *error = nil;
    BKOverlayRenderer *r = [[BKOverlayRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(r, @"%@", error);

    const uint32_t W = 160, H = 120;
    BKOverlayList *l = BKOverlayListCreate();
    BKOverlayStroke s; memset(&s, 0, sizeof(s));
    s.width = 2.5f; s.join = BKOverlayJoinMiter; s.miterLimit = 10; s.smooth = 1;
    BKVec2f zig[4] = { {10, 10}, {60, 40}, {90, 12}, {150, 50} };
    BKOverlayColor cols[4] = { {1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {1, 1, 0, 0.6f} };
    BKOverlayStrokePolyline(l, zig, cols, 4, 0, &s, cols[0]);
    float dash[2] = { 6, 4 };
    BKOverlayStroke ds = s; ds.dashes = dash; ds.dashCount = 2; ds.width = 1; ds.smooth = 0;
    BKVec2f line[2] = { {5, 70}, {155, 70} };
    BKOverlayColor yellow = { 1, 1, 0, 1 };
    BKOverlayStrokePolyline(l, line, NULL, 2, 0, &ds, yellow);
    BKVec2f poly[5] = { {20, 80}, {60, 78}, {70, 110}, {40, 95}, {15, 112} };
    BKOverlayColor fillc = { 0.2f, 0.6f, 1, 0.5f };
    BKOverlayFillPolygon(l, poly, NULL, 5, BKOverlayFillEvenOdd, 1, fillc);
    BKVec2f dots[3] = { {100, 90}, {110.5f, 95.5f}, {125, 100} };
    BKOverlayColor white = { 1, 1, 1, 1 };
    BKOverlayPoints(l, dots, NULL, 3, 5, 1, 1, white);
    uint8_t px[16] = { 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 255, 64 };
    int32_t img = BKOverlayAddImage(l, 2, 2, BKOverlayImageRGBA8, px, 8);
    BKOverlayDrawImage(l, img, BKV2f(130, 80), BKV2f(10, 0), BKV2f(0, 10), 0, white);
    uint8_t mask[9] = { 0, 128, 255, 255, 128, 0, 64, 192, 32 };
    int32_t m = BKOverlayAddImage(l, 3, 3, BKOverlayImageAlpha8, mask, 3);
    BKOverlayColor tint = { 1, 0.4f, 0.1f, 1 };
    BKOverlayDrawImage(l, m, BKV2f(100, 15), BKV2f(8, 3), BKV2f(-3, 8), 0, tint);
    BKOverlaySetClip(l, 0, 100, 80, 20);
    BKOverlaySetIgnoreAlpha(l, 1);
    BKVec2f bar[4] = { {0, 105}, {160, 105}, {160, 118}, {0, 118} };
    BKOverlayColor half = { 0.5f, 0.5f, 0.5f, 0.3f };
    BKOverlayFillPolygon(l, bar, NULL, 4, BKOverlayFillFan, 0, half);
    XCTAssertEqual(BKOverlayListError(l), 0);

    // GPU
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [device newTextureWithDescriptor:td];
    NSMutableData *black = [NSMutableData dataWithLength:W * H * 4];
    for (uint32_t i = 0; i < W * H; i++) ((uint8_t *)black.mutableBytes)[i * 4 + 3] = 255;
    [tex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:black.bytes bytesPerRow:W * 4];
    id<MTLCommandQueue> q = [device newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    XCTAssertTrue([r renderList:l intoTexture:tex commandBuffer:cb error:&error], @"%@", error);
    [cb commit]; [cb waitUntilCompleted];
    NSMutableData *gpu = [NSMutableData dataWithLength:W * H * 4];
    [tex getBytes:gpu.mutableBytes bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];

    // CPU reference (black, opaque background)
    float *cpu = calloc(W * H * 4, sizeof(float));
    for (uint32_t i = 0; i < W * H; i++) cpu[i * 4 + 3] = 1;
    BKOverlayRasterize(l, cpu, W, H);

    // Compare: 8-bit rounding (<= 2/255) everywhere except a few edge pixels where the GPU's and the
    // reference's float maths fall on different sides of a pixel centre.
    const uint8_t *g = gpu.bytes;
    uint32_t off = 0;
    float worst = 0;
    for (uint32_t i = 0; i < W * H * 4; i++) {
        float d = fabsf(g[i] / 255.0f - fminf(fmaxf(cpu[i], 0), 1));
        if (d > 2.5f / 255.0f) off++;
        if (d > worst) worst = d;
    }
    NSLog(@"BKOverlayRenderer GPU vs CPU: %u of %u channel values differ by more than 2.5/255 (worst %.3f)", off, W * H * 4, worst);
    // Where they are (for diagnosis): bounding box of the differing pixels and a few examples.
    int bx0 = W, by0 = H, bx1 = -1, by1 = -1, shown = 0;
    for (uint32_t y = 0; y < H; y++)
        for (uint32_t x = 0; x < W; x++)
            for (int k = 0; k < 4; k++) {
                uint32_t i = (y * W + x) * 4 + k;
                float d = fabsf(g[i] / 255.0f - fminf(fmaxf(cpu[i], 0), 1));
                if (d <= 2.5f / 255.0f) continue;
                bx0 = MIN(bx0, (int)x); by0 = MIN(by0, (int)y); bx1 = MAX(bx1, (int)x); by1 = MAX(by1, (int)y);
                if (d > 0.3f && shown < 12) { shown++; NSLog(@"  differ at %u,%u ch %d: gpu %.3f cpu %.3f", x, y, k, g[i] / 255.0f, cpu[i]); }
            }
    if (bx1 >= 0) NSLog(@"  differing pixels within x %d..%d, y %d..%d", bx0, bx1, by0, by1);
    XCTAssertLessThan(off, W * H * 4 / 200);   // under 0.5 %
    free(cpu);
    BKOverlayListFree(l);
}

@end
