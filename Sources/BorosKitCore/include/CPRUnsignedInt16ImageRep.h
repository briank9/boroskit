/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

// BorosKit: Cocoa replaced by Foundation + CoreGraphics so this engine file
// builds on both macOS and iOS (no AppKit dependency).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "N3Geometry.h"

// BorosKit: this used to subclass NSImageRep (AppKit, macOS only) although it was
// never drawn (its -draw method just asserted). It is now a plain NSObject that
// holds a 16-bit pixel buffer plus its geometry, so it works on macOS and iOS.
// pixelsWide/pixelsHigh, previously inherited from NSImageRep, are declared here.
@interface CPRUnsignedInt16ImageRep : NSObject {
    uint16_t *_unsignedInt16Data;
    NSUInteger _pixelsWide;
    NSUInteger _pixelsHigh;
    
    CGFloat _offset;
    CGFloat _slope;
    
    CGFloat _windowWidth;
    CGFloat _windowLevel;
    CGFloat _pixelSpacingX;
    CGFloat _pixelSpacingY;
    CGFloat _sliceThickness;
    
    N3AffineTransform _imageToDicomTransform;
    
    BOOL _freeWhenDone;
}

@property (nonatomic, readwrite, assign) CGFloat windowWidth; // display hints kept for compatibility; the engine itself never draws
@property (nonatomic, readwrite, assign) CGFloat windowLevel;


- (id)initWithData:(uint16_t *)data pixelsWide:(NSUInteger)pixelsWide pixelsHigh:(NSUInteger)pixelsHigh;

- (uint16_t *)unsignedInt16Data;
@property (nonatomic, readonly) NSUInteger pixelsWide; // BorosKit: was inherited from NSImageRep
@property (nonatomic, readonly) NSUInteger pixelsHigh; // BorosKit: was inherited from NSImageRep
@property (nonatomic, readwrite, assign) CGFloat offset;
@property (nonatomic, readwrite, assign) CGFloat slope;
@property (nonatomic, readwrite, assign) CGFloat pixelSpacingX;
@property (nonatomic, readwrite, assign) CGFloat pixelSpacingY;
@property (nonatomic, readwrite, assign) CGFloat sliceThickness;

@property (nonatomic, readwrite, assign) N3AffineTransform imageToDicomTransform;

@end

@interface CPRUnsignedInt16ImageRep (Orientation) // BorosKit: renamed; it never used DCMPix

- (void)getOrientation:(float[6])orientation;
- (void)getOrientationDouble:(double[6])orientation;

@property (readonly) float originX;
@property (readonly) float originY;
@property (readonly) float originZ;

@end


