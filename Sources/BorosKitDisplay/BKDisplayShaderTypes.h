// BorosKitDisplay: the parameter block shared by the CPU (Objective-C) and the GPU shader.
//
// Why a macro: the same field list is compiled into the Objective-C struct below and,
// as text, into the Metal shader source (BKDisplayShaderSource.mm), so the two can never
// disagree. Only 4-byte scalars are used, so the memory layout is identical in C and Metal
// without any alignment padding surprises.

#ifndef BK_DISPLAY_SHADER_TYPES_H
#define BK_DISPLAY_SHADER_TYPES_H

#define BK_DISPLAY_PARAMS_FIELDS \
    float m_a; float m_b; float m_c; float m_d; float m_tx; float m_ty; /* view point -> image pixel (CGAffineTransform layout) */ \
    float scale;                     /* device pixels per view point */ \
    float imageWidth; float imageHeight; \
    float windowLower; float windowWidth; /* window/level as lower bound + width */ \
    int interpolation;               /* 0 nearest, 1 linear */ \
    int useColorTable; int invert; \
    float bgR; float bgG; float bgB; float bgA;

typedef struct BKDisplayParams { BK_DISPLAY_PARAMS_FIELDS } BKDisplayParams;

#define BKD_STRINGIFY_(...) #__VA_ARGS__
#define BKD_STRINGIFY(...) BKD_STRINGIFY_(__VA_ARGS__)

#endif
