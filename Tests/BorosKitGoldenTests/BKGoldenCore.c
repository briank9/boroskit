// BorosKitGoldenTests: BKGoldenCore implementation (see BKGoldenCore.h).
// Original BorosKit code written for this project; contains no third-party code.
//
// Must be compiled with floating-point contraction OFF (Package.swift passes
// -ffp-contract=off for this test target) so the phantom is bit-identical everywhere.

#include "BKGoldenCore.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ============================================================================================
// Random numbers and hashing
// ============================================================================================

// What: three rounds of "xor the high bits into the low bits, multiply by an odd number".
// Why: every input bit ends up influencing every output bit, which is all the noise and
// the hash need. The two multipliers are arbitrary odd 64-bit numbers picked for this
// project (any odd number keeps the step reversible); they are not taken from anywhere.
uint64_t bk_golden_mix64(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xB0B05EED2026D11BULL;
    x ^= x >> 29;
    x *= 0xD1CE0C7A5B3F4E2DULL;
    x ^= x >> 32;
    return x;
}

double bk_golden_uniform(uint64_t seed, uint64_t index)
{
    // Seed and index are mixed separately first, so (seed, index) pairs never collide in an
    // obvious way. The top 53 bits make an exact double in [0, 1).
    uint64_t h = bk_golden_mix64(bk_golden_mix64(seed ^ 0x5EEDULL) + index);
    return (double)(h >> 11) * (1.0 / 9007199254740992.0);   // 2^-53
}

double bk_golden_noise(uint64_t seed, uint64_t index)
{
    // Sum of 4 uniforms: mean 2, variance 4/12. Centre it and scale by sqrt(3) for sigma 1.
    // Each uniform uses its own counter (4 * index + k), so voxels stay independent.
    double sum = 0.0;
    for (uint64_t k = 0; k < 4; k++) sum += bk_golden_uniform(seed, 4 * index + k);
    return (sum - 2.0) * 1.7320508075688772;
}

uint64_t bk_golden_hash(const void *bytes, size_t size)
{
    const uint8_t *p = (const uint8_t *)bytes;
    uint64_t h = bk_golden_mix64(0x426F726F734B6974ULL ^ (uint64_t)size);   // "BorosKit" in ASCII
    size_t i = 0;
    for (; i + 8 <= size; i += 8) {
        // Assemble 8 bytes little-endian by hand: same hash on any CPU.
        uint64_t w = 0;
        for (int k = 7; k >= 0; k--) w = (w << 8) | p[i + (size_t)k];
        h = bk_golden_mix64(h ^ w);
    }
    uint64_t tail = 0;
    for (size_t k = size; k > i; k--) tail = (tail << 8) | p[k - 1];
    return bk_golden_mix64(h ^ tail ^ 0xFFULL);
}

// ============================================================================================
// Phantom
// ============================================================================================

void bk_golden_volume_free(BKGoldenVolume *volume)
{
    if (!volume) return;
    free(volume->voxels);
    volume->voxels = NULL;
}

// Squared distance from point (px, py) to the segment a-b (2D). Plain arithmetic only.
static double bk_segment_distance2(double px, double py, double ax, double ay, double bx, double by)
{
    double dx = bx - ax, dy = by - ay;
    double len2 = dx * dx + dy * dy;
    double t = len2 > 0.0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0.0;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    double qx = ax + t * dx - px, qy = ay + t * dy - py;
    return qx * qx + qy * qy;
}

// The "jaw" curve: 41 points on y = -18 + 0.045 x^2, x = -20...20 (1 mm apart), in the
// axial plane z = -6 mm. Built once per phantom.
#define BK_JAW_POINTS 41
static void bk_jaw_points(double xs[BK_JAW_POINTS], double ys[BK_JAW_POINTS])
{
    for (int k = 0; k < BK_JAW_POINTS; k++) {
        double x = -20.0 + (double)k;
        xs[k] = x;
        ys[k] = -18.0 + 0.045 * x * x;
    }
}

