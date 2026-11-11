// BorosKitDisplay: BKViewTransform implementation. See the header for conventions.

#import "BKViewTransform.h"
#import <math.h>

// What: the aspect factor that turns image-y pixels into "x-pixel-sized" units.
// Why: CT/CBCT pixels can be non-square (e.g. a reformatted slab); Horos stretches the
// image vertically by spacingY/spacingX so millimetres look the same in both directions.
static CGFloat BKAspect(BKViewTransform t)
{
    if (t.pixelSpacingX > 0 && t.pixelSpacingY > 0)
        return t.pixelSpacingY / t.pixelSpacingX;
    return 1.0;
}

// What: a fit-to-view transform for a new image. Why: the starting state of every
// viewer; also the reference for "reset view".
BKViewTransform BKViewTransformMakeFit(CGFloat imageWidth, CGFloat imageHeight, CGFloat viewWidth, CGFloat viewHeight)
{
    BKViewTransform t;
    memset(&t, 0, sizeof(t));
    t.imageWidth = imageWidth;
    t.imageHeight = imageHeight;
    t.pixelSpacingX = 1.0;
    t.pixelSpacingY = 1.0;
    t.viewWidth = viewWidth;
    t.viewHeight = viewHeight;
    t.zoom = 1.0;
    t.zoom = BKViewTransformFitZoom(t);
    return t;
}

// What: largest zoom that still shows the whole image, taking rotation and pixel aspect
// into account. Why: rotated images need a smaller zoom to fit; doing it here keeps
// the rule in one place.
CGFloat BKViewTransformFitZoom(BKViewTransform t)
{
    CGFloat w = t.imageWidth;
    CGFloat h = t.imageHeight * BKAspect(t);
    if (w <= 0 || h <= 0 || t.viewWidth <= 0 || t.viewHeight <= 0)
        return 1.0;
    CGFloat a = t.rotationDegrees * M_PI / 180.0;
    CGFloat c = fabs(cos(a)), s = fabs(sin(a));
    CGFloat boxW = w * c + h * s;   // bounding box of the rotated image
    CGFloat boxH = w * s + h * c;
    return fmin(t.viewWidth / boxW, t.viewHeight / boxH);
}

// What: builds image -> view as a chain of simple steps:
//   1. move the image centre to the origin
//   2. stretch y by the pixel aspect (non-square pixels)
//   3. mirror (flips act in the image's own orientation, before rotation)
//   4. rotate clockwise on screen (y-down, so the standard matrix turns clockwise)
//   5. zoom
//   6. move to the view centre plus pan
// Why one function: the shader, the overlays and the mouse all need exactly this, and a
// CGAffineTransform can be handed to CoreGraphics and (as 6 floats) to the GPU.
CGAffineTransform BKViewTransformImageToView(BKViewTransform t)
{
    CGFloat a = t.rotationDegrees * M_PI / 180.0;
    CGFloat cs = cos(a), sn = sin(a);
    CGFloat fx = t.flipHorizontal ? -1.0 : 1.0;
    CGFloat fy = t.flipVertical ? -1.0 : 1.0;
    CGFloat sx = t.zoom * fx;
    CGFloat sy = t.zoom * BKAspect(t) * fy;

    // Linear part M = R * S, with S = diag(sx, sy), R = [[cs, -sn], [sn, cs]] (y-down
    // screen: this turns clockwise for positive angles).
    // CGAffineTransform maps x' = a*x + c*y + tx, y' = b*x + d*y + ty.
    CGAffineTransform m;
    m.a = cs * sx;
    m.b = sn * sx;
    m.c = -sn * sy;
    m.d = cs * sy;
    // Translation: the image centre goes to the view centre + pan.
    CGFloat cx = t.imageWidth * 0.5, cy = t.imageHeight * 0.5;
    m.tx = t.viewWidth * 0.5 + t.panX - (m.a * cx + m.c * cy);
    m.ty = t.viewHeight * 0.5 + t.panY - (m.b * cx + m.d * cy);
    return m;
}

// What: the inverse mapping. Why: the shader needs, for every screen pixel, which image
// pixel to show; the mouse needs to know which image pixel was clicked.
CGAffineTransform BKViewTransformViewToImage(BKViewTransform t)
{
    return CGAffineTransformInvert(BKViewTransformImageToView(t));
}

// What/why: point helpers so callers never build the matrix themselves.
CGPoint BKViewTransformImagePointToView(BKViewTransform t, CGPoint imagePoint)
{
    return CGPointApplyAffineTransform(imagePoint, BKViewTransformImageToView(t));
}

CGPoint BKViewTransformViewPointToImage(BKViewTransform t, CGPoint viewPoint)
{
    return CGPointApplyAffineTransform(viewPoint, BKViewTransformViewToImage(t));
}

// What: mm per view point along the image x axis. Why: the scale bar and on-screen
// distances need it; zoom is "points per x pixel", so this is spacingX / zoom.
CGFloat BKViewTransformMillimetresPerViewPoint(BKViewTransform t)
{
    if (t.zoom <= 0)
        return 0;
    CGFloat spacing = t.pixelSpacingX > 0 ? t.pixelSpacingX : 1.0;
    return spacing / t.zoom;
}

// What: zoom while pinning the image point under the cursor/fingers. Why: zooming about
// the view centre feels wrong with a mouse wheel or pinch; this keeps the anatomy under
// the pointer still, by solving for the pan that maps the same image point back there.
BKViewTransform BKViewTransformZoomedAroundViewPoint(BKViewTransform t, CGFloat factor, CGPoint viewPoint)
{
    if (!(factor > 0))
        return t;
    CGPoint anchor = BKViewTransformViewPointToImage(t, viewPoint);
    BKViewTransform z = t;
    z.zoom = t.zoom * factor;
    CGPoint moved = BKViewTransformImagePointToView(z, anchor);
    z.panX += viewPoint.x - moved.x;
    z.panY += viewPoint.y - moved.y;
    return z;
}
