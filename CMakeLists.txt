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
#   - Floating point (user decision D3, 2026-11-25): -ffp-contract=off, never fast-math - the same flag as
#     Package.swift, so the CPU cores give identical bits in both builds (ctest golden_cpu_* proves it).
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
set(BK_CORES_LISTED ${BOROSKIT_VEC_SOURCES} ${BOROSKIT_CORE_C_SOURCES} ${BOROSKIT_CORE_CXX_SOURCES} ${BOROSKIT_GPU_VULKAN_SOURCES})
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

# boroskit_gpu: the backend-neutral GPU interface (BKGPU.h, C++17, header only so far; step M5).
add_library(boroskit_gpu INTERFACE)
target_include_directories(boroskit_gpu INTERFACE Sources/BorosKitGPU/include)
target_compile_features(boroskit_gpu INTERFACE cxx_std_17)

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
    Tests/BorosKitCoreTestsC/BKGoldenCPUCoresTest.cpp
    Tests/BorosKitCoreTestsC/BKAccuracyTests.c
    Tests/BorosKitCoreTestsC/BKMeshAccuracyTests.cpp
    Tests/BorosKitCoreTestsC/BKExportAccuracyTests.cpp
    Tests/BorosKitCoreTestsC/BKSegmentationTests.c       # 2026-11-26: segmentations as label maps
    Tests/BorosKitCoreTestsC/BKRenderParamsTests.c       # 2026-11-26: ray-cast parameter block (7.1 #4a)
)
target_link_libraries(bk_core_tests PRIVATE boroskit_cores bk_golden_core)
target_compile_definitions(bk_core_tests PRIVATE
    BK_GOLDEN_REFERENCES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Tests/BorosKitGoldenTests/References"
    BK_TEST_OUTPUT_DIR="${CMAKE_CURRENT_BINARY_DIR}")

