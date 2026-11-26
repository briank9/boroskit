// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSegmentation: BKSegmentationCore - the label map, its .boroseg file and its measurements.
// See BKSegmentationCore.h (what / why / PORTING NOTES). Written 2026-11-26 by agent "segmentation".
//
// Layout of this file: small helpers (numbers, checksum, varints) -> geometry -> volume + classes -> JSON writer
// -> JSON reader -> encode / decode -> files -> measurements -> slices / planes -> overlay picture -> masks.
// Everything is single-threaded and uses double for geometry, so the results are the same on every run / machine.

#include "BKSegmentationCore.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <clocale>
#include <new>
#include <string>
#include <vector>

// ======================================================================================================================
// Small helpers
// ======================================================================================================================

namespace {

// The file's first 8 bytes.
const uint8_t kMagic[8] = { 'B', 'O', 'R', 'O', 'S', 'E', 'G', 0 };
// A header larger than this is refused (a real header is a few kB; protects against damaged length fields).
const uint32_t kMaxHeaderBytes = 64u * 1024u * 1024u;
const char *kEncodingName = "rle-u16le-leb128";

// What: FNV-1a 64-bit checksum (the public, very simple Fowler-Noll-Vo hash: xor a byte, multiply by a prime).
// Why: a damaged label file must be refused instead of shown half-right; FNV-1a is enough to catch damage
// (it is not a security feature) and is trivial to write identically on every platform.
uint64_t Fnv1a64(const uint8_t *bytes, size_t size)
{
    uint64_t h = 14695981039346656037ull;
    for (size_t i = 0; i < size; i++) {
        h ^= bytes[i];
        h *= 1099511628211ull;
    }
    return h;
}

// What: copy a C string into a fixed buffer, always zero-terminated, cut at a whole UTF-8 character.
void CopyText(char *dst, size_t dstSize, const char *src, size_t srcLen)
{
    if (dstSize == 0) return;
    size_t n = srcLen < dstSize - 1 ? srcLen : dstSize - 1;
    // Do not cut a multi-byte UTF-8 character in half: step back over continuation bytes (10xxxxxx).
    if (n < srcLen) while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80) n--;
    memcpy(dst, src, n);
    dst[n] = 0;
}

// What: a double as the shortest text that reads back as exactly the same double (15, 16 or 17 significant
// digits), with '.' as decimal point whatever the C locale says. -0 and non-finite values become 0.
std::string FormatDouble(double value);
bool ParseNumberText(const char *text, size_t length, double *out);

std::string FormatDouble(double value)
{
    if (!std::isfinite(value) || value == 0.0) value = 0.0;
    char buffer[40];
    for (int digits = 15; digits <= 17; digits++) {
        snprintf(buffer, sizeof buffer, "%.*g", digits, value);
        for (char *p = buffer; *p; p++) if (*p == ',') *p = '.';   // locale-proof: always '.'
        double back = 0;
        if (digits == 17 || (ParseNumberText(buffer, strlen(buffer), &back) && back == value)) break;
    }
    return std::string(buffer);
}

// What: reads a JSON number text ([-]digits[.digits][e[+-]digits]) exactly as strtod would in the "C" locale.
// How: strtod uses the current locale's decimal point, so '.' is swapped for it first (portable, no _l variants).
bool ParseNumberText(const char *text, size_t length, double *out)
{
    if (length == 0 || length > 64) return false;
    char buffer[72];
    const char *point = localeconv()->decimal_point;
    char dp = (point && point[0]) ? point[0] : '.';
    for (size_t i = 0; i < length; i++) buffer[i] = text[i] == '.' ? dp : text[i];
    buffer[length] = 0;
    char *end = nullptr;
    double v = strtod(buffer, &end);
    if (end != buffer + length || !std::isfinite(v)) return false;
    *out = v;
    return true;
}

void PutVarint(std::vector<uint8_t> &out, uint64_t v)
{
    while (v >= 0x80) {
        out.push_back((uint8_t)(v | 0x80));
        v >>= 7;
    }
    out.push_back((uint8_t)v);
}

// Returns false on a varint longer than 10 bytes or running past the end.
bool GetVarint(const uint8_t *&p, const uint8_t *end, uint64_t *v)
{
    uint64_t r = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        if (p >= end) return false;
        uint8_t b = *p++;
        r |= (uint64_t)(b & 0x7F) << shift;
        if ((b & 0x80) == 0) { *v = r; return true; }
    }
    return false;
}

