// BorosKitVec: BKOnce - run a set-up function exactly once, from any thread, in portable C.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (Vulkan engine kickoff, step M1).
//
// PORTING NOTES (Vulkan / Windows / Linux):
//   - Header only, plain C99 + compiler atomic built-ins. No <pthread.h>, no <threads.h>, no
//     Apple or Windows headers with clang or GCC (the compilers BorosKit uses on every platform:
//     Apple clang, clang / clang-cl, GCC). Plain MSVC (cl.exe, no clang) is covered by a small
//     branch on the Interlocked intrinsics from <intrin.h>.
//   - Replaces pthread_once in the plain-C cores (first user: BKSurfaceCore's marching-cubes
//     tables). pthread_once does not exist with MSVC / clang-cl on Windows, and C11 call_once
//     (<threads.h>) is missing from Apple's C library, so neither is portable.
//   - Memory order: the "done" flag is written with RELEASE after the set-up function returns and
//     read with ACQUIRE, so every thread that sees "done" also sees everything the set-up wrote.
//
// What: BKOnceRun(&flag, setup) calls setup() the first time any thread reaches it; every other
// caller (at the same time or later) waits until setup() has finished, then returns. The flag is
// a plain int32 that starts at 0 (BK_ONCE_INIT), so it can be a static variable.
// Why: tables that are computed on first use (instead of being copied from a publication, which
// would bring a third-party licence) must be built exactly once even when two threads ask for
// them at the same moment.
//
// Limits (on purpose, to keep it tiny): setup() must not call BKOnceRun on the same flag (it would
// wait for itself forever), and it should be short - a waiting thread spins (checks the flag in a
// loop) instead of sleeping. Every current user builds a table in microseconds.
//
// Plain language: "do this once, and make everybody else wait for the first one to finish".

#ifndef BK_ONCE_H
#define BK_ONCE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The flag. 0 = set-up not started, 1 = running in some thread, 2 = finished.
typedef volatile int32_t BKOnceFlag;
#define BK_ONCE_INIT 0

#if defined(_MSC_VER) && !defined(__clang__)
// Plain MSVC: Interlocked functions are full barriers (stronger than acquire/release - fine).
#include <intrin.h>
static inline int32_t BKOnceLoad_(BKOnceFlag *flag)
{
    return (int32_t)_InterlockedCompareExchange((volatile long *)flag, 0, 0);
}
static inline int BKOnceClaim_(BKOnceFlag *flag)
{
    return _InterlockedCompareExchange((volatile long *)flag, 1, 0) == 0;
}
static inline void BKOnceFinish_(BKOnceFlag *flag) { _InterlockedExchange((volatile long *)flag, 2); }
#else
// clang / GCC: the __atomic built-ins (available in C99 mode, no header needed).
static inline int32_t BKOnceLoad_(BKOnceFlag *flag) { return __atomic_load_n(flag, __ATOMIC_ACQUIRE); }
static inline int BKOnceClaim_(BKOnceFlag *flag)
{
    int32_t expected = 0;
    return __atomic_compare_exchange_n(flag, &expected, 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}
static inline void BKOnceFinish_(BKOnceFlag *flag) { __atomic_store_n(flag, 2, __ATOMIC_RELEASE); }
#endif

// What: run setup() once per flag (see the top of this file). Cheap after the first call: one
// atomic read.
static inline void BKOnceRun(BKOnceFlag *flag, void (*setup)(void))
{
    if (BKOnceLoad_(flag) == 2) return;          // usual case: already done
    if (BKOnceClaim_(flag)) {                    // this thread won the race: do the work
        setup();
        BKOnceFinish_(flag);
        return;
    }
    while (BKOnceLoad_(flag) != 2) { }           // another thread is working: wait for it
}

#ifdef __cplusplus
}
#endif

#endif // BK_ONCE_H
