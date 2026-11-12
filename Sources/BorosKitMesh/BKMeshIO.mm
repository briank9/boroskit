// BorosKitMesh: BKMeshIO implementation (see the header for what it does).

/* BOROS OVERVIEW (plain language)
 * This file opens and saves 3D surface files: STL (3D printing), PLY (intraoral
 * scanners, with colour) and OBJ. A file is just a long row of bytes; each format
 * says how to cut it into corner points and triangles.
 * Because a file can be damaged, cut short, or not what its name says, every count
 * the file announces is checked against the real file size BEFORE memory is reserved
 * or bytes are read, and every problem is reported as a readable error message
 * instead of a crash. The numbers are written with enough digits that saving and
 * reopening gives back exactly the same shape.
 */

#import "BKMeshIO.h"
#import <vector>
#import <string>
#import <unordered_map>
#import <cstring>
#import <cstdlib>
#import <cmath>
#import <climits>
#import <cstdarg>

// Makes an NSError in the mesh domain with a plain-language message.
static NSError *BKIOError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:BKMeshErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Sets *error (if wanted) and returns nil, to keep the readers short.
#define BK_FAIL(code, ...) do { if (error) *error = BKIOError((code), [NSString stringWithFormat:__VA_ARGS__]); return nil; } while (0)

#pragma mark - Small text helpers

// What: a read position inside a text buffer that always ends with a 0 byte.
// Why: the C number parsers (strtod...) need that final 0 so they can never run past
// the end of the file.
struct BKText {
    const char *p;
    const char *end;
};

static inline bool BKIsSpace(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v'; }

// Skips spaces/tabs AND line breaks.
static inline void BKSkipWhitespace(BKText &t) { while (t.p < t.end && BKIsSpace(*t.p)) t.p++; }

// Next word (sequence of non-space characters); empty string at the end.
static std::string BKNextToken(BKText &t)
{
    BKSkipWhitespace(t);
    const char *s = t.p;
    while (t.p < t.end && !BKIsSpace(*t.p)) t.p++;
    return std::string(s, t.p - s);
}

// Next number (any line). Returns false if the next word is not a number.
static bool BKNextDouble(BKText &t, double *out)
{
    BKSkipWhitespace(t);
    if (t.p >= t.end) return false;
    char *stop = NULL;
    double v = strtod(t.p, &stop);
    if (stop == t.p || stop > t.end) return false;
    // The number must end at a space (rejects "1.5abc").
    if (stop < t.end && !BKIsSpace(*stop)) return false;
    t.p = stop;
    *out = v;
    return true;
}

// Copies the bytes into a buffer with a terminating 0 (see BKText).
static std::vector<char> BKTerminatedCopy(NSData *data)
{
    std::vector<char> buffer(data.length + 1, 0);
    if (data.length) memcpy(buffer.data(), data.bytes, data.length);
    return buffer;
}

// Appends printf-style text to a std::string (used by the text writers).
static void BKAppend(std::string &s, const char *format, ...) __attribute__((format(printf, 2, 3)));
static void BKAppend(std::string &s, const char *format, ...)
{
    char line[256];
    va_list args, again;
    va_start(args, format);
    va_copy(again, args);
    int n = vsnprintf(line, sizeof line, format, args);
    if (n > 0 && (size_t)n < sizeof line) {
        s.append(line, (size_t)n);
    } else if (n > 0) {
        // Rare long line (e.g. a long object name): format again into a big enough buffer.
        std::vector<char> big((size_t)n + 1);
        vsnprintf(big.data(), big.size(), format, again);
        s.append(big.data(), (size_t)n);
    }
    va_end(again);
    va_end(args);
}

// Little-endian readers/writers (all formats here are little-endian; Macs and iPads are too,
// but the explicit conversion keeps the files correct on any machine).
static inline uint32_t BKReadU32LE(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return CFSwapInt32LittleToHost(v); }
static inline float BKReadF32LE(const uint8_t *p) { uint32_t v = BKReadU32LE(p); float f; memcpy(&f, &v, 4); return f; }
static inline void BKPutU32LE(std::vector<uint8_t> &out, uint32_t v) { v = CFSwapInt32HostToLittle(v); const uint8_t *b = (const uint8_t *)&v; out.insert(out.end(), b, b + 4); }
static inline void BKPutF32LE(std::vector<uint8_t> &out, float f) { uint32_t v; memcpy(&v, &f, 4); BKPutU32LE(out, v); }

// Builds the final mesh (which re-checks every index and coordinate).
static BKMesh *BKMakeMesh(const std::vector<simd_float3> &v, const std::vector<uint32_t> &idx,
                          const std::vector<simd_float3> *normals, const std::vector<simd_float4> *colors, NSError **error)
{
    NSError *inner = nil;
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:v.data() vertexCount:v.size() indices:idx.data() indexCount:idx.size()
                                            normals:(normals && !normals->empty()) ? normals->data() : NULL
                                             colors:(colors && !colors->empty()) ? colors->data() : NULL
                                              error:&inner];
    if (!mesh && error)
        *error = BKIOError(BKMeshErrorMalformedFile, [@"The file contains invalid geometry: " stringByAppendingString:inner.localizedDescription ?: @""]);
    return mesh;
}

#pragma mark - STL

