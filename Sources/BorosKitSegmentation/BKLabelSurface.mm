// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSegmentation: BKLabelSurface - see BKLabelSurface.h. ARC. Written 2026-11-26 by agent "segmentation".

#import "BKLabelSurface.h"
#import "BKSurfaceExtractor.h"
#import "BKVolumeTexture.h"
#import "BKMesh.h"
#import "BKMeshProcessing.h"
#include <cmath>

static NSError *BKLabelSurfaceError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"BKLabelSurfaceErrorDomain" code:code userInfo:@{ NSLocalizedDescriptionKey: message }];
}

@implementation BKLabelSurfaceOptions
- (instancetype)init
{
    if ((self = [super init])) {
        _maskSmoothing = 0.5f;
        _meshSmoothingIterations = 10;
    }
    return self;
}
@end

@implementation BKLabelSurface

- (instancetype)initWithExtractor:(BKSurfaceExtractor *)extractor
{
    if ((self = [super init])) _extractor = extractor;
    return self;
}

- (BKMesh *)meshForLabelVolume:(const BKLabelVolume *)volume value:(uint16_t)value
                       options:(BKLabelSurfaceOptions *)options error:(NSError **)error
{
    if (options == nil) options = [[BKLabelSurfaceOptions alloc] init];
    if (volume == NULL || BKLabelVolumeVoxelsConst(volume) == NULL) {
        if (error) *error = BKLabelSurfaceError(1, @"The segmentation's label data is not loaded.");
        return nil;
    }
    // (1) The class's box, grown so the blur and the closing layer of background fit around it.
    const uint32_t margin = 2 + (uint32_t)std::ceil(3.0 * MAX(options.maskSmoothing, 0.0f));
    int64_t boxMin[3];
    uint32_t boxDims[3];
    if (!BKLabelMaskBox(volume, value, margin, boxMin, boxDims)) {
        if (error) *error = BKLabelSurfaceError(2, @"This structure has no voxels.");
        return nil;
    }
    // (2) Box voxel -> patient mm (double), and its inverse for the texture's patient -> voxel transform.
    const BKLabelGrid *grid = BKLabelVolumeGetGrid(volume);
    double toPatient[16], toVoxel[16];
    BKLabelMaskBoxToPatient(grid, boxMin, toPatient);
    BKLabelGrid box = *grid;
    BKLabelGridVoxelToPatient(grid, (double)boxMin[0], (double)boxMin[1], (double)boxMin[2], box.origin);
    for (int a = 0; a < 3; a++) box.dims[a] = boxDims[a];
    if (!BKLabelGridPatientToVoxelMatrix(&box, toVoxel)) {
        if (error) *error = BKLabelSurfaceError(3, @"The scan grid is degenerate.");
        return nil;
    }
    double minSpacing = MIN(grid->spacing[0], MIN(grid->spacing[1], grid->spacing[2]));
    // (3) The 0 / 1 mask straight into the GPU upload (steps 0 / 65535 = values 0 / 1). Blocks cannot capture C
    // arrays: pointers to the box (alive until the synchronous upload returns).
    const int64_t *bm = boxMin;
    const uint32_t *bd = boxDims;
    BKVolumeTexture *texture = [[BKVolumeTexture alloc] initWithWidth:boxDims[0] height:boxDims[1] depth:boxDims[2]
        valueScale:1 valueOffset:0 minimumValue:0 maximumValue:1 patientToVoxel:toVoxel minPixelSpacing:minSpacing
        outOfBoundsValue:0 device:_extractor.device
        fillSteps:^BOOL(NSUInteger firstSlice, NSUInteger sliceCount, uint16_t *steps) {
            BKLabelMaskFill16(volume, value, bm, bd, (uint32_t)firstSlice, (uint32_t)sliceCount, 65535, steps);
            return YES;
        } error:error];
    if (texture == nil) return nil;
    // (4) The surface at 0.5, vertices straight in patient mm.
    BKSurfaceOptions *surfaceOptions = [[BKSurfaceOptions alloc] init];
    surfaceOptions.resolution = 1;
    surfaceOptions.scanSmoothing = MAX(options.maskSmoothing, 0.0f);
    surfaceOptions.sampling = BKSurfaceSamplingManualTrilinear;   // same numbers on every GPU / backend
    simd_float4x4 m;
    for (int c = 0; c < 4; c++)
        m.columns[c] = simd_make_float4((float)toPatient[4 * c], (float)toPatient[4 * c + 1], (float)toPatient[4 * c + 2],
                                        (float)toPatient[4 * c + 3]);
    surfaceOptions.outputTransform = m;
    surfaceOptions.hasOutputTransform = YES;
    NSArray<BKMesh *> *meshes = [_extractor extractSurfacesFromVolume:texture thresholds:@[ @0.5f ] options:surfaceOptions
                                                              timings:NULL error:error];
    BKMesh *mesh = meshes.firstObject;
    if (mesh == nil) return nil;
    if (mesh.triangleCount == 0) {
        if (error) *error = BKLabelSurfaceError(2, @"This structure gave no surface.");
        return nil;
    }
    if (options.meshSmoothingIterations > 0) {
        BKMesh *smoothed = [mesh meshBySmoothingWithIterations:options.meshSmoothingIterations
                                                      passBand:BKMeshSmoothingDefaultPassBand progress:nil report:NULL];
        if (smoothed) mesh = smoothed;
    }
    return mesh;
}

@end
