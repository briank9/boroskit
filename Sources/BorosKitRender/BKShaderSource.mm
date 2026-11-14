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

/* BOROS OVERVIEW (plain language)
 * This file holds the drawing program for the graphics chip. The program is a set of
 * instructions that works out the colour of each pixel in the 3D picture by following
 * an imaginary ray through the scan and combining what it passes through.
 * The program is stored as text inside this file and compiled the first time a
 * renderer starts, which works the same on Mac and iPad. The text must be edited
 * with care because it is code, even though it sits inside a string.
 */

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
typedef float4   bk_float4;
)METAL";

        const char *params = "struct BKRenderParams { " BK_STRINGIFY(BK_RENDER_PARAMS_FIELDS) " };\n"
                             // Brick size and lookup-table size, from the same header as the CPU side.
                             "constant int BKBrickSize = " BK_STRINGIFY(BK_BRICK_SIZE) ";\n"
                             "constant int BKTransferFunctionEntries = " BK_STRINGIFY(BK_TRANSFER_FUNCTION_ENTRIES) ";\n"
                             "constant int BKMaxClipPlanes = " BK_STRINGIFY(BK_MAX_CLIP_PLANES) ";\n";

        const char *kernels = R"METAL(
// Render modes / projections (must match BKRenderMode / BKProjection in BKVolumeRenderer.h).
constant int BKModeComposite = 0;
constant int BKModeMIP       = 1;
constant int BKModeMinIP     = 2;
constant int BKModeAverage   = 3;
constant int BKProjPerspective = 1;

// The parameter block stores every 3D quantity in a float4 (std430-friendly, see
// BKShaderTypes.h); these two helpers rebuild the 3x3 matrix and read .xyz in one place.
static float3x3 bk_patient_to_voxel(constant BKRenderParams &p)
{
    return float3x3(p.patientToVoxelColumns[0].xyz, p.patientToVoxelColumns[1].xyz, p.patientToVoxelColumns[2].xyz);
}

// Reads the real (CT) value at a position given in voxel index coordinates, with
// hardware trilinear interpolation. Voxel centres sit at whole numbers, texel centres
// at (i + 0.5) / size, hence the +0.5.
static float bk_sample(texture3d<float> volume, sampler s, float3 voxel, constant BKRenderParams &p)
{
    float3 tc = (voxel + 0.5f) / p.volumeSize.xyz;
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
    return transpose(bk_patient_to_voxel(p)) * (0.5f * g);
}

// Packs a 0..1 colour into 8-bit RGBA inside one 32-bit word (r in the lowest byte, so
// the bytes in memory are r, g, b, a). Why a uint and not uchar4: GPU buffers here hold
// only 32-bit words, so a Vulkan device needs no optional 8-bit storage feature.
static uint bk_pack(float4 c)
{
    uint4 q = uint4(clamp(c, 0.0f, 1.0f) * 255.0f + 0.5f);
    return q.x | (q.y << 8) | (q.z << 16) | (q.w << 24);
}

// Per-brick value range, packed as (lowest | highest << 16) in one 32-bit word (raw
// 16-bit stored steps). Same reason: only 32-bit words in GPU buffers.
static uint2 bk_unpack_range(uint packed)
{
    return uint2(packed & 0xffffu, packed >> 16);
}

// ---- Empty-space skipping helpers -------------------------------------------------
// See BK_BRICK_SIZE in BKShaderTypes.h for the idea. Brick b covers the voxel-space
// positions b*BKBrickSize .. (b+1)*BKBrickSize. Its stored value range was measured
// over one extra voxel on every side, so any sample within half a voxel of the brick
// (which reads its 8 neighbouring voxels for interpolation) is covered by that range.

// Which brick a voxel-space position lies in (clamped to the grid, so positions on
// the very edge of the volume use the edge brick).
static int3 bk_brick_of(float3 v, constant BKRenderParams &p)
{
    int3 last = int3(p.brickGrid.xyz) - 1;
    return clamp(int3(floor(v * (1.0f / (float)BKBrickSize))), int3(0), last);
}

// Position of brick b in the flat per-brick lists (x fastest, then y, then z).
static uint bk_brick_index(int3 b, constant BKRenderParams &p)
{
    uint3 g = uint3(p.brickGrid.xyz);
    return ((uint)b.z * g.y + (uint)b.y) * g.x + (uint)b.x;
}

