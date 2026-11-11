// BorosKitRender: BKVolumeCamera implementation (see the header for what it does).

/* BOROS OVERVIEW (plain language)
 * The camera is the virtual eye that looks at the 3D model of the scan. It records
 * where the eye stands, which way it faces, how far away it is, and whether the view
 * is flat or has natural perspective.
 * This file keeps those settings, works out the eye position, and performs the turns,
 * tilts and rolls used when the user rotates the model. The renderer uses the camera
 * to decide the viewpoint for each picture.
 */

#import "BKVolumeCamera.h"
#import <math.h>

// Degrees to radians.
static CGFloat BKRadians(CGFloat degrees)
{
    return degrees * (CGFloat)M_PI / 180.0;
}

// What: rotates vector v around the unit axis by `radians` (Rodrigues' formula).
// Why: every camera move (azimuth, elevation, roll) is a rotation about one axis.
static N3Vector BKRotateVector(N3Vector v, N3Vector axis, CGFloat radians)
{
    CGFloat c = cos(radians), s = sin(radians);
    N3Vector cross = N3VectorCrossProduct(axis, v);
    CGFloat dot = N3VectorDotProduct(axis, v);
    return N3VectorAdd(N3VectorAdd(N3VectorScalarMultiply(v, c), N3VectorScalarMultiply(cross, s)),
                       N3VectorScalarMultiply(axis, dot * (1.0 - c)));
}

@implementation BKVolumeCamera

// What: a camera looking from the front (anterior view), head up, 100 mm field.
// Why: a sane default before -resetToBoxMin:max: fits it to a real volume.
- (instancetype)init
{
    if ((self = [super init])) {
        _focalPoint = N3VectorZero;
        _direction = N3VectorMake(0, 1, 0);
        _viewUp = N3VectorMake(0, 0, 1);
        _distance = 500;
        _parallelScale = 50;
        _projection = BKProjectionOrthographic;
        _viewAngle = 30;
    }
    return self;
}

// What: copies every camera parameter. Why: views keep the camera to restore after a
// "reset", and tests compare before/after states.
- (id)copyWithZone:(NSZone *)zone
{
    BKVolumeCamera *copy = [[[self class] allocWithZone:zone] init];
    copy->_focalPoint = _focalPoint;
    copy->_direction = _direction;
    copy->_viewUp = _viewUp;
    copy->_distance = _distance;
    copy->_parallelScale = _parallelScale;
    copy->_projection = _projection;
    copy->_viewAngle = _viewAngle;
    return copy;
}

// What: eye position (focal point minus direction times distance).
// Why: the perspective renderer needs the eye; VTK stores it the same way.
- (N3Vector)position
{
    return N3VectorSubtract(_focalPoint, N3VectorScalarMultiply(_direction, _distance));
}

// What: sets direction + up, re-orthogonalised (VTK OrthogonalizeViewUp).
// Why: a camera frame must stay orthonormal or the image shears.
- (BOOL)setDirection:(N3Vector)direction viewUp:(N3Vector)viewUp
{
    if (N3VectorLength(direction) < 1e-9) return NO;
    N3Vector d = N3VectorNormalize(direction);
    N3Vector right = N3VectorCrossProduct(d, viewUp);
    if (N3VectorLength(right) < 1e-9) return NO;
    right = N3VectorNormalize(right);
    _direction = d;
    _viewUp = N3VectorNormalize(N3VectorCrossProduct(right, d));
    return YES;
}

// What: the camera's "right" axis (cross(direction, up)), matching BKVolumeRenderer.
// Why: azimuth, pan and roll all move along it.
- (N3Vector)right
{
    return N3VectorNormalize(N3VectorCrossProduct(_direction, _viewUp));
}

// What: fits the camera to a box like VTK ResetCamera (see header).
// Why: opening a volume or pressing "reset" must show the whole volume.
- (void)resetToBoxMin:(N3Vector)boxMin max:(N3Vector)boxMax
{
    N3Vector diagonal = N3VectorSubtract(boxMax, boxMin);
    CGFloat radius = 0.5 * N3VectorLength(diagonal);
    if (radius <= 0) radius = 0.5;
    _focalPoint = N3VectorScalarMultiply(N3VectorAdd(boxMin, boxMax), 0.5);
    _parallelScale = radius;
    CGFloat halfAngle = BKRadians(MAX(_viewAngle, 1.0)) * 0.5;
    _distance = radius / sin(halfAngle);
}

// What: unit direction/up of each standard view (see the enum for the Horos match).
// Why: one table shared by the camera and the tests.
+ (void)getStandardView:(BKStandardView)view direction:(N3Vector *)direction viewUp:(N3Vector *)viewUp
{
    N3Vector d, u = N3VectorMake(0, 0, 1);       // head up for the four side views
    switch (view) {
        case BKStandardViewAnterior:  d = N3VectorMake(0, 1, 0);  break; // camera in front, looks back (+y)
        case BKStandardViewPosterior: d = N3VectorMake(0, -1, 0); break;
        case BKStandardViewLeft:      d = N3VectorMake(-1, 0, 0); break; // camera at patient's left (+x)
        case BKStandardViewRight:     d = N3VectorMake(1, 0, 0);  break;
        case BKStandardViewInferior:  d = N3VectorMake(0, 0, 1);  u = N3VectorMake(0, -1, 0); break; // from the feet, anterior up
        case BKStandardViewSuperior:  d = N3VectorMake(0, 0, -1); u = N3VectorMake(0, -1, 0); break;
        default:                      d = N3VectorMake(0, 1, 0);  break;
    }
    if (direction) *direction = d;
    if (viewUp) *viewUp = u;
}