// A binary STL is: 80-byte header, 32-bit triangle count, then 50 bytes per triangle
// (normal + 3 corners as 12 floats, plus a 2-byte "attribute" field).
static const NSUInteger kSTLHeader = 84, kSTLTriangle = 50;

// What: YES if the size matches a binary STL exactly. Why: some binary STL headers
// start with the word "solid" too, so the size is the reliable test.
static bool BKLooksLikeBinarySTL(NSData *data)
{
    if (data.length < kSTLHeader) return false;
    uint64_t count = BKReadU32LE((const uint8_t *)data.bytes + 80);
    return kSTLHeader + count * kSTLTriangle == data.length;
}

static bool BKStartsWithWord(NSData *data, const char *word)
{
    const char *p = (const char *)data.bytes, *end = p + data.length;
    while (p < end && BKIsSpace(*p)) p++;
    size_t n = strlen(word);
    return (size_t)(end - p) >= n && strncasecmp(p, word, n) == 0;
}

static BKMesh *BKReadBinarySTL(NSData *data, NSError **error)
{
    if (data.length < kSTLHeader) BK_FAIL(BKMeshErrorMalformedFile, @"The STL file is too short to be valid (%lu bytes).", (unsigned long)data.length);
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint64_t count = BKReadU32LE(bytes + 80);
    if (kSTLHeader + count * kSTLTriangle > data.length)
        BK_FAIL(BKMeshErrorMalformedFile, @"The STL file is cut short: it announces %llu triangles but only has room for %lu.",
                count, (unsigned long)((data.length - kSTLHeader) / kSTLTriangle));
    std::vector<simd_float3> v;
    std::vector<uint32_t> idx;
    v.reserve(count * 3); idx.reserve(count * 3);
    for (uint64_t t = 0; t < count; t++) {
        const uint8_t *tri = bytes + kSTLHeader + t * kSTLTriangle + 12;   // skip the stored normal
        for (int k = 0; k < 3; k++) {
            const uint8_t *c = tri + 12 * k;
            idx.push_back((uint32_t)v.size());
            v.push_back(simd_make_float3(BKReadF32LE(c), BKReadF32LE(c + 4), BKReadF32LE(c + 8)));
        }
    }
    return BKMakeMesh(v, idx, NULL, NULL, error);
}

// ASCII STL: "solid name / facet normal ... / outer loop / vertex x y z (x3) / endloop /
// endfacet / ... / endsolid". Only the "vertex" lines matter; normals are recomputed.
static BKMesh *BKReadASCIISTL(NSData *data, NSError **error)
{
    std::vector<char> buffer = BKTerminatedCopy(data);
    BKText t = {buffer.data(), buffer.data() + data.length};
    std::vector<simd_float3> v;
    std::vector<uint32_t> idx;
    bool sawSolid = false;
    for (;;) {
        std::string word = BKNextToken(t);
        if (word.empty()) break;
        if (strcasecmp(word.c_str(), "solid") == 0) sawSolid = true;
        if (strcasecmp(word.c_str(), "vertex") != 0) continue;
        double x, y, z;
        if (!BKNextDouble(t, &x) || !BKNextDouble(t, &y) || !BKNextDouble(t, &z))
            BK_FAIL(BKMeshErrorMalformedFile, @"The text STL file has a damaged 'vertex' line (vertex %lu).", (unsigned long)v.size() + 1);
        idx.push_back((uint32_t)v.size());
        v.push_back(simd_make_float3((float)x, (float)y, (float)z));
        if (v.size() >= UINT32_MAX) BK_FAIL(BKMeshErrorUnsupportedFile, @"The STL file has too many triangles.");
    }
    if (!sawSolid) BK_FAIL(BKMeshErrorMalformedFile, @"This is not an STL file (no 'solid' keyword and the size does not match a binary STL).");
    if (v.size() % 3 != 0) BK_FAIL(BKMeshErrorMalformedFile, @"The text STL file is incomplete: the last triangle has fewer than 3 corners.");
    return BKMakeMesh(v, idx, NULL, NULL, error);
}

static BKMesh *BKReadSTL(NSData *data, NSError **error)
{
    BKMesh *mesh;
    if (BKLooksLikeBinarySTL(data)) mesh = BKReadBinarySTL(data, error);
    else if (BKStartsWithWord(data, "solid")) mesh = BKReadASCIISTL(data, error);
    else mesh = BKReadBinarySTL(data, error);   // gives the right "cut short / too short" message
    // STL repeats each corner for every triangle; merge exact repeats so the triangles
    // are connected (needed for the closed-surface check and smooth shading).
    if (mesh) [mesh weldVerticesWithTolerance:0];
    return mesh;
}