// What: the number of the first sample (on the ray's normal, unchanged sample grid)
// that lies at or past the point where the ray leaves brick b.
// Why: jumping straight to that sample skips the samples inside the brick but keeps
// every later sample at exactly the position it would have had without skipping,
// which is what keeps the picture identical. Always moves at least one sample on.
static int bk_first_sample_after_brick(int3 b, float3 ov, float3 dv, float tLo, float step, int i, int n)
{
    float3 lo = float3(b * BKBrickSize);
    float3 hi = lo + (float)BKBrickSize;
    // Ray parameter where it crosses the far wall of the brick on each axis (a ray
    // that does not move along an axis never leaves the brick through that axis).
    float3 tWall;
    for (int k = 0; k < 3; k++) {
        if (dv[k] > 0.0f)      tWall[k] = (hi[k] - ov[k]) / dv[k];
        else if (dv[k] < 0.0f) tWall[k] = (lo[k] - ov[k]) / dv[k];
        else                   tWall[k] = INFINITY;
    }
    float tExit = min(tWall.x, min(tWall.y, tWall.z));
    // Sample j sits at tLo + (j + 0.5) * step; we want the first j with t >= tExit.
    float next = ceil((tExit - tLo) / step - 0.5f);
    return (int)clamp(next, (float)(i + 1), (float)n);
}

// The result of tracing one ray: the full-precision value (projected CT value, or the
// accumulated opacity in composite mode) and the colour (premultiplied by alpha).
struct BKTraceResult {
    float value;
    float4 color;
};