// What: the phantom's value (HU) at patient point (x, y, z), without noise.
// Why a list of "last one wins" layers: easy to read and to extend; each layer is a
// simple shape with an exact inside test.
static double bk_head_value(double x, double y, double z, const double *jx, const double *jy)
{
    double v = -1000.0;   // air
    // Soft-tissue ellipsoid, semi-axes 28 x 26 x 27 mm.
    if ((x * x) / (28.0 * 28.0) + (y * y) / (26.0 * 26.0) + (z * z) / (27.0 * 27.0) <= 1.0) v = 40.0;
    // Fat ball.
    {
        double dx = x + 12.0, dy = y + 8.0, dz = z - 6.0;
        if (dx * dx + dy * dy + dz * dz <= 25.0) v = -100.0;
    }
    // Bone ball.
    {
        double dx = x - 10.0, dy = y - 6.0, dz = z - 8.0;
        if (dx * dx + dy * dy + dz * dz <= 36.0) v = 1000.0;
    }
    // Dense "metal" ball.
    {
        double dx = x + 6.0, dy = y - 12.0, dz = z + 10.0;
        if (dx * dx + dy * dy + dz * dz <= 6.25) v = 2500.0;
    }
    // Vertical cylinder at (14, 4), r 3.5 mm, z -18...18.
    {
        double dx = x - 14.0, dy = y - 4.0;
        if (dx * dx + dy * dy <= 12.25 && z >= -18.0 && z <= 18.0) v = 400.0;
    }
    // Step wedge: x -20...20 in 5 blocks of 8 mm, y 14...20, z -22...-16.
    if (x >= -20.0 && x < 20.0 && y >= 14.0 && y <= 20.0 && z >= -22.0 && z <= -16.0) {
        static const double steps[5] = {-500.0, 0.0, 250.0, 600.0, 1200.0};
        int k = (int)floor((x + 20.0) / 8.0);
        if (k < 0) k = 0;
        if (k > 4) k = 4;
        v = steps[k];
    }
    // Jaw tube (r 3 mm, 1500 HU) with a nerve canal (r 1.5 mm, 300 HU), around z = -6.
    {
        double dz = z + 6.0;
        if (dz >= -3.0 && dz <= 3.0) {
            double best = 1e30;
            for (int k = 0; k + 1 < BK_JAW_POINTS; k++) {
                double d2 = bk_segment_distance2(x, y, jx[k], jy[k], jx[k + 1], jy[k + 1]);
                if (d2 < best) best = d2;
            }
            double r2 = best + dz * dz;   // distance to the curve (the curve lies in the plane)
            if (r2 <= 9.0) v = (r2 <= 2.25) ? 300.0 : 1500.0;
        }
    }
    return v;
}

int bk_golden_make_head_phantom(BKGoldenVolume *out)
{
    memset(out, 0, sizeof(*out));
    out->width = 64;
    out->height = 64;
    out->depth = 48;
    out->spacing[0] = 1.0;
    out->spacing[1] = 1.0;
    out->spacing[2] = 1.25;
    // The centre of the voxel grid sits at patient (0, 0, 0).
    for (int a = 0; a < 3; a++) {
        uint32_t n = a == 0 ? out->width : (a == 1 ? out->height : out->depth);
        out->origin[a] = -0.5 * (double)(n - 1) * out->spacing[a];
    }
    out->minSpacing = 1.0;
    out->outOfBoundsValue = -1000.0f;
    // voxel = (p - origin) / spacing; column-major 4x4.
    memset(out->patientToVoxel, 0, sizeof(out->patientToVoxel));
    memset(out->voxelToPatient, 0, sizeof(out->voxelToPatient));
    for (int a = 0; a < 3; a++) {
        out->patientToVoxel[a * 4 + a] = 1.0 / out->spacing[a];
        out->patientToVoxel[12 + a] = -out->origin[a] / out->spacing[a];
        out->voxelToPatient[a * 4 + a] = out->spacing[a];
        out->voxelToPatient[12 + a] = out->origin[a];
    }
    out->patientToVoxel[15] = 1.0;
    out->voxelToPatient[15] = 1.0;

    size_t count = (size_t)out->width * out->height * out->depth;
    out->voxels = (float *)malloc(count * sizeof(float));
    if (!out->voxels) return -1;

    double jx[BK_JAW_POINTS], jy[BK_JAW_POINTS];
    bk_jaw_points(jx, jy);
    for (uint32_t k = 0; k < out->depth; k++)
        for (uint32_t j = 0; j < out->height; j++)
            for (uint32_t i = 0; i < out->width; i++) {
                // 2 x 2 x 2 sub-samples at +-1/4 voxel: partial-volume edges like a real scan.
                double sum = 0.0;
                for (int s = 0; s < 8; s++) {
                    double fx = (double)i + ((s & 1) ? 0.25 : -0.25);
                    double fy = (double)j + ((s & 2) ? 0.25 : -0.25);
                    double fz = (double)k + ((s & 4) ? 0.25 : -0.25);
                    sum += bk_head_value(out->origin[0] + fx * out->spacing[0],
                                         out->origin[1] + fy * out->spacing[1],
                                         out->origin[2] + fz * out->spacing[2], jx, jy);
                }
                size_t index = ((size_t)k * out->height + j) * out->width + i;
                double v = sum / 8.0 + BK_GOLDEN_HEAD_NOISE_HU * bk_golden_noise(BK_GOLDEN_HEAD_SEED, index);
                v = floor(v + 0.5);   // whole HU, like a CT
                if (v < -1024.0) v = -1024.0;
                if (v > 3071.0) v = 3071.0;
                out->voxels[index] = (float)v;
            }
    return 0;
}

// ============================================================================================
// Images and meshes
// ============================================================================================

static size_t bk_format_bytes(BKGoldenFormat f)
{
    return f == BKGoldenFormatU8 ? 1 : (f == BKGoldenFormatU16 ? 2 : 4);
}

BKGoldenImage bk_golden_image_make(uint32_t width, uint32_t height, uint32_t channels, BKGoldenFormat format)
{
    BKGoldenImage image = {width, height, channels, format, NULL};
    image.data = calloc((size_t)width * height * channels, bk_format_bytes(format));
    return image;
}

