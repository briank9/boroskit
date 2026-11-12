// BorosKitMesh: BKMeshIO
//
// What it is: reading and writing mesh files in the three formats used in dentistry
// and surgical planning:
//   - STL: the 3D-printing standard (implant guides, models). Triangles only, no
//     colour. Read: binary and text ("ASCII") STL. Write: binary STL.
//   - PLY: common for intraoral scanners because it can carry a colour per vertex.
//     Read and write: text (ASCII) and binary little-endian (binary big-endian is
//     read too). Vertex normals and colours are kept.
//   - OBJ: a general text format. Read: vertices (v, optionally followed by an RGB
//     colour, a common extension), normals (vn) and faces (f) including polygons
//     with more than 3 corners, which are split into triangles. Write: v / vn / f.
//
// Why: Boros must open bone surfaces, intraoral scans and implant models from other
// software, and export guides for printing, without VTK.
//
// Safety: files may be damaged or not what their name says. Every reader checks every
// count and number against the real file size and returns nil + an NSError
// (BKMeshErrorDomain) with a plain-language message instead of crashing.

#import <Foundation/Foundation.h>
#import "BKMesh.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BKMeshFileFormat) {
    BKMeshFileFormatUnknown = 0,  // reading: detect from the content
    BKMeshFileFormatSTL,          // binary STL (reading also accepts ASCII STL)
    BKMeshFileFormatPLY,          // binary little-endian PLY (reading accepts all PLY kinds)
    BKMeshFileFormatPLYASCII,     // text PLY (only differs from BKMeshFileFormatPLY when writing)
    BKMeshFileFormatOBJ,          // Wavefront OBJ (text)
};

@interface BKMeshIO : NSObject

// The format a file name suggests (.stl, .ply, .obj; case-insensitive), or Unknown.
+ (BKMeshFileFormat)formatForPathExtension:(NSString *)extension;

// The format the bytes look like (PLY starts with "ply", OBJ/STL are recognised by
// their content), or Unknown. Why: files are often misnamed.
+ (BKMeshFileFormat)detectFormatOfData:(NSData *)data;

// Reads a mesh from a file. The format is detected from the content (falling back to
// the file extension). STL meshes come back welded (exactly repeated corners merged,
// see -[BKMesh weldVerticesWithTolerance:]) so they are ready for the closed-surface
// check. The mesh's name is set to the file name without extension.
+ (nullable BKMesh *)readMeshFromURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

// Reads a mesh from bytes in memory. `format` Unknown = detect.
+ (nullable BKMesh *)readMeshFromData:(NSData *)data
                               format:(BKMeshFileFormat)format
                                error:(NSError * _Nullable * _Nullable)error;

// Encodes a mesh in the given format (Unknown is an error).
// STL: triangle directions are written from the triangle corners; colours/normals
// are not stored (STL cannot hold them). OBJ: colours are written after each vertex
// as "v x y z r g b" (alpha is lost). PLY: colours are stored as 0..255 per channel.
// Numbers are written with enough digits that reading them back gives exactly the
// same 32-bit values.
+ (nullable NSData *)dataForMesh:(BKMesh *)mesh
                          format:(BKMeshFileFormat)format
                           error:(NSError * _Nullable * _Nullable)error;

// Writes a mesh to a file (atomically). `format` Unknown = use the file extension
// (.ply is written as binary PLY).
+ (BOOL)writeMesh:(BKMesh *)mesh
            toURL:(NSURL *)url
           format:(BKMeshFileFormat)format
            error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
