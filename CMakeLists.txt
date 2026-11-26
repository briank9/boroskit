# BorosKit: CMake build of the portable plain-C / C++ cores and their tests (Windows / Linux / Mac).
# Original BorosKit code written for this project; contains no third-party code.
# Written 2026-11-25 by agent "vulkan-engine" (Vulkan engine kickoff, step M4; VULKAN-ENGINE-KICKOFF.md
# section 5).
#
# PORTING NOTES:
#   - This is NOT the Mac app build: Boros 6 keeps using Package.swift (SwiftPM, Metal, Objective-C).
#     CMake builds only what must also run on Windows / Linux: the cores (and, from step M6 on, the
#     Vulkan engine, which never appears in Package.swift, so Boros 6 never needs the Vulkan SDK).
#   - Compiler: clang everywhere is the plan (Apple clang here, clang on Linux, clang-cl on Windows), so the
#     C maths behaves the same; GCC is accepted for the cores. Not yet tried on Windows / Linux (to verify).
#   - Floating point (user decision D3): -ffp-contract=off, never fast-math. The SwiftPM build does not pin
#     this yet - see VULKAN-ENGINE-PROGRESS.md (it changes the ROI core's results; awaiting the user).
#
# Use (from the BorosKit folder; the build folder build-cmake/ is git-ignored):
#   cmake -S . -B build-cmake -DCMAKE_BUILD_TYPE=Release
#   cmake --build build-cmake
#   ctest --test-dir build-cmake --output-on-failure

cmake_minimum_required(VERSION 3.24)
project(BorosKit LANGUAGES C CXX)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)          # strict C99, like docs/tools/check-portable-cores.sh
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release)
endif()

include(cmake/BorosKitSources.cmake)

# ---- One list of sources: stop if a core on disk is not listed (or a listed one is gone) ----------------
file(GLOB_RECURSE BK_CORES_ON_DISK RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}"
     "${CMAKE_CURRENT_SOURCE_DIR}/Sources/*.c" "${CMAKE_CURRENT_SOURCE_DIR}/Sources/*.cpp")
set(BK_CORES_LISTED ${BOROSKIT_VEC_SOURCES} ${BOROSKIT_CORE_C_SOURCES} ${BOROSKIT_CORE_CXX_SOURCES})
set(BK_MISSING ${BK_CORES_ON_DISK})
list(REMOVE_ITEM BK_MISSING ${BK_CORES_LISTED})
set(BK_GONE ${BK_CORES_LISTED})
list(REMOVE_ITEM BK_GONE ${BK_CORES_ON_DISK})
if(BK_MISSING OR BK_GONE)
    message(FATAL_ERROR "cmake/BorosKitSources.cmake is out of date.\n  On disk but not listed: ${BK_MISSING}\n  Listed but not on disk: ${BK_GONE}")
endif()

# ---- The floating-point rule for every BorosKit target -------------------------------------------------
add_library(boroskit_flags INTERFACE)
if(MSVC AND NOT CMAKE_C_COMPILER_ID MATCHES "Clang")
    # Plain MSVC: precise model, no contraction (to verify on Windows; clang-cl is the plan).
    target_compile_options(boroskit_flags INTERFACE /fp:precise /fp:contract-)
elseif(MSVC)
    # clang-cl: the clang flag passed through.
    target_compile_options(boroskit_flags INTERFACE /fp:precise /clang:-ffp-contract=off)
else()
    target_compile_options(boroskit_flags INTERFACE -ffp-contract=off -fno-fast-math)
endif()
target_compile_definitions(boroskit_flags INTERFACE
    _USE_MATH_DEFINES     # Windows: M_PI etc. from <math.h>
    _DEFAULT_SOURCE       # Linux glibc: M_PI under strict -std=c99
)
if(NOT MSVC)
    target_compile_options(boroskit_flags INTERFACE -Wall -Wno-unused-function)
endif()

# ---- Libraries ------------------------------------------------------------------------------------------
# boroskit_vec: BorosKit's own vector types, run-once, parallel-for and GPU block types (header-only + BKVec.c).
add_library(boroskit_vec STATIC ${BOROSKIT_VEC_SOURCES})
target_include_directories(boroskit_vec PUBLIC Sources/BorosKitVec/include)
target_link_libraries(boroskit_vec PUBLIC boroskit_flags)

# boroskit_cores: every portable plain-C / C++ core.
find_package(Threads REQUIRED)        # std::thread for BKParallelFor off Apple (system threads, not a library)
add_library(boroskit_cores STATIC ${BOROSKIT_CORE_C_SOURCES} ${BOROSKIT_CORE_CXX_SOURCES})
target_include_directories(boroskit_cores PUBLIC ${BOROSKIT_CORE_INCLUDE_DIRS})
target_link_libraries(boroskit_cores PUBLIC boroskit_vec Threads::Threads)
if(NOT APPLE)
    target_compile_definitions(boroskit_cores PRIVATE BK_PARALLEL_USE_STD_THREAD=1)
endif()

# bk_golden_core: the golden harness's plain-C half (phantoms, file formats, comparers), shared with the
# Mac XCTest runner and, later, the Vulkan golden runner.
add_library(bk_golden_core STATIC Tests/BorosKitGoldenTests/BKGoldenCore.c)
target_include_directories(bk_golden_core PUBLIC Tests/BorosKitGoldenTests)
target_link_libraries(bk_golden_core PUBLIC boroskit_flags)

# ---- Tests ----------------------------------------------------------------------------------------------
enable_testing()

add_executable(bk_core_tests
    Tests/BorosKitCoreTestsC/BKCoreTestMain.c
    Tests/BorosKitCoreTestsC/BKVecGPUTypesTests.c
    Tests/BorosKitCoreTestsC/BKCameraMathTests.c
    Tests/BorosKitCoreTestsC/BKMeshDrawCoreTests.c
    Tests/BorosKitCoreTestsC/BKOnceTests.cpp
    Tests/BorosKitCoreTestsC/BKGoldenPhantomTest.c
)
target_link_libraries(bk_core_tests PRIVATE boroskit_cores bk_golden_core)
target_compile_definitions(bk_core_tests PRIVATE
    BK_GOLDEN_REFERENCES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Tests/BorosKitGoldenTests/References")

# One ctest entry per test function (names from `bk_core_tests --list`).
set(BK_CORE_TEST_NAMES
    vec_basics gpu_types_layout
    camera_right_vector camera_ortho_ray_and_scale camera_perspective_ray camera_project_inverts_ray
    camera_world_delta
    mesh_facing_rule mesh_texture_expand_rule mesh_texture_sample_rule mesh_camera_axes
    mesh_uniforms_fill mesh_uniforms_model_and_colour mesh_depth_range
    once_single_thread once_many_threads
    golden_phantom
)
foreach(name IN LISTS BK_CORE_TEST_NAMES)
    add_test(NAME core.${name} COMMAND bk_core_tests ${name})
endforeach()

# The layout tests again with the plain-struct GPU types (what GCC / plain MSVC compile).
add_executable(bk_layout_portable_test
    Tests/BorosKitCoreTestsC/BKLayoutPortableMain.c
    Tests/BorosKitCoreTestsC/BKVecGPUTypesTests.c
)
target_link_libraries(bk_layout_portable_test PRIVATE boroskit_cores)
target_compile_definitions(bk_layout_portable_test PRIVATE BK_GPU_TYPES_PORTABLE_STRUCTS=1)
add_test(NAME core.gpu_types_layout_portable_structs COMMAND bk_layout_portable_test)