// Traces the ray of output pixel `gid`. Shared by every kernel below, so the buffer
// output (exports, tests) and the texture output (on-screen 3D view) can never differ.
// Builds the ray in patient space, clips it to the volume/crop box (in voxel space; the
// transform is affine so the ray parameter t is the same in both spaces), to the slab
// and to the clipping plane, then marches through what is left.
// brickEmpty / brickRange: the per-brick lists used for empty-space skipping (only
// read when p.skipEmptySpace is 1).
static BKTraceResult bk_trace(texture3d<float> volume, texture2d<float> transferFn,
                              constant BKRenderParams &p, uint2 gid,
                              device const uint *brickEmpty, device const uint *brickRange)
{
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler tfSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    // Image-plane coordinates in -0.5..0.5, y up (row 0 is the top of the image).
    float u = ((float)gid.x + 0.5f) / (float)p.width - 0.5f;
    float w = 0.5f - ((float)gid.y + 0.5f) / (float)p.height;

    float3 origin, dir;
    float tLo, tHi;
    if (p.projection == BKProjPerspective) {
        origin = p.cameraPosition.xyz;
        dir = normalize(p.cameraForward.xyz + p.cameraRight.xyz * (u * p.viewWidth) + p.cameraUp.xyz * (w * p.viewHeight));
        tLo = 0.0f; tHi = INFINITY;
    } else {
        origin = p.cameraPosition.xyz + p.cameraRight.xyz * (u * p.viewWidth) + p.cameraUp.xyz * (w * p.viewHeight);
        dir = p.cameraForward.xyz;
        tLo = -INFINITY; tHi = INFINITY;
    }

    // Ray in voxel space.
    float3x3 patientToVoxel = bk_patient_to_voxel(p);
    float3 ov = patientToVoxel * origin + p.patientToVoxelTranslation.xyz;
    float3 dv = patientToVoxel * dir;

    // Slab-test against the box (standard ray/box intersection).
    float3 inv = 1.0f / dv;
    float3 boxMin = p.boxMin.xyz, boxMax = p.boxMax.xyz;
    float3 t0 = (boxMin - ov) * inv;
    float3 t1 = (boxMax - ov) * inv;
    float3 tSmall = min(t0, t1), tBig = max(t0, t1);
    // Axis-parallel rays: inside the box on that axis -> no constraint, outside -> miss.
    for (int k = 0; k < 3; k++) {
        if (dv[k] == 0.0f) {
            bool inside = ov[k] >= boxMin[k] && ov[k] <= boxMax[k];
            tSmall[k] = inside ? -INFINITY : INFINITY;
            tBig[k]   = inside ?  INFINITY : -INFINITY;
        }
    }
    tLo = max(tLo, max(tSmall.x, max(tSmall.y, tSmall.z)));
    tHi = min(tHi, min(tBig.x, min(tBig.y, tBig.z)));

    bool singlePlane = false;
    if (p.useSlab != 0) {
        // Signed distance from the slab's centre plane along the ray: s(t) = s0 + t*dn.
        float s0 = dot(origin - p.slabPoint.xyz, p.slabNormal.xyz);
        float dn = dot(dir, p.slabNormal.xyz);
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

    if (p.useClip != 0) {
        // Clipping ("scissors") plane: keep only points with dot(x - clipPoint, n) <= 0,
        // i.e. cut away the side the normal points to. s(t) = c0 + t*cn along the ray.
        float c0 = dot(origin - p.clipPoint.xyz, p.clipNormal.xyz);
        float cn = dot(dir, p.clipNormal.xyz);
        if (fabs(cn) < 1e-6f) {
            if (c0 > 0.0f) tHi = -INFINITY;               // ray runs parallel, on the cut side
        } else if (cn > 0.0f) {
            tHi = min(tHi, -c0 / cn);                    // ray moves into the cut side
        } else {
            tLo = max(tLo, -c0 / cn);                    // ray comes out of the cut side
        }
    }

    // Extra clipping planes (e.g. the 6 faces of a rotated cropping box), same rule as the
    // single plane above: cut where dot(n, x) + w > 0. What: shortens [tLo, tHi] to the part
    // of the ray inside all planes. Why: the 3D window's crop box can be rotated, so an
    // axis-aligned voxel box is not enough. Plain loop over a fixed-size array (maps 1:1 to
    // a Vulkan/SPIR-V uniform buffer).
    for (int i = 0; i < p.clipPlaneCount && i < BKMaxClipPlanes; i++) {
        float3 n = p.clipPlanes[i].xyz;
        float c0 = dot(origin, n) + p.clipPlanes[i].w;
        float cn = dot(dir, n);
        if (fabs(cn) < 1e-6f) {
            if (c0 > 0.0f) tHi = -INFINITY;
        } else if (cn > 0.0f) {
            tHi = min(tHi, -c0 / cn);
        } else {
            tLo = max(tLo, -c0 / cn);
        }
    }

    bool composite = (p.mode == BKModeComposite);
    BKTraceResult r;

    if (!(tHi >= tLo) || isinf(tLo) || isinf(tHi)) {
        // Ray misses the volume (or the slab).
        r.value = composite ? 0.0f : p.outOfBoundsValue;
        r.color = composite ? float4(0.0f) : float4(0.0f, 0.0f, 0.0f, 1.0f);
        return r;
    }

    // Evenly spaced samples in the middle of n equal segments: always at least one,
    // and the same positions whatever the camera distance.
    int n = singlePlane ? 1 : max(1, (int)ceil((tHi - tLo) / p.stepSize));
    float step = singlePlane ? 0.0f : (tHi - tLo) / (float)n;

    // Skipping only makes sense with more than one sample (a single-plane slice has one).
    bool skip = (p.skipEmptySpace != 0) && !singlePlane;
    // The brick the current sample is in is worked out once, when the ray enters it,
    // together with brickEnd = the first sample past it. Samples before brickEnd are in
    // the same brick, so they need no lookup at all (keeps the per-sample cost tiny).
    int brickEnd = 0;

    if (composite) {
        float3 color = float3(0.0f);
        float alpha = 0.0f;
        float3 light = -dir;  // head-light: the light sits at the viewer
        // Opacity correction so the result does not depend on the sample spacing.
        float exponent = (singlePlane ? p.stepSize : step) / p.opacityUnitDistance;
        float tfRange = max(p.tfMax - p.tfMin, 1e-6f);
        bool brickIsEmpty = false;
        for (int i = 0; i < n && alpha < 0.99f; i++) {   // early ray termination
            float t = tLo + ((float)i + 0.5f) * step;
            float3 v = ov + t * dv;
            if (skip) {
                if (i >= brickEnd) {   // the ray has entered a new brick
                    int3 b = bk_brick_of(v, p);
                    brickEnd = bk_first_sample_after_brick(b, ov, dv, tLo, step, i, n);
                    brickIsEmpty = brickEmpty[bk_brick_index(b, p)] != 0;
                }
                // Fully transparent brick: every sample in it would be thrown away by
                // the "c.a <= 0" test below anyway, so jump to the first sample after it.
                if (brickIsEmpty) {
                    i = brickEnd - 1;  // the loop adds 1
                    continue;
                }
            }
            float value = bk_sample(volume, linearSampler, v, p);
            float4 c = transferFn.sample(tfSampler, float2((value - p.tfMin) / tfRange, 0.5f));
            if (c.a <= 0.0f) continue;
            float a = 1.0f - pow(1.0f - min(c.a, 0.9999f), exponent);
            float3 rgb = c.rgb;
            if (p.shading != 0) {
                // Phong lighting from the value gradient (the "surface" normal), with
                // the light at the viewer: ambient + diffuse * cos + specular * cos^power.
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
        r.value = alpha;
        r.color = float4(color, alpha);
        return r;
    }

    // MIP / MinIP / Average.
    float result = (p.mode == BKModeMIP) ? -INFINITY : (p.mode == BKModeMinIP ? INFINITY : 0.0f);
    // MIP / MinIP may skip a brick whose values cannot beat the result found so far
    // (MIP: its highest value is not above the current maximum; MinIP: its lowest is not
    // below the current minimum). The average needs every sample, so it never skips.
    bool skipProjection = skip && (p.mode == BKModeMIP || p.mode == BKModeMinIP);
    float brickLow = 0.0f, brickHigh = 0.0f;
    for (int i = 0; i < n; i++) {
        float t = tLo + ((float)i + 0.5f) * step;
        if (skipProjection) {
            if (i >= brickEnd) {   // the ray has entered a new brick
                int3 b = bk_brick_of(ov + t * dv, p);
                brickEnd = bk_first_sample_after_brick(b, ov, dv, tLo, step, i, n);
                // Stored range -> real values. One 16-bit step of margin on each side so
                // that GPU rounding of an interpolated sample can never step outside it.
                uint2 raw = bk_unpack_range(brickRange[bk_brick_index(b, p)]);
                brickLow  = (max((float)raw.x - 1.0f, 0.0f) / 65535.0f) * p.valueScale + p.valueOffset;
                brickHigh = (min((float)raw.y + 1.0f, 65535.0f) / 65535.0f) * p.valueScale + p.valueOffset;
            }
            bool cannotChange = (p.mode == BKModeMIP) ? (brickHigh <= result) : (brickLow >= result);
            if (cannotChange) {
                i = brickEnd - 1;  // the loop adds 1
                continue;
            }
        }
        float value = bk_sample(volume, linearSampler, ov + t * dv, p);
        if (p.mode == BKModeMIP) result = max(result, value);
        else if (p.mode == BKModeMinIP) result = min(result, value);
        else result += value;
    }
    if (p.mode == BKModeAverage) result /= (float)n;

    float gray = clamp((result - (p.windowCenter - 0.5f * p.windowWidth)) / max(p.windowWidth, 1e-6f), 0.0f, 1.0f);
    r.value = result;
    r.color = float4(gray, gray, gray, 1.0f);
    return r;
}

// One thread = one output pixel, written to CPU-readable buffers (8-bit RGBA + float).
// Used by -renderWithWidth:height:error: (exports, MPR slabs, tests).
kernel void bk_raycast(texture3d<float> volume       [[texture(0)]],
                       texture2d<float> transferFn   [[texture(1)]],
                       constant BKRenderParams &p    [[buffer(0)]],
                       device uint   *colorOut       [[buffer(1)]],   /* RGBA8 packed in one word */
                       device float  *valueOut       [[buffer(2)]],
                       device const uint *brickEmpty    [[buffer(3)]],   /* 1 word per brick */
                       device const uint *brickRange    [[buffer(4)]],   /* lowest | highest << 16 */
                       uint2 gid                     [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint index = gid.y * p.width + gid.x;
    BKTraceResult r = bk_trace(volume, transferFn, p, gid, brickEmpty, brickRange);
    valueOut[index] = r.value;
    colorOut[index] = bk_pack(r.color);
}

// One thread = one output pixel, written straight into a GPU texture (e.g. the screen's
// drawable) so the 3D view never copies pixels back to the CPU. The colour is laid over
// an opaque background colour, so the result can be shown as is.
kernel void bk_raycast_texture(texture3d<float> volume                      [[texture(0)]],
                               texture2d<float> transferFn                  [[texture(1)]],
                               texture2d<float, access::write> target       [[texture(2)]],
                               constant BKRenderParams &p                   [[buffer(0)]],
                               constant float4 &background                  [[buffer(1)]],
                               device const uint *brickEmpty                [[buffer(2)]],
                               device const uint *brickRange                [[buffer(3)]],
                               uint2 gid                                    [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    BKTraceResult r = bk_trace(volume, transferFn, p, gid, brickEmpty, brickRange);
    float3 rgb = r.color.rgb + (1.0f - r.color.a) * background.rgb;  // colour is premultiplied
    target.write(float4(clamp(rgb, 0.0f, 1.0f), 1.0f), gid);
}

// Scales a (low-resolution) image up to the size of `target` with linear filtering.
// Used while the user rotates or zooms: the 3D image is ray-cast at reduced resolution
// for speed, then stretched to fill the view (Horos does the same with its LOD setting).
kernel void bk_upscale(texture2d<float> source                 [[texture(0)]],
                       texture2d<float, access::write> target  [[texture(1)]],
                       uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / float2(target.get_width(), target.get_height());
    target.write(source.sample(s, uv), gid);
}

// Empty-space skipping, step 1 (once per volume): one thread per brick finds the
// lowest and highest stored value in the brick PLUS one voxel on every side. The extra
// voxel matters: a sample just inside the brick's edge blends in its neighbours, so
// they must count as part of the brick, or a brick could wrongly look empty.
// Values are kept as the raw 16-bit numbers, exactly as stored in the volume.
kernel void bk_brick_ranges(texture3d<float> volume      [[texture(0)]],
                            device uint *brickRange      [[buffer(0)]],   /* lowest | highest << 16 */
                            constant uint4 &grid4        [[buffer(1)]],   /* xyz = brick counts (uint4: no 3-vectors in GPU buffers) */
                            uint3 gid                    [[thread_position_in_grid]])
{
    uint3 grid = grid4.xyz;
    if (any(gid >= grid)) return;
    int3 last = int3(volume.get_width(), volume.get_height(), volume.get_depth()) - 1;
    int3 lo = max(int3(gid) * BKBrickSize - 1, int3(0));
    int3 hi = min(int3(gid) * BKBrickSize + BKBrickSize + 1, last);
    float mn = 1.0f, mx = 0.0f;
    for (int z = lo.z; z <= hi.z; z++)
        for (int y = lo.y; y <= hi.y; y++)
            for (int x = lo.x; x <= hi.x; x++) {
                float v = volume.read(uint3(x, y, z)).r;
                mn = min(mn, v);
                mx = max(mx, v);
            }
    uint index = (gid.z * grid.y + gid.y) * grid.x + gid.x;
    brickRange[index] = uint(rint(mn * 65535.0f)) | (uint(rint(mx * 65535.0f)) << 16);
}

// Empty-space skipping, step 2 (whenever the colour/opacity rule changes): one thread
// per brick decides whether the brick is completely see-through, i.e. every lookup-
// table entry the ray could possibly read for a value in the brick's range has zero
// opacity. Mirrors the ray's own lookup (same value scaling, same table position) and
// adds one table entry of margin on each side for the table's linear blending and for
// rounding. alphaCount[k] = how many of the first k table entries are not see-through,
// so "any opaque entry between a and b" is a single subtraction.
kernel void bk_classify_bricks(device const uint *brickRange     [[buffer(0)]],
                               device const uint *alphaCount    [[buffer(1)]],
                               device uint *brickEmpty          [[buffer(2)]],
                               constant BKRenderParams &p       [[buffer(3)]],
                               uint3 gid                        [[thread_position_in_grid]])
{
    uint3 g = uint3(p.brickGrid.xyz);
    if (any(gid >= g)) return;
    uint index = (gid.z * g.y + gid.y) * g.x + gid.x;
    uint2 raw = bk_unpack_range(brickRange[index]);
    float tfRange = max(p.tfMax - p.tfMin, 1e-6f);
    float lowValue  = ((float)raw.x / 65535.0f) * p.valueScale + p.valueOffset;
    float highValue = ((float)raw.y / 65535.0f) * p.valueScale + p.valueOffset;
    // Same position formula as the hardware lookup: texel = x * entries - 0.5; it blends
    // entries floor(texel) and floor(texel) + 1.
    float entries = (float)BKTransferFunctionEntries;
    float texLow  = (lowValue  - p.tfMin) / tfRange * entries - 0.5f;
    float texHigh = (highValue - p.tfMin) / tfRange * entries - 0.5f;
    // Clamp before converting to whole numbers (huge values would overflow).
    int first = (int)floor(clamp(texLow,  -4.0f, entries + 4.0f)) - 1;
    int last  = (int)floor(clamp(texHigh, -4.0f, entries + 4.0f)) + 2;
    first = clamp(first, 0, BKTransferFunctionEntries - 1);
    last  = clamp(last,  0, BKTransferFunctionEntries - 1);
    bool empty = (alphaCount[last + 1] - alphaCount[first]) == 0;
    brickEmpty[index] = empty ? 1 : 0;
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
