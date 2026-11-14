// BorosKitRender: BKVolumeScene implementation (see the header for what it does).

/* BOROS OVERVIEW (plain language)
 * The scene is the 3D view as a whole. It decides how sharp the picture should be.
 * While the user is dragging or rotating the model, it draws a rougher, faster image
 * so the motion stays smooth, then returns to full sharpness when they stop.
 * It uses the timing of recent frames to pick a quality level from a fixed set of
 * steps, which keeps the view responsive on slower computers.
 */

#import "BKVolumeScene.h"
#import "BKVolumeTexture.h"
#import "BKPreset.h"
#import "BKTransferFunction.h"
#import "CPRVolumeData.h"
#import "BKCameraMath.h"
#import <QuartzCore/QuartzCore.h>

// What: GPU cost of a level relative to full quality (pixel count x samples per ray).
// Why: lets the controller estimate how long another level would take from one timing.
float BKQualityLevelRelativeCost(BKQualityLevel level)
{
    float scale = level.resolutionScale > 0 ? level.resolutionScale : 1.0f;
    float step = level.sampleStepFactor > 0 ? level.sampleStepFactor : 1.0f;
    return scale * scale / step;
}

// What: the default quality ladder (see header). Why: gradual steps, cheapest last.
NSArray<NSValue *> *BKDefaultQualityLevels(void)
{
    BKQualityLevel levels[] = {
        {1.0f, 1.0f}, {0.75f, 1.0f}, {0.5f, 1.0f}, {0.5f, 2.0f}, {0.35f, 2.0f},
    };
    NSMutableArray *array = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(levels) / sizeof(levels[0]); i++)
        [array addObject:[NSValue valueWithBytes:&levels[i] objCType:@encode(BKQualityLevel)]];
    return array;
}

// What: best level whose estimated time fits the budget, from a full-quality timing.
// Why: when a drag starts we already know what full quality costs, so we can pick a
// good starting level instead of discovering it frame by frame.
NSInteger BKInitialInteractiveQualityLevel(const BKQualityLevel *levels, NSInteger count,
                                           double lastFullQualityFrameTime, double budget)
{
    if (count <= 0 || !(lastFullQualityFrameTime > 0) || !(budget > 0)) return 0;
    for (NSInteger i = 0; i < count; i++)
        if (lastFullQualityFrameTime * BKQualityLevelRelativeCost(levels[i]) <= budget)
            return i;
    return count - 1;
}

// What: one-step-at-a-time adjustment from the last interactive frame (see header).
// Why: frame times are noisy; single steps with an 80 % margin for stepping up avoid
// flickering between levels while still reacting within a few frames.
NSInteger BKNextInteractiveQualityLevel(const BKQualityLevel *levels, NSInteger count,
                                        NSInteger currentLevel, double lastFrameTime, double budget)
{
    if (count <= 0) return 0;
    if (currentLevel < 0) currentLevel = 0;
    if (currentLevel >= count) currentLevel = count - 1;
    if (!(lastFrameTime > 0) || !(budget > 0)) return currentLevel;

    if (lastFrameTime > budget)
        return MIN(currentLevel + 1, count - 1);

    if (currentLevel > 0) {
        double fullEstimate = lastFrameTime / BKQualityLevelRelativeCost(levels[currentLevel]);
        if (fullEstimate * BKQualityLevelRelativeCost(levels[currentLevel - 1]) <= 0.8 * budget)
            return currentLevel - 1;
    }
    return currentLevel;
}

@implementation BKVolumeScene {
    BKQualityLevel *_levels;      // C copy of qualityLevels for the hot path
    NSInteger _levelCount;
    NSInteger _nextLevel;         // level for the next frame
    id<MTLTexture> _lowResTexture; // reused intermediate for reduced-resolution frames
    BKPreset *_windowedPreset;    // advanced presets: the preset with curve 0 moved by WL/WW
}

// What: makes the renderer and camera with Horos-like defaults.
// Why: a ready-to-use scene; the view only needs to give it a volume and a surface.
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _renderer = [[BKVolumeRenderer alloc] initWithDevice:device error:error];
    if (!_renderer) return nil;
    _camera = [[BKVolumeCamera alloc] init];
    _backgroundColor = simd_make_float4(0, 0, 0, 1);
    _targetInteractiveFrameTime = 0.016;
    _windowCenter = _renderer.windowCenter;
    _windowWidth = _renderer.windowWidth;
    self.qualityLevels = BKDefaultQualityLevels();
    return self;
}