// What: turns to a standard view keeping focal point, distance and zoom.
// Why: Horos' view buttons keep the zoom ("apply the same zoom").
- (void)showStandardView:(BKStandardView)view
{
    N3Vector d, u;
    [[self class] getStandardView:view direction:&d viewUp:&u];
    [self setDirection:d viewUp:u];
}

// What: positive degrees move the camera toward its right around the focal point,
// about the up axis. Why: horizontal trackball drags and Horos' turntable movies.
- (void)azimuth:(CGFloat)degrees
{
    _direction = N3VectorNormalize(BKRotateVector(_direction, _viewUp, BKRadians(degrees)));
    [self setDirection:_direction viewUp:_viewUp];
}

// What: positive degrees move the camera upward around the focal point; "up" turns
// with it. Why: vertical trackball drags. (VTK's Elevation leaves up behind, which
// breaks near the poles - Horos works around that in its movie code.)
- (void)elevation:(CGFloat)degrees
{
    N3Vector right = [self right];
    // Rotating about -right by +angle tips the direction down = the camera moves up.
    N3Vector axis = N3VectorScalarMultiply(right, -1.0);
    N3Vector d = BKRotateVector(_direction, axis, BKRadians(degrees));
    N3Vector u = BKRotateVector(_viewUp, axis, BKRadians(degrees));
    [self setDirection:d viewUp:u];
}

// What: spins the up vector around the viewing direction (positive = clockwise on
// screen). Why: the roll tool / two-finger rotate.
- (void)roll:(CGFloat)degrees
{
    N3Vector u = BKRotateVector(_viewUp, _direction, BKRadians(degrees));
    [self setDirection:_direction viewUp:u];
}

// What: VTK trackball-camera mapping: a full-width drag turns 200 degrees.
// Why: same rotation speed as the VR window, so it feels familiar.
- (void)rotateByViewDelta:(CGSize)delta viewSize:(CGSize)viewSize
{
    if (viewSize.width <= 0 || viewSize.height <= 0) return;
    // Drag right -> the volume turns right -> the camera moves left (negative azimuth).
    [self azimuth:-200.0 * delta.width / viewSize.width];
    // Drag down (y down) -> the top of the volume comes toward the viewer -> camera moves up.
    [self elevation:200.0 * delta.height / viewSize.height];
}

// What: mm per view point at the focal plane. Why: pan must follow the pointer exactly.
- (CGFloat)millimetresPerViewPointForViewHeight:(CGFloat)viewHeight
{
    if (viewHeight <= 0) return 0;
    if (_projection == BKProjectionPerspective)
        return 2.0 * _distance * tan(BKRadians(_viewAngle) * 0.5) / viewHeight;
    return 2.0 * _parallelScale / viewHeight;
}

// What: moves focal point and eye together in the image plane (see header).
// Why: dragging with the pan tool must move the volume with the pointer.
- (void)panByViewDelta:(CGSize)delta viewSize:(CGSize)viewSize
{
    CGFloat mm = [self millimetresPerViewPointForViewHeight:viewSize.height];
    N3Vector right = [self right];
    // Content follows the pointer, so the camera moves the opposite way (y down).
    N3Vector move = N3VectorAdd(N3VectorScalarMultiply(right, -delta.width * mm),
                                N3VectorScalarMultiply(_viewUp, delta.height * mm));
    _focalPoint = N3VectorAdd(_focalPoint, move);
}

// What: zoom (see header). Why: scroll wheel / pinch.
- (void)zoomByFactor:(CGFloat)factor
{
    if (!(factor > 0)) return;
    if (_projection == BKProjectionPerspective)
        _distance /= factor;
    else
        _parallelScale /= factor;
}

// What: copies the camera into the renderer's camera properties.
// Why: the renderer takes an image-plane centre + size (ortho) or an eye + angle
// (perspective); this is the one place that converts.
- (void)applyToRenderer:(BKVolumeRenderer *)renderer aspectRatio:(CGFloat)aspectRatio
{
    if (!(aspectRatio > 0)) aspectRatio = 1;
    renderer.projection = _projection;
    renderer.cameraDirection = _direction;
    renderer.cameraUp = _viewUp;
    if (_projection == BKProjectionPerspective) {
        renderer.cameraPosition = self.position;
        renderer.fieldOfView = _viewAngle;
    } else {
        renderer.cameraPosition = _focalPoint;
        renderer.viewHeight = 2.0 * _parallelScale;
        renderer.viewWidth = 2.0 * _parallelScale * aspectRatio;
    }
}

@end
