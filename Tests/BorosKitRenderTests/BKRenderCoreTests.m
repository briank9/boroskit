// Tests for BKRenderCore (the plain-C maths of the volume renderer).
// Original BorosKit code written for this project; contains no third-party code.
//
// What is checked, in plain terms:
//  - the portable 16-bit rounding (BKRenderQuantizeToSteps) gives exactly what Apple's
//    Accelerate routine used by the Metal upload gives, including values exactly halfway
//    between two steps (so a Windows/Linux upload stores the same volume);
//  - the transfer-function table baked by the core equals the one BKTransferFunction
//    hands out (they are the same code now; this guards against the two drifting apart);
//  - the brick grid and the "visible entries" running count on small hand-made examples.

#import <XCTest/XCTest.h>
#import <Accelerate/Accelerate.h>
#import "BorosKitRender.h"

@interface BKRenderCoreTests : XCTestCase
@end

@implementation BKRenderCoreTests

- (void)testQuantizeMatchesAccelerate
{
    // Whole numbers over a CT-like range, plus values that land exactly on .5 steps.
    const size_t n = 200000;
    float *values = malloc(n * sizeof(float));
    for (size_t i = 0; i < n; i++) values[i] = (float)((long)(i * 7919 % 5000) - 1024);
    BKRenderQuantization q = BKRenderQuantizationForRange(-1024, 3975, 1);
    // A second quantisation where step = 2 exactly, so odd inputs are exact ties (x.5).
    BKRenderQuantization tie = {0.0f, 131070.0f, 2.0f, 0};
    for (int pass = 0; pass < 2; pass++) {
        BKRenderQuantization use = pass ? tie : q;
        if (pass) for (size_t i = 0; i < n; i++) values[i] = (float)(i % 131071);
        uint16_t *core = malloc(n * sizeof(uint16_t)), *accel = malloc(n * sizeof(uint16_t));
        float *scratch = malloc(n * sizeof(float));
        BKRenderQuantizeToSteps(values, n, use, core);
        // Exactly the Accelerate sequence of -[BKVolumeTexture uploadFloats:...].
        const float negOffset = -use.valueOffset, invStep = 1.0f / use.step, zero = 0, top = 65535;
        vDSP_vsadd(values, 1, &negOffset, scratch, 1, n);
        vDSP_vsmul(scratch, 1, &invStep, scratch, 1, n);
        vDSP_vclip(scratch, 1, &zero, &top, scratch, 1, n);
        vDSP_vfixru16(scratch, 1, accel, 1, n);
        size_t differ = 0;
        for (size_t i = 0; i < n; i++) differ += core[i] != accel[i];
        XCTAssertEqual(differ, 0u, @"pass %d: portable rounding differs from Accelerate", pass);
        free(core); free(accel); free(scratch);
    }
    free(values);
}

- (void)testBakeMatchesTransferFunction
{
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    [tf addColorPointAtValue:-500 red:0.1f green:0.2f blue:0.3f];
    [tf addColorPointAtValue:700 red:1 green:0.9f blue:0.4f];
    [tf addOpacityPointAtValue:-100 opacity:0];
    [tf addOpacityPointAtValue:1200 opacity:0.8f];
    float *a = malloc(4096 * 4 * sizeof(float)), *b = malloc(4096 * 4 * sizeof(float));
    [tf bakeIntoRGBA:a count:4096];
    BKRenderTFPoint color[2] = {{-500, {0.1f, 0.2f, 0.3f}}, {700, {1, 0.9f, 0.4f}}};
    BKRenderTFPoint opacity[2] = {{-100, {0, 0, 0}}, {1200, {0.8f, 0, 0}}};
    BKRenderTFBake(color, 2, opacity, 2, b, 4096);
    XCTAssertEqual(memcmp(a, b, 4096 * 4 * sizeof(float)), 0);
    XCTAssertEqual(BKRenderTFMinimumValue(color, 2, opacity, 2), -500.0f);
    XCTAssertEqual(BKRenderTFMaximumValue(color, 2, opacity, 2), 1200.0f);
    free(a); free(b);
}

- (void)testBrickGridAndAlphaCount
{
    uint32_t g[3];
    BKRenderBrickGrid(64, 65, 1, 8, g);
    XCTAssertEqual(g[0], 8u);
    XCTAssertEqual(g[1], 9u);
    XCTAssertEqual(g[2], 1u);
    float rgba[4 * 5] = {0,0,0,0,  0,0,0,0.5f,  0,0,0,0,  0,0,0,1,  0,0,0,0.01f};
    uint32_t counts[6];
    BKRenderAlphaPrefixCount(rgba, 5, counts);
    uint32_t expected[6] = {0, 0, 1, 1, 2, 3};
    XCTAssertEqual(memcmp(counts, expected, sizeof counts), 0);
}

@end