// What: frees the C copy of the quality ladder.
- (void)dealloc
{
    free(_levels);
}

// What: stores the ladder and its C copy; resets the chosen level.
// Why: the controller functions take a plain C array.
- (void)setQualityLevels:(NSArray<NSValue *> *)qualityLevels
{
    if (qualityLevels.count == 0) qualityLevels = BKDefaultQualityLevels();
    _qualityLevels = [qualityLevels copy];
    free(_levels);
    _levelCount = (NSInteger)_qualityLevels.count;
    _levels = calloc((size_t)_levelCount, sizeof(BKQualityLevel));
    for (NSInteger i = 0; i < _levelCount; i++)
        [_qualityLevels[i] getValue:&_levels[i] size:sizeof(BKQualityLevel)];
    _nextLevel = 0;
}

#pragma mark - Volume

// What: uploads a volume and fits the camera. Why: the usual way to open a study.
- (BOOL)setVolumeData:(CPRVolumeData *)volumeData error:(NSError **)error
{
    if (![_renderer setVolumeData:volumeData error:error]) return NO;
    [self volumeDidChange];
    return YES;
}

// What / why: see the header. The bounds are recomputed (same numbers for the same geometry);
// camera and preset stay. Empty-space skipping re-measures the new texture on its first frame.
- (BOOL)replaceVolumeValues:(CPRVolumeData *)volumeData error:(NSError **)error
{
    BKVolumeTexture *old = _renderer.volumeTexture;
    if (old == nil || volumeData.pixelsWide != old.pixelsWide || volumeData.pixelsHigh != old.pixelsHigh
        || volumeData.pixelsDeep != old.pixelsDeep)
        return [self setVolumeData:volumeData error:error];   // a different scan: open it fully
    if (![_renderer setVolumeData:volumeData error:error]) return NO;
    // Only the bounds: the preset is NOT re-applied (that would undo the user's window/level; the
    // app keeps its own colour/opacity in sync) and the camera is NOT reset.
    [self recomputeVolumeBounds];
    return YES;
}

- (BKVolumeTexture *)volumeTexture
{
    return _renderer.volumeTexture;
}

// What: shares an already uploaded volume. Why: several views on one GPU copy.
- (void)setVolumeTexture:(BKVolumeTexture *)volumeTexture
{
    _renderer.volumeTexture = volumeTexture;
    [self volumeDidChange];
}

// What: recomputes the patient-space bounds, re-applies the preset (advanced presets
// depend on the volume's value range) and resets the camera.
// Why: a new volume invalidates all three.
- (void)volumeDidChange
{
    if (![self recomputeVolumeBounds]) return;
    if (_preset) [self applyPreset:_preset];
    [self resetCamera];
}

// What: the volume's patient-space bounds from the current texture. NO when there is no volume.
- (BOOL)recomputeVolumeBounds
{
    BKVolumeTexture *vt = _renderer.volumeTexture;
    if (!vt) {
        _volumeBoundsMin = _volumeBoundsMax = N3VectorZero;
        return NO;
    }
    // Voxel -> patient = inverse of the stored patient -> voxel transform; take the
    // 8 corner voxel centres.
    N3AffineTransform toPatient = N3AffineTransformInvert(vt.volumeTransform);
    N3Vector lo = N3VectorMake(INFINITY, INFINITY, INFINITY), hi = N3VectorMake(-INFINITY, -INFINITY, -INFINITY);
    for (int c = 0; c < 8; c++) {
        N3Vector v = N3VectorMake((c & 1) ? vt.pixelsWide - 1 : 0, (c & 2) ? vt.pixelsHigh - 1 : 0, (c & 4) ? vt.pixelsDeep - 1 : 0);
        N3Vector p = N3VectorApplyTransform(v, toPatient);
        lo = N3VectorMake(MIN(lo.x, p.x), MIN(lo.y, p.y), MIN(lo.z, p.z));
        hi = N3VectorMake(MAX(hi.x, p.x), MAX(hi.y, p.y), MAX(hi.z, p.z));
    }
    _volumeBoundsMin = lo;
    _volumeBoundsMax = hi;
    return YES;
}

// What: fit + Horos' reset view (left side). Why: matches -[VRView resetImage:].
- (void)resetCamera
{
    [_camera showStandardView:BKStandardViewLeft];
    [_camera resetToBoxMin:_volumeBoundsMin max:_volumeBoundsMax];
}

- (BKRenderMode)mode
{
    return _renderer.mode;
}

