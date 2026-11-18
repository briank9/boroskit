// BorosKitRender: BKStereoCore - see BKStereoCore.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKStereoCore.h"

static unsigned char Luma(const unsigned char *p, const float bg[3])
{
    // Premultiplied colour over the background, then brightness.
    float a = p[3] / 255.0f, c[3];
    for (int i = 0; i < 3; i++) c[i] = p[i] + bg[i] * 255.0f * (1.0f - a);
    float y = 0.30f * c[0] + 0.59f * c[1] + 0.11f * c[2];
    if (y > 255.0f) y = 255.0f;
    if (y < 0.0f) y = 0.0f;
    return (unsigned char)(y + 0.5f);
}

void BKStereoComposeRedBlue(const unsigned char *left, const unsigned char *right, size_t count,
                            const float background[3], unsigned char *out)
{
    if (!left || !right || !out || !background) return;
    for (size_t i = 0; i < count; i++) {
        out[4 * i + 0] = Luma(left + 4 * i, background);
        out[4 * i + 1] = 0;
        out[4 * i + 2] = Luma(right + 4 * i, background);
        out[4 * i + 3] = 255;
    }
}

double BKStereoEyeAzimuth(double eyeAngleDegrees, int rightEye)
{
    return (rightEye ? 0.5 : -0.5) * eyeAngleDegrees;
}