void PutU32LE(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

uint32_t GetU32LE(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

void SetMessage(char *message, size_t size, const char *text)
{
    if (message && size) CopyText(message, size, text, strlen(text));
}

} // namespace

const char *BKSegStatusMessage(BKSegStatus status)
{
    switch (status) {
        case BKSegStatusOK: return "OK";
        case BKSegStatusInvalidInput: return "Invalid input.";
        case BKSegStatusOutOfMemory: return "Not enough memory.";
        case BKSegStatusIOError: return "The file could not be read or written.";
        case BKSegStatusBadFormat: return "This is not a readable segmentation file.";
        case BKSegStatusUnsupportedVersion: return "This segmentation was saved by a newer Boros.";
        case BKSegStatusChecksumMismatch: return "The segmentation file is damaged (checksum).";
        case BKSegStatusNoLabels: return "The segmentation was read without its label data.";
    }
    return "Unknown problem.";
}

// ======================================================================================================================
// Geometry
// ======================================================================================================================

namespace {

// The three voxel edge vectors as matrix columns: E = [sx*a | sy*b | sz*c] (row r, column c at e[3*c + r]).
void EdgeMatrix(const BKLabelGrid *g, double e[9])
{
    for (int c = 0; c < 3; c++)
        for (int r = 0; r < 3; r++) e[3 * c + r] = g->spacing[c] * g->axes[3 * c + r];
}

double Det3(const double e[9])
{
    // Columns u = e[0..2], v = e[3..5], w = e[6..8]: det = u . (v x w), explicit fma.
    double cx = std::fma(e[4], e[8], -e[5] * e[7]);
    double cy = std::fma(e[5], e[6], -e[3] * e[8]);
    double cz = std::fma(e[3], e[7], -e[4] * e[6]);
    return std::fma(e[0], cx, std::fma(e[1], cy, e[2] * cz));
}

// Inverse of the 3x3 column matrix e (same layout); false if (nearly) singular.
bool Invert3(const double e[9], double inv[9])
{
    double det = Det3(e);
    if (!(std::fabs(det) > 1e-300) || !std::isfinite(det)) return false;
    // inv = adj(e) / det, adj = transpose of cofactors; e(r, c) = e[3*c + r].
#define E(r, c) e[3 * (c) + (r)]
#define I(r, c) inv[3 * (c) + (r)]
    I(0, 0) = std::fma(E(1, 1), E(2, 2), -E(1, 2) * E(2, 1)) / det;
    I(0, 1) = std::fma(E(0, 2), E(2, 1), -E(0, 1) * E(2, 2)) / det;
    I(0, 2) = std::fma(E(0, 1), E(1, 2), -E(0, 2) * E(1, 1)) / det;
    I(1, 0) = std::fma(E(1, 2), E(2, 0), -E(1, 0) * E(2, 2)) / det;
    I(1, 1) = std::fma(E(0, 0), E(2, 2), -E(0, 2) * E(2, 0)) / det;
    I(1, 2) = std::fma(E(0, 2), E(1, 0), -E(0, 0) * E(1, 2)) / det;
    I(2, 0) = std::fma(E(1, 0), E(2, 1), -E(1, 1) * E(2, 0)) / det;
    I(2, 1) = std::fma(E(0, 1), E(2, 0), -E(0, 0) * E(2, 1)) / det;
    I(2, 2) = std::fma(E(0, 0), E(1, 1), -E(0, 1) * E(1, 0)) / det;
#undef E
#undef I
    return true;
}

// out = m * v for a 3x3 column matrix.
void Apply3(const double m[9], const double v[3], double out[3])
{
    for (int r = 0; r < 3; r++) out[r] = std::fma(m[r], v[0], std::fma(m[3 + r], v[1], m[6 + r] * v[2]));
}

} // namespace

int BKLabelGridIsValid(const BKLabelGrid *g)
{
    if (!g) return 0;
    for (int a = 0; a < 3; a++) {
        if (g->dims[a] < 1) return 0;
        if (!(g->spacing[a] > 0) || !std::isfinite(g->spacing[a])) return 0;
        if (!std::isfinite(g->origin[a])) return 0;
    }
    for (int i = 0; i < 9; i++) if (!std::isfinite(g->axes[i])) return 0;
    double e[9], inv[9];
    EdgeMatrix(g, e);
    if (!Invert3(e, inv)) return 0;
    // 2^31 voxels per side would overflow int64 index maths nowhere, but the total must fit in memory sizes.
    uint64_t n = (uint64_t)g->dims[0] * g->dims[1] * g->dims[2];
    if (n == 0 || n > (1ull << 40)) return 0;
    return 1;
}

void BKLabelGridVoxelToPatient(const BKLabelGrid *g, double i, double j, double k, double out[3])
{
    double e[9];
    EdgeMatrix(g, e);
    for (int r = 0; r < 3; r++) out[r] = std::fma(e[r], i, std::fma(e[3 + r], j, std::fma(e[6 + r], k, g->origin[r])));
}

int BKLabelGridPatientToVoxel(const BKLabelGrid *g, const double p[3], double outIJK[3])
{
    double e[9], inv[9];
    EdgeMatrix(g, e);
    if (!Invert3(e, inv)) return 0;
    double d[3] = { p[0] - g->origin[0], p[1] - g->origin[1], p[2] - g->origin[2] };
    Apply3(inv, d, outIJK);
    return 1;
}

void BKLabelGridVoxelToPatientMatrix(const BKLabelGrid *g, double m[16])
{
    double e[9];
    EdgeMatrix(g, e);
    for (int c = 0; c < 3; c++) {
        for (int r = 0; r < 3; r++) m[4 * c + r] = e[3 * c + r];
        m[4 * c + 3] = 0;
    }
    for (int r = 0; r < 3; r++) m[12 + r] = g->origin[r];
    m[15] = 1;
}

int BKLabelGridPatientToVoxelMatrix(const BKLabelGrid *g, double m[16])
{
    double e[9], inv[9];
    EdgeMatrix(g, e);
    if (!Invert3(e, inv)) return 0;
    double t[3];
    Apply3(inv, g->origin, t);
    for (int c = 0; c < 3; c++) {
        for (int r = 0; r < 3; r++) m[4 * c + r] = inv[3 * c + r];
        m[4 * c + 3] = 0;
    }
    for (int r = 0; r < 3; r++) m[12 + r] = -t[r];
    m[15] = 1;
    return 1;
}

double BKLabelGridVoxelVolume(const BKLabelGrid *g)
{
    double e[9];
    EdgeMatrix(g, e);
    return std::fabs(Det3(e));
}

double BKLabelGridVolumeOfCount(const BKLabelGrid *g, uint64_t count)
{
    // count is exact up to 2^53 as a double (far beyond any scan); one rounding in the multiply.
    return (double)count * BKLabelGridVoxelVolume(g);
}

// ======================================================================================================================
// Volume and classes
// ======================================================================================================================

struct BKLabelVolume {
    BKLabelGrid grid;
    uint16_t *voxels = nullptr;      // NULL = header-only
    uint64_t count = 0;
    std::vector<BKLabelClass> classes;
    BKLabelInfo info;
    std::string extraJSON;           // unknown top-level header members, as text ("\"key\":value" joined by ',')
};

namespace {

BKLabelVolume *NewVolume(const BKLabelGrid *grid, bool withVoxels)
{
    if (!BKLabelGridIsValid(grid)) return nullptr;
    BKLabelVolume *v = new (std::nothrow) BKLabelVolume();
    if (!v) return nullptr;
    v->grid = *grid;
    memset(&v->info, 0, sizeof v->info);
    v->count = (uint64_t)grid->dims[0] * grid->dims[1] * grid->dims[2];
    if (withVoxels) {
        if (v->count > SIZE_MAX / sizeof(uint16_t)) { delete v; return nullptr; }
        v->voxels = (uint16_t *)calloc((size_t)v->count, sizeof(uint16_t));
        if (!v->voxels) { delete v; return nullptr; }
    }
    return v;
}

} // namespace

BKLabelVolume *BKLabelVolumeCreate(const BKLabelGrid *grid) { return NewVolume(grid, true); }

void BKLabelVolumeFree(BKLabelVolume *volume)
{
    if (!volume) return;
    free(volume->voxels);
    delete volume;
}

const BKLabelGrid *BKLabelVolumeGetGrid(const BKLabelVolume *v) { return v ? &v->grid : nullptr; }
uint64_t BKLabelVolumeVoxelCount(const BKLabelVolume *v) { return v ? v->count : 0; }
uint16_t *BKLabelVolumeVoxels(BKLabelVolume *v) { return v ? v->voxels : nullptr; }
const uint16_t *BKLabelVolumeVoxelsConst(const BKLabelVolume *v) { return v ? v->voxels : nullptr; }
BKLabelInfo *BKLabelVolumeInfo(BKLabelVolume *v) { return v ? &v->info : nullptr; }
const BKLabelInfo *BKLabelVolumeInfoConst(const BKLabelVolume *v) { return v ? &v->info : nullptr; }

int32_t BKLabelVolumeSetClass(BKLabelVolume *v, const BKLabelClass *cls)
{
    if (!v || !cls || cls->value == 0) return -1;
    BKLabelClass c = *cls;
    c.name[BKLabelNameBytes - 1] = 0;
    c.category[BKLabelCategoryBytes - 1] = 0;
    if (!(c.opacity >= 0)) c.opacity = 0;      // also NaN -> 0
    if (c.opacity > 1) c.opacity = 1;
    c.visible = c.visible ? 1 : 0;
    for (size_t i = 0; i < v->classes.size(); i++)
        if (v->classes[i].value == c.value) { v->classes[i] = c; return (int32_t)i; }
    v->classes.push_back(c);
    return (int32_t)(v->classes.size() - 1);
}

uint32_t BKLabelVolumeClassCount(const BKLabelVolume *v) { return v ? (uint32_t)v->classes.size() : 0; }

BKLabelClass *BKLabelVolumeClassAt(BKLabelVolume *v, uint32_t index)
{
    return (v && index < v->classes.size()) ? &v->classes[index] : nullptr;
}

const BKLabelClass *BKLabelVolumeClassAtConst(const BKLabelVolume *v, uint32_t index)
{
    return (v && index < v->classes.size()) ? &v->classes[index] : nullptr;
}

BKLabelClass *BKLabelVolumeFindClass(BKLabelVolume *v, uint16_t value)
{
    if (!v) return nullptr;
    for (BKLabelClass &c : v->classes) if (c.value == value) return &c;
    return nullptr;
}

int BKLabelVolumeRemoveClass(BKLabelVolume *v, uint16_t value, int clearVoxels)
{
    if (!v) return 0;
    for (size_t i = 0; i < v->classes.size(); i++) {
        if (v->classes[i].value != value) continue;
        v->classes.erase(v->classes.begin() + (long)i);
        if (clearVoxels && v->voxels)
            for (uint64_t n = 0; n < v->count; n++) if (v->voxels[n] == value) v->voxels[n] = 0;
        return 1;
    }
    return 0;
}

BKSegStatus BKLabelVolumeSetLabels8(BKLabelVolume *v, const uint8_t *labels, uint64_t count)
{
    if (!v || !labels || count != v->count) return BKSegStatusInvalidInput;
    if (!v->voxels) return BKSegStatusNoLabels;
    for (uint64_t n = 0; n < count; n++) v->voxels[n] = labels[n];
    return BKSegStatusOK;
}

// ======================================================================================================================
// JSON writer (only what the header needs)
// ======================================================================================================================

namespace {

void JsonString(std::string &s, const char *text)
{
    s.push_back('"');
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        unsigned char c = *p;
        if (c == '"') s += "\\\"";
        else if (c == '\\') s += "\\\\";
        else if (c == '\n') s += "\\n";
        else if (c == '\r') s += "\\r";
        else if (c == '\t') s += "\\t";
        else if (c < 0x20) {
            char b[8];
            snprintf(b, sizeof b, "\\u%04x", c);
            s += b;
        } else s.push_back((char)c);   // UTF-8 bytes go through unchanged
    }
    s.push_back('"');
}

void JsonDoubles(std::string &s, const double *v, int n)
{
    s.push_back('[');
    for (int i = 0; i < n; i++) {
        if (i) s.push_back(',');
        s += FormatDouble(v[i]);
    }
    s.push_back(']');
}

std::string BuildHeader(const BKLabelVolume *v, uint64_t payloadBytes, uint64_t checksum)
{
    std::string s;
    s.reserve(4096 + v->classes.size() * 160);
    char b[64];
    s += "{\"format\":\"boroseg\",\"version\":";
    snprintf(b, sizeof b, "%d", (int)BKSegFormatVersion);
    s += b;
    s += ",\"name\":"; JsonString(s, v->info.name);
    s += ",\"source\":"; JsonString(s, v->info.source);
    s += ",\"created\":"; JsonString(s, v->info.created);
    s += ",\"seriesInstanceUID\":"; JsonString(s, v->info.seriesInstanceUID);
    s += ",\n\"grid\":{\"dims\":[";
    snprintf(b, sizeof b, "%u,%u,%u", v->grid.dims[0], v->grid.dims[1], v->grid.dims[2]);
    s += b;
    s += "],\"spacing\":"; JsonDoubles(s, v->grid.spacing, 3);
    s += ",\"origin\":"; JsonDoubles(s, v->grid.origin, 3);
    s += ",\"axes\":"; JsonDoubles(s, v->grid.axes, 9);
    s += "},\n\"classes\":[";
    for (size_t i = 0; i < v->classes.size(); i++) {
        const BKLabelClass &c = v->classes[i];
        s += i ? ",\n" : "\n";
        snprintf(b, sizeof b, "{\"value\":%u,\"name\":", (unsigned)c.value);
        s += b; JsonString(s, c.name);
        s += ",\"category\":"; JsonString(s, c.category);
        snprintf(b, sizeof b, ",\"color\":[%u,%u,%u],\"opacity\":", (unsigned)c.rgb[0], (unsigned)c.rgb[1], (unsigned)c.rgb[2]);
        s += b; s += FormatDouble(c.opacity);
        s += c.visible ? ",\"visible\":true}" : ",\"visible\":false}";
    }
    s += "],\n\"payload\":{\"encoding\":\"";
    s += kEncodingName;
    snprintf(b, sizeof b, "\",\"bytes\":%llu,\"voxels\":%llu,\"fnv1a64\":\"%016llx\"}",
             (unsigned long long)payloadBytes, (unsigned long long)v->count, (unsigned long long)checksum);
    s += b;
    if (!v->extraJSON.empty()) { s += ",\n"; s += v->extraJSON; }
    s += "}\n";
    return s;
}

} // namespace