static NSData *BKWriteBinarySTL(BKMesh *mesh, NSError **error)
{
    std::vector<uint8_t> out;
    out.reserve(kSTLHeader + mesh.triangleCount * kSTLTriangle);
    // The header must NOT start with "solid", or some programs take it for a text STL.
    char header[80] = {0};
    strncpy(header, "Binary STL written by BorosKit", sizeof header);
    out.insert(out.end(), header, header + 80);
    BKPutU32LE(out, (uint32_t)mesh.triangleCount);
    const simd_float3 *v = mesh.vertices;
    const uint32_t *idx = mesh.indices;
    for (NSUInteger t = 0; t < mesh.triangleCount; t++) {
        simd_float3 a = v[idx[3 * t]], b = v[idx[3 * t + 1]], c = v[idx[3 * t + 2]];
        simd_float3 n = simd_cross(b - a, c - a);
        float len = simd_length(n);
        n = len > 0 ? n / len : simd_make_float3(0, 0, 0);
        simd_float3 values[4] = {n, a, b, c};
        for (int k = 0; k < 4; k++) { BKPutF32LE(out, values[k].x); BKPutF32LE(out, values[k].y); BKPutF32LE(out, values[k].z); }
        out.push_back(0); out.push_back(0);   // attribute byte count: unused
    }
    return [NSData dataWithBytes:out.data() length:out.size()];
}

#pragma mark - PLY

// The scalar types a PLY file may use (both old and new names).
enum BKPLYType { BKPLYInvalid = 0, BKPLYInt8, BKPLYUInt8, BKPLYInt16, BKPLYUInt16, BKPLYInt32, BKPLYUInt32, BKPLYFloat32, BKPLYFloat64 };

static BKPLYType BKPLYTypeNamed(const std::string &n)
{
    if (n == "char" || n == "int8") return BKPLYInt8;
    if (n == "uchar" || n == "uint8") return BKPLYUInt8;
    if (n == "short" || n == "int16") return BKPLYInt16;
    if (n == "ushort" || n == "uint16") return BKPLYUInt16;
    if (n == "int" || n == "int32") return BKPLYInt32;
    if (n == "uint" || n == "uint32") return BKPLYUInt32;
    if (n == "float" || n == "float32") return BKPLYFloat32;
    if (n == "double" || n == "float64") return BKPLYFloat64;
    return BKPLYInvalid;
}

static size_t BKPLYTypeSize(BKPLYType t)
{
    switch (t) {
        case BKPLYInt8: case BKPLYUInt8: return 1;
        case BKPLYInt16: case BKPLYUInt16: return 2;
        case BKPLYInt32: case BKPLYUInt32: case BKPLYFloat32: return 4;
        case BKPLYFloat64: return 8;
        default: return 0;
    }
}

// What a colour channel stored as this type means: integers are 0..max, floats 0..1.
static double BKPLYColorScale(BKPLYType t)
{
    switch (t) {
        case BKPLYInt8: case BKPLYUInt8: return 1.0 / 255.0;
        case BKPLYInt16: case BKPLYUInt16: return 1.0 / 65535.0;
        case BKPLYInt32: case BKPLYUInt32: return 1.0 / 255.0;   // rare; most writers mean 0..255
        default: return 1.0;
    }
}

struct BKPLYProperty {
    std::string name;
    BKPLYType type = BKPLYInvalid;      // value type (for lists: the item type)
    BKPLYType countType = BKPLYInvalid; // lists only: type of the leading item count
    bool isList = false;
};

struct BKPLYElement {
    std::string name;
    uint64_t count = 0;
    std::vector<BKPLYProperty> properties;
};

enum BKPLYEncoding { BKPLYASCII, BKPLYBinaryLE, BKPLYBinaryBE };

// Reads one value of `type` from the body (binary or text). Returns false at the end
// of the data or on a damaged number.
struct BKPLYReader {
    BKPLYEncoding encoding;
    const uint8_t *p, *end;   // binary
    BKText text;              // ASCII

    bool read(BKPLYType type, double *out) {
        if (encoding == BKPLYASCII) return BKNextDouble(text, out);
        size_t size = BKPLYTypeSize(type);
        if (size == 0 || (size_t)(end - p) < size) return false;
        uint8_t raw[8];
        memcpy(raw, p, size);
        p += size;
        // Bring the bytes into this machine's order (Apple devices are little-endian).
        bool fileLittle = encoding == BKPLYBinaryLE;
        if (fileLittle != (CFByteOrderGetCurrent() == CFByteOrderLittleEndian))
            for (size_t i = 0; i < size / 2; i++) std::swap(raw[i], raw[size - 1 - i]);
        switch (type) {
            case BKPLYInt8:    { int8_t v;   memcpy(&v, raw, 1); *out = v; break; }
            case BKPLYUInt8:   { uint8_t v;  memcpy(&v, raw, 1); *out = v; break; }
            case BKPLYInt16:   { int16_t v;  memcpy(&v, raw, 2); *out = v; break; }
            case BKPLYUInt16:  { uint16_t v; memcpy(&v, raw, 2); *out = v; break; }
            case BKPLYInt32:   { int32_t v;  memcpy(&v, raw, 4); *out = v; break; }
            case BKPLYUInt32:  { uint32_t v; memcpy(&v, raw, 4); *out = v; break; }
            case BKPLYFloat32: { float v;    memcpy(&v, raw, 4); *out = v; break; }
            case BKPLYFloat64: { double v;   memcpy(&v, raw, 8); *out = v; break; }
            default: return false;
        }
        return true;
    }

    // Bytes (binary) or characters (text) left: an upper bound on how many values remain.
    uint64_t remaining() const {
        return encoding == BKPLYASCII ? (uint64_t)(text.end - text.p) : (uint64_t)(end - p);
    }
};