# One ctest entry per test function (names from `bk_core_tests --list`).
set(BK_CORE_TEST_NAMES
    vec_basics gpu_types_layout
    camera_right_vector camera_ortho_ray_and_scale camera_perspective_ray camera_project_inverts_ray
    camera_world_delta
    mesh_facing_rule mesh_texture_expand_rule mesh_texture_sample_rule mesh_camera_axes
    mesh_uniforms_fill mesh_uniforms_model_and_colour mesh_depth_range
    once_single_thread once_many_threads
    golden_phantom golden_cpu_numbers golden_cpu_meshes
    roi_accuracy_length roi_accuracy_angle roi_accuracy_area roi_accuracy_stats roi_accuracy_centre
    mesh_accuracy_box export_accuracy_geometry
    seg_round_trip seg_damaged_files seg_counts_volumes seg_slices_planes seg_overlay_picture seg_mask_surface
    render_params_frame render_params_fields render_params_clut
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

# BKGPU.h compiles alone (no Apple / Vulkan headers) and can be implemented (a CPU-only stand-in device).
add_executable(bk_gpu_interface_test Tests/BorosKitCoreTestsC/BKGPUInterfaceTest.cpp)
target_link_libraries(bk_gpu_interface_test PRIVATE boroskit_gpu boroskit_flags)
if(NOT MSVC)
    target_compile_options(bk_gpu_interface_test PRIVATE -Wextra -pedantic -Werror)
endif()
add_test(NAME gpu.interface COMMAND bk_gpu_interface_test)

# ---- Vulkan engine (step M6+, 2026-11-26) ----------------------------------------------------------------------
# Needs the Vulkan SDK at BUILD time only: headers, glslc, spirv-val (user decisions D1 / D2). Found through the
# VULKAN_SDK environment variable or the usual install places; without it the Vulkan part is skipped.
find_path(BK_VULKAN_INCLUDE_DIR vulkan/vulkan.h HINTS "$ENV{VULKAN_SDK}/include" /usr/local/include)
find_program(BK_GLSLC glslc HINTS "$ENV{VULKAN_SDK}/bin")
find_program(BK_SPIRV_VAL spirv-val HINTS "$ENV{VULKAN_SDK}/bin")
if(BK_VULKAN_INCLUDE_DIR AND BK_GLSLC AND BK_SPIRV_VAL)
    message(STATUS "BorosKit Vulkan engine: headers ${BK_VULKAN_INCLUDE_DIR}, ${BK_GLSLC}, ${BK_SPIRV_VAL}")
    # GLSL -> SPIR-V (SPIR-V for Vulkan 1.2 so compute workgroup sizes need no maintenance4 feature; optimised, no fast-math options exist in glslc) -> spirv-val -> embedded table.
    set(BK_SPIRV_FILES "")
    foreach(shader IN LISTS BOROSKIT_GPU_VULKAN_SHADERS)
        get_filename_component(name "${shader}" NAME)
        set(spv "${CMAKE_CURRENT_BINARY_DIR}/shaders/${name}.spv")
        add_custom_command(OUTPUT "${spv}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/shaders"
            COMMAND ${BK_GLSLC} --target-env=vulkan1.2 -O
                    -I "${CMAKE_CURRENT_SOURCE_DIR}/Sources/BorosKitGPUVulkan/Shaders"
                    -I "${CMAKE_CURRENT_SOURCE_DIR}/Sources/BorosKitMeshRender/include"
                    -I "${CMAKE_CURRENT_SOURCE_DIR}/Sources/BorosKitSurface/include"
                    -I "${CMAKE_CURRENT_SOURCE_DIR}/Sources/BorosKitRender"
                    -I "${CMAKE_CURRENT_SOURCE_DIR}/Sources/BorosKitRender/include"
                    -I "${CMAKE_CURRENT_SOURCE_DIR}/Sources/BorosKitVec/include"
                    -I "${CMAKE_CURRENT_SOURCE_DIR}/Sources/BorosKitDisplay"
                    -I "${CMAKE_CURRENT_SOURCE_DIR}/Sources/BorosKitDisplay/include"
                    -MD -MF "${spv}.d" -o "${spv}" "${CMAKE_CURRENT_SOURCE_DIR}/${shader}"
            COMMAND ${BK_SPIRV_VAL} --target-env vulkan1.2 "${spv}"
            DEPENDS "${shader}" DEPFILE "${spv}.d"
            COMMENT "glslc + spirv-val ${name}" VERBATIM)
        list(APPEND BK_SPIRV_FILES "${spv}")
    endforeach()
    set(BK_SHADER_TABLE "${CMAKE_CURRENT_BINARY_DIR}/shaders/BKVulkanShaderTable.cpp")
    add_custom_command(OUTPUT "${BK_SHADER_TABLE}"
        COMMAND ${CMAKE_COMMAND} "-DOUTPUT=${BK_SHADER_TABLE}" "-DSPIRV_FILES=${BK_SPIRV_FILES}"
                -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/BKEmbedSpirv.cmake"
        DEPENDS ${BK_SPIRV_FILES} "${CMAKE_CURRENT_SOURCE_DIR}/cmake/BKEmbedSpirv.cmake"
        COMMENT "Embedding SPIR-V" VERBATIM)

    # boroskit_gpu_vulkan: the backend. Nothing from Vulkan is linked (own loader, dlopen at run time).
    add_library(boroskit_gpu_vulkan STATIC ${BOROSKIT_GPU_VULKAN_SOURCES} "${BK_SHADER_TABLE}")
    target_include_directories(boroskit_gpu_vulkan PUBLIC Sources/BorosKitGPUVulkan/include
                               PRIVATE Sources/BorosKitGPUVulkan "${BK_VULKAN_INCLUDE_DIR}")
    target_link_libraries(boroskit_gpu_vulkan PUBLIC boroskit_gpu boroskit_cores ${CMAKE_DL_LIBS})

    # Milestone 1 tests. The loader is told to use MoltenVK (this Mac; the SDK also has KosmicKrisp) and to
    # find the validation layer in the SDK; MoltenVK's fast-math is switched off for golden runs.
    set(BK_VULKAN_TEST_ENV "")
    if(APPLE AND DEFINED ENV{VULKAN_SDK})
        set(BK_VULKAN_TEST_ENV
            "VK_DRIVER_FILES=$ENV{VULKAN_SDK}/share/vulkan/icd.d/MoltenVK_icd.json"
            "MVK_CONFIG_FAST_MATH_ENABLED=0")
        # The SDK installer normally also puts the layers in /usr/local; adding the SDK folder a second time
        # would make the loader warn about duplicates (which the tests count), so only when they are missing.
        if(NOT EXISTS "/usr/local/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json")
            list(APPEND BK_VULKAN_TEST_ENV "VK_ADD_LAYER_PATH=$ENV{VULKAN_SDK}/share/vulkan/explicit_layer.d")
        endif()
    endif()
    # Tests shared by every backend (2026-11-26, phase 2): triangle, golden meshes through BKMeshPass, winding,
    # feature scene. Linked into the Vulkan programs below and the Apple-only Metal + Vulkan cross program.
    add_library(bk_gpu_shared_tests STATIC Tests/BorosKitGPUShared/BKGPUSharedTests.cpp)
    target_include_directories(bk_gpu_shared_tests PUBLIC Tests/BorosKitGPUShared)
    target_link_libraries(bk_gpu_shared_tests PUBLIC boroskit_gpu boroskit_cores bk_golden_core)

    add_executable(bk_vulkan_triangle_test Tests/BorosKitGoldenVulkan/BKVulkanTriangleTest.cpp)
    target_include_directories(bk_vulkan_triangle_test PRIVATE Tests/BorosKitGoldenVulkan)
    target_link_libraries(bk_vulkan_triangle_test PRIVATE boroskit_gpu_vulkan bk_gpu_shared_tests)
    add_test(NAME vulkan.triangle COMMAND bk_vulkan_triangle_test)

    add_executable(bk_golden_vulkan Tests/BorosKitGoldenVulkan/BKGoldenVulkan.cpp Tests/BorosKitGoldenVulkan/BKPNGWrite.c)
    target_include_directories(bk_golden_vulkan PRIVATE Tests/BorosKitGoldenVulkan)
    target_link_libraries(bk_golden_vulkan PRIVATE boroskit_gpu_vulkan bk_gpu_shared_tests bk_golden_core)
    target_compile_definitions(bk_golden_vulkan PRIVATE
        BK_GOLDEN_REFERENCES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Tests/BorosKitGoldenTests/References")
    set(BK_MILESTONE_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/milestone1" CACHE PATH "where bk_golden_vulkan writes its pictures")
    file(MAKE_DIRECTORY "${BK_MILESTONE_OUTPUT}")
    add_test(NAME vulkan.golden_mesh COMMAND bk_golden_vulkan "${BK_MILESTONE_OUTPUT}")
    set(BK_VULKAN_TESTS vulkan.triangle vulkan.golden_mesh)

    # Apple only: the Metal device built by CMake too (BKGPUMetal.mm + BKMetalDevice.m + the mesh MSL source), so one
    # program can run the shared tests on Metal AND Vulkan and compare them live (kickoff plan section 6, point 3).
    if(APPLE)
        enable_language(OBJC OBJCXX)
        add_library(boroskit_gpu_metal STATIC
            Sources/BorosKitGPU/BKGPUMetal.mm
            Sources/BorosKitRender/BKMetalDevice.m
            Sources/BorosKitMeshRender/BKMeshShaderSource.mm
            Sources/BorosKitSurface/BKSurfaceShaderSource.mm    # 2026-11-26: surface MSL (SurfacePass on Metal)
            Sources/BorosKitRender/BKShaderSource.mm            # 2026-11-26: volume MSL (RaycastPass on Metal)
            Sources/BorosKitRender/BKReformatShaderSource.mm    # 2026-11-26: reformat MSL (ReformatPass on Metal)
            Sources/BorosKitDisplay/BKDisplayShaderSource.mm    # 2026-11-26: 2D display MSL (DisplayPass on Metal)
            Sources/BorosKitDisplay/BKOverlayShaderSource.mm)   # 2026-11-26: 2D overlay MSL (OverlayPass on Metal)
        target_include_directories(boroskit_gpu_metal PUBLIC Sources/BorosKitGPU/include)
        target_compile_options(boroskit_gpu_metal PRIVATE -fobjc-arc)
        target_link_libraries(boroskit_gpu_metal PUBLIC boroskit_gpu boroskit_cores "-framework Metal" "-framework Foundation")
        add_executable(bk_gpu_cross Tests/BorosKitGoldenVulkan/BKGPUCrossTest.mm Tests/BorosKitGPUShared/BKGPUTestMetal.mm
                       Tests/BorosKitGoldenVulkan/BKPNGWrite.c)
        target_include_directories(bk_gpu_cross PRIVATE Tests/BorosKitGoldenVulkan)
        target_compile_options(bk_gpu_cross PRIVATE -fobjc-arc)
        target_link_libraries(bk_gpu_cross PRIVATE boroskit_gpu_vulkan boroskit_gpu_metal bk_gpu_shared_tests bk_golden_core)
        target_compile_definitions(bk_gpu_cross PRIVATE
            BK_GOLDEN_REFERENCES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/Tests/BorosKitGoldenTests/References")
        add_test(NAME gpu.metal_vs_vulkan COMMAND bk_gpu_cross "${BK_MILESTONE_OUTPUT}")
        list(APPEND BK_VULKAN_TESTS gpu.metal_vs_vulkan)
    endif()
    set_tests_properties(${BK_VULKAN_TESTS} PROPERTIES ENVIRONMENT "${BK_VULKAN_TEST_ENV}")
else()
    message(STATUS "BorosKit Vulkan engine: SKIPPED (Vulkan SDK headers / glslc / spirv-val not found; set VULKAN_SDK)")
endif()