// What: switches 3D / MIP / MinIP / mean and re-applies the window to the right place.
// Why: WL/WW means colours in 3D but the grayscale window in projection modes.
- (void)setMode:(BKRenderMode)mode
{
    _renderer.mode = mode;
    [self applyWindow];
}

// Empty-space skipping lives in the renderer; the scene just passes it through so the
// app can switch it from one place (see BKVolumeRenderer.skipsEmptySpace).
- (BOOL)skipsEmptySpace
{
    return _renderer.skipsEmptySpace;
}

- (void)setSkipsEmptySpace:(BOOL)skipsEmptySpace
{
    _renderer.skipsEmptySpace = skipsEmptySpace;
}

#pragma mark - Preset and window/level

// What: applies the whole preset (see header). Why: same looks as the VR window.
- (void)applyPreset:(BKPreset *)preset
{
    _preset = [preset copy];
    _windowedPreset = nil;
    if (!_preset) return;
    [_preset applyToRenderer:_renderer];
    _windowCenter = _preset.windowCenter;
    _windowWidth = _preset.windowWidth;
    _camera.projection = _preset.projection;
    _camera.viewAngle = _preset.fieldOfView;
    _backgroundColor = simd_make_float4(_preset.backgroundRed, _preset.backgroundGreen, _preset.backgroundBlue, 1);
    // For simple presets this rebuilds the same function; for projection modes it sets
    // the grayscale window.
    [self applyWindow];
}

- (void)setWindowCenter:(float)windowCenter
{
    _windowCenter = windowCenter;
    [self applyWindow];
}

- (void)setWindowWidth:(float)windowWidth
{
    _windowWidth = MAX(windowWidth, 0.1f);
    [self applyWindow];
}

// What: the VR window's WL/WW drag formula (see header).
// Why: identical feel to -[VRView mouseDragged:] with the WL tool.
- (void)adjustWindowLevelByDeltaX:(CGFloat)dx deltaY:(CGFloat)dy
{
    float adapter = _windowWidth / 100.0f;
    _windowCenter = _windowCenter - (float)dy * adapter;
    _windowWidth = MAX(_windowWidth + (float)dx * adapter, 0.1f);
    [self applyWindow];
}

// What: pushes the current WL/WW into the renderer.
// Why: projection modes use it as the grayscale window; in 3D it moves the preset's
// colour/opacity (simple presets) or reshapes the first curve (advanced presets).
- (void)applyWindow
{
    _renderer.windowCenter = _windowCenter;
    _renderer.windowWidth = _windowWidth;
    if (!_preset) return;
    if (!_preset.usesAdvancedCLUT) {
        _renderer.transferFunction = [_preset transferFunctionWithWindowCenter:_windowCenter windowWidth:_windowWidth];
        return;
    }
    BKPreset *moved = [self presetWithFirstCurveFittedToWindow];
    if (!moved) return;
    _windowedPreset = moved;
    BKVolumeTexture *vt = _renderer.volumeTexture;
    _renderer.transferFunction = vt ? [moved transferFunctionForVolumeMinimum:vt.minimumValue volumeMaximum:vt.maximumValue]
                                    : [moved transferFunction];
}

// What: a copy of the advanced preset whose first curve is centred on WL and spans
// WW, moving each point proportionally to its distance from the curve's middle.
// Why: this is -[CLUTOpacityView setWL:ww:], which the VR window calls when you drag
// WL/WW on a 16-bit CLUT. (Horos' extra "legalizePoint" clamping to the editor's
// range is not reproduced; it only matters at the extreme ends of the scale.)
- (BKPreset *)presetWithFirstCurveFittedToWindow
{
    NSArray<BKPresetCurve *> *curves = _preset.advancedCurves;
    if (curves.count == 0 || curves[0].pointCount < 2) return nil;
    BKPresetCurve *curve = curves[0];
    NSUInteger n = curve.pointCount;
    BKPresetCurvePoint first = [curve pointAtIndex:0], last = [curve pointAtIndex:n - 1];
    float half = (last.value - first.value) / 2.0f;
    if (!(half > 0)) return nil;
    float middle = first.value + half;
    float shiftWL = _windowCenter - middle;
    float shiftWW = first.value + shiftWL - (_windowCenter - 0.5f * _windowWidth);

    BKPresetCurvePoint *points = malloc(sizeof(BKPresetCurvePoint) * n);
    for (NSUInteger i = 0; i < n; i++) {
        BKPresetCurvePoint pt = [curve pointAtIndex:i];
        float factor = fabsf(pt.value - middle) / half;
        pt.value += shiftWL;
        if ((double)i < n / 2.0) pt.value -= shiftWW * factor;
        else pt.value += shiftWW * factor;
        points[i] = pt;
    }
    NSMutableArray *newCurves = [curves mutableCopy];
    newCurves[0] = [[BKPresetCurve alloc] initWithPoints:points count:n];
    free(points);
    BKPreset *moved = [_preset copy];
    moved.advancedCurves = newCurves;
    return moved;
}

