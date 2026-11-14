// BorosKitMesh: BKParallel (internal helper, not a public header)
// Original BorosKit code written for this project; contains no third-party code.
//
// What it is: one tiny function, BKParallelFor, that splits a long job ("do this for
// every vertex 0..N-1") into chunks and runs the chunks on all processor cores at once.
//
// Why it exists: smoothing and decimating meshes with millions of triangles is only fast
// enough if all cores work together. On Apple systems we use Grand Central Dispatch
// (Apple's thread pool). All multithreading in the mesh processing code goes through
// this ONE function, so nothing else mentions GCD; moving BorosKit to Windows/Linux only
// means using the std::thread version below (chosen automatically when not on Apple, or
// forced with -DBK_PARALLEL_USE_STD_THREAD=1).
//
// Rules for callers:
//   - the chunks run at the same time, so the work for one chunk must not write
//     anything that another chunk reads or writes;
//   - the result must not depend on how the work was split into chunks. Every caller in
//     BorosKit follows this, which is why the mesh results are identical whether 1 or
//     16 threads are used (checked by a test).

#pragma once

#include <cstddef>
#include <algorithm>
#include <atomic>

#if defined(__APPLE__) && !BK_PARALLEL_USE_STD_THREAD
#define BK_PARALLEL_GCD 1
#include <dispatch/dispatch.h>
#else
#define BK_PARALLEL_GCD 0
#include <thread>
#include <vector>
#endif

// What: the most threads BKParallelFor may use (0 = all cores, 1 = run everything on the
// calling thread). Why: tests run once with 1 thread and once with all threads and
// check the results are identical; also handy when debugging.
inline std::atomic<unsigned> &BKParallelMaxThreadsStorage()
{
    static std::atomic<unsigned> maxThreads(0);
    return maxThreads;
}

// What: calls body(begin, end) for consecutive ranges covering 0..count-1, in parallel.
// `grain` is the smallest useful chunk (tiny chunks cost more in bookkeeping than they
// save). Returns when every chunk has finished.
template <typename Body>
inline void BKParallelFor(size_t count, size_t grain, const Body &body)
{
    if (count == 0) return;
    if (grain < 1) grain = 1;
    unsigned maxThreads = BKParallelMaxThreadsStorage().load();
    // Aim for many more chunks than cores so a slow chunk does not hold up the rest,
    // but never chunks smaller than `grain`.
    size_t chunk = std::max(grain, count / 512 + 1);
    size_t chunks = (count + chunk - 1) / chunk;
    if (chunks <= 1 || maxThreads == 1) { body((size_t)0, count); return; }

#if BK_PARALLEL_GCD
    if (maxThreads == 0) {
        struct Context { const Body *body; size_t count, chunk; };
        Context context = {&body, count, chunk};
        dispatch_apply_f(chunks, DISPATCH_APPLY_AUTO, &context, [](void *raw, size_t i) {
            const Context *c = (const Context *)raw;
            size_t begin = i * c->chunk;
            size_t end = std::min(c->count, begin + c->chunk);
            (*c->body)(begin, end);
        });
        return;
    }
    // A limited thread count: run `maxThreads` workers, each taking every n-th chunk.
    struct Context { const Body *body; size_t count, chunk, chunks; unsigned workers; };
    Context context = {&body, count, chunk, chunks, maxThreads};
    dispatch_apply_f(maxThreads, DISPATCH_APPLY_AUTO, &context, [](void *raw, size_t w) {
        const Context *c = (const Context *)raw;
        for (size_t i = w; i < c->chunks; i += c->workers) {
            size_t begin = i * c->chunk;
            (*c->body)(begin, std::min(c->count, begin + c->chunk));
        }
    });
#else
    // Portable version: one std::thread per core (or per allowed thread), each taking
    // every n-th chunk.
    unsigned threads = maxThreads ? maxThreads : std::max(1u, std::thread::hardware_concurrency());
    threads = (unsigned)std::min<size_t>(threads, chunks);
    std::vector<std::thread> pool;
    for (unsigned t = 0; t < threads; t++) {
        pool.emplace_back([&, t]() {
            for (size_t i = t; i < chunks; i += threads) {
                size_t begin = i * chunk;
                body(begin, std::min(count, begin + chunk));
            }
        });
    }
    for (auto &th : pool) th.join();
#endif
}
