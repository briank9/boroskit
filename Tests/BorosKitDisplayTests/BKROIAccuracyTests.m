// Mac (XCTest) runner for the shared ROI accuracy phantoms (precision follow-up, 2026-11-26, agent "vulkan-engine").
// Original BorosKit code written for this project; contains no third-party code.
//
// What: compiles Tests/BorosKitCoreTestsC/BKAccuracyTests.c into this test file and runs its functions, so the
// Mac suite and the CMake / ctest suite (Windows / Linux / Mac) check IDENTICAL facts with identical code.
// The BK_CHECK macros of that file report through bk_test_fail below, which turns each failure into an
// XCTest failure.

#import <XCTest/XCTest.h>

// The tiny C runner's counters and failure hook (BKCoreTest.h), here backed by XCTest.
int bk_test_checks = 0;
int bk_test_failures = 0;
static NSMutableArray<NSString *> *gFailures;
void bk_test_fail(const char *file, int line, const char *what)
{
    bk_test_failures++;
    [gFailures addObject:[NSString stringWithFormat:@"%s:%d: %s", file, line, what]];
}

#include "../BorosKitCoreTestsC/BKAccuracyTests.c"

@interface BKROIAccuracyTests : XCTestCase
@end

@implementation BKROIAccuracyTests

// Runs one shared C test and fails with its messages.
- (void)run:(void (*)(void))test name:(NSString *)name
{
    gFailures = [NSMutableArray array];
    int before = bk_test_checks;
    test();
    XCTAssertGreaterThan(bk_test_checks, before, @"%@ ran no checks", name);
    for (NSString *f in gFailures) XCTFail(@"%@: %@", name, f);
}

- (void)testLength { [self run:bk_test_roi_accuracy_length name:@"REQ-ROI-LENGTH"]; }
- (void)testAngle { [self run:bk_test_roi_accuracy_angle name:@"REQ-ROI-ANGLE"]; }
- (void)testArea { [self run:bk_test_roi_accuracy_area name:@"REQ-ROI-AREA"]; }
- (void)testStatistics { [self run:bk_test_roi_accuracy_stats name:@"REQ-ROI-STATS"]; }
- (void)testCentre { [self run:bk_test_roi_accuracy_centre name:@"REQ-ROI-CENTRE"]; }

@end