// ======================================================================================================================
// JSON reader (a small recursive-descent parser: objects, arrays, strings, numbers, true / false / null)
// ======================================================================================================================

namespace {

struct JVal {
    enum Kind { Null, Bool, Number, String, Array, Object } kind = Null;
    bool b = false;
    double num = 0;
    std::string str;
    std::vector<JVal> items;                       // Array items, or Object values
    std::vector<std::string> keys;                 // Object keys (same order as items)
    size_t begin = 0, end = 0;                     // where the value's text is in the header (to keep unknown fields)

    const JVal *Get(const char *key) const
    {
        if (kind != Object) return nullptr;
        for (size_t i = 0; i < keys.size(); i++) if (keys[i] == key) return &items[i];
        return nullptr;
    }
};

struct JParser {
    const char *s;
    size_t n, i = 0;
    int depth = 0;
    bool ok = true;

    void Ws() { while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++; }
    bool Lit(const char *w)
    {
        size_t l = strlen(w);
        if (i + l > n || memcmp(s + i, w, l) != 0) return false;
        i += l;
        return true;
    }
    static void PutUtf8(std::string &o, uint32_t cp)
    {
        if (cp < 0x80) o.push_back((char)cp);
        else if (cp < 0x800) { o.push_back((char)(0xC0 | (cp >> 6))); o.push_back((char)(0x80 | (cp & 0x3F))); }
        else if (cp < 0x10000) {
            o.push_back((char)(0xE0 | (cp >> 12))); o.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            o.push_back((char)(0x80 | (cp & 0x3F)));
        } else {
            o.push_back((char)(0xF0 | (cp >> 18))); o.push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
            o.push_back((char)(0x80 | ((cp >> 6) & 0x3F))); o.push_back((char)(0x80 | (cp & 0x3F)));
        }
    }
    bool Hex4(uint32_t *out)
    {
        if (i + 4 > n) return false;
        uint32_t v = 0;
        for (int k = 0; k < 4; k++) {
            char c = s[i + k];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= (uint32_t)(c - '0');
            else if (c >= 'a' && c <= 'f') v |= (uint32_t)(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= (uint32_t)(c - 'A' + 10);
            else return false;
        }
        i += 4;
        *out = v;
        return true;
    }
    bool String(std::string &o)
    {
        if (i >= n || s[i] != '"') return false;
        i++;
        while (i < n) {
            unsigned char c = (unsigned char)s[i++];
            if (c == '"') return true;
            if (c < 0x20) return false;
            if (c != '\\') { o.push_back((char)c); continue; }
            if (i >= n) return false;
            char e = s[i++];
            switch (e) {
                case '"': o.push_back('"'); break;
                case '\\': o.push_back('\\'); break;
                case '/': o.push_back('/'); break;
                case 'b': o.push_back('\b'); break;
                case 'f': o.push_back('\f'); break;
                case 'n': o.push_back('\n'); break;
                case 'r': o.push_back('\r'); break;
                case 't': o.push_back('\t'); break;
                case 'u': {
                    uint32_t cp;
                    if (!Hex4(&cp)) return false;
                    if (cp >= 0xD800 && cp < 0xDC00) {            // surrogate pair
                        uint32_t lo;
                        if (i + 2 > n || s[i] != '\\' || s[i + 1] != 'u') return false;
                        i += 2;
                        if (!Hex4(&lo) || lo < 0xDC00 || lo >= 0xE000) return false;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    } else if (cp >= 0xDC00 && cp < 0xE000) return false;
                    PutUtf8(o, cp);
                    break;
                }
                default: return false;
            }
        }
        return false;
    }
    bool Number(double *out)
    {
        size_t start = i;
        if (i < n && s[i] == '-') i++;
        if (i >= n) return false;
        if (s[i] == '0') i++;
        else if (s[i] >= '1' && s[i] <= '9') while (i < n && s[i] >= '0' && s[i] <= '9') i++;
        else return false;
        if (i < n && s[i] == '.') {
            i++;
            if (i >= n || s[i] < '0' || s[i] > '9') return false;
            while (i < n && s[i] >= '0' && s[i] <= '9') i++;
        }
        if (i < n && (s[i] == 'e' || s[i] == 'E')) {
            i++;
            if (i < n && (s[i] == '+' || s[i] == '-')) i++;
            if (i >= n || s[i] < '0' || s[i] > '9') return false;
            while (i < n && s[i] >= '0' && s[i] <= '9') i++;
        }
        return ParseNumberText(s + start, i - start, out);
    }
    bool Value(JVal &v)
    {
        if (++depth > 64) return false;   // no runaway nesting from a damaged file
        Ws();
        v.begin = i;
        bool good = false;
        if (i >= n) good = false;
        else if (s[i] == '{') {
            v.kind = JVal::Object;
            i++;
            Ws();
            if (i < n && s[i] == '}') { i++; good = true; }
            else {
                while (true) {
                    Ws();
                    std::string key;
                    if (!String(key)) break;
                    Ws();
                    if (i >= n || s[i] != ':') break;
                    i++;
                    JVal item;
                    if (!Value(item)) break;
                    v.keys.push_back(key);
                    v.items.push_back(std::move(item));
                    Ws();
                    if (i < n && s[i] == ',') { i++; continue; }
                    if (i < n && s[i] == '}') { i++; good = true; }
                    break;
                }
            }
        } else if (s[i] == '[') {
            v.kind = JVal::Array;
            i++;
            Ws();
            if (i < n && s[i] == ']') { i++; good = true; }
            else {
                while (true) {
                    JVal item;
                    if (!Value(item)) break;
                    v.items.push_back(std::move(item));
                    Ws();
                    if (i < n && s[i] == ',') { i++; continue; }
                    if (i < n && s[i] == ']') { i++; good = true; }
                    break;
                }
            }
        } else if (s[i] == '"') { v.kind = JVal::String; good = String(v.str); }
        else if (Lit("true")) { v.kind = JVal::Bool; v.b = true; good = true; }
        else if (Lit("false")) { v.kind = JVal::Bool; v.b = false; good = true; }
        else if (Lit("null")) { v.kind = JVal::Null; good = true; }
        else { v.kind = JVal::Number; good = Number(&v.num); }
        v.end = i;
        depth--;
        return good;
    }
};

bool JNumber(const JVal *v, double *out)
{
    if (!v || v->kind != JVal::Number) return false;
    *out = v->num;
    return true;
}

// A whole number in [lo, hi].
bool JInteger(const JVal *v, double lo, double hi, uint64_t *out)
{
    double d;
    if (!JNumber(v, &d) || d != std::floor(d) || d < lo || d > hi) return false;
    *out = (uint64_t)d;
    return true;
}

bool JDoubles(const JVal *v, double *out, size_t count)
{
    if (!v || v->kind != JVal::Array || v->items.size() != count) return false;
    for (size_t k = 0; k < count; k++) if (!JNumber(&v->items[k], &out[k])) return false;
    return true;
}

void JText(const JVal *v, char *dst, size_t size)
{
    if (v && v->kind == JVal::String) CopyText(dst, size, v->str.c_str(), v->str.size());
    else if (size) dst[0] = 0;
}

bool IsKnownTopKey(const std::string &k)
{
    static const char *known[] = { "format", "version", "name", "source", "created", "seriesInstanceUID",
                                   "grid", "classes", "payload" };
    for (const char *q : known) if (k == q) return true;
    return false;
}

} // namespace

// ======================================================================================================================
// Encode / decode
// ======================================================================================================================

namespace {

// The run-length payload: (value uint16 LE, run length LEB128 >= 1) ... covering every voxel in order.
bool EncodePayload(const BKLabelVolume *v, std::vector<uint8_t> &out)
{
    try {
        out.clear();
        out.reserve(1 << 20);
        uint64_t n = v->count;
        uint64_t i = 0;
        while (i < n) {
            uint16_t value = v->voxels[i];
            uint64_t j = i + 1;
            while (j < n && v->voxels[j] == value) j++;
            out.push_back((uint8_t)(value & 0xFF));
            out.push_back((uint8_t)(value >> 8));
            PutVarint(out, j - i);
            i = j;
        }
        return true;
    } catch (...) {
        return false;
    }
}

BKSegStatus ParseHeader(const char *text, size_t length, bool headerOnly, BKLabelVolume **out, uint64_t *payloadBytes,
                        uint64_t *checksum, char *message, size_t messageSize)
{
    JParser p{ text, length };
    JVal root;
    if (!p.Value(root) || root.kind != JVal::Object) {
        SetMessage(message, messageSize, "header is not a JSON object");
        return BKSegStatusBadFormat;
    }
    const JVal *format = root.Get("format");
    if (!format || format->kind != JVal::String || format->str != "boroseg") {
        SetMessage(message, messageSize, "header has no \"format\": \"boroseg\"");
        return BKSegStatusBadFormat;
    }
    uint64_t version = 0;
    if (!JInteger(root.Get("version"), 1, 1e9, &version)) {
        SetMessage(message, messageSize, "header has no valid version");
        return BKSegStatusBadFormat;
    }
    if (version > (uint64_t)BKSegFormatVersion) {
        SetMessage(message, messageSize, "file version is newer than this Boros");
        return BKSegStatusUnsupportedVersion;
    }
    // Grid.
    const JVal *grid = root.Get("grid");
    BKLabelGrid g;
    memset(&g, 0, sizeof g);
    double dims[3];
    if (!grid || !JDoubles(grid->Get("dims"), dims, 3) || !JDoubles(grid->Get("spacing"), g.spacing, 3) ||
        !JDoubles(grid->Get("origin"), g.origin, 3) || !JDoubles(grid->Get("axes"), g.axes, 9)) {
        SetMessage(message, messageSize, "grid is missing or incomplete");
        return BKSegStatusBadFormat;
    }
    for (int a = 0; a < 3; a++) {
        if (dims[a] != std::floor(dims[a]) || dims[a] < 1 || dims[a] > 4294967295.0) {
            SetMessage(message, messageSize, "grid dims are not whole numbers");
            return BKSegStatusBadFormat;
        }
        g.dims[a] = (uint32_t)dims[a];
    }
    if (!BKLabelGridIsValid(&g)) {
        SetMessage(message, messageSize, "grid is not valid");
        return BKSegStatusBadFormat;
    }
    // Payload description.
    const JVal *payload = root.Get("payload");
    const JVal *encoding = payload ? payload->Get("encoding") : nullptr;
    uint64_t voxels = 0;
    const JVal *sum = payload ? payload->Get("fnv1a64") : nullptr;
    if (!payload || !encoding || encoding->kind != JVal::String || encoding->str != kEncodingName ||
        !JInteger(payload->Get("bytes"), 0, 9007199254740992.0, payloadBytes) ||
        !JInteger(payload->Get("voxels"), 1, 9007199254740992.0, &voxels) ||
        !sum || sum->kind != JVal::String || sum->str.size() != 16) {
        SetMessage(message, messageSize, "payload description is missing or uses an unknown encoding");
        return BKSegStatusBadFormat;
    }
    if (voxels != (uint64_t)g.dims[0] * g.dims[1] * g.dims[2]) {
        SetMessage(message, messageSize, "payload voxel count does not match the grid");
        return BKSegStatusBadFormat;
    }
    char *endp = nullptr;
    *checksum = strtoull(sum->str.c_str(), &endp, 16);
    if (endp != sum->str.c_str() + 16) {
        SetMessage(message, messageSize, "payload checksum is not hexadecimal");
        return BKSegStatusBadFormat;
    }
    BKLabelVolume *v = NewVolume(&g, !headerOnly);
    if (!v) {
        SetMessage(message, messageSize, "not enough memory for the labels");
        return BKSegStatusOutOfMemory;
    }
    JText(root.Get("name"), v->info.name, sizeof v->info.name);
    JText(root.Get("source"), v->info.source, sizeof v->info.source);
    JText(root.Get("created"), v->info.created, sizeof v->info.created);
    JText(root.Get("seriesInstanceUID"), v->info.seriesInstanceUID, sizeof v->info.seriesInstanceUID);
    // Classes (an entry without a valid value is a format error: it could not be shown or measured).
    const JVal *classes = root.Get("classes");
    if (classes && classes->kind != JVal::Array) classes = nullptr;
    if (classes) {
        for (const JVal &c : classes->items) {
            BKLabelClass cls;
            memset(&cls, 0, sizeof cls);
            uint64_t value = 0;
            if (!JInteger(c.Get("value"), 1, 65535, &value)) {
                BKLabelVolumeFree(v);
                SetMessage(message, messageSize, "a class has no valid value (1..65535)");
                return BKSegStatusBadFormat;
            }
            cls.value = (uint16_t)value;
            JText(c.Get("name"), cls.name, sizeof cls.name);
            JText(c.Get("category"), cls.category, sizeof cls.category);
            double rgb[3] = { 255, 200, 0 };
            if (JDoubles(c.Get("color"), rgb, 3))
                for (int k = 0; k < 3; k++) cls.rgb[k] = (uint8_t)(rgb[k] < 0 ? 0 : (rgb[k] > 255 ? 255 : std::floor(rgb[k] + 0.5)));
            else { cls.rgb[0] = 255; cls.rgb[1] = 200; cls.rgb[2] = 0; }
            double opacity = 1;
            JNumber(c.Get("opacity"), &opacity);
            cls.opacity = opacity;
            const JVal *vis = c.Get("visible");
            cls.visible = (vis && vis->kind == JVal::Bool) ? (vis->b ? 1 : 0) : 1;
            BKLabelVolumeSetClass(v, &cls);
        }
    }
    // Unknown top-level members are kept as they were written (framework rule: unknown fields survive a save).
    for (size_t k = 0; k < root.keys.size(); k++) {
        if (IsKnownTopKey(root.keys[k])) continue;
        if (!v->extraJSON.empty()) v->extraJSON += ",\n";
        JsonString(v->extraJSON, root.keys[k].c_str());
        v->extraJSON.push_back(':');
        v->extraJSON.append(text + root.items[k].begin, root.items[k].end - root.items[k].begin);
    }
    *out = v;
    return BKSegStatusOK;
}

} // namespace

BKSegStatus BKLabelVolumeEncode(const BKLabelVolume *v, uint8_t **bytes, size_t *size)
{
    if (!v || !bytes || !size) return BKSegStatusInvalidInput;
    if (!v->voxels) return BKSegStatusNoLabels;
    std::vector<uint8_t> payload;
    if (!EncodePayload(v, payload)) return BKSegStatusOutOfMemory;
    std::string header;
    try { header = BuildHeader(v, payload.size(), Fnv1a64(payload.data(), payload.size())); }
    catch (...) { return BKSegStatusOutOfMemory; }
    if (header.size() > kMaxHeaderBytes) return BKSegStatusInvalidInput;
    size_t total = 12 + header.size() + payload.size();
    uint8_t *b = (uint8_t *)malloc(total);
    if (!b) return BKSegStatusOutOfMemory;
    memcpy(b, kMagic, 8);
    PutU32LE(b + 8, (uint32_t)header.size());
    memcpy(b + 12, header.data(), header.size());
    if (!payload.empty()) memcpy(b + 12 + header.size(), payload.data(), payload.size());
    *bytes = b;
    *size = total;
    return BKSegStatusOK;
}

BKSegStatus BKLabelVolumeDecode(const uint8_t *bytes, size_t size, int headerOnly, BKLabelVolume **out,
                                char *message, size_t messageSize)
{
    if (out) *out = nullptr;
    if (!bytes || !out) return BKSegStatusInvalidInput;
    if (size < 12 || memcmp(bytes, kMagic, 8) != 0) {
        SetMessage(message, messageSize, "not a .boroseg file (no BOROSEG mark)");
        return BKSegStatusBadFormat;
    }
    uint32_t headerBytes = GetU32LE(bytes + 8);
    if (headerBytes == 0 || headerBytes > kMaxHeaderBytes || headerBytes > size - 12) {
        SetMessage(message, messageSize, "header length is damaged or the file is cut short");
        return BKSegStatusBadFormat;
    }
    uint64_t payloadBytes = 0, checksum = 0;
    BKLabelVolume *v = nullptr;
    BKSegStatus st = ParseHeader((const char *)bytes + 12, headerBytes, headerOnly != 0, &v, &payloadBytes, &checksum,
                                 message, messageSize);
    if (st != BKSegStatusOK) return st;
    if (headerOnly) { *out = v; return BKSegStatusOK; }

    const uint8_t *p = bytes + 12 + headerBytes;
    if ((uint64_t)(size - 12 - headerBytes) != payloadBytes) {
        BKLabelVolumeFree(v);
        SetMessage(message, messageSize, "label data has the wrong length (file cut short or padded)");
        return BKSegStatusBadFormat;
    }
    if (Fnv1a64(p, (size_t)payloadBytes) != checksum) {
        BKLabelVolumeFree(v);
        SetMessage(message, messageSize, "label data checksum does not match");
        return BKSegStatusChecksumMismatch;
    }
    const uint8_t *end = p + payloadBytes;
    uint64_t at = 0;
    while (p < end) {
        if (end - p < 3) break;                    // a run needs at least 2 value bytes + 1 length byte
        uint16_t value = (uint16_t)(p[0] | (p[1] << 8));
        p += 2;
        uint64_t run = 0;
        if (!GetVarint(p, end, &run) || run == 0 || run > v->count - at) { at = UINT64_MAX; break; }
        for (uint64_t k = 0; k < run; k++) v->voxels[at + k] = value;
        at += run;
    }
    if (p != end || at != v->count) {
        BKLabelVolumeFree(v);
        SetMessage(message, messageSize, "label runs do not add up to the grid");
        return BKSegStatusBadFormat;
    }
    *out = v;
    return BKSegStatusOK;
}

void BKSegFree(void *pointer) { free(pointer); }

// ======================================================================================================================
// Files
// ======================================================================================================================

namespace {

// PORTING NOTE (Windows): fopen takes the ANSI code page there; open with _wfopen after a UTF-8 -> UTF-16 conversion.
FILE *BKSegOpenFile(const char *path, const char *mode) { return fopen(path, mode); }

} // namespace

BKSegStatus BKLabelVolumeSave(const BKLabelVolume *v, const char *path)
{
    if (!v || !path) return BKSegStatusInvalidInput;
    uint8_t *bytes = nullptr;
    size_t size = 0;
    BKSegStatus st = BKLabelVolumeEncode(v, &bytes, &size);
    if (st != BKSegStatusOK) return st;
    std::string tmp = std::string(path) + ".tmp";
    FILE *f = BKSegOpenFile(tmp.c_str(), "wb");
    if (!f) { free(bytes); return BKSegStatusIOError; }
    bool good = fwrite(bytes, 1, size, f) == size;
    good = (fflush(f) == 0) && good;
    good = (fclose(f) == 0) && good;
    free(bytes);
    if (!good) { remove(tmp.c_str()); return BKSegStatusIOError; }
    // rename() replaces the old file in one step on Mac / Linux. PORTING NOTE (Windows): use MoveFileEx with
    // MOVEFILE_REPLACE_EXISTING (rename fails there when the target exists).
    if (rename(tmp.c_str(), path) != 0) { remove(tmp.c_str()); return BKSegStatusIOError; }
    return BKSegStatusOK;
}

namespace {

BKSegStatus ReadFile(const char *path, bool headerOnly, BKLabelVolume **out, char *message, size_t messageSize)
{
    if (out) *out = nullptr;
    if (!path || !out) return BKSegStatusInvalidInput;
    FILE *f = BKSegOpenFile(path, "rb");
    if (!f) { SetMessage(message, messageSize, "file could not be opened"); return BKSegStatusIOError; }
    uint8_t first[12];
    if (fread(first, 1, 12, f) != 12) {
        fclose(f);
        SetMessage(message, messageSize, "file is too short");
        return BKSegStatusBadFormat;
    }
    if (memcmp(first, kMagic, 8) != 0) {
        fclose(f);
        SetMessage(message, messageSize, "not a .boroseg file (no BOROSEG mark)");
        return BKSegStatusBadFormat;
    }
    size_t want = 0;
    if (headerOnly) {
        uint32_t h = GetU32LE(first + 8);
        if (h == 0 || h > kMaxHeaderBytes) {
            fclose(f);
            SetMessage(message, messageSize, "header length is damaged");
            return BKSegStatusBadFormat;
        }
        want = 12 + (size_t)h;
    } else {
        if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return BKSegStatusIOError; }
        long end = ftell(f);
        if (end < 12) { fclose(f); return BKSegStatusBadFormat; }
        want = (size_t)end;
    }
    uint8_t *bytes = (uint8_t *)malloc(want);
    if (!bytes) { fclose(f); return BKSegStatusOutOfMemory; }
    memcpy(bytes, first, 12);
    bool good = fseek(f, 12, SEEK_SET) == 0 && fread(bytes + 12, 1, want - 12, f) == want - 12;
    fclose(f);
    if (!good) {
        free(bytes);
        SetMessage(message, messageSize, "file is cut short");
        return BKSegStatusBadFormat;
    }
    BKSegStatus st = BKLabelVolumeDecode(bytes, want, headerOnly ? 1 : 0, out, message, messageSize);
    free(bytes);
    return st;
}

} // namespace