#pragma mark - Adaptive quality

// What: starts an interaction at the best level that fits the budget.
// Why: if full quality is fast enough, rotation stays at full quality.
- (void)beginInteraction
{
    @synchronized (self) {
        _interacting = YES;
        _nextLevel = BKInitialInteractiveQualityLevel(_levels, _levelCount, _lastFullQualityFrameTime, _targetInteractiveFrameTime);
    }
}

// What: ends the interaction; the next frame is full quality.
- (void)endInteraction
{
    @synchronized (self) {
        _interacting = NO;
        _nextLevel = 0;
    }
}

// What: stores a frame time and lets the controller pick the next level.
// Why: called from the GPU completion handler (another thread), hence the lock.
- (void)recordFrameTime:(double)seconds atQualityLevel:(NSInteger)level
{
    @synchronized (self) {
        _lastFrameTime = seconds;
        if (level == 0) _lastFullQualityFrameTime = seconds;
        if (_interacting)
            _nextLevel = BKNextInteractiveQualityLevel(_levels, _levelCount, level, seconds, _targetInteractiveFrameTime);
        else
            _nextLevel = 0;
    }
}

// What: ray-cast size for a target at a level (at least 1 x 1).
- (CGSize)renderSizeForTargetSize:(CGSize)size qualityLevel:(NSInteger)level
{
    level = MAX(0, MIN(level, _levelCount - 1));
    float scale = _levels[level].resolutionScale;
    if (!(scale > 0) || scale > 1) scale = 1;
    return CGSizeMake(MAX(1.0, round(size.width * scale)), MAX(1.0, round(size.height * scale)));
}

#pragma mark - Rendering

#pragma mark - Camera slab

// What: switching the camera slab on or off. Why: off must also switch the renderer's slab
// off, otherwise the last slab would stay in the picture.
- (void)setViewSlabEnabled:(BOOL)viewSlabEnabled
{
    _viewSlabEnabled = viewSlabEnabled;
    if (!viewSlabEnabled) _renderer.slabEnabled = NO;
}

// What: the scene camera in the plain-C form used by BKCameraMath (patient mm).
static BKCameraFrame BKSceneCameraFrame(BKVolumeCamera *camera)
{
    N3Vector p = camera.position, d = camera.direction, u = camera.viewUp;
    BKCameraFrame f;
    f.position = BKV3d(p.x, p.y, p.z);
    f.direction = BKV3d(d.x, d.y, d.z);
    f.up = BKV3d(u.x, u.y, u.z);
    f.parallelScale = camera.parallelScale;
    f.viewAngle = camera.viewAngle;
    f.perspective = camera.projection == BKProjectionPerspective;
    return f;
}

// What: places the renderer's slab from the current camera (see viewSlabEnabled).
// Why: called just before every render so the slab always matches the camera of that frame.
- (void)applyViewSlab
{
    if (!_viewSlabEnabled) return;
    BKVec3d point, normal;   // BorosKit neutral vectors (BKCameraMath is plain C99)
    double thickness;
    if (!BKCameraSlab(BKSceneCameraFrame(_camera), _viewSlabNear, _viewSlabFar, &point, &normal, &thickness)) {
        _renderer.slabEnabled = NO;   // empty slab settings: show nothing special rather than garbage
        return;
    }
    // The renderer's slab API takes BorosKitCore's plane type (point + normal, patient mm).
    _renderer.slabPlane = N3PlaneMake(N3VectorMake(point.x, point.y, point.z), N3VectorMake(normal.x, normal.y, normal.z));
    _renderer.slabThickness = thickness;
    _renderer.slabEnabled = YES;
}

// What: one full-quality CPU-readable render with the scene's camera (see header).
// Why: the 16-bit export needs the real projected values, not screen colours.
- (BKRenderResult *)renderFullQualityWithWidth:(NSUInteger)width height:(NSUInteger)height
                                     missValue:(float)missValue error:(NSError **)error
{
    if (width == 0 || height == 0) {
        if (error) *error = [NSError errorWithDomain:@"BorosKit" code:1 userInfo:@{NSLocalizedDescriptionKey: @"empty image size"}];
        return nil;
    }
    _renderer.sampleSpacing = _baseSampleSpacing;   // full quality (0 = automatic half voxel)
    [_camera applyToRenderer:_renderer aspectRatio:(CGFloat)width / (CGFloat)height];
    [self applyViewSlab];
    float savedMiss = _renderer.missValue;
    _renderer.missValue = missValue;
    BKRenderResult *result = [_renderer renderWithWidth:width height:height error:error];
    _renderer.missValue = savedMiss;
    return result;
}