void bk_golden_image_free(BKGoldenImage *image)
{
    if (!image) return;
    free(image->data);
    image->data = NULL;
}

size_t bk_golden_image_bytes(const BKGoldenImage *image)
{
    return (size_t)image->width * image->height * image->channels * bk_format_bytes(image->format);
}

void bk_golden_mesh_free(BKGoldenMesh *mesh)
{
    if (!mesh) return;
    free(mesh->positions);
    free(mesh->normals);
    free(mesh->indices);
    mesh->positions = mesh->normals = NULL;
    mesh->indices = NULL;
}

BKGoldenMeshSummary bk_golden_mesh_summary(const BKGoldenMesh *m)
{
    BKGoldenMeshSummary s;
    memset(&s, 0, sizeof s);
    s.vertexCount = m->vertexCount;
    s.triangleCount = m->triangleCount;
    for (int a = 0; a < 3; a++) {
        s.boundsMin[a] = m->vertexCount ? INFINITY : 0.0;
        s.boundsMax[a] = m->vertexCount ? -INFINITY : 0.0;
    }
    // Hash of positions rounded to 1e-3 mm (as 64-bit integers) and of the triangles.
    uint64_t h = bk_golden_mix64(m->vertexCount ^ (m->triangleCount << 32));
    for (uint64_t i = 0; i < m->vertexCount; i++)
        for (int a = 0; a < 3; a++) {
            double v = m->positions[3 * i + (uint64_t)a];
            if (v < s.boundsMin[a]) s.boundsMin[a] = v;
            if (v > s.boundsMax[a]) s.boundsMax[a] = v;
            int64_t q = (int64_t)floor(v * 1000.0 + 0.5);
            h = bk_golden_mix64(h ^ (uint64_t)q);
        }
    for (uint64_t t = 0; t < m->triangleCount; t++) {
        const uint32_t *c = m->indices + 3 * t;
        h = bk_golden_mix64(h ^ ((uint64_t)c[0] | ((uint64_t)c[1] << 32)));
        h = bk_golden_mix64(h ^ (uint64_t)c[2]);
        const float *p0 = m->positions + 3 * (uint64_t)c[0];
        const float *p1 = m->positions + 3 * (uint64_t)c[1];
        const float *p2 = m->positions + 3 * (uint64_t)c[2];
        double e1[3], e2[3], n[3];
        for (int a = 0; a < 3; a++) { e1[a] = (double)p1[a] - p0[a]; e2[a] = (double)p2[a] - p0[a]; }
        n[0] = e1[1] * e2[2] - e1[2] * e2[1];
        n[1] = e1[2] * e2[0] - e1[0] * e2[2];
        n[2] = e1[0] * e2[1] - e1[1] * e2[0];
        s.area += 0.5 * sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        // Signed volume of the tetrahedron (origin, p0, p1, p2) = p0 . (p1 x p2) / 6.
        double c12[3] = {(double)p1[1] * p2[2] - (double)p1[2] * p2[1],
                         (double)p1[2] * p2[0] - (double)p1[0] * p2[2],
                         (double)p1[0] * p2[1] - (double)p1[1] * p2[0]};
        s.volume += ((double)p0[0] * c12[0] + (double)p0[1] * c12[1] + (double)p0[2] * c12[2]) / 6.0;
    }
    s.quantizedHash = h;
    return s;
}

// ============================================================================================
// Files
// ============================================================================================

int bk_golden_read_file(const char *path, uint8_t **bytes, size_t *size)
{
    *bytes = NULL;
    *size = 0;
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long n = ftell(f);
    if (n < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return -1; }
    uint8_t *data = (uint8_t *)malloc(n > 0 ? (size_t)n : 1);
    if (!data) { fclose(f); return -1; }
    if (n > 0 && fread(data, 1, (size_t)n, f) != (size_t)n) { free(data); fclose(f); return -1; }
    fclose(f);
    *bytes = data;
    *size = (size_t)n;
    return 0;
}

int bk_golden_write_file(const char *path, const void *bytes, size_t size)
{
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    int ok = (size == 0 || fwrite(bytes, 1, size, f) == size);
    ok = (fclose(f) == 0) && ok;
    return ok ? 0 : -1;
}

// A tiny cursor for parsing Netpbm-style text headers out of a byte buffer.
typedef struct { const uint8_t *p; size_t size, pos; } BKCursor;

// Next whitespace-separated token (skips '#' comments). Returns 0 if none.
static int bk_next_token(BKCursor *c, char *token, size_t tokenSize)
{
    for (;;) {
        while (c->pos < c->size && (c->p[c->pos] == ' ' || c->p[c->pos] == '\n' || c->p[c->pos] == '\r' || c->p[c->pos] == '\t'))
            c->pos++;
        if (c->pos < c->size && c->p[c->pos] == '#') {
            while (c->pos < c->size && c->p[c->pos] != '\n') c->pos++;
            continue;
        }
        break;
    }
    size_t n = 0;
    while (c->pos < c->size && c->p[c->pos] != ' ' && c->p[c->pos] != '\n' && c->p[c->pos] != '\r' && c->p[c->pos] != '\t') {
        if (n + 1 < tokenSize) token[n++] = (char)c->p[c->pos];
        c->pos++;
    }
    token[n] = 0;
    return n > 0;
}