BKSegStatus BKLabelVolumeLoad(const char *path, BKLabelVolume **out, char *message, size_t messageSize)
{
    return ReadFile(path, false, out, message, messageSize);
}

BKSegStatus BKLabelVolumeReadHeader(const char *path, BKLabelVolume **out, char *message, size_t messageSize)
{
    return ReadFile(path, true, out, message, messageSize);
}

// ======================================================================================================================
// Measurements
// ======================================================================================================================

BKSegStatus BKLabelVolumeCount(const BKLabelVolume *v, uint64_t *counts)
{
    if (!v || !counts) return BKSegStatusInvalidInput;
    if (!v->voxels) return BKSegStatusNoLabels;
    memset(counts, 0, 65536 * sizeof(uint64_t));
    for (uint64_t n = 0; n < v->count; n++) counts[v->voxels[n]]++;
    return BKSegStatusOK;
}

int BKLabelVolumeClassBounds(const BKLabelVolume *v, uint16_t value, uint32_t minIJK[3], uint32_t maxIJK[3])
{
    if (!v || !v->voxels || !minIJK || !maxIJK) return 0;
    const uint32_t w = v->grid.dims[0], h = v->grid.dims[1], d = v->grid.dims[2];
    uint32_t lo[3] = { UINT32_MAX, UINT32_MAX, UINT32_MAX }, hi[3] = { 0, 0, 0 };
    bool any = false;
    const uint16_t *p = v->voxels;
    for (uint32_t k = 0; k < d; k++)
        for (uint32_t j = 0; j < h; j++) {
            const uint16_t *row = p + ((uint64_t)k * h + j) * w;
            uint32_t first = UINT32_MAX, last = 0;
            for (uint32_t i = 0; i < w; i++)
                if (row[i] == value) { if (first == UINT32_MAX) first = i; last = i; }
            if (first == UINT32_MAX) continue;
            any = true;
            if (first < lo[0]) lo[0] = first;
            if (last > hi[0]) hi[0] = last;
            if (j < lo[1]) lo[1] = j;
            if (j > hi[1]) hi[1] = j;
            if (k < lo[2]) lo[2] = k;
            if (k > hi[2]) hi[2] = k;
        }
    if (!any) return 0;
    for (int a = 0; a < 3; a++) { minIJK[a] = lo[a]; maxIJK[a] = hi[a]; }
    return 1;
}

