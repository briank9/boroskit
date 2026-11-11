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

#import "CPRProjectionOperation.h"
#include <Accelerate/Accelerate.h>
#import "CPRVolumeData.h"

@implementation CPRProjectionOperation

@synthesize volumeData = _volumeData;
@synthesize generatedVolume = _generatedVolume;
@synthesize projectionMode = _projectionMode;

- (id)init
{
    if ( (self = [super init]) ) {
        _projectionMode = CPRProjectionModeNone;
    }
    return self;
}

- (void)dealloc
{
    [_volumeData release];
    _volumeData = nil;
    [_generatedVolume release];
    _generatedVolume = nil;
    [super dealloc];
}

- (void)main
{
    float *floatBytes;
    NSInteger i;
    float floati;
    NSInteger pixelsPerPlane;
	N3AffineTransform volumeTransform;
	CPRVolumeDataInlineBuffer inlineBuffer;
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    @try {
        if ([self isCancelled]) {
            return;
        }
        
		if (_projectionMode == CPRProjectionModeNone) {
			_generatedVolume = [_volumeData retain];
			return;
		}
		
		pixelsPerPlane = _volumeData.pixelsWide * _volumeData.pixelsHigh;
		floatBytes = malloc(sizeof(float) * pixelsPerPlane);
				
		if ([_volumeData aquireInlineBuffer:&inlineBuffer]) {
			memcpy(floatBytes, CPRVolumeDataFloatBytes(&inlineBuffer), sizeof(float) * pixelsPerPlane);
			switch (_projectionMode) {
				case CPRProjectionModeMIP:
					for (i = 1; i < _volumeData.pixelsDeep; i++) {
						if ([self isCancelled]) {
							break;
						}
						vDSP_vmax(floatBytes, 1, (float *)CPRVolumeDataFloatBytes(&inlineBuffer) + (i * pixelsPerPlane), 1, floatBytes, 1, pixelsPerPlane);
					}
					break;
				case CPRProjectionModeMinIP:
					for (i = 1; i < _volumeData.pixelsDeep; i++) {
						if ([self isCancelled]) {
							break;
						}					
						vDSP_vmin(floatBytes, 1, (float *)CPRVolumeDataFloatBytes(&inlineBuffer) + (i * pixelsPerPlane), 1, floatBytes, 1, pixelsPerPlane);
					}
					break;
				case CPRProjectionModeMean:
					for (i = 1; i < _volumeData.pixelsDeep; i++) {
						if ([self isCancelled]) {
							break;
						}					
						floati = i;
						vDSP_vavlin((float *)CPRVolumeDataFloatBytes(&inlineBuffer) + (i * pixelsPerPlane), 1, &floati, floatBytes, 1, pixelsPerPlane);
					}
					break;
				case CPRProjectionModeRadiograph:
				{
					// Simulated radiograph, like a panoramic X-ray (OPG) through the slab.
					// CT values (HU) are converted to linear attenuation coefficients,
					//     mu = muWater * (1 + HU/1000)   (HU below -1000 are treated as air),
					// integrated along the slab depth, and passed through Beer-Lambert absorption,
					//     absorbed = 1 - exp(-sum(mu * ds)).
					// The result is mapped to an HU-like scale (-1000 = no absorption, 3000 = full absorption)
					// so the window/level shared with the MPR views keeps working.
					const float muWater = 0.0195f; // 1/mm, water at typical dental X-ray energies (~70 keV)
					CGFloat m33 = _volumeData.volumeTransform.m33; // the slab volume transform scales z by 1/sampleDistance
					float sampleDistance = (m33 != 0.0) ? (float)(1.0 / fabs(m33)) : 1.0f; // mm between slab samples
					// Overall absorption strength (1.0 = physical water attenuation). Lower values give a darker, less
					// saturated image; tunable with: defaults write org.horosproject.horos CPRRadiographStrength -float 0.6
					float strength = 0.75f;
					if ([[NSUserDefaults standardUserDefaults] objectForKey:@"CPRRadiographStrength"]) {
						strength = [[NSUserDefaults standardUserDefaults] floatForKey:@"CPRRadiographStrength"];
						if (strength <= 0.0f) strength = 0.75f;
					}
					float k = strength * muWater / 1000.0f * sampleDistance; // (HU + 1000) * k = mu * ds (scaled)
					float airHU = -1000.0f, plus1000 = 1000.0f;
					float *slice = malloc(sizeof(float) * pixelsPerPlane);
					
					if (slice) {
						vDSP_vclr(floatBytes, 1, pixelsPerPlane); // floatBytes accumulates sum(mu * ds)
						for (i = 0; i < _volumeData.pixelsDeep; i++) {
							if ([self isCancelled]) {
								break;
							}
							vDSP_vthr((float *)CPRVolumeDataFloatBytes(&inlineBuffer) + (i * pixelsPerPlane), 1, &airHU, slice, 1, pixelsPerPlane); // clamp below air
							vDSP_vsadd(slice, 1, &plus1000, slice, 1, pixelsPerPlane);
							vDSP_vsma(slice, 1, &k, floatBytes, 1, floatBytes, 1, pixelsPerPlane); // sum += (HU + 1000) * k
						}
						free(slice);
						
						int n = (int)pixelsPerPlane;
						float minus4000 = -4000.0f, plus3000 = 3000.0f;
						vDSP_vneg(floatBytes, 1, floatBytes, 1, pixelsPerPlane);
						vvexpf(floatBytes, floatBytes, &n); // transmitted fraction exp(-sum)
						vDSP_vsmsa(floatBytes, 1, &minus4000, &plus3000, floatBytes, 1, pixelsPerPlane); // -1000 + 4000 * (1 - transmitted)
					}
					break;
				}
				default:
					break;
			}
		}
		[_volumeData releaseInlineBuffer:&inlineBuffer];
        
		volumeTransform = N3AffineTransformConcat(_volumeData.volumeTransform, N3AffineTransformMakeScale(1.0, 1.0, 1.0/(CGFloat)_volumeData.pixelsDeep));
        _generatedVolume = [[CPRVolumeData alloc] initWithFloatBytesNoCopy:floatBytes pixelsWide:_volumeData.pixelsWide pixelsHigh:_volumeData.pixelsHigh pixelsDeep:1
                                                           volumeTransform:volumeTransform outOfBoundsValue:_volumeData.outOfBoundsValue freeWhenDone:YES];
    }
    @catch (...) {
    }
    @finally {
        [pool release];
    }
}

@end





