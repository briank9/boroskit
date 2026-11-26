// BorosKit plain-C core tests: BKOnce (portable run-once), single thread and many threads at once.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (step M4). C++17 only for std::thread (the portable way
// to start threads in a test); BKOnce itself is plain C.

#include "BKCoreTest.h"
#include "BKOnce.h"
#include <atomic>
#include <chrono>
#include <thread>
#include <vector>

static int gSetupCalls = 0;
static int gTable[64];

static void BKTestSetup(void)
{
    gSetupCalls++;
    for (int i = 0; i < 64; i++) gTable[i] = i * i;
}

extern "C" void bk_test_once_single_thread(void)
{
    static BKOnceFlag flag = BK_ONCE_INIT;
    gSetupCalls = 0;
    for (int i = 0; i < 5; i++) BKOnceRun(&flag, BKTestSetup);
    BK_CHECK(gSetupCalls == 1);
    BK_CHECK(gTable[7] == 49);
    BK_CHECK(flag == 2);
}

// Slow set-up, so the other threads really arrive while it runs and must wait.
static std::atomic<int> gSlowCalls(0);
static int gSlowTable[256];
static void BKTestSlowSetup(void)
{
    gSlowCalls++;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    for (int i = 0; i < 256; i++) gSlowTable[i] = 3 * i + 1;
}

extern "C" void bk_test_once_many_threads(void)
{
    for (int round = 0; round < 20; round++) {
        static BKOnceFlag flags[20];   // a fresh flag per round (zero = BK_ONCE_INIT)
        gSlowCalls = 0;
        for (int i = 0; i < 256; i++) gSlowTable[i] = 0;
        std::atomic<int> wrong(0);
        std::vector<std::thread> threads;
        for (int t = 0; t < 8; t++)
            threads.emplace_back([&]() {
                BKOnceRun(&flags[round], BKTestSlowSetup);
                // After BKOnceRun returns, the whole table must be visible to this thread.
                for (int i = 0; i < 256; i++) if (gSlowTable[i] != 3 * i + 1) wrong++;
            });
        for (auto &th : threads) th.join();
        BK_CHECK(gSlowCalls == 1);
        BK_CHECK(wrong == 0);
        if (round == 1) break;   // two rounds are enough (each sleeps 20 ms)
    }
}
