# BorosKit: the ONE list of portable plain-C / C++ core sources built by CMake (Windows / Linux / Mac).
# Original BorosKit code written for this project; contains no third-party code.
# Written 2026-11-25 by agent "vulkan-engine" (Vulkan engine kickoff, step M4).
#
# What: every *.c / *.cpp file under Sources/ is a backend-neutral core (no Objective-C, no Metal, no Apple
#       headers - docs/tools/check-portable-cores.sh proves it). They are named here explicitly, file by file.
# Why:  SwiftPM (Package.swift, the Mac build of Boros 6) picks files up by folder, CMake needs a list. So the
#       two builds cannot silently drift, CMakeLists.txt compares this list with what is really on disk and
#       stops with an error naming any core that is missing here (or listed but gone).
# Rule: adding a new core = add it to Sources/<Target>/ (SwiftPM sees it) AND here.

set(BOROSKIT_VEC_SOURCES
    Sources/BorosKitVec/BKVec.c
)

set(BOROSKIT_CORE_C_SOURCES
    # BorosKitCore (plain-C cores only; the Objective-C / Horos-derived files are never built here)
    Sources/BorosKitCore/BKContourCore.c
    Sources/BorosKitCore/BKKnotInterpCore.c
    Sources/BorosKitCore/BKRigidFitCore.c
    Sources/BorosKitCore/BKTiffCore.c
    # BorosKitDisplay
    Sources/BorosKitDisplay/BKAngleCore.c
    Sources/BorosKitDisplay/BKOverlayCore.c
    Sources/BorosKitDisplay/BKROICore.c
    Sources/BorosKitDisplay/BKROIDraw.c
    Sources/BorosKitDisplay/BKTextLayoutCore.c
    Sources/BorosKitDisplay/BKViewFrameState.c
    Sources/BorosKitDisplay/BKViewMatrix.c
    Sources/BorosKitDisplay/BKViewOverlayDraw.c
    Sources/BorosKitDisplay/BKViewPenState.c
    # BorosKitMeshRender
    Sources/BorosKitMeshRender/BKMeshDrawCore.c
    # BorosKitRender
    Sources/BorosKitRender/BKBoxWidgetMath.c
    Sources/BorosKitRender/BKCameraMath.c
    Sources/BorosKitRender/BKCropBoxCore.c
    Sources/BorosKitRender/BKCurveCore.c
    Sources/BorosKitRender/BKCurvedReformatCore.c
    Sources/BorosKitRender/BKGPUChoiceCore.c
    Sources/BorosKitRender/BKHeightBandCore.c
    Sources/BorosKitRender/BKOrientationCubeCore.c
    Sources/BorosKitRender/BKRenderCore.c
    Sources/BorosKitRender/BKScanGeometryCore.c
    Sources/BorosKitRender/BKSlabBrickCore.c
    Sources/BorosKitRender/BKSlabCameraCore.c
    Sources/BorosKitRender/BKSlabColourCore.c
    Sources/BorosKitRender/BKSlabGeometryCore.c
    Sources/BorosKitRender/BKSlabScanCore.c
    Sources/BorosKitRender/BKSlabViewCore.c
    Sources/BorosKitRender/BKStereoCore.c
    Sources/BorosKitRender/BKThickSlabCore.c
    Sources/BorosKitRender/BKVolumeFusionCore.c
    Sources/BorosKitRender/BKVolumeRayCore.c
    # BorosKitSurface
    Sources/BorosKitSurface/BKSurfaceCore.c
)

set(BOROSKIT_CORE_CXX_SOURCES
    Sources/BorosKitMesh/BKMeshProcessingCore.cpp
    Sources/BorosKitMesh/BKSceneExportCore.cpp
)

# Header folders the cores include from (public include/ folders and the folders holding private core
# headers such as BKMeshProcessingCore.h and BKShaderTypes.h).
set(BOROSKIT_CORE_INCLUDE_DIRS
    Sources/BorosKitVec/include
    Sources/BorosKitCore/include
    Sources/BorosKitDisplay/include
    Sources/BorosKitDisplay
    Sources/BorosKitMesh
    Sources/BorosKitMeshRender/include
    Sources/BorosKitRender/include
    Sources/BorosKitRender
    Sources/BorosKitSurface/include
)