static BKMesh *BKReadPLY(NSData *data, NSError **error)
{
    const char *bytes = (const char *)data.bytes;
    const char *end = bytes + data.length;

    // --- Header: plain text lines up to "end_header" ---
    if (data.length < 4 || strncmp(bytes, "ply", 3) != 0 || (bytes[3] != '\n' && bytes[3] != '\r'))
        BK_FAIL(BKMeshErrorMalformedFile, @"This is not a PLY file (it does not start with 'ply').");
    const char *line = bytes;
    const char *body = NULL;
    BKPLYEncoding encoding = BKPLYASCII;
    bool sawFormat = false;
    std::vector<BKPLYElement> elements;
    while (line < end) {
        const char *eol = (const char *)memchr(line, '\n', end - line);
        if (!eol) eol = end;
        std::string text(line, eol - line);
        line = eol < end ? eol + 1 : end;
        // Split the line into words.
        std::vector<std::string> words;
        size_t i = 0;
        while (i < text.size()) {
            while (i < text.size() && BKIsSpace(text[i])) i++;
            size_t s = i;
            while (i < text.size() && !BKIsSpace(text[i])) i++;
            if (i > s) words.push_back(text.substr(s, i - s));
        }
        if (words.empty()) continue;
        const std::string &key = words[0];
        if (key == "end_header") { body = line; break; }
        if (key == "ply" || key == "comment" || key == "obj_info") continue;
        if (key == "format") {
            if (words.size() < 2) BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header has an incomplete 'format' line.");
            if (words[1] == "ascii") encoding = BKPLYASCII;
            else if (words[1] == "binary_little_endian") encoding = BKPLYBinaryLE;
            else if (words[1] == "binary_big_endian") encoding = BKPLYBinaryBE;
            else BK_FAIL(BKMeshErrorUnsupportedFile, @"Unknown PLY format '%s'.", words[1].c_str());
            sawFormat = true;
        } else if (key == "element") {
            if (words.size() < 3) BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header has an incomplete 'element' line.");
            char *stop = NULL;
            unsigned long long count = strtoull(words[2].c_str(), &stop, 10);
            if (!stop || *stop || words[2][0] == '-') BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header has an invalid element count '%s'.", words[2].c_str());
            BKPLYElement element;
            element.name = words[1];
            element.count = count;
            elements.push_back(element);
        } else if (key == "property") {
            if (elements.empty()) BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header lists a property before any element.");
            BKPLYProperty prop;
            if (words.size() >= 5 && words[1] == "list") {
                prop.isList = true;
                prop.countType = BKPLYTypeNamed(words[2]);
                prop.type = BKPLYTypeNamed(words[3]);
                prop.name = words[4];
                if (prop.countType == BKPLYInvalid || prop.countType == BKPLYFloat32 || prop.countType == BKPLYFloat64 || prop.type == BKPLYInvalid)
                    BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header has an invalid list property '%s'.", text.c_str());
            } else if (words.size() >= 3 && words[1] != "list") {
                prop.type = BKPLYTypeNamed(words[1]);
                prop.name = words[2];
                if (prop.type == BKPLYInvalid) BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header uses an unknown type '%s'.", words[1].c_str());
            } else {
                BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header has an incomplete 'property' line.");
            }
            elements.back().properties.push_back(prop);
        } else {
            BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header has an unknown line '%s'.", text.c_str());
        }
    }
    if (!body) BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header is incomplete (no 'end_header').");
    if (!sawFormat) BK_FAIL(BKMeshErrorMalformedFile, @"The PLY header does not say whether the file is text or binary.");

    // --- Body ---
    std::vector<char> buffer;   // text bodies need a terminating 0 for strtod
    BKPLYReader reader;
    reader.encoding = encoding;
    if (encoding == BKPLYASCII) {
        buffer.assign(body, end);
        buffer.push_back(0);
        reader.text = BKText{buffer.data(), buffer.data() + (end - body)};
        reader.p = reader.end = NULL;
    } else {
        reader.p = (const uint8_t *)body;
        reader.end = (const uint8_t *)end;
        reader.text = BKText{NULL, NULL};
    }

    std::vector<simd_float3> v, normals;
    std::vector<simd_float4> colors;
    std::vector<uint32_t> idx;
    bool haveVertices = false;
    for (const BKPLYElement &element : elements) {
        if (element.properties.empty()) continue;
        // Every item takes at least one byte (binary) or one character (text): a count
        // larger than what is left in the file means the file is damaged. Checked
        // before reserving memory so a bogus count cannot exhaust it.
        if (element.count > reader.remaining())
            BK_FAIL(BKMeshErrorMalformedFile, @"The PLY file is cut short: element '%s' announces %llu items.", element.name.c_str(), element.count);
        bool isVertex = element.name == "vertex", isFace = element.name == "face";
        // Which property of the vertex holds what (-1 = absent).
        int ix = -1, iy = -1, iz = -1, inx = -1, iny = -1, inz = -1, ir = -1, ig = -1, ib = -1, ia = -1, iface = -1;
        for (int i = 0; i < (int)element.properties.size(); i++) {
            const BKPLYProperty &p = element.properties[i];
            const std::string &n = p.name;
            if (isVertex && !p.isList) {
                if (n == "x") ix = i; else if (n == "y") iy = i; else if (n == "z") iz = i;
                else if (n == "nx") inx = i; else if (n == "ny") iny = i; else if (n == "nz") inz = i;
                else if (n == "red" || n == "r" || n == "diffuse_red") ir = i;
                else if (n == "green" || n == "g" || n == "diffuse_green") ig = i;
                else if (n == "blue" || n == "b" || n == "diffuse_blue") ib = i;
                else if (n == "alpha" || n == "a") ia = i;
            }
            if (isFace && p.isList && (n == "vertex_indices" || n == "vertex_index") && iface < 0) iface = i;
        }
        if (isVertex) {
            if (haveVertices) BK_FAIL(BKMeshErrorUnsupportedFile, @"The PLY file has more than one vertex list.");
            if (ix < 0 || iy < 0 || iz < 0) BK_FAIL(BKMeshErrorMalformedFile, @"The PLY vertices have no x, y, z coordinates.");
            if (element.count >= UINT32_MAX) BK_FAIL(BKMeshErrorUnsupportedFile, @"The PLY file has too many vertices.");
            haveVertices = true;
            v.reserve(element.count);
            bool hasNormals = inx >= 0 && iny >= 0 && inz >= 0;
            bool hasColors = ir >= 0 && ig >= 0 && ib >= 0;
            if (hasNormals) normals.reserve(element.count);
            if (hasColors) colors.reserve(element.count);
            std::vector<double> values(element.properties.size(), 0.0);
            for (uint64_t item = 0; item < element.count; item++) {
                for (size_t i = 0; i < element.properties.size(); i++) {
                    const BKPLYProperty &p = element.properties[i];
                    if (!p.isList) {
                        if (!reader.read(p.type, &values[i]))
                            BK_FAIL(BKMeshErrorMalformedFile, @"The PLY file is damaged or cut short at vertex %llu.", item);
                        continue;
                    }
                    double n;   // a list on a vertex: read and ignore its items
                    if (!reader.read(p.countType, &n) || n < 0 || n > reader.remaining())
                        BK_FAIL(BKMeshErrorMalformedFile, @"The PLY file is damaged at vertex %llu.", item);
                    for (uint64_t k = 0; k < (uint64_t)n; k++) {
                        double ignored;
                        if (!reader.read(p.type, &ignored)) BK_FAIL(BKMeshErrorMalformedFile, @"The PLY file is cut short at vertex %llu.", item);
                    }
                }
                v.push_back(simd_make_float3((float)values[ix], (float)values[iy], (float)values[iz]));
                if (hasNormals) normals.push_back(simd_make_float3((float)values[inx], (float)values[iny], (float)values[inz]));
                if (hasColors) {
                    simd_float4 c = simd_make_float4((float)(values[ir] * BKPLYColorScale(element.properties[ir].type)),
                                                     (float)(values[ig] * BKPLYColorScale(element.properties[ig].type)),
                                                     (float)(values[ib] * BKPLYColorScale(element.properties[ib].type)),
                                                     ia >= 0 ? (float)(values[ia] * BKPLYColorScale(element.properties[ia].type)) : 1.0f);
                    colors.push_back(simd_clamp(c, simd_make_float4(0, 0, 0, 0), simd_make_float4(1, 1, 1, 1)));
                }
            }
        } else {
            // Faces (triangulated), or any other element whose data is skipped.
            for (uint64_t item = 0; item < element.count; item++) {
                for (size_t i = 0; i < element.properties.size(); i++) {
                    const BKPLYProperty &p = element.properties[i];
                    double value;
                    if (!p.isList) {
                        if (!reader.read(p.type, &value))
                            BK_FAIL(BKMeshErrorMalformedFile, @"The PLY file is damaged or cut short in '%s' %llu.", element.name.c_str(), item);
                        continue;
                    }
                    double n;
                    if (!reader.read(p.countType, &n) || n < 0 || n != std::floor(n) || n > reader.remaining())
                        BK_FAIL(BKMeshErrorMalformedFile, @"The PLY file has an invalid list length in '%s' %llu.", element.name.c_str(), item);
                    uint64_t count = (uint64_t)n;
                    bool isCornerList = isFace && (int)i == iface;
                    uint32_t first = 0, previous = 0;
                    for (uint64_t k = 0; k < count; k++) {
                        if (!reader.read(p.type, &value))
                            BK_FAIL(BKMeshErrorMalformedFile, @"The PLY file is cut short in face %llu.", item);
                        if (!isCornerList) continue;
                        if (value < 0 || value >= UINT32_MAX || value != std::floor(value))
                            BK_FAIL(BKMeshErrorMalformedFile, @"Face %llu of the PLY file has an invalid vertex number.", item);
                        uint32_t corner = (uint32_t)value;
                        // Polygons are split into a fan of triangles around the first corner.
                        if (k == 0) first = corner;
                        else if (k >= 2) { idx.push_back(first); idx.push_back(previous); idx.push_back(corner); }
                        previous = corner;
                    }
                }
            }
        }
    }
    if (!haveVertices) BK_FAIL(BKMeshErrorMalformedFile, @"The PLY file has no vertex list.");
    return BKMakeMesh(v, idx, &normals, &colors, error);
}