int bk_golden_write_pam(const char *path, const BKGoldenImage *image)
{
    if (image->format != BKGoldenFormatU8 && image->format != BKGoldenFormatU16) return -1;
    if (image->channels < 1 || image->channels > 4) return -1;
    static const char *types[5] = {"", "GRAYSCALE", "GRAYSCALE_ALPHA", "RGB", "RGB_ALPHA"};
    char header[256];
    int h = snprintf(header, sizeof header, "P7\nWIDTH %u\nHEIGHT %u\nDEPTH %u\nMAXVAL %u\nTUPLTYPE %s\nENDHDR\n",
                     image->width, image->height, image->channels,
                     image->format == BKGoldenFormatU8 ? 255u : 65535u, types[image->channels]);
    size_t body = bk_golden_image_bytes(image);
    uint8_t *buffer = (uint8_t *)malloc((size_t)h + body);
    if (!buffer) return -1;
    memcpy(buffer, header, (size_t)h);
    if (image->format == BKGoldenFormatU8) {
        memcpy(buffer + h, image->data, body);
    } else {
        // Netpbm stores 16-bit samples most significant byte first.
        const uint16_t *s = (const uint16_t *)image->data;
        for (size_t i = 0; i < body / 2; i++) {
            buffer[h + 2 * i] = (uint8_t)(s[i] >> 8);
            buffer[h + 2 * i + 1] = (uint8_t)(s[i] & 0xFF);
        }
    }
    int result = bk_golden_write_file(path, buffer, (size_t)h + body);
    free(buffer);
    return result;
}

int bk_golden_read_pam(const char *path, BKGoldenImage *out)
{
    memset(out, 0, sizeof(*out));
    uint8_t *bytes;
    size_t size;
    if (bk_golden_read_file(path, &bytes, &size) != 0) return -1;
    BKCursor c = {bytes, size, 0};
    char token[64];
    unsigned width = 0, height = 0, depth = 0, maxval = 0;
    int result = -1;
    if (!bk_next_token(&c, token, sizeof token) || strcmp(token, "P7") != 0) goto done;
    for (;;) {
        if (!bk_next_token(&c, token, sizeof token)) goto done;
        if (strcmp(token, "ENDHDR") == 0) break;
        char value[64];
        if (!bk_next_token(&c, value, sizeof value)) goto done;
        if (strcmp(token, "WIDTH") == 0) width = (unsigned)strtoul(value, NULL, 10);
        else if (strcmp(token, "HEIGHT") == 0) height = (unsigned)strtoul(value, NULL, 10);
        else if (strcmp(token, "DEPTH") == 0) depth = (unsigned)strtoul(value, NULL, 10);
        else if (strcmp(token, "MAXVAL") == 0) maxval = (unsigned)strtoul(value, NULL, 10);
        // TUPLTYPE is informational only.
    }
    c.pos++;   // the single newline after ENDHDR
    if (!width || !height || depth < 1 || depth > 4 || (maxval != 255 && maxval != 65535)) goto done;
    *out = bk_golden_image_make(width, height, depth, maxval == 255 ? BKGoldenFormatU8 : BKGoldenFormatU16);
    if (!out->data) goto done;
    size_t body = bk_golden_image_bytes(out);
    if (c.pos + body > size) { bk_golden_image_free(out); goto done; }
    if (maxval == 255) {
        memcpy(out->data, bytes + c.pos, body);
    } else {
        uint16_t *d = (uint16_t *)out->data;
        for (size_t i = 0; i < body / 2; i++)
            d[i] = (uint16_t)((bytes[c.pos + 2 * i] << 8) | bytes[c.pos + 2 * i + 1]);
    }
    result = 0;
done:
    free(bytes);
    return result;
}

// float <-> 4 little-endian bytes, without relying on the machine's byte order.
static void bk_put_f32(uint8_t *b, float v)
{
    uint32_t u;
    memcpy(&u, &v, 4);
    b[0] = (uint8_t)u; b[1] = (uint8_t)(u >> 8); b[2] = (uint8_t)(u >> 16); b[3] = (uint8_t)(u >> 24);
}

static float bk_get_f32(const uint8_t *b)
{
    uint32_t u = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    float v;
    memcpy(&v, &u, 4);
    return v;
}

static void bk_put_u32(uint8_t *b, uint32_t u)
{
    b[0] = (uint8_t)u; b[1] = (uint8_t)(u >> 8); b[2] = (uint8_t)(u >> 16); b[3] = (uint8_t)(u >> 24);
}

static uint32_t bk_get_u32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

