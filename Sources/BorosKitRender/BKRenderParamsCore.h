// BorosKitRender: BKRenderParamsCore.h - the volume ray caster's parameter block (BKRenderParams) built in plain C,
// and the preset -> transfer-function rules (plan refactor R3 / audit finding 2).
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan step 7.1 #4a). The arithmetic is moved one-to-one from
// -[BKVolumeRenderer fillParams:...] and +[BKTransferFunction transferFunctionWithCLUTRed:...], so the Metal pictures
// stay bit-identical (golden strict).
//
// PORTING NOTES:
//   - Plain C99, no Apple simd / Objective-C / Horos-derived N3 types: Vulkan and the Windows / Linux build use it.
//   - User-visible geometry comes in as double (precision rule, BOROSCMF-FRAMEWORK.md section 8); the block itself
//     is float (GPU picture). Every double -> float conversion happens exactly where the old Objective-C code did it.
//   - Vector normalisation: BKRenderNormalize3fPortable (double precision, rounded to float once) on EVERY platform,
//     the Mac included (user decision 2026-11-26, "universal" like D3). Apple's simd_normalize was used before; it
//     relies on the CPU's hardware 1/sqrt estimate and differed in the last bit for oblique cameras, so the
//     affected volume golden references were re-recorded once (see VULKAN-ENGINE-PROGRESS.md).
//
//   - Private header (next to BKShaderTypes.h, which it needs); not part of the public module.
//
// Plain language: "fill in the form the 3D drawing program reads" - written once so the Mac engine and the
// Windows / Linux engine fill it identically.

#ifndef BK_RENDER_PARAMS_CORE_H
#define BK_RENDER_PARAMS_CORE_H

#include <stddef.h>
#include <stdint.h>
#include "BKShaderTypes.h"
#include "BKRenderCore.h"   // BKRenderTFPoint

#ifdef __cplusplus
extern "C" {
#endif

// What: the portable normalisation (v unit length in place; the caller has checked its length is not ~0): length and division in double, rounded to float once (deterministic).
void BKRenderNormalize3fPortable(float v[3]);

// Everything BKRenderParamsFill needs, as plain numbers (the renderer's settings + the volume's facts).
typedef struct {
    // The scan.
    uint32_t volumeSize[3];          // voxels
    double patientToVoxel[16];       // column-major 4x4: voxel = M * (x, y, z, 1) for patient mm
    double minPixelSpacing;          // mm (default sample spacing = half of it)
    float valueScale, valueOffset;   // stored texel (0..1) -> real value
    float outOfBoundsValue;          // the volume's value outside the scan
    int32_t colorVolume;             // 1 = RGBA8 colour scan

    // Camera and view.
    int32_t mode;                    // BKRenderMode (0 composite, 1 MIP, 2 MinIP, 3 average)
    int32_t projection;              // BKProjection (0 orthographic, 1 perspective)
    double cameraPosition[3], cameraDirection[3], cameraUp[3];   // patient mm; direction / up need not be unit
    double viewWidth, viewHeight;    // orthographic, mm
    double fieldOfView;              // perspective, degrees (vertical)
    double sampleSpacing;            // mm, <= 0 = half the smallest voxel spacing

    // Cutting.
    double cropMin[3], cropMax[3];   // voxel-space crop box
    int32_t slabEnabled;
    double slabPoint[3], slabNormal[3], slabThickness;
    int32_t clipPlaneEnabled;
    double clipPoint[3], clipNormal[3];
    float clipPlanes[4 * BK_MAX_CLIP_PLANES];   // extra planes, GPU packing (nx, ny, nz, w), already unit normals
    uint32_t clipPlaneCount;

    // Look.
    float tfMin, tfMax;              // value range of the transfer function (first / last table entry)
    float windowCenter, windowWidth; // MIP / MinIP / average grey window
    float missValue;                 // NaN = use outOfBoundsValue
    float opacityUnitDistance;       // <= 0 = 1 mm
    int32_t shading;
    float ambient, diffuse, specular, specularPower;
    int32_t manualFiltering;
    int32_t useGeometry;             // embedded objects present (the caller checked the pictures)
    int32_t colorUsesTable;

    // Fusion (only read when useBlend = 1; the caller checked volume + table exist).
    int32_t useBlend;
    float blendOpacityUnitDistance;  // <= 0 = 1 mm
    double blendPatientToVoxel[16];  // column-major, like patientToVoxel
    uint32_t blendVolumeSize[3];
    float blendValueScale, blendValueOffset, blendTfMin, blendTfMax;
    int32_t blendColorVolume;

} BKRenderSettings;

// Result codes of BKRenderParamsFill (the renderer's NSError codes 11 / 12).
enum { BKRenderParamsOK = 0, BKRenderParamsZeroDirection = 11, BKRenderParamsUpParallel = 12 };

// What: fills `p` (zeroed first) for an output of width x height pixels. valuesOnly and the empty-space skipping
// fields (skipEmptySpace, brickGrid) are left 0 for the caller. Returns a BKRenderParams* code.
int BKRenderParamsFill(const BKRenderSettings *s, uint32_t width, uint32_t height, BKRenderParams *p);

// ---- Preset -> transfer function (VRView rules) --------------------------------------------------------------------

// What: inserts a point keeping the list sorted by value; a point at an existing value replaces it (VTK AddPoint).
// Returns the new count (unchanged when the list is full).
size_t BKRenderTFInsertPoint(BKRenderTFPoint *points, size_t count, size_t capacity, BKRenderTFPoint point);

// What: a classic 256-entry colour table + opacity curve -> transfer-function points, exactly like
// -[VRView setCLUT:::] (vtkColorTransferFunction::BuildFunctionFromTable over the FIRST 255 entries, spaced
// (end - start) / 254) and -[VRView setOpacity:] (x in 0..256 across the window, anchors at the ends when missing).
// opacityXY: count (x, y) pairs (may be NULL when count = 0). color must hold 255 points, opacity count + 2.
// Writes the point counts. The points come out sorted as BKRenderTFInsertPoint would sort them.
void BKRenderTFFromCLUT(const uint8_t red[256], const uint8_t green[256], const uint8_t blue[256],
                        float windowCenter, float windowWidth, const double *opacityXY, size_t count,
                        BKRenderTFPoint *color, size_t *colorCount, BKRenderTFPoint *opacity, size_t *opacityCount);

#ifdef __cplusplus
}
#endif

#endif