// Converts a 0..1 colour channel to 0..255.
static uint8_t BKColorByte(float c)
{
    if (!(c > 0)) return 0;
    if (c >= 1) return 255;
    return (uint8_t)lroundf(c * 255.0f);
}

static NSData *BKWritePLY(BKMesh *mesh, bool binary)
{
    const simd_float3 *v = mesh.vertices, *n = mesh.normals;
    const simd_float4 *c = mesh.colors;
    const uint32_t *idx = mesh.indices;
    std::string header = "ply\n";
    header += binary ? "format binary_little_endian 1.0\n" : "format ascii 1.0\n";
    header += "comment written by BorosKit (units: patient millimetres)\n";
    BKAppend(header, "element vertex %lu\n", (unsigned long)mesh.vertexCount);
    header += "property float x\nproperty float y\nproperty float z\n";
    if (n) header += "property float nx\nproperty float ny\nproperty float nz\n";
    if (c) header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\n";
    BKAppend(header, "element face %lu\n", (unsigned long)mesh.triangleCount);
    header += "property list uchar int vertex_indices\nend_header\n";

    if (binary) {
        std::vector<uint8_t> out(header.begin(), header.end());
        out.reserve(header.size() + mesh.vertexCount * 28 + mesh.triangleCount * 13);
        for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
            BKPutF32LE(out, v[i].x); BKPutF32LE(out, v[i].y); BKPutF32LE(out, v[i].z);
            if (n) { BKPutF32LE(out, n[i].x); BKPutF32LE(out, n[i].y); BKPutF32LE(out, n[i].z); }
            if (c) { out.push_back(BKColorByte(c[i].x)); out.push_back(BKColorByte(c[i].y)); out.push_back(BKColorByte(c[i].z)); out.push_back(BKColorByte(c[i].w)); }
        }
        for (NSUInteger t = 0; t < mesh.triangleCount; t++) {
            out.push_back(3);
            for (int k = 0; k < 3; k++) BKPutU32LE(out, idx[3 * t + k]);
        }
        return [NSData dataWithBytes:out.data() length:out.size()];
    }
    std::string out = header;
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
        // %.9g = enough digits to get exactly the same 32-bit float back.
        BKAppend(out, "%.9g %.9g %.9g", v[i].x, v[i].y, v[i].z);
        if (n) BKAppend(out, " %.9g %.9g %.9g", n[i].x, n[i].y, n[i].z);
        if (c) BKAppend(out, " %u %u %u %u", BKColorByte(c[i].x), BKColorByte(c[i].y), BKColorByte(c[i].z), BKColorByte(c[i].w));
        out += "\n";
    }
    for (NSUInteger t = 0; t < mesh.triangleCount; t++)
        BKAppend(out, "3 %u %u %u\n", idx[3 * t], idx[3 * t + 1], idx[3 * t + 2]);
    return [NSData dataWithBytes:out.data() length:out.size()];
}

