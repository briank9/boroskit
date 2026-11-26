// BorosKitSegmentation tests on the Mac (SwiftPM): the very same plain-C checks CMake runs as ctest core.seg_*
// (Tests/BorosKitCoreTestsC/BKSegmentationTests.c is compiled into this test target; as Objective-C, because the
// SwiftPM modules of these headers are Objective-C modules), with a tiny counter so the
// XCTest wrapper (BKSegmentationTests.m) can fail when any check fails. 2026-11-26, agent "segmentation".
// Original BorosKit code written for this project; contains no third-party code.

#define BK_TEST_OUTPUT_DIR ".build"
#include "../BorosKitCoreTestsC/BKSegmentationTests.c"

int bk_test_checks = 0;
int bk_test_failures = 0;

void bk_test_fail(const char *file, int line, const char *what)
{
    bk_test_failures++;
    printf("  FAIL %s:%d: %s\n", file, line, what);
}
