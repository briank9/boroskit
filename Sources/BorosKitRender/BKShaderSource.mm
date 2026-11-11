// BorosKitRender: the Metal shader source, compiled at runtime.
//
// Why runtime compilation instead of a prebuilt .metallib: a Swift package built with
// `swift build` does not reliably compile .metal files, and the app may consume
// BorosKit as a local package, a submodule or an Xcode project. Embedding the source
// and compiling it with -[MTLDevice newLibraryWithSource:] works identically in all of
// those, on macOS and iOS. Cost: a one-time compile (tens of milliseconds) when the
// first renderer is created; the compiled library is cached per device.
//
// This file is Objective-C++ only so the shader can be written as a readable C++ raw
// string literal (R"( ... )") with real line numbers in compiler messages.

#import <Foundation/Foundation.h>
#import "BKShaderTypes.h"

// Returns the full shader source: a small prelude, the shared parameter struct (from
// BKShaderTypes.h, so CPU and GPU can never disagree), and the kernels.
// extern "C": this file is Objective-C++, but the renderer (plain Objective-C) calls
// this function, so it must not get a C++ mangled name.
extern "C" NSString *BKVolumeShaderSource(void)
{
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *prelude = R"METAL(
#include <metal_stdlib>
using namespace metal;
typedef float3   bk_float3;
typedef float3x3 bk_float3x3;
)METAL";

        const char *params = "struct BKRenderParams { " BK_STRINGIFY(BK_RENDER_PARAMS_FIELDS) " };\n";

        const char *kernels = R"METAL(
// Render modes / projections (must match BKRenderMode / BKProjection in BKVolumeRenderer.h).
constant int BKModeComposite = 0;
constant int BKModeMIP       = 1;
constant int BKModeMinIP     = 2;
constant int BKModeAverage   = 3;
constant int BKProjPerspective = 1;

// Reads the real (CT) value at a position given in voxel index coordinates, with
// hardware trilinear interpolation. Voxel centres sit at whole numbers, texel centres
// at (i + 0.5) / size, hence the +0.5.
static float bk_sample(texture3d<float> volume, sampler s, float3 voxel, constant BKRenderParams &p)
{
    float3 tc = (voxel + 0.5f) / p.volumeSize;
    return volume.sample(s, tc).r * p.valueScale + p.valueOffset;
}

// Surface normal for lighting: central differences of the value in voxel space,
// converted to patient space (grad_patient = A^T * grad_voxel, A = patient->voxel),
// so anisotropic or tilted voxels still light correctly.
static float3 bk_gradient(texture3d<float> volume, sampler s, float3 v, constant BKRenderParams &p)
{
    float3 g;
    g.x = bk_sample(volume, s, v + float3(1,0,0), p) - bk_sample(volume, s, v - float3(1,0,0), p);
    g.y = bk_sample(volume, s, v + float3(0,1,0), p) - bk_sample(volume, s, v - float3(0,1,0), p);
    g.z = bk_sample(volume, s, v + float3(0,0,1), p) - bk_sample(volume, s, v - float3(0,0,1), p);
    return transpose(p.patientToVoxel) * (0.5f * g);
}

// Packs a 0..1 colour into 8-bit RGBA.
static uchar4 bk_pack(float4 c)
{
    return uchar4(clamp(c, 0.0f, 1.0f) * 255.0f + 0.5f);
}