#pragma mark - OBJ

// Parses one face corner "v", "v/vt", "v//vn" or "v/vt/vn" (numbers from 1, or
// negative = counted back from the latest). Returns false if damaged.
static bool BKParseOBJCorner(const std::string &word, long vertexCount, long normalCount, long *vi, long *ni)
{
    const char *s = word.c_str();
    char *stop = NULL;
    long v = strtol(s, &stop, 10);
    if (stop == s || v == 0) return false;
    *vi = v > 0 ? v - 1 : vertexCount + v;
    *ni = -1;
    if (*stop == 0) return *vi >= 0;
    if (*stop != '/') return false;
    s = stop + 1;
    if (*s != '/') {                        // texture coordinate: read and ignore
        strtol(s, &stop, 10);
        if (stop == s) return false;
        s = stop;
        if (*s == 0) return *vi >= 0;
        if (*s != '/') return false;
    }
    s++;                                    // skip the '/' before the normal
    if (*s == 0) return *vi >= 0;           // "v/vt/" (tolerated)
    long n = strtol(s, &stop, 10);
    if (stop == s || *stop != 0 || n == 0) return false;
    *ni = n > 0 ? n - 1 : normalCount + n;
    return *vi >= 0 && *ni >= 0;
}

static BKMesh *BKReadOBJ(NSData *data, NSError **error)
{
    std::vector<char> buffer = BKTerminatedCopy(data);
    const char *p = buffer.data(), *end = buffer.data() + data.length;
    std::vector<simd_float3> positions, fileNormals;
    std::vector<simd_float4> fileColors;      // filled only if some "v" line has a colour
    std::vector<long> cornerV, cornerN;       // all triangle corners (file numbering)
    bool anyColor = false;
    unsigned long lineNumber = 0;
    while (p < end) {
        const char *eol = (const char *)memchr(p, '\n', end - p);
        if (!eol) eol = end;
        lineNumber++;
        // Work on a 0-terminated copy of the line so the number parsers stop at its end.
        std::string line(p, eol - p);
        p = eol + 1;
        BKText t = {line.c_str(), line.c_str() + line.size()};
        std::string key = BKNextToken(t);
        if (key == "v") {
            double values[7];
            int count = 0;
            while (count < 7 && BKNextDouble(t, &values[count])) count++;
            if (count < 3) BK_FAIL(BKMeshErrorMalformedFile, @"Line %lu of the OBJ file has a damaged vertex.", lineNumber);
            positions.push_back(simd_make_float3((float)values[0], (float)values[1], (float)values[2]));
            // "v x y z r g b" (6 numbers, or 7 with a weight) = vertex colour extension.
            simd_float4 color = simd_make_float4(1, 1, 1, 1);
            if (count >= 6) {
                color = simd_make_float4((float)values[3], (float)values[4], (float)values[5], 1.0f);
                anyColor = true;
            }
            fileColors.push_back(color);
        } else if (key == "vn") {
            double x, y, z;
            if (!BKNextDouble(t, &x) || !BKNextDouble(t, &y) || !BKNextDouble(t, &z))
                BK_FAIL(BKMeshErrorMalformedFile, @"Line %lu of the OBJ file has a damaged normal.", lineNumber);
            fileNormals.push_back(simd_make_float3((float)x, (float)y, (float)z));
        } else if (key == "f") {
            std::vector<long> fv, fn;
            for (std::string word = BKNextToken(t); !word.empty(); word = BKNextToken(t)) {
                long vi, ni;
                if (!BKParseOBJCorner(word, (long)positions.size(), (long)fileNormals.size(), &vi, &ni))
                    BK_FAIL(BKMeshErrorMalformedFile, @"Line %lu of the OBJ file has a damaged face corner '%s'.", lineNumber, word.c_str());
                fv.push_back(vi); fn.push_back(ni);
            }
            if (fv.size() < 3) BK_FAIL(BKMeshErrorMalformedFile, @"Line %lu of the OBJ file has a face with fewer than 3 corners.", lineNumber);
            // Polygons are split into a fan of triangles around the first corner
            // (correct for the convex polygons OBJ exporters write).
            for (size_t k = 2; k < fv.size(); k++) {
                long tri[3] = {0, (long)k - 1, (long)k};
                for (long j : tri) { cornerV.push_back(fv[j]); cornerN.push_back(fn[j]); }
            }
        }
        // Everything else (vt, g, o, s, usemtl, mtllib, l, comments) is not needed for the shape.
    }
    for (size_t i = 0; i < cornerV.size(); i++) {
        if (cornerV[i] >= (long)positions.size())
            BK_FAIL(BKMeshErrorMalformedFile, @"An OBJ face refers to vertex %ld, but the file only has %lu.", cornerV[i] + 1, (unsigned long)positions.size());
        if (cornerN[i] >= (long)fileNormals.size())
            BK_FAIL(BKMeshErrorMalformedFile, @"An OBJ face refers to normal %ld, but the file only has %lu.", cornerN[i] + 1, (unsigned long)fileNormals.size());
    }
    if (positions.size() >= UINT32_MAX) BK_FAIL(BKMeshErrorUnsupportedFile, @"The OBJ file has too many vertices.");

    // OBJ gives each face CORNER its own normal number, while BKMesh has one normal per
    // vertex. Each vertex keeps the first normal it is used with; if the same vertex
    // is used with a different normal (a sharp edge), a copy of the vertex is added.
    // Files without normals keep their vertices exactly as listed.
    bool anyNormal = false;
    for (long n : cornerN) if (n >= 0) { anyNormal = true; break; }
    std::vector<simd_float3> v = positions, normals;
    std::vector<simd_float4> colors = anyColor ? fileColors : std::vector<simd_float4>();
    std::vector<uint32_t> idx(cornerV.size());
    if (!anyNormal) {
        for (size_t i = 0; i < cornerV.size(); i++) idx[i] = (uint32_t)cornerV[i];
    } else {
        normals.assign(v.size(), simd_make_float3(0, 0, 0));
        std::vector<long> claimedNormal(v.size(), LONG_MIN);   // LONG_MIN = vertex not used yet
        std::unordered_map<uint64_t, uint32_t> copies;          // (vertex, normal) -> copied vertex
        for (size_t i = 0; i < cornerV.size(); i++) {
            long vi = cornerV[i], ni = cornerN[i];
            if (claimedNormal[vi] == LONG_MIN) {
                claimedNormal[vi] = ni;
                if (ni >= 0) normals[vi] = fileNormals[ni];
            }
            if (claimedNormal[vi] == ni) { idx[i] = (uint32_t)vi; continue; }
            uint64_t key = ((uint64_t)vi << 32) ^ (uint64_t)(uint32_t)(ni + 1);
            auto it = copies.find(key);
            if (it == copies.end()) {
                if (v.size() >= UINT32_MAX) BK_FAIL(BKMeshErrorUnsupportedFile, @"The OBJ file has too many vertices.");
                v.push_back(positions[vi]);
                normals.push_back(ni >= 0 ? fileNormals[ni] : simd_make_float3(0, 0, 0));
                if (anyColor) colors.push_back(fileColors[vi]);
                it = copies.emplace(key, (uint32_t)(v.size() - 1)).first;
            }
            idx[i] = it->second;
        }
    }
    return BKMakeMesh(v, idx, &normals, &colors, error);
}

