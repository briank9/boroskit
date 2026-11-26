// BorosKit Vulkan tests: milestone 1 part (a) - one flat-coloured triangle (step M7), and (2026-11-26, phase 3) the
// front / back face test. The checks themselves are the shared code Tests/BorosKitGPUShared (same on Metal).
// Original BorosKit code written for this project; contains no third-party code. Agent "vulkan-engine".
// Pass = the shared checks pass AND zero validation-layer messages.

#include "BKVulkanTestSupport.h"
#include "BKGPUSharedTests.h"

using namespace bktest;

int main()
{
    Messages messages;
    int failures = 0;
    {
        std::unique_ptr<Device> device = StartDevice(&messages);
        if (!device) return 1;
        failures += bkshared::TestTriangle(*device);
        failures += bkshared::TestWinding(*device);
    }   // everything destroyed first, so clean-up messages are counted too
    std::printf("validation messages: %d errors, %d warnings\n", messages.errors, messages.warnings);
    if (messages.errors || messages.warnings) failures++;
    std::printf("%s Vulkan triangle + winding\n", failures ? "FAILED" : "PASSED");
    return failures ? 1 : 0;
}