// ======================================================================================================================
// Slices and planes
// ======================================================================================================================

int BKLabelVolumeExtractSlice(const BKLabelVolume *v, uint32_t k, uint16_t *out)
{
    if (!v || !v->voxels || !out || k >= v->grid.dims[2]) return 0;
    uint64_t plane = (uint64_t)v->grid.dims[0] * v->grid.dims[1];
    memcpy(out, v->voxels + plane * k, (size_t)plane * sizeof(uint16_t));
    return 1;
}

int BKLabelVolumeSamplePlane(const BKLabelVolume *v, const double origin[3], const double uStep[3],
                             const double vStep[3], uint32_t width, uint32_t height, uint16_t *out)
{
    if (!v || !v->voxels || !origin || !uStep || !vStep || !out || width == 0 || height == 0) return 0;
    double e[9], inv[9];
    EdgeMatrix(&v->grid, e);
    if (!Invert3(e, inv)) return 0;
    // In voxel coordinates: base = inv * (origin - gridOrigin); du = inv * uStep; dv = inv * vStep.
    double rel[3] = { origin[0] - v->grid.origin[0], origin[1] - v->grid.origin[1], origin[2] - v->grid.origin[2] };
    double base[3], du[3], dv[3];
    Apply3(inv, rel, base);
    Apply3(inv, uStep, du);
    Apply3(inv, vStep, dv);
    const int64_t w = v->grid.dims[0], h = v->grid.dims[1], d = v->grid.dims[2];
    for (uint32_t y = 0; y < height; y++) {
        double ry[3];
        for (int a = 0; a < 3; a++) ry[a] = std::fma((double)y, dv[a], base[a]);
        uint16_t *row = out + (uint64_t)y * width;
        for (uint32_t x = 0; x < width; x++) {
            double fx = std::fma((double)x, du[0], ry[0]);
            double fy = std::fma((double)x, du[1], ry[1]);
            double fz = std::fma((double)x, du[2], ry[2]);
            // Nearest voxel: floor(c + 0.5); outside the grid = background.
            double ix = std::floor(fx + 0.5), iy = std::floor(fy + 0.5), iz = std::floor(fz + 0.5);
            if (ix < 0 || iy < 0 || iz < 0 || ix >= (double)w || iy >= (double)h || iz >= (double)d) { row[x] = 0; continue; }
            row[x] = v->voxels[((uint64_t)iz * (uint64_t)h + (uint64_t)iy) * (uint64_t)w + (uint64_t)ix];
        }
    }
    return 1;
}

