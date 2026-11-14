// Speed check for the shader maths setting (2026-11-14, user: "how will switching off fast math
// affect speed"). Runs ONLY when the environment variable BK_BENCH=1 is set, so normal test runs
// skip it. BK_BENCH_MATH = safe | relaxed | fast picks the mode (one mode per process, because
// shader libraries are compiled once per GPU and cached).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// What it measures: the GPU time of 3D (composite, shaded, empty-space skipping on) and MIP renders
// of a 256^3 "skull-like" phantom (a thick shell with noise + an inner blob) at 1024 x 1024, median
// of 40 frames, printed as "BKBENCH <mode> composite <ms> mip <ms>".

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

@interface BKShaderMathBenchmarkTests : XCTestCase
@end

@implementation BKShaderMathBenchmarkTests

static double BKMedian(NSMutableArray<NSNumber *> *a)
{
    [a sortUsingSelector:@selector(compare:)];
    return a.count ? a[a.count / 2].doubleValue : 0;
}

- (double)timeRenderer:(BKVolumeRenderer *)r target:(id<MTLTexture>)target frames:(int)frames
{
    NSMutableArray<NSNumber *> *times = [NSMutableArray array];
    NSError *error = nil;
    for (int i = 0; i < frames + 3; i++) {
        id<MTLCommandBuffer> cb = [r.commandQueue commandBuffer];
        XCTAssertTrue([r encodeRenderToTexture:target commandBuffer:cb backgroundColor:simd_make_float4(0, 0, 0, 1) error:&error], @"%@", error);
        [cb commit];
        [cb waitUntilCompleted];
        if (i >= 3) [times addObject:@((cb.GPUEndTime - cb.GPUStartTime) * 1000.0)];   // skip warm-up frames
    }
    return BKMedian(times);
}

- (void)testShaderMathSpeed
{
    NSDictionary *env = [NSProcessInfo processInfo].environment;
    if (![env[@"BK_BENCH"] isEqualToString:@"1"]) return;   // opt-in only
    NSString *mode = env[@"BK_BENCH_MATH"] ?: @"safe";
    BKMetalDevice.shaderMath = [mode isEqualToString:@"fast"] ? BKShaderMathFast
                             : ([mode isEqualToString:@"relaxed"] ? BKShaderMathRelaxed : BKShaderMathSafe);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) return;

    const NSUInteger n = 256;
    float *v = malloc(sizeof(float) * n * n * n);
    uint32_t seed = 12345;
    for (NSUInteger z = 0; z < n; z++)
        for (NSUInteger y = 0; y < n; y++)
            for (NSUInteger x = 0; x < n; x++) {
                double dx = x - 128.0, dy = y - 128.0, dz = (z - 128.0) * 1.2;
                double r = sqrt(dx * dx + dy * dy + dz * dz);
                seed = seed * 1664525u + 1013904223u;
                double noise = ((seed >> 8) & 0xFFFF) / 65535.0 * 200.0 - 100.0;
                double val = -1000.0;
                if (r > 95 && r < 110) val = 1200.0 + noise;            // "skull" shell
                else if (r < 95) val = 40.0 + noise;                    // soft tissue inside
                if (fabs(dx - 30) < 20 && fabs(dy) < 15 && fabs(dz + 20) < 25) val = 900.0 + noise;   // inner "bone"
                v[(z * n + y) * n + x] = (float)val;
            }
    double o[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    CPRVolumeData *data = [[CPRVolumeData alloc] initWithFloatBytesNoCopy:v pixelsWide:n pixelsHigh:n pixelsDeep:n
                                                                   origin:N3VectorMake(-128, -128, -128) orientation:o
                                                                 spacingX:1 spacingY:1 spacingZ:1 freeWhenDone:YES];
    NSError *error = nil;
    BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    XCTAssertTrue([r setVolumeData:data error:&error], @"%@", error);
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];   // bone-ish: soft tissue faint, bone opaque
    [tf addColorPointAtValue:-1000 red:0 green:0 blue:0];
    [tf addColorPointAtValue:300 red:0.9 green:0.7 blue:0.6];
    [tf addColorPointAtValue:1500 red:1 green:1 blue:0.9];
    [tf addOpacityPointAtValue:-1000 opacity:0];
    [tf addOpacityPointAtValue:100 opacity:0];
    [tf addOpacityPointAtValue:300 opacity:0.05];
    [tf addOpacityPointAtValue:1000 opacity:0.8];
    [tf addOpacityPointAtValue:1500 opacity:1];
    r.transferFunction = tf;
    r.shadingEnabled = YES;
    r.skipsEmptySpace = YES;
    BKVolumeCamera *camera = [[BKVolumeCamera alloc] init];
    [camera resetToBoxMin:N3VectorMake(-128, -128, -128) max:N3VectorMake(127, 127, 127)];
    [camera showStandardView:BKStandardViewAnterior];
    [camera azimuth:30];
    [camera elevation:20];
    [camera applyToRenderer:r aspectRatio:1];

    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1024 height:1024 mipmapped:NO];
    d.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:d];

    r.mode = BKRenderModeComposite;
    double composite = [self timeRenderer:r target:target frames:40];
    r.mode = BKRenderModeMIP;
    r.windowCenter = 400; r.windowWidth = 2000;
    double mip = [self timeRenderer:r target:target frames:40];
    printf("BKBENCH %s composite %.2f ms mip %.2f ms\n", mode.UTF8String, composite, mip);
    fflush(stdout);
}

@end
