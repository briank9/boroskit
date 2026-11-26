// BorosKit plain-C core tests: the golden harness's head phantom, built by the CMake build, must give
// exactly the numbers recorded by the Mac (Tests/BorosKitGoldenTests/References/numbers_phantom.txt).
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (step M4).
// Why: "first check of any port: the phantom hash" (VULKAN-PORT-PLAN.md section 10). The phantom uses
// only + - * / sqrt floor and is compiled with -ffp-contract=off, so every platform must match bit for bit.

#include "BKCoreTest.h"
#include "BKGoldenCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef BK_GOLDEN_REFERENCES_DIR
#error "BK_GOLDEN_REFERENCES_DIR must name Tests/BorosKitGoldenTests/References (set by CMakeLists.txt)"
#endif

void bk_test_golden_phantom(void)
{
    BKGoldenVolume v;
    BK_CHECK(bk_golden_make_head_phantom(&v) == 0);
    if (!v.voxels) return;
    size_t count = (size_t)v.width * v.height * v.depth;
    double sum = 0, lo = INFINITY, hi = -INFINITY;
    for (size_t i = 0; i < count; i++) {
        double x = v.voxels[i];
        sum += x;
        if (x < lo) lo = x;
        if (x > hi) hi = x;
    }
    uint64_t hash = bk_golden_hash(v.voxels, count * sizeof(float));
    BKGoldenNumber mine[6];
    const char *names[6] = { "phantom_hash_low32", "phantom_hash_high32", "phantom_min", "phantom_max",
                             "phantom_mean", "noise_first_value" };
    double values[6] = { (double)(hash & 0xFFFFFFFFu), (double)(hash >> 32), lo, hi, sum / (double)count,
                         bk_golden_noise(BK_GOLDEN_HEAD_SEED, 0) };
    for (int i = 0; i < 6; i++) {
        strncpy(mine[i].name, names[i], sizeof mine[i].name - 1);
        mine[i].name[sizeof mine[i].name - 1] = 0;
        mine[i].value = values[i];
    }
    BKGoldenNumber *ref = NULL;
    size_t refCount = 0;
    BK_CHECK(bk_golden_read_numbers(BK_GOLDEN_REFERENCES_DIR "/numbers_phantom.txt", &ref, &refCount) == 0);
    int found = 0;
    for (int i = 0; i < 6; i++)
        for (size_t k = 0; k < refCount; k++)
            if (strcmp(mine[i].name, ref[k].name) == 0) {
                found++;
                BK_CHECK_SAME(mine[i].value, ref[k].value);   // strict: bit for bit
            }
    BK_CHECK(found == 6);
    free(ref);
    bk_golden_volume_free(&v);
}