int bk_golden_write_pfm(const char *path, const BKGoldenImage *image)
{
    if (image->format != BKGoldenFormatF32 || (image->channels != 1 && image->channels != 3)) return -1;
    char header[128];
    // A negative scale means little-endian (PFM rule).
    int h = snprintf(header, sizeof header, "%s\n%u %u\n-1.0\n", image->channels == 1 ? "Pf" : "PF",
                     image->width, image->height);
    size_t row = (size_t)image->width * image->channels;
    size_t body = row * image->height * 4;
    uint8_t *buffer = (uint8_t *)malloc((size_t)h + body);
    if (!buffer) return -1;
    memcpy(buffer, header, (size_t)h);
    const float *src = (const float *)image->data;
    for (uint32_t y = 0; y < image->height; y++) {
        const float *line = src + (size_t)(image->height - 1 - y) * row;   // PFM: bottom row first
        for (size_t i = 0; i < row; i++) bk_put_f32(buffer + h + 4 * ((size_t)y * row + i), line[i]);
    }
    int result = bk_golden_write_file(path, buffer, (size_t)h + body);
    free(buffer);
    return result;
}

int bk_golden_read_pfm(const char *path, BKGoldenImage *out)
{
    memset(out, 0, sizeof(*out));
    uint8_t *bytes;
    size_t size;
    if (bk_golden_read_file(path, &bytes, &size) != 0) return -1;
    BKCursor c = {bytes, size, 0};
    char magic[8], w[32], hgt[32], scale[32];
    int result = -1;
    if (!bk_next_token(&c, magic, sizeof magic) || !bk_next_token(&c, w, sizeof w) ||
        !bk_next_token(&c, hgt, sizeof hgt) || !bk_next_token(&c, scale, sizeof scale)) goto done;
    c.pos++;   // single whitespace after the scale
    uint32_t channels = strcmp(magic, "Pf") == 0 ? 1 : (strcmp(magic, "PF") == 0 ? 3 : 0);
    if (!channels || strtod(scale, NULL) >= 0.0) goto done;   // only little-endian files are written
    *out = bk_golden_image_make((uint32_t)strtoul(w, NULL, 10), (uint32_t)strtoul(hgt, NULL, 10), channels, BKGoldenFormatF32);
    if (!out->data || !out->width || !out->height) { bk_golden_image_free(out); goto done; }
    size_t row = (size_t)out->width * channels;
    if (c.pos + row * out->height * 4 > size) { bk_golden_image_free(out); goto done; }
    float *dst = (float *)out->data;
    for (uint32_t y = 0; y < out->height; y++) {
        float *line = dst + (size_t)(out->height - 1 - y) * row;
        for (size_t i = 0; i < row; i++) line[i] = bk_get_f32(bytes + c.pos + 4 * ((size_t)y * row + i));
    }
    result = 0;
done:
    free(bytes);
    return result;
}

int bk_golden_write_mesh(const char *path, const BKGoldenMesh *m)
{
    uint64_t v = m->vertexCount, t = m->triangleCount;
    size_t size = 8 + 8 + 8 + 4 + 4 + (size_t)v * 12 * (m->normals ? 2 : 1) + (size_t)t * 12;
    uint8_t *b = (uint8_t *)malloc(size);
    if (!b) return -1;
    memcpy(b, "BKMESH1\n", 8);
    bk_put_u32(b + 8, (uint32_t)v); bk_put_u32(b + 12, (uint32_t)(v >> 32));
    bk_put_u32(b + 16, (uint32_t)t); bk_put_u32(b + 20, (uint32_t)(t >> 32));
    bk_put_u32(b + 24, m->normals ? 1u : 0u);
    bk_put_u32(b + 28, 0u);
    size_t o = 32;
    for (uint64_t i = 0; i < v * 3; i++, o += 4) bk_put_f32(b + o, m->positions[i]);
    if (m->normals)
        for (uint64_t i = 0; i < v * 3; i++, o += 4) bk_put_f32(b + o, m->normals[i]);
    for (uint64_t i = 0; i < t * 3; i++, o += 4) bk_put_u32(b + o, m->indices[i]);
    int result = bk_golden_write_file(path, b, size);
    free(b);
    return result;
}

int bk_golden_read_mesh(const char *path, BKGoldenMesh *out)
{
    memset(out, 0, sizeof(*out));
    uint8_t *b;
    size_t size;
    if (bk_golden_read_file(path, &b, &size) != 0) return -1;
    int result = -1;
    if (size < 32 || memcmp(b, "BKMESH1\n", 8) != 0) goto done;
    uint64_t v = (uint64_t)bk_get_u32(b + 8) | ((uint64_t)bk_get_u32(b + 12) << 32);
    uint64_t t = (uint64_t)bk_get_u32(b + 16) | ((uint64_t)bk_get_u32(b + 20) << 32);
    int hasNormals = bk_get_u32(b + 24) != 0;
    if (32 + v * 12 * (hasNormals ? 2 : 1) + t * 12 != size) goto done;
    out->vertexCount = v;
    out->triangleCount = t;
    out->positions = (float *)malloc((size_t)v * 12 + 4);
    out->normals = hasNormals ? (float *)malloc((size_t)v * 12 + 4) : NULL;
    out->indices = (uint32_t *)malloc((size_t)t * 12 + 4);
    if (!out->positions || !out->indices || (hasNormals && !out->normals)) { bk_golden_mesh_free(out); goto done; }
    size_t o = 32;
    for (uint64_t i = 0; i < v * 3; i++, o += 4) out->positions[i] = bk_get_f32(b + o);
    if (hasNormals)
        for (uint64_t i = 0; i < v * 3; i++, o += 4) out->normals[i] = bk_get_f32(b + o);
    for (uint64_t i = 0; i < t * 3; i++, o += 4) out->indices[i] = bk_get_u32(b + o);
    result = 0;
done:
    free(b);
    return result;
}

