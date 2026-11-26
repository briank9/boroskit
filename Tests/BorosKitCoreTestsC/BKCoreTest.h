// BorosKit plain-C core tests: a tiny test runner of our own (no third-party test framework).
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (Vulkan engine kickoff, step M4).
//
// PORTING NOTES (Vulkan / Windows / Linux):
//   - Plain C99 (the threaded BKOnce test is C++17, std::thread). Built by CMake on every platform
//     (target bk_core_tests, run by ctest). No Apple, Objective-C or XCTest code.
//   - Every check is a macro that records the file / line and keeps going, so one run lists every failure.
//   - The expected numbers are the same as in the XCTest files of the cores (BKCameraMathTests.m,
//     BKMeshDrawCoreTests.m ...), so the Mac and other systems check identical facts. Later the XCTest
//     targets can call these very functions too (VULKAN-ENGINE-KICKOFF.md section 6, point 4).
//
// Plain language: a list of small "does this maths give the known answer?" checks that can run on any
// computer, not only on a Mac.

#ifndef BK_CORE_TEST_H
#define BK_CORE_TEST_H

#include <math.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// Counters of the current run (defined in BKCoreTestMain.c).
extern int bk_test_checks;
extern int bk_test_failures;

// What: report one failed check (file, line, what was checked).
void bk_test_fail(const char *file, int line, const char *what);

// BK_CHECK(cond): cond must be true.
#define BK_CHECK(cond) \
    do { bk_test_checks++; if (!(cond)) bk_test_fail(__FILE__, __LINE__, #cond); } while (0)

// BK_CHECK_NEAR(a, b, tol): |a - b| <= tol (NaN fails).
#define BK_CHECK_NEAR(a, b, tol) \
    do { double bk_a_ = (double)(a), bk_b_ = (double)(b); bk_test_checks++; \
         if (!(fabs(bk_a_ - bk_b_) <= (double)(tol))) { \
             char bk_msg_[256]; \
             snprintf(bk_msg_, sizeof bk_msg_, "%s = %.17g, expected %s = %.17g (tolerance %g)", #a, bk_a_, #b, bk_b_, (double)(tol)); \
             bk_test_fail(__FILE__, __LINE__, bk_msg_); } } while (0)

// BK_CHECK_SAME(a, b): exactly equal numbers (bit for bit for finite values; used where two code paths
// must compute the very same thing, e.g. BKMeshCameraAxes vs BKCameraRight).
#define BK_CHECK_SAME(a, b) \
    do { double bk_a_ = (double)(a), bk_b_ = (double)(b); bk_test_checks++; \
         if (!(bk_a_ == bk_b_)) { \
             char bk_msg_[256]; \
             snprintf(bk_msg_, sizeof bk_msg_, "%s = %.17g is not exactly %s = %.17g", #a, bk_a_, #b, bk_b_); \
             bk_test_fail(__FILE__, __LINE__, bk_msg_); } } while (0)

// One test = a function without arguments. The list lives in BKCoreTestMain.c.
typedef void (*BKCoreTestFunction)(void);

#ifdef __cplusplus
}
#endif

#endif // BK_CORE_TEST_H