static NSData *BKWriteOBJ(BKMesh *mesh)
{
    const simd_float3 *v = mesh.vertices, *n = mesh.normals;
    const simd_float4 *c = mesh.colors;
    const uint32_t *idx = mesh.indices;
    std::string out = "# OBJ written by BorosKit (units: patient millimetres)\n";
    if (mesh.name.length) BKAppend(out, "o %s\n", [[mesh.name stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]);
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
        BKAppend(out, "v %.9g %.9g %.9g", v[i].x, v[i].y, v[i].z);
        if (c) BKAppend(out, " %.9g %.9g %.9g", c[i].x, c[i].y, c[i].z);
        out += "\n";
    }
    if (n) for (NSUInteger i = 0; i < mesh.vertexCount; i++) BKAppend(out, "vn %.9g %.9g %.9g\n", n[i].x, n[i].y, n[i].z);
    for (NSUInteger t = 0; t < mesh.triangleCount; t++) {
        // OBJ counts from 1.
        uint32_t a = idx[3 * t] + 1, b = idx[3 * t + 1] + 1, cc = idx[3 * t + 2] + 1;
        if (n) BKAppend(out, "f %u//%u %u//%u %u//%u\n", a, a, b, b, cc, cc);
        else BKAppend(out, "f %u %u %u\n", a, b, cc);
    }
    return [NSData dataWithBytes:out.data() length:out.size()];
}