int bk_golden_write_numbers(const char *path, const BKGoldenNumber *numbers, size_t count)
{
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    for (size_t i = 0; i < count; i++) fprintf(f, "%s %.17g\n", numbers[i].name, numbers[i].value);
    return fclose(f) == 0 ? 0 : -1;
}

int bk_golden_read_numbers(const char *path, BKGoldenNumber **numbers, size_t *count)
{
    *numbers = NULL;
    *count = 0;
    uint8_t *bytes;
    size_t size;
    if (bk_golden_read_file(path, &bytes, &size) != 0) return -1;
    size_t capacity = 64, n = 0;
    BKGoldenNumber *list = (BKGoldenNumber *)malloc(capacity * sizeof(BKGoldenNumber));
    BKCursor c = {bytes, size, 0};
    char name[64], value[64];
    while (list && bk_next_token(&c, name, sizeof name) && bk_next_token(&c, value, sizeof value)) {
        if (n == capacity) {
            capacity *= 2;
            BKGoldenNumber *grown = (BKGoldenNumber *)realloc(list, capacity * sizeof(BKGoldenNumber));
            if (!grown) { free(list); list = NULL; break; }
            list = grown;
        }
        memcpy(list[n].name, name, sizeof name);
        list[n].value = strtod(value, NULL);
        n++;
    }
    free(bytes);
    if (!list) return -1;
    *numbers = list;
    *count = n;
    return 0;
}

// ============================================================================================
// Comparers
// ============================================================================================

BKGoldenImageTolerance bk_golden_tolerance_u8(void)
{
    BKGoldenImageTolerance t = {1.0, 0.005};
    return t;
}

// One channel value as a double, whatever the format.
static double bk_channel(const BKGoldenImage *image, size_t i)
{
    switch (image->format) {
        case BKGoldenFormatU8: return ((const uint8_t *)image->data)[i];
        case BKGoldenFormatU16: return ((const uint16_t *)image->data)[i];
        default: return ((const float *)image->data)[i];
    }
}

BKGoldenImageReport bk_golden_compare_images(const BKGoldenImage *ref, const BKGoldenImage *test,
                                             BKGoldenImageTolerance tol)
{
    BKGoldenImageReport r;
    memset(&r, 0, sizeof r);
    if (ref->width != test->width || ref->height != test->height || ref->channels != test->channels ||
        ref->format != test->format || !ref->data || !test->data) {
        r.sizeMismatch = 1;
        return r;
    }
    size_t n = (size_t)ref->width * ref->height * ref->channels;
    for (size_t i = 0; i < n; i++) {
        double a = bk_channel(ref, i), b = bk_channel(test, i);
        if (a == b || (isnan(a) && isnan(b))) { r.identicalCount++; continue; }
        if (isinf(a) || isinf(b) || isnan(a) || isnan(b)) { r.outlierCount++; continue; }
        double d = fabs(a - b);
        if (d > r.maxDiff) r.maxDiff = d;
        if (d > tol.maxAbsDiff) r.outlierCount++;
    }
    r.outlierFraction = n ? (double)r.outlierCount / (double)n : 0.0;
    r.pass = r.outlierFraction <= tol.maxOutlierFraction;
    return r;
}

BKGoldenMeshReport bk_golden_compare_meshes(const BKGoldenMesh *ref, const BKGoldenMesh *test, BKGoldenMeshTolerance tol)
{
    BKGoldenMeshReport r;
    memset(&r, 0, sizeof r);
    if (ref->vertexCount != test->vertexCount || ref->triangleCount != test->triangleCount) {
        r.countMismatch = 1;
        return r;
    }
    for (uint64_t i = 0; i < ref->triangleCount * 3; i++)
        if (ref->indices[i] != test->indices[i]) {
            r.triangleMismatch = 1;
            r.firstBadTriangle = i / 3;
            break;
        }
    for (uint64_t i = 0; i < ref->vertexCount; i++) {
        double d2 = 0.0;
        for (int a = 0; a < 3; a++) {
            double d = ((double)test->positions[3 * i + (uint64_t)a] - ref->positions[3 * i + (uint64_t)a]) / tol.voxelSize[a];
            d2 += d * d;
        }
        double d = sqrt(d2);
        if (d > r.maxPositionVoxels || isnan(d)) r.maxPositionVoxels = isnan(d) ? INFINITY : d;
    }
    if ((ref->normals == NULL) != (test->normals == NULL)) {
        r.normalsMissing = 1;
    } else if (ref->normals) {
        for (uint64_t i = 0; i < ref->vertexCount; i++) {
            double d2 = 0.0;
            for (int a = 0; a < 3; a++) {
                double d = (double)test->normals[3 * i + (uint64_t)a] - ref->normals[3 * i + (uint64_t)a];
                d2 += d * d;
            }
            double d = sqrt(d2);
            if (d > r.maxNormalDiff || isnan(d)) r.maxNormalDiff = isnan(d) ? INFINITY : d;
        }
    }
    r.pass = !r.triangleMismatch && !r.normalsMissing && r.maxPositionVoxels <= tol.maxPositionVoxels &&
             r.maxNormalDiff <= tol.maxNormalDiff;
    return r;
}

