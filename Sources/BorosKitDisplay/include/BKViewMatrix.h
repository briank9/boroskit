// BorosKitDisplay: BKViewMatrix - the 2D views' positioning (where their drawing lands on the screen after
// zoom, rotation, flip and offset), kept as matrix stacks in plain C99. Overlay-engine plan step 8c
// (2026-11-16): takes over what the app's soft-GL layer kept, so the views' drawing places itself with
// BorosKit maths only (the soft-GL layer is then removed, plan step 8e/8f).
//
// Original BorosKit code written for this project; contains no third-party code. The operations are the
// standard 4 x 4 transform maths (scale, translation, rotation about an axis, matrix product) in the
// column-by-column layout the views' code already uses (element [col * 4 + row]).
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 on doubles; no Apple, GPU or LGPL types.
// - Three stacks like the classic drawing code expects: model-view (32 deep), projection and texture
//   (4 deep). Every operation changes the top matrix of the CURRENT stack (chosen by the mode), multiplying
//   on the right as the classic code assumes (the last operation applies first to a point).
// - BKViewMatricesTo2D turns the current model-view + projection + viewport into the 2D affine BKViewXf
//   (drawing space -> view pixels, top-left origin, y down) that BKViewOverlayDraw / BKROIDraw use.
//
// Plain language: the view says "zoom by this, turn by that, move here"; this file remembers it and says
// where any point of the drawing ends up on the screen.

#ifndef BK_VIEW_MATRIX_H
#define BK_VIEW_MATRIX_H

#include <stdint.h>
#include "BKViewOverlayDraw.h"

#ifdef __cplusplus
extern "C" {
#endif

enum { BKMatrixModelView = 0, BKMatrixProjection = 1, BKMatrixTexture = 2 };
#define BK_VIEW_MV_DEPTH 32
#define BK_VIEW_OTHER_DEPTH 4

typedef struct {
    int32_t mode;                                   // BKMatrixModelView / Projection / Texture
    double mv[BK_VIEW_MV_DEPTH][16];    int32_t mvTop;
    double pr[BK_VIEW_OTHER_DEPTH][16]; int32_t prTop;
    double tx[BK_VIEW_OTHER_DEPTH][16]; int32_t txTop;
} BKViewMatrices;

// What: every stack holds one identity matrix; mode = model-view.
void BKViewMatricesReset(BKViewMatrices *m);
// What: each stack keeps only its current top matrix (as the bottom one) - the state a view carries into its
// next frame.
void BKViewMatricesKeepTops(BKViewMatrices *m);
void BKViewMatricesSetMode(BKViewMatrices *m, int32_t mode);

// What: the current matrix becomes identity / is multiplied on the right by a scale, a translation, a rotation
// of `degrees` about the axis (x, y, z) (right-hand rule; a zero axis changes nothing), or `c` (16 values,
// column by column).
void BKViewMatricesIdentity(BKViewMatrices *m);
void BKViewMatricesScale(BKViewMatrices *m, double x, double y, double z);
void BKViewMatricesTranslate(BKViewMatrices *m, double x, double y, double z);
void BKViewMatricesRotate(BKViewMatrices *m, double degrees, double x, double y, double z);
void BKViewMatricesMultiply(BKViewMatrices *m, const double c[16]);
void BKViewMatricesLoad(BKViewMatrices *m, const double c[16]);

// What: push a copy of the current top / drop it. Return 1, or 0 when the stack is full / has only one matrix
// (nothing changed then; the caller decides what to do - the old drawing treated it as "cannot draw this").
int BKViewMatricesPush(BKViewMatrices *m);
int BKViewMatricesPop(BKViewMatrices *m);

// What: the top matrix of stack `mode` (16 values, column by column).
const double *BKViewMatricesTop(const BKViewMatrices *m, int32_t mode);

// What: the current drawing space as a 2D placement on a view of vpW x vpH pixels, when the matrices are plain
// 2D ones: projection = identity, model-view without perspective (bottom row 0 0 0 1). The viewport (vpX, vpY,
// vpW, vpH, bottom-left origin as the classic code gives it) must start at 0, 0. *xf: drawing space -> view
// pixels (top-left, y down); *zx / *zy (may be NULL): view pixels per unit of depth (3D drawing spaces).
// Returns 1, or 0 when the matrices are not plain 2D (the caller then draws another way).
int BKViewMatricesTo2D(const BKViewMatrices *m, int32_t vpX, int32_t vpY, int32_t vpW, int32_t vpH,
                       BKViewXf *xf, double *zx, double *zy);

#ifdef __cplusplus
}
#endif

#endif
