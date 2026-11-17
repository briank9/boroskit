// BorosKitDisplay: BKViewMatrix - see BKViewMatrix.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKViewMatrix.h"
#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static void Identity(double a[16])
{
    memset(a, 0, 16 * sizeof(double));
    a[0] = a[5] = a[10] = a[15] = 1;
}

// a = a * b (column by column: element [col * 4 + row]).
static void MultiplyRight(double a[16], const double b[16])
{
    double r[16];
    for (int c = 0; c < 4; c++)
        for (int row = 0; row < 4; row++) {
            double v = 0;
            for (int k = 0; k < 4; k++) v += a[k * 4 + row] * b[c * 4 + k];
            r[c * 4 + row] = v;
        }
    memcpy(a, r, sizeof r);
}

static double *Current(BKViewMatrices *m)
{
    switch (m->mode) {
        case BKMatrixProjection: return m->pr[m->prTop];
        case BKMatrixTexture: return m->tx[m->txTop];
        default: return m->mv[m->mvTop];
    }
}

void BKViewMatricesReset(BKViewMatrices *m)
{
    if (!m) return;
    memset(m, 0, sizeof *m);
    Identity(m->mv[0]); Identity(m->pr[0]); Identity(m->tx[0]);
    m->mode = BKMatrixModelView;
}

void BKViewMatricesKeepTops(BKViewMatrices *m)
{
    if (!m) return;
    memmove(m->mv[0], m->mv[m->mvTop], sizeof m->mv[0]); m->mvTop = 0;
    memmove(m->pr[0], m->pr[m->prTop], sizeof m->pr[0]); m->prTop = 0;
    memmove(m->tx[0], m->tx[m->txTop], sizeof m->tx[0]); m->txTop = 0;
}

void BKViewMatricesSetMode(BKViewMatrices *m, int32_t mode)
{
    if (m) m->mode = mode;
}

void BKViewMatricesIdentity(BKViewMatrices *m)
{
    if (m) Identity(Current(m));
}

void BKViewMatricesScale(BKViewMatrices *m, double x, double y, double z)
{
    if (!m) return;
    double s[16]; Identity(s);
    s[0] = x; s[5] = y; s[10] = z;
    MultiplyRight(Current(m), s);
}

void BKViewMatricesTranslate(BKViewMatrices *m, double x, double y, double z)
{
    if (!m) return;
    double t[16]; Identity(t);
    t[12] = x; t[13] = y; t[14] = z;
    MultiplyRight(Current(m), t);
}

void BKViewMatricesRotate(BKViewMatrices *m, double degrees, double x, double y, double z)
{
    if (!m) return;
    double len = sqrt(x * x + y * y + z * z);
    if (!(len > 0)) return;
    double ux = x / len, uy = y / len, uz = z / len;
    double a = degrees * M_PI / 180.0, c = cos(a), s = sin(a), t = 1.0 - c;
    double r[16]; Identity(r);
    // Rotation about a unit axis (Rodrigues' formula), column by column.
    r[0] = t * ux * ux + c;      r[4] = t * ux * uy - s * uz; r[8] = t * ux * uz + s * uy;
    r[1] = t * ux * uy + s * uz; r[5] = t * uy * uy + c;      r[9] = t * uy * uz - s * ux;
    r[2] = t * ux * uz - s * uy; r[6] = t * uy * uz + s * ux; r[10] = t * uz * uz + c;
    MultiplyRight(Current(m), r);
}

void BKViewMatricesMultiply(BKViewMatrices *m, const double c[16])
{
    if (m && c) MultiplyRight(Current(m), c);
}

void BKViewMatricesLoad(BKViewMatrices *m, const double c[16])
{
    if (m && c) memcpy(Current(m), c, 16 * sizeof(double));
}

int BKViewMatricesPush(BKViewMatrices *m)
{
    if (!m) return 0;
    switch (m->mode) {
        case BKMatrixProjection:
            if (m->prTop + 1 >= BK_VIEW_OTHER_DEPTH) return 0;
            memcpy(m->pr[m->prTop + 1], m->pr[m->prTop], sizeof m->pr[0]); m->prTop++; return 1;
        case BKMatrixTexture:
            if (m->txTop + 1 >= BK_VIEW_OTHER_DEPTH) return 0;
            memcpy(m->tx[m->txTop + 1], m->tx[m->txTop], sizeof m->tx[0]); m->txTop++; return 1;
        default:
            if (m->mvTop + 1 >= BK_VIEW_MV_DEPTH) return 0;
            memcpy(m->mv[m->mvTop + 1], m->mv[m->mvTop], sizeof m->mv[0]); m->mvTop++; return 1;
    }
}

int BKViewMatricesPop(BKViewMatrices *m)
{
    if (!m) return 0;
    switch (m->mode) {
        case BKMatrixProjection: if (m->prTop == 0) return 0; m->prTop--; return 1;
        case BKMatrixTexture: if (m->txTop == 0) return 0; m->txTop--; return 1;
        default: if (m->mvTop == 0) return 0; m->mvTop--; return 1;
    }
}

const double *BKViewMatricesTop(const BKViewMatrices *m, int32_t mode)
{
    if (!m) return NULL;
    switch (mode) {
        case BKMatrixProjection: return m->pr[m->prTop];
        case BKMatrixTexture: return m->tx[m->txTop];
        default: return m->mv[m->mvTop];
    }
}

int BKViewMatricesTo2D(const BKViewMatrices *m, int32_t vpX, int32_t vpY, int32_t vpW, int32_t vpH,
                       BKViewXf *xf, double *zx, double *zy)
{
    if (!m || !xf || vpX != 0 || vpY != 0 || vpW <= 0 || vpH <= 0) return 0;
    const double *mv = m->mv[m->mvTop], *pr = m->pr[m->prTop];
    for (int i = 0; i < 16; i++)
        if (fabs(pr[i] - ((i % 5 == 0) ? 1.0 : 0.0)) > 1e-6) return 0;   // projection = identity
    if (fabs(mv[3]) > 1e-6 || fabs(mv[7]) > 1e-6 || fabs(mv[11]) > 1e-6 || fabs(mv[15] - 1.0) > 1e-6) return 0;
    // Clip space (-1..1, y up) -> view pixels (top-left, y down).
    double w2 = vpW / 2.0, h2 = vpH / 2.0;
    xf->a = w2 * mv[0]; xf->c = w2 * mv[4]; xf->tx = w2 * (1.0 + mv[12]);
    xf->b = -h2 * mv[1]; xf->d = -h2 * mv[5]; xf->ty = h2 * (1.0 - mv[13]);
    if (zx) *zx = w2 * mv[8];
    if (zy) *zy = -h2 * mv[9];
    return 1;
}
