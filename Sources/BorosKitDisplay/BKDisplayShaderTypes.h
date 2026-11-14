// BorosKitDisplay: the parameter block shared by the CPU (Objective-C) and the GPU shader.
//
// Why a macro: the same field list is compiled into the Objective-C struct below and,
// as text, into the Metal shader source (BKDisplayShaderSource.mm), so the two can never
// disagree. Only 4-byte scalars are used, so the memory layout is identical in C and Metal
// without any alignment padding surprises.

//
// ---- PORTING NOTES (future Vulkan backend) -------------------------------------------
//  - Layout: only 4-byte scalars (float and bk_i32 = int32_t in C, int in Metal / GLSL),
//    no vectors, no bool; 20 fields = 80 bytes (a multiple of 16, no padding). It therefore
//    has the same layout in std430 AND std140 (scalars are packed the same in both), so it
//    can be a small uniform buffer. At 80 bytes it also fits the guaranteed 128 bytes of
//    Vulkan push constants.
//  - The shader is one full-screen triangle + a fragment shader. Vulkan differences to
//    handle: clip-space y points DOWN in Vulkan (flip y in the vertex shader or use a
//    negative viewport height); gl_FragCoord is pixel centre (x + 0.5, y + 0.5) with y
//    down from the top, which matches Metal's [[position]] used here.
//  - The image is read with texelFetch (no sampler, no filtering): bilinear is done by
//    hand, so R32_SFLOAT images need no optional "linear filtering of float" feature.
//  - The fusion overlay is a second draw in the same pass with premultiplied "over"
//    blending (src = one, dst = one-minus-src-alpha) - see BKImageLayerRenderer.m.
// ---------------------------------------------------------------------------------------

#ifndef BK_DISPLAY_SHADER_TYPES_H
#define BK_DISPLAY_SHADER_TYPES_H

#ifndef __METAL_VERSION__
#include <stdint.h>
typedef int32_t bk_i32;   // the shader declares bk_i32 as int (also 32 bits)
#endif

#define BK_DISPLAY_PARAMS_FIELDS \
    float m_a; float m_b; float m_c; float m_d; float m_tx; float m_ty; /* view point -> image pixel (CGAffineTransform layout) */ \
    float scale;                     /* device pixels per view point */ \
    float imageWidth; float imageHeight; \
    float windowLower; float windowWidth; /* window/level as lower bound + width */ \
    bk_i32 interpolation;            /* 0 nearest, 1 linear */ \
    bk_i32 useColorTable; bk_i32 invert; \
    bk_i32 colorImage;               /* 1 = image texture is a finished RGBA picture */ \
    bk_i32 useImageAlpha;            /* 1 = keep a colour picture's own alpha (see-through overlay layer) */ \
    float bgR; float bgG; float bgB; float bgA;

#ifndef __METAL_VERSION__
typedef struct BKDisplayParams { BK_DISPLAY_PARAMS_FIELDS } BKDisplayParams;
// The layout promise above, checked by the compiler.
_Static_assert(sizeof(BKDisplayParams) == 80, "BKDisplayParams must stay 80 bytes (see PORTING NOTES)");
#endif

#define BKD_STRINGIFY_(...) #__VA_ARGS__
#define BKD_STRINGIFY(...) BKD_STRINGIFY_(__VA_ARGS__)

#endif