// One thread = one output pixel. Builds the ray in patient space, clips it to the
// volume/crop box (in voxel space; the transform is affine so the ray parameter t is
// the same in both spaces) and to the slab, then marches through it.
kernel void bk_raycast(texture3d<float> volume       [[texture(0)]],
                       texture2d<float> transferFn   [[texture(1)]],
                       constant BKRenderParams &p    [[buffer(0)]],
                       device uchar4 *colorOut       [[buffer(1)]],
                       device float  *valueOut       [[buffer(2)]],
                       uint2 gid                     [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint index = gid.y * p.width + gid.x;

    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler tfSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    // Image-plane coordinates in -0.5..0.5, y up (row 0 is the top of the image).
    float u = ((float)gid.x + 0.5f) / (float)p.width - 0.5f;
    float w = 0.5f - ((float)gid.y + 0.5f) / (float)p.height;

    float3 origin, dir;
    float tLo, tHi;
    if (p.projection == BKProjPerspective) {
        origin = p.cameraPosition;
        dir = normalize(p.cameraForward + p.cameraRight * (u * p.viewWidth) + p.cameraUp * (w * p.viewHeight));
        tLo = 0.0f; tHi = INFINITY;
    } else {
        origin = p.cameraPosition + p.cameraRight * (u * p.viewWidth) + p.cameraUp * (w * p.viewHeight);
        dir = p.cameraForward;
        tLo = -INFINITY; tHi = INFINITY;
    }

    // Ray in voxel space.
    float3 ov = p.patientToVoxel * origin + p.patientToVoxelTranslation;
    float3 dv = p.patientToVoxel * dir;

    // Slab-test against the box (standard ray/box intersection).
    float3 inv = 1.0f / dv;
    float3 t0 = (p.boxMin - ov) * inv;
    float3 t1 = (p.boxMax - ov) * inv;
    float3 tSmall = min(t0, t1), tBig = max(t0, t1);
    // Axis-parallel rays: inside the box on that axis -> no constraint, outside -> miss.
    for (int k = 0; k < 3; k++) {
        if (dv[k] == 0.0f) {
            bool inside = ov[k] >= p.boxMin[k] && ov[k] <= p.boxMax[k];
            tSmall[k] = inside ? -INFINITY : INFINITY;
            tBig[k]   = inside ?  INFINITY : -INFINITY;
        }
    }
    tLo = max(tLo, max(tSmall.x, max(tSmall.y, tSmall.z)));
    tHi = min(tHi, min(tBig.x, min(tBig.y, tBig.z)));

    bool singlePlane = false;
    if (p.useSlab != 0) {
        // Signed distance from the slab's centre plane along the ray: s(t) = s0 + t*dn.
        float s0 = dot(origin - p.slabPoint, p.slabNormal);
        float dn = dot(dir, p.slabNormal);
        float halfThick = 0.5f * p.slabThickness;
        if (p.slabThickness <= 0.0f) {
            // Thin slice: exactly one sample where the ray crosses the plane.
            if (fabs(dn) < 1e-6f) { tHi = -INFINITY; }
            else { float t = -s0 / dn; tLo = max(tLo, t); tHi = min(tHi, t); singlePlane = true; }
        } else if (fabs(dn) < 1e-6f) {
            if (fabs(s0) > halfThick) tHi = -INFINITY;   // ray runs parallel, outside the slab
        } else {
            float ta = (-halfThick - s0) / dn, tb = (halfThick - s0) / dn;
            tLo = max(tLo, min(ta, tb));
            tHi = min(tHi, max(ta, tb));
        }
    }

    bool composite = (p.mode == BKModeComposite);

    if (!(tHi >= tLo) || isinf(tLo) || isinf(tHi)) {
        // Ray misses the volume (or the slab).
        valueOut[index] = composite ? 0.0f : p.outOfBoundsValue;
        colorOut[index] = composite ? uchar4(0) : uchar4(0, 0, 0, 255);
        return;
    }

    // Evenly spaced samples in the middle of n equal segments: always at least one,
    // and the same positions whatever the camera distance.
    int n = singlePlane ? 1 : max(1, (int)ceil((tHi - tLo) / p.stepSize));
    float step = singlePlane ? 0.0f : (tHi - tLo) / (float)n;

    if (composite) {
        float3 color = float3(0.0f);
        float alpha = 0.0f;
        float3 light = -dir;  // head-light: the light sits at the viewer
        // Opacity correction so the result does not depend on the sample spacing.
        float exponent = (singlePlane ? p.stepSize : step) / p.opacityUnitDistance;
        float tfRange = max(p.tfMax - p.tfMin, 1e-6f);
        for (int i = 0; i < n && alpha < 0.99f; i++) {   // early ray termination
            float t = tLo + ((float)i + 0.5f) * step;
            float3 v = ov + t * dv;
            float value = bk_sample(volume, linearSampler, v, p);
            float4 c = transferFn.sample(tfSampler, float2((value - p.tfMin) / tfRange, 0.5f));
            if (c.a <= 0.0f) continue;
            float a = 1.0f - pow(1.0f - min(c.a, 0.9999f), exponent);
            float3 rgb = c.rgb;
            if (p.shading != 0) {
                float3 g = bk_gradient(volume, linearSampler, v, p);
                float len = length(g);
                if (len > 1e-3f) {
                    float ndl = fabs(dot(g / len, light));
                    rgb = rgb * (p.ambient + p.diffuse * ndl) + p.specular * pow(ndl, p.specularPower);
                } else {
                    rgb = rgb * (p.ambient + p.diffuse);  // flat region: no direction to light
                }
            }
            color += (1.0f - alpha) * a * rgb;   // front-to-back compositing
            alpha += (1.0f - alpha) * a;
        }
        valueOut[index] = alpha;
        colorOut[index] = bk_pack(float4(color, alpha));
        return;
    }

    // MIP / MinIP / Average.
    float result = (p.mode == BKModeMIP) ? -INFINITY : (p.mode == BKModeMinIP ? INFINITY : 0.0f);
    for (int i = 0; i < n; i++) {
        float t = tLo + ((float)i + 0.5f) * step;
        float value = bk_sample(volume, linearSampler, ov + t * dv, p);
        if (p.mode == BKModeMIP) result = max(result, value);
        else if (p.mode == BKModeMinIP) result = min(result, value);
        else result += value;
    }
    if (p.mode == BKModeAverage) result /= (float)n;

    valueOut[index] = result;
    float gray = clamp((result - (p.windowCenter - 0.5f * p.windowWidth)) / max(p.windowWidth, 1e-6f), 0.0f, 1.0f);
    colorOut[index] = bk_pack(float4(gray, gray, gray, 1.0f));
}

// Test helper: reports the size of the parameter block as the GPU sees it, so a unit
// test can prove the CPU and GPU layouts are identical.
kernel void bk_params_size(device uint *out [[buffer(0)]])
{
    out[0] = sizeof(BKRenderParams);
}
)METAL";

        source = [NSString stringWithFormat:@"%s%s%s", prelude, params, kernels];
    });
    return source;
}