int bk_golden_numbers_close(double test, double reference, double absTol, double relTol)
{
    if (test == reference) return 1;
    if (isnan(test) || isnan(reference)) return isnan(test) && isnan(reference);
    return fabs(test - reference) <= absTol + relTol * fabs(reference);
}

void bk_golden_describe_image_report(const BKGoldenImageReport *r, char *text, size_t size)
{
    if (r->sizeMismatch) { snprintf(text, size, "size/format mismatch"); return; }
    snprintf(text, size, "%s: max difference %.4g, %llu channels beyond tolerance (%.3f%%), %llu identical",
             r->pass ? "pass" : "FAIL", r->maxDiff, (unsigned long long)r->outlierCount,
             100.0 * r->outlierFraction, (unsigned long long)r->identicalCount);
}

void bk_golden_describe_mesh_report(const BKGoldenMeshReport *r, char *text, size_t size)
{
    if (r->countMismatch) { snprintf(text, size, "FAIL: vertex/triangle counts differ"); return; }
    snprintf(text, size, "%s: max position difference %.3g voxel, max normal difference %.3g%s%s",
             r->pass ? "pass" : "FAIL", r->maxPositionVoxels, r->maxNormalDiff,
             r->triangleMismatch ? ", triangle lists differ" : ", identical triangles",
             r->normalsMissing ? ", normals missing on one side" : "");
}

// ============================================================================================
// Test cases
// ============================================================================================

// Bone + soft tissue: dark red soft tissue, skin colour around 40 HU, bone white.
const BKGoldenColorPoint kBKGoldenColorPoints[] = {
    {-1000.0f, 0.00f, 0.00f, 0.00f},
    {-200.0f, 0.55f, 0.25f, 0.15f},
    {40.0f, 0.90f, 0.60f, 0.50f},
    {300.0f, 0.95f, 0.90f, 0.80f},
    {1500.0f, 1.00f, 1.00f, 1.00f},
};
const uint32_t kBKGoldenColorPointCount = sizeof(kBKGoldenColorPoints) / sizeof(kBKGoldenColorPoints[0]);

const BKGoldenOpacityPoint kBKGoldenOpacityPoints[] = {
    {-1000.0f, 0.00f}, {-400.0f, 0.00f}, {-100.0f, 0.04f}, {150.0f, 0.06f},
    {300.0f, 0.50f}, {1200.0f, 0.90f}, {3071.0f, 1.00f},
};
const uint32_t kBKGoldenOpacityPointCount = sizeof(kBKGoldenOpacityPoints) / sizeof(kBKGoldenOpacityPoints[0]);

// Field order: name, mode, projection, position, direction, up, viewWidth, viewHeight,
// fieldOfView, sampleSpacing, slabEnabled, slabPoint, slabNormal, slabThickness,
// windowCenter, windowWidth, shading, opacityUnitDistance, useTransferFunction,
// width, height, skipEmptySpace, clipPlaneCount, clipPlanes.
const BKGoldenVolumeCase kBKGoldenVolumeCases[] = {
    // 3D (composite), from the front, orthographic, lit, empty-space skipping on.
    {"vr_ortho_anterior", 0, 0, {0, 0, 0}, {0, 1, 0}, {0, 0, 1}, 70, 70, 30, 0.5,
     0, {0, 0, 0}, {0, 0, 1}, 0, 40, 400, 1, 1.0f, 1, 96, 96, 1, 0, {{0}}},
    // 3D, perspective from front-left-above, non-square image.
    {"vr_persp_oblique", 0, 1, {-110, -150, 60}, {110, 150, -60}, {0, 0, 1}, 0, 0, 30, 0.5,
     0, {0, 0, 0}, {0, 0, 1}, 0, 40, 400, 1, 1.0f, 1, 96, 80, 1, 0, {{0}}},
    // 3D from the patient's left, no lighting, top half cut away by a clip plane, no skipping.
    {"vr_ortho_left_clipped_unlit", 0, 0, {0, 0, 0}, {-1, 0, 0}, {0, 0, 1}, 70, 70, 30, 0.5,
     0, {0, 0, 0}, {0, 0, 1}, 0, 40, 400, 0, 1.0f, 1, 96, 96, 0, 1, {{0, 0, 2, 0, 0.2, 1}, {0}}},
    // Axial MIP slab, 10 mm thick through the jaw tube.
    {"mip_axial_slab10", 1, 0, {0, 0, -6}, {0, 0, 1}, {0, -1, 0}, 66, 66, 30, 0.5,
     1, {0, 0, -6}, {0, 0, 1}, 10, 400, 2000, 0, 1.0f, 0, 96, 96, 1, 0, {{0}}},
    // Axial MinIP slab (air and fat darkest).
    {"minip_axial_slab10", 2, 0, {0, 0, 4}, {0, 0, 1}, {0, -1, 0}, 66, 66, 30, 0.5,
     1, {0, 0, 4}, {0, 0, 1}, 10, -500, 1500, 0, 1.0f, 0, 96, 96, 1, 0, {{0}}},
    // Coronal average ("thick radiograph") slab, 20 mm.
    {"avg_coronal_slab20", 3, 0, {0, 0, 0}, {0, 1, 0}, {0, 0, 1}, 66, 66, 30, 0.5,
     1, {0, 0, 0}, {0, 1, 0}, 20, 40, 400, 0, 1.0f, 0, 96, 96, 1, 0, {{0}}},
    // Thin (single-plane) oblique MPR slice.
    {"mpr_thin_oblique", 1, 0, {1, -2, -5}, {0.3, 0.2, 0.93}, {0, 1, 0}, 66, 66, 30, 0.5,
     1, {1, -2, -5}, {0.3, 0.2, 0.93}, 0, 300, 1800, 0, 1.0f, 0, 96, 96, 1, 0, {{0}}},
    // Full-depth MIP in perspective (empty-space skipping in MIP mode).
    {"mip_persp_full", 1, 1, {120, -130, 40}, {-120, 130, -40}, {0, 0, 1}, 0, 0, 28, 0.5,
     0, {0, 0, 0}, {0, 0, 1}, 0, 1000, 3000, 0, 1.0f, 0, 80, 96, 1, 0, {{0}}},
};
const uint32_t kBKGoldenVolumeCaseCount = sizeof(kBKGoldenVolumeCases) / sizeof(kBKGoldenVolumeCases[0]);