int BKLabelVolumePlaneIsGridSlice(const BKLabelVolume *v, const double origin[3], const double uStep[3],
                                  const double vStep[3], double toleranceMM, uint32_t *k, int64_t *i0, int64_t *j0)
{
    if (!v || !origin || !uStep || !vStep || !k || !i0 || !j0) return 0;
    double e[9], inv[9];
    EdgeMatrix(&v->grid, e);
    if (!Invert3(e, inv)) return 0;
    double rel[3] = { origin[0] - v->grid.origin[0], origin[1] - v->grid.origin[1], origin[2] - v->grid.origin[2] };
    double base[3], du[3], dv[3];
    Apply3(inv, rel, base);
    Apply3(inv, uStep, du);
    Apply3(inv, vStep, dv);
    // One sample per voxel along i (u) and j (v), nothing along k.
    const double dirTol = 1e-6;
    if (std::fabs(du[0] - 1) > dirTol || std::fabs(du[1]) > dirTol || std::fabs(du[2]) > dirTol) return 0;
    if (std::fabs(dv[1] - 1) > dirTol || std::fabs(dv[0]) > dirTol || std::fabs(dv[2]) > dirTol) return 0;
    double ri = std::floor(base[0] + 0.5), rj = std::floor(base[1] + 0.5), rk = std::floor(base[2] + 0.5);
    if (std::fabs(base[0] - ri) * v->grid.spacing[0] > toleranceMM) return 0;
    if (std::fabs(base[1] - rj) * v->grid.spacing[1] > toleranceMM) return 0;
    if (std::fabs(base[2] - rk) * v->grid.spacing[2] > toleranceMM) return 0;
    if (rk < 0 || rk >= (double)v->grid.dims[2]) return 0;
    *k = (uint32_t)rk;
    *i0 = (int64_t)ri;
    *j0 = (int64_t)rj;
    return 1;
}