// What: encodes one frame at the chosen level (see header): direct ray-cast at full
// resolution, or ray-cast into a smaller texture + upscale. Records the GPU time.
// Why: never blocks; quality adapts to the measured cost.
- (BOOL)encodeFrameToTexture:(id<MTLTexture>)target commandBuffer:(id<MTLCommandBuffer>)commandBuffer error:(NSError **)error
{
    return [self encodeFrameToTexture:target commandBuffer:commandBuffer includeGeometry:NO error:error];
}

// What: see the header. The objects are encoded first (same command buffer, so the GPU finishes
// them before the ray-cast reads them), at the target's full size, with exactly the camera the
// volume uses for this frame.
- (BOOL)encodeFrameToTexture:(id<MTLTexture>)target commandBuffer:(id<MTLCommandBuffer>)commandBuffer
             includeGeometry:(BOOL)includeGeometry error:(NSError **)error
{
    NSInteger level;
    @synchronized (self) {
        level = _interacting ? _nextLevel : 0;
        _currentQualityLevel = level;
    }
    BKQualityLevel q = _levels[MAX(0, MIN(level, _levelCount - 1))];

    // Sample spacing: base (or automatic half voxel) times the level's factor.
    CGFloat base = _baseSampleSpacing;
    if (!(base > 0)) base = 0.5 * _renderer.volumeTexture.minPixelSpacing;
    _renderer.sampleSpacing = (q.sampleStepFactor > 1.0f) ? base * q.sampleStepFactor : _baseSampleSpacing;

    CGSize full = CGSizeMake(target.width, target.height);
    CGSize size = [self renderSizeForTargetSize:full qualityLevel:level];
    [_camera applyToRenderer:_renderer aspectRatio:full.width / MAX(full.height, 1.0)];
    [self applyViewSlab];

    // Embedded objects (2026-11-14): drawn into two pictures the ray-cast reads (see
    // BKVolumeRenderer geometry*Texture). Cleared again after encoding, so a later frame without
    // objects (e.g. a preset thumbnail sharing this scene) never sees them.
    id<MTLTexture> geometryColor = nil, geometryDistance = nil;
    if (includeGeometry && _geometryLayer &&
        ![_geometryLayer encodeGeometryWithCamera:_camera width:target.width height:target.height
                                    commandBuffer:commandBuffer colorTexture:&geometryColor
                               rayDistanceTexture:&geometryDistance]) {
        geometryColor = geometryDistance = nil;   // nothing to draw (or failed): volume alone
    }
    _renderer.geometryColorTexture = geometryColor;
    _renderer.geometryRayDistanceTexture = geometryDistance;

    BOOL ok;
    if (size.width >= full.width && size.height >= full.height) {
        ok = [_renderer encodeRenderToTexture:target commandBuffer:commandBuffer backgroundColor:_backgroundColor error:error];
    } else {
        if (!_lowResTexture || _lowResTexture.width != (NSUInteger)size.width || _lowResTexture.height != (NSUInteger)size.height) {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                             width:(NSUInteger)size.width
                                                                                            height:(NSUInteger)size.height
                                                                                         mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            desc.storageMode = MTLStorageModePrivate;
            _lowResTexture = [_renderer.device newTextureWithDescriptor:desc];
        }
        ok = [_renderer encodeRenderToTexture:_lowResTexture commandBuffer:commandBuffer backgroundColor:_backgroundColor error:error];
        if (ok) [_renderer encodeUpscaleFromTexture:_lowResTexture toTexture:target commandBuffer:commandBuffer];
    }
    _renderer.geometryColorTexture = nil;        // encoded above; the command buffer keeps them
    _renderer.geometryRayDistanceTexture = nil;
    if (!ok) return NO;

    __weak BKVolumeScene *weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        // GPU time when available (macOS 10.15+/iOS 10.3+); it excludes queueing delays.
        double seconds = cb.GPUEndTime - cb.GPUStartTime;
        if (seconds > 0) [weakSelf recordFrameTime:seconds atQualityLevel:level];
    }];
    return YES;
}

@end
