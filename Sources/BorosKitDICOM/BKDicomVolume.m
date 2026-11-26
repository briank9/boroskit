// BorosKitDICOM: BKDicomVolume - see BKDicomVolume.h. ARC.
//
// Original BorosKit code written for this project; contains no third-party code.

#import "BKDicomVolume.h"
#import "BKDicomSeriesCore.h"

#import <stdatomic.h>

static NSError *BKVolumeError(BKDicomErrorCode code, NSString *text)
{
    return [NSError errorWithDomain:BKDicomErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: text}];
}

@implementation BKDicomVolume {
    double _voxelToPatient[16];
    double _patientToVoxel[16];
    NSMutableData *_voxelData;
}

+ (instancetype)volumeWithFileURLs:(NSArray<NSURL *> *)urls maximumVoxels:(NSUInteger)maximumVoxels
                          progress:(BOOL (^)(double))progress error:(NSError **)error
{
    NSMutableArray<BKDicomFile *> *files = [NSMutableArray array];
    NSString *firstProblem = nil;
    for (NSURL *url in urls) {
        NSError *e = nil;
        BKDicomFile *f = [BKDicomFile fileWithURL:url error:&e];
        if (f && f.canDecode) [files addObject:f];
        else if (!firstProblem) firstProblem = f ? f.unsupportedReason : e.localizedDescription;
    }
    if (files.count == 0) {
        if (error) *error = BKVolumeError(BKDicomErrorCodeUnsupported, firstProblem ?: @"No images found.");
        return nil;
    }
    return [self volumeWithFiles:files maximumVoxels:maximumVoxels progress:progress error:error];
}

+ (instancetype)volumeWithFiles:(NSArray<BKDicomFile *> *)inputFiles maximumVoxels:(NSUInteger)maximumVoxels
                       progress:(BOOL (^)(double))progress error:(NSError **)error
{
    BKDicomVolume *v = [[self alloc] init];
    return [v buildFromFiles:inputFiles maximumVoxels:maximumVoxels progress:progress error:error] ? v : nil;
}