// ======================================================================================================================
// Overlay picture
// ======================================================================================================================

void BKLabelColourTableBuild(const BKLabelVolume *v, double overallOpacity, uint8_t *table)
{
    if (!table) return;
    memset(table, 0, BKLabelColourTableBytes);
    if (!v) return;
    if (!(overallOpacity >= 0)) overallOpacity = 0;
    if (overallOpacity > 1) overallOpacity = 1;
    for (const BKLabelClass &c : v->classes) {
        if (!c.visible) continue;
        double a = std::floor(c.opacity * overallOpacity * 255.0 + 0.5);
        if (a <= 0) continue;
        uint8_t *t = table + 4 * (size_t)c.value;
        t[0] = c.rgb[0]; t[1] = c.rgb[1]; t[2] = c.rgb[2];
        t[3] = (uint8_t)(a > 255 ? 255 : a);
    }
}

uint64_t BKLabelSliceToRGBA(const uint16_t *labels, uint32_t width, uint32_t height, const uint8_t *table,
                            int outlineOnly, uint8_t *rgba, uint32_t box[4])
{
    if (box) { box[0] = box[1] = box[2] = box[3] = 0; }
    if (!labels || !table || !rgba || width == 0 || height == 0) return 0;
    uint32_t x0 = UINT32_MAX, y0 = UINT32_MAX, x1 = 0, y1 = 0;
    uint64_t coloured = 0;
    for (uint32_t y = 0; y < height; y++) {
        const uint16_t *row = labels + (uint64_t)y * width;
        uint8_t *o = rgba + (uint64_t)y * width * 4;
        for (uint32_t x = 0; x < width; x++, o += 4) {
            uint16_t L = row[x];
            const uint8_t *t = table + 4 * (size_t)L;
            bool show = L != 0 && t[3] != 0;
            if (show && outlineOnly) {
                // Outline: a neighbour (left, right, up, down) with another label, or the picture edge.
                bool edge = x == 0 || y == 0 || x + 1 == width || y + 1 == height ||
                            row[x - 1] != L || row[x + 1] != L ||
                            labels[(uint64_t)(y - 1) * width + x] != L || labels[(uint64_t)(y + 1) * width + x] != L;
                show = edge;
            }
            if (!show) { o[0] = o[1] = o[2] = o[3] = 0; continue; }
            o[0] = t[0]; o[1] = t[1]; o[2] = t[2]; o[3] = t[3];
            coloured++;
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
        }
    }
    if (box && coloured) { box[0] = x0; box[1] = y0; box[2] = x1 - x0 + 1; box[3] = y1 - y0 + 1; }
    return coloured;
}