#pragma mark - Public API

@implementation BKMeshIO

+ (BKMeshFileFormat)formatForPathExtension:(NSString *)extension
{
    NSString *e = extension.lowercaseString;
    if ([e isEqualToString:@"stl"]) return BKMeshFileFormatSTL;
    if ([e isEqualToString:@"ply"]) return BKMeshFileFormatPLY;
    if ([e isEqualToString:@"obj"]) return BKMeshFileFormatOBJ;
    return BKMeshFileFormatUnknown;
}

+ (BKMeshFileFormat)detectFormatOfData:(NSData *)data
{
    const char *b = (const char *)data.bytes;
    if (data.length >= 4 && strncmp(b, "ply", 3) == 0 && (b[3] == '\n' || b[3] == '\r')) return BKMeshFileFormatPLY;
    if (BKLooksLikeBinarySTL(data)) return BKMeshFileFormatSTL;
    if (BKStartsWithWord(data, "solid")) return BKMeshFileFormatSTL;
    // OBJ: text (no zero bytes) with a line starting with "v " or "f " near the top.
    NSUInteger n = MIN(data.length, (NSUInteger)65536);
    if (n == 0 || memchr(b, 0, n)) return BKMeshFileFormatUnknown;
    for (NSUInteger i = 0; i + 1 < n; i++) {
        if (i > 0 && b[i - 1] != '\n') continue;
        if ((b[i] == 'v' || b[i] == 'f') && (b[i + 1] == ' ' || b[i + 1] == '\t')) return BKMeshFileFormatOBJ;
    }
    return BKMeshFileFormatUnknown;
}

+ (BKMesh *)readMeshFromData:(NSData *)data format:(BKMeshFileFormat)format error:(NSError **)error
{
    if (!data) BK_FAIL(BKMeshErrorUnreadableFile, @"No data to read.");
    if (format == BKMeshFileFormatUnknown) format = [self detectFormatOfData:data];
    switch (format) {
        case BKMeshFileFormatSTL: return BKReadSTL(data, error);
        case BKMeshFileFormatPLY:
        case BKMeshFileFormatPLYASCII: return BKReadPLY(data, error);
        case BKMeshFileFormatOBJ: return BKReadOBJ(data, error);
        default: BK_FAIL(BKMeshErrorUnknownFormat, @"The data is not an STL, PLY or OBJ mesh.");
    }
}

+ (BKMesh *)readMeshFromURL:(NSURL *)url error:(NSError **)error
{
    NSError *readError = nil;
    // Mapped reading: large scans are not copied into memory twice.
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
    if (!data) BK_FAIL(BKMeshErrorUnreadableFile, @"The file %@ could not be opened: %@", url.lastPathComponent, readError.localizedDescription);
    BKMeshFileFormat format = [self detectFormatOfData:data];
    if (format == BKMeshFileFormatUnknown) format = [self formatForPathExtension:url.pathExtension];
    BKMesh *mesh = [self readMeshFromData:data format:format error:error];
    mesh.name = url.lastPathComponent.stringByDeletingPathExtension;
    return mesh;
}

+ (NSData *)dataForMesh:(BKMesh *)mesh format:(BKMeshFileFormat)format error:(NSError **)error
{
    if (!mesh) BK_FAIL(BKMeshErrorInvalidGeometry, @"No mesh to write.");
    switch (format) {
        case BKMeshFileFormatSTL: return BKWriteBinarySTL(mesh, error);
        case BKMeshFileFormatPLY: return BKWritePLY(mesh, true);
        case BKMeshFileFormatPLYASCII: return BKWritePLY(mesh, false);
        case BKMeshFileFormatOBJ: return BKWriteOBJ(mesh);
        default: BK_FAIL(BKMeshErrorUnknownFormat, @"Please choose a file format (STL, PLY or OBJ).");
    }
}

+ (BOOL)writeMesh:(BKMesh *)mesh toURL:(NSURL *)url format:(BKMeshFileFormat)format error:(NSError **)error
{
    if (format == BKMeshFileFormatUnknown) format = [self formatForPathExtension:url.pathExtension];
    NSData *data = [self dataForMesh:mesh format:format error:error];
    if (!data) return NO;
    NSError *writeError = nil;
    if (![data writeToURL:url options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = BKIOError(BKMeshErrorUnreadableFile, [NSString stringWithFormat:@"The file %@ could not be written: %@",
                                                                  url.lastPathComponent, writeError.localizedDescription]);
        return NO;
    }
    return YES;
}

@end