- (BOOL)buildFromFiles:(NSArray<BKDicomFile *> *)inputFiles maximumVoxels:(NSUInteger)maximumVoxels
              progress:(BOOL (^)(double))progress error:(NSError **)error
{
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    // Keep decodable files of the first file's image size (a scout / localizer of another size is left out).
    NSArray<BKDicomFile *> *candidates = [inputFiles filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(BKDicomFile *f, id b) { return f.canDecode; }]];
    if (candidates.count == 0) {
        NSString *reason = inputFiles.firstObject.unsupportedReason ?: @"No images found.";
        if (error) *error = BKVolumeError(BKDicomErrorCodeUnsupported, reason);
        return NO;
    }
    BKDicomFile *model = candidates.firstObject;
    NSMutableArray<BKDicomFile *> *files = [NSMutableArray array];
    for (BKDicomFile *f in candidates)
        if (f.rows == model.rows && f.columns == model.columns) [files addObject:f];
    if (files.count < candidates.count)
        [warnings addObject:[NSString stringWithFormat:@"%lu image(s) of a different size were left out.", (unsigned long)(candidates.count - files.count)]];

    // One slice per frame.
    NSUInteger total = 0;
    for (BKDicomFile *f in files) total += f.numberOfFrames;
    if (total > UINT32_MAX / 2) { if (error) *error = BKVolumeError(BKDicomErrorCodeDamaged, @"Too many slices."); return NO; }
    BKDicomSlice *slices = calloc(total, sizeof(BKDicomSlice));
    uint32_t *fileOf = calloc(total, sizeof(uint32_t)), *frameOf = calloc(total, sizeof(uint32_t));
    if (!slices || !fileOf || !frameOf) {
        free(slices); free(fileOf); free(frameOf);
        if (error) *error = BKVolumeError(BKDicomErrorCodeNoMemory, @"Out of memory.");
        return NO;
    }
    uint32_t s = 0;
    for (uint32_t fi = 0; fi < files.count; fi++) {
        BKDicomFile *f = files[fi];
        for (uint32_t fr = 0; fr < f.numberOfFrames; fr++, s++) {
            double p[3], o[6];
            BKDicomSlice *slice = &slices[s];
            if ([f getPosition:p orientation:o forFrame:fr]) {
                slice->hasGeometry = 1;
                slice->position = BKV3d(p[0], p[1], p[2]);
                slice->rowDirection = BKV3dNormalize(BKV3d(o[0], o[1], o[2]));
                slice->columnDirection = BKV3dNormalize(BKV3d(o[3], o[4], o[5]));
                if (!(BKV3dLength(BKV3dCross(slice->rowDirection, slice->columnDirection)) > 0.5)) slice->hasGeometry = 0;
            }
            if (!slice->hasGeometry) {
                slice->rowDirection = BKV3d(1, 0, 0);
                slice->columnDirection = BKV3d(0, 1, 0);
            }
            NSInteger instance = f.instanceNumber;
            slice->instanceNumber = instance == NSNotFound ? (int32_t)fr : (int32_t)(instance * 100000 + fr);
            slice->sourceIndex = s;
            fileOf[s] = fi;
            frameOf[s] = fr;
        }
    }
    double fallback = model.spacingBetweenSlices > 0 ? model.spacingBetweenSlices : (model.sliceThickness > 0 ? model.sliceThickness : 1.0);
    BKDicomSeriesOrder order;
    if (!BKDicomSeriesSort(slices, (uint32_t)total, fallback, &order) || order.count == 0) {
        free(slices); free(fileOf); free(frameOf);
        if (error) *error = BKVolumeError(BKDicomErrorCodeMismatch, @"The slices could not be put in order.");
        return NO;
    }
    if (order.warnings & BKSeriesWarningUneven) [warnings addObject:@"The slices are not evenly spaced; distances along the slice direction are approximate."];
    if (order.warnings & BKSeriesWarningDuplicates) [warnings addObject:[NSString stringWithFormat:@"%u repeated slice(s) were left out.", order.dropped]];
    if (order.warnings & BKSeriesWarningNoGeometry) [warnings addObject:@"The files do not say where the slices are; they are stacked by number with an assumed spacing. Do not measure in 3D."];
    if (order.warnings & BKSeriesWarningTilted) [warnings addObject:@"The slices are tilted (gantry tilt); the volume keeps the true geometry."];
    if (order.warnings & BKSeriesWarningMixedOrientation) [warnings addObject:@"Slices with a different direction were left out."];

    // Size and memory: reduce in-plane by an integer factor when the volume is too large.
    NSUInteger factor = 1;
    NSUInteger W0 = model.columns, H0 = model.rows, D = order.count;
    while (maximumVoxels > 0 && (W0 / factor) * (H0 / factor) * D > maximumVoxels && factor < 8) factor++;
    NSUInteger W = W0 / factor, H = H0 / factor;
    if (factor > 1) [warnings addObject:[NSString stringWithFormat:@"The scan is very large: shown at 1/%lu of its resolution in each slice to fit this device's memory.", (unsigned long)factor]];
    size_t voxelCount = (size_t)W * H * D;
    _voxelData = [NSMutableData dataWithLength:voxelCount * sizeof(float)];
    if (_voxelData == nil || W == 0 || H == 0) {
        free(slices); free(fileOf); free(frameOf); free(order.order);
        if (error) *error = BKVolumeError(BKDicomErrorCodeNoMemory, @"Not enough memory for this scan.");
        return NO;
    }
    float *voxels = _voxelData.mutableBytes;

    // Decode every slice on all cores; each writes only its own slice of the volume.
    __block atomic_uint done = 0;
    __block atomic_int cancelled = 0;
    __block NSString *failure = nil;
    NSObject *lock = [[NSObject alloc] init];
    uint32_t *sorted = order.order;
    dispatch_apply(D, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t k) {
        if (atomic_load(&cancelled) || failure) return;
        uint32_t source = sorted[k];
        BKDicomFile *f = files[fileOf[source]];
        float *target = voxels + (size_t)k * W * H;
        NSError *e = nil;
        BOOL ok;
        if (factor == 1) {
            ok = [f decodeFrame:frameOf[source] into:target error:&e];
        } else {
            float *full = malloc(sizeof(float) * W0 * H0);
            ok = full != NULL && [f decodeFrame:frameOf[source] into:full error:&e];
            if (ok) {
                // Average factor x factor blocks (box filter) so thin structures are not lost by skipping.
                for (NSUInteger y = 0; y < H; y++)
                    for (NSUInteger x = 0; x < W; x++) {
                        double sum = 0;
                        for (NSUInteger dy = 0; dy < factor; dy++)
                            for (NSUInteger dx = 0; dx < factor; dx++) sum += full[(y * factor + dy) * W0 + x * factor + dx];
                        target[y * W + x] = (float)(sum / (double)(factor * factor));
                    }
            }
            free(full);
        }
        if (!ok) {
            @synchronized (lock) { if (!failure) failure = e.localizedDescription ?: @"A slice could not be decoded."; }
            return;
        }
        unsigned n = atomic_fetch_add(&done, 1) + 1;
        if (progress && !progress((double)n / (double)D)) atomic_store(&cancelled, 1);
    });
    if (failure || atomic_load(&cancelled)) {
        free(slices); free(fileOf); free(frameOf); free(order.order);
        _voxelData = nil;
        if (error) *error = failure ? BKVolumeError(BKDicomErrorCodeUnsupported, failure) : BKVolumeError(BKDicomErrorCodeCancelled, @"Cancelled.");
        return NO;
    }

    // Geometry of the first sorted slice; in-plane spacing grows with the reduction factor. The first voxel
    // centre moves to the centre of the first averaged block.
    BKDicomSlice first = slices[sorted[0]];
    _referenceFile = files[fileOf[sorted[0]]];
    double dx = model.pixelSpacingX, dy = model.pixelSpacingY;
    if (!model.hasPixelSpacing) [warnings addObject:@"The files give no pixel size; 1 mm is assumed. Do not measure."];
    if (factor > 1) {
        double shift = (double)(factor - 1) / 2.0;
        first.position = BKV3dAdd(first.position, BKV3dAdd(BKV3dScale(first.rowDirection, dx * shift), BKV3dScale(first.columnDirection, dy * shift)));
        dx *= factor; dy *= factor;
    }
    BKDicomVoxelToPatient(&first, dx, dy, order.sliceStep, _voxelToPatient);
    if (!BKDicomInvertAffine(_voxelToPatient, _patientToVoxel)) {
        free(slices); free(fileOf); free(frameOf); free(order.order);
        if (error) *error = BKVolumeError(BKDicomErrorCodeMismatch, @"The slice geometry is invalid.");
        return NO;
    }
    _width = W; _height = H; _depth = D;
    _spacingX = dx; _spacingY = dy; _spacingZ = order.sliceSpacing;
    _downsampleFactor = factor;
    _monochrome1 = model.monochrome1;
    _transferSyntaxName = model.transferSyntaxName;

    float lo = INFINITY, hi = -INFINITY;
    for (size_t i = 0; i < voxelCount; i++) { float x = voxels[i]; if (x < lo) lo = x; if (x > hi) hi = x; }
    _minimumValue = lo; _maximumValue = hi;
    if (model.windowWidth > 0) { _defaultWindowCenter = model.windowCenter; _defaultWindowWidth = model.windowWidth; }
    else if ([model.modality isEqualToString:@"CT"]) { _defaultWindowCenter = 400; _defaultWindowWidth = 2000; }
    else { _defaultWindowCenter = (lo + hi) / 2.0; _defaultWindowWidth = MAX(hi - lo, 1.0); }
    _warnings = warnings;
    free(slices); free(fileOf); free(frameOf); free(order.order);
    return YES;
}

- (NSData *)voxels { return _voxelData; }
- (void)releaseVoxels { _voxelData = nil; }
- (void)getVoxelToPatient:(double *)matrix { memcpy(matrix, _voxelToPatient, sizeof(_voxelToPatient)); }
- (void)getPatientToVoxel:(double *)matrix { memcpy(matrix, _patientToVoxel, sizeof(_patientToVoxel)); }

@end
