// BorosKitRender: BKStereoCore - red / blue ("anaglyph") stereo pictures, plain C99. Boros 6 (2026-11-17, 3D-off-VTK
// plan step 5.3): the surface window's Stereo button without VTK.
//
// Original BorosKit code written for this project; contains no third-party code. The method is the textbook
// anaglyph: the left eye's picture (brightness) goes into red, the right eye's into blue, green stays dark - for
// glasses with the red filter on the left eye. Brightness = 0.30 R + 0.59 G + 0.11 B (the usual luma weights).
//
// PORTING NOTES (Vulkan / other backends): VULKAN: safe to translate directly (or as a tiny fragment / compute
// shader with the same formula). Pure C99, no Apple or GPU types.
//
// Plain language: two pictures from slightly different places, one per eye, mixed into one picture for red/blue
// glasses.

#ifndef BK_STEREO_CORE_H
#define BK_STEREO_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: left / right = premultiplied RGBA8 pictures over a transparent background (what BorosKit renders),
// `count` pixels each; background = the window's background colour (RGB 0..1) put behind both first.
// out = RGBA8 (alpha 255): R = brightness of left, G = 0, B = brightness of right.
void BKStereoComposeRedBlue(const unsigned char *left, const unsigned char *right, size_t count,
                            const float background[3], unsigned char *out);

// What: the turn (degrees around the camera's up direction, through the focal point) for each eye: the left eye
// sits left of the camera (-half the eye angle), the right eye right of it (+half). VTK's default eye angle: 2.
double BKStereoEyeAzimuth(double eyeAngleDegrees, int rightEye);

#ifdef __cplusplus
}
#endif

#endif