// ======================================================================================================================
// Masks
// ======================================================================================================================

int BKLabelMaskBox(const BKLabelVolume *v, uint16_t value, uint32_t margin, int64_t boxMin[3], uint32_t boxDims[3])
{
    uint32_t lo[3], hi[3];
    if (!boxMin || !boxDims || !BKLabelVolumeClassBounds(v, value, lo, hi)) return 0;
    for (int a = 0; a < 3; a++) {
        boxMin[a] = (int64_t)lo[a] - (int64_t)margin;
        uint64_t extent = (uint64_t)(hi[a] - lo[a]) + 1 + 2ull * margin;
        if (extent > UINT32_MAX) return 0;
        boxDims[a] = (uint32_t)extent;
    }
    return 1;
}

namespace {

// Calls put(boxIndex, inside?) for slices [zFirst, zFirst + zCount) of the box.
template <typename Put>
void MaskWalk(const BKLabelVolume *v, uint16_t value, const int64_t boxMin[3], const uint32_t boxDims[3],
              uint32_t zFirst, uint32_t zCount, Put put)
{
    const int64_t w = v->grid.dims[0], h = v->grid.dims[1], d = v->grid.dims[2];
    const uint64_t bw = boxDims[0], bh = boxDims[1];
    for (uint32_t z = zFirst; z < zFirst + zCount; z++) {
        int64_t k = boxMin[2] + z;
        for (uint64_t y = 0; y < bh; y++) {
            int64_t j = boxMin[1] + (int64_t)y;
            uint64_t outRow = ((uint64_t)(z - zFirst) * bh + y) * bw;
            bool rowInside = k >= 0 && k < d && j >= 0 && j < h;
            const uint16_t *src = rowInside ? v->voxels + ((uint64_t)k * (uint64_t)h + (uint64_t)j) * (uint64_t)w : nullptr;
            for (uint64_t x = 0; x < bw; x++) {
                int64_t i = boxMin[0] + (int64_t)x;
                put(outRow + x, src && i >= 0 && i < w && src[i] == value);
            }
        }
    }
}

} // namespace

void BKLabelMaskFill16(const BKLabelVolume *v, uint16_t value, const int64_t boxMin[3], const uint32_t boxDims[3],
                       uint32_t zFirst, uint32_t zCount, uint16_t inside, uint16_t *out)
{
    if (!v || !v->voxels || !boxMin || !boxDims || !out || zFirst + (uint64_t)zCount > boxDims[2]) return;
    MaskWalk(v, value, boxMin, boxDims, zFirst, zCount, [&](uint64_t n, bool in) { out[n] = in ? inside : 0; });
}

void BKLabelMaskFillFloat(const BKLabelVolume *v, uint16_t value, const int64_t boxMin[3], const uint32_t boxDims[3],
                          float *out)
{
    if (!v || !v->voxels || !boxMin || !boxDims || !out) return;
    MaskWalk(v, value, boxMin, boxDims, 0, boxDims[2], [&](uint64_t n, bool in) { out[n] = in ? 1.0f : 0.0f; });
}

void BKLabelMaskBoxToPatient(const BKLabelGrid *g, const int64_t boxMin[3], double m[16])
{
    BKLabelGridVoxelToPatientMatrix(g, m);
    // Translation = position of volume voxel boxMin.
    double p[3];
    BKLabelGridVoxelToPatient(g, (double)boxMin[0], (double)boxMin[1], (double)boxMin[2], p);
    for (int r = 0; r < 3; r++) m[12 + r] = p[r];
}