// Field order: name, slice, outWidth, outHeight, windowCenter, windowWidth, linear, invert,
// useColorTable, zoom, panX, panY, rotation, flipH, flipV, background.
const BKGoldenImageCase kBKGoldenImageCases[] = {
    {"slice_nearest_fit", 18, 96, 96, 40, 400, 0, 0, 0, 1.5, 0, 0, 0, 0, 0, {0, 0, 0, 1}},
    {"slice_linear_lut_rotated", 18, 96, 80, 300, 1800, 1, 0, 1, 1.9, 5, -3, 20, 1, 0, {0.1f, 0.2f, 0.3f, 1}},
    {"slice_linear_inverted_flipped", 30, 80, 96, -200, 1200, 1, 1, 0, 1.3, -4, 6, -35, 0, 1, {0, 0, 0, 1}},
};
const uint32_t kBKGoldenImageCaseCount = sizeof(kBKGoldenImageCases) / sizeof(kBKGoldenImageCases[0]);

void bk_golden_color_table(uint8_t rgb[768])
{
    // Black -> blue -> red -> yellow -> white, in four linear ramps of 64 entries.
    for (int i = 0; i < 256; i++) {
        int seg = i / 64, f = (i % 64) * 4;   // f: 0...252 within a ramp
        int r = 0, g = 0, b = 0;
        switch (seg) {
            case 0: r = 0; g = 0; b = f; break;
            case 1: r = f; g = 0; b = 255 - f; break;
            case 2: r = 255; g = f; b = 0; break;
            default: r = 255; g = 255; b = f; break;
        }
        rgb[3 * i] = (uint8_t)r;
        rgb[3 * i + 1] = (uint8_t)g;
        rgb[3 * i + 2] = (uint8_t)b;
    }
}

// Hardware-filtered sampling at resolution < 1 is left out on purpose: GPUs from
// different makers round the filter weights differently, so the triangle lists could
// legitimately differ. The manual path gives the same numbers everywhere.
const BKGoldenSurfaceCase kBKGoldenSurfaceCases[] = {
    {"surface_bone_300", 300.0f, 1.0f, 0.0f, 0},
    {"surface_skin_m500", -500.0f, 1.0f, 0.0f, 0},
    {"surface_bone_res05_smooth1_manual", 300.0f, 0.5f, 1.0f, 1},
};
const uint32_t kBKGoldenSurfaceCaseCount = sizeof(kBKGoldenSurfaceCases) / sizeof(kBKGoldenSurfaceCases[0]);

const BKGoldenMeshRenderCase kBKGoldenMeshRenderCases[] = {
    {"meshrender_bone_ortho", 0, {0, 0, 0}, {0, 1, 0}, {0, 0, 1}, 70, 70, 30, 96, 96, {0.95f, 0.90f, 0.80f}, 1.0f},
    {"meshrender_bone_persp_seethrough", 1, {-110, -150, 60}, {110, 150, -60}, {0, 0, 1}, 0, 0, 30, 96, 80,
     {0.90f, 0.85f, 0.70f}, 0.6f},
};
const uint32_t kBKGoldenMeshRenderCaseCount = sizeof(kBKGoldenMeshRenderCases) / sizeof(kBKGoldenMeshRenderCases[0]);
