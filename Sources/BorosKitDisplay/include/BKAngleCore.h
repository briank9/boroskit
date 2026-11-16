// BorosKitDisplay: BKAngleCore - geometry of the arc that marks a measured angle (angle ROIs), plain C99.
// First piece of the licence-free ROI core (overlay-engine plan, 2026-11-16; user request: "add curved
// line like in the ROI icon to indicate the angle that is being measured").
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 on BKVec2f (no Objective-C, Apple, LGPL types),
//   deterministic, no allocation. The caller draws the returned points as a line (overlay engine).
// - Units: whatever 2D units the caller uses (view pixels in Boros 6); y may point up or down.
//
// Plain language: an angle ROI has a corner and two arms; the arc is a short curved line from one arm
// to the other around the corner, on the side of the angle whose value is shown, like the angle icon.
// The dynamic angle has two separate lines: its corner is where the lines (or their extensions) cross,
// and its arc spans the acute angle between them (the value it shows, 0..90 degrees).

#ifndef BK_ANGLE_CORE_H
#define BK_ANGLE_CORE_H

#include "BKVec.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: points of the arc of radius `radius` around `vertex`, from the ray towards `towardA` to the ray
// towards `towardB`, going the SHORTER way (the angle below 180 degrees). Points are about `maxStep`
// apart along the arc (at least 3 points). Returns how many were written (0: a ray of zero length,
// radius <= 0, or maxOut < 3).
uint32_t BKAngleArcPoints(BKVec2f vertex, BKVec2f towardA, BKVec2f towardB, float radius, float maxStep,
                          BKVec2f *out, uint32_t maxOut);

// What: the arc radius for arms of lengths armA and armB: `preferred`, but never more than 40 % of the
// shorter arm (so the arc stays inside the angle on short arms). 0 for an arm of zero length.
float BKAngleArcRadius(float armA, float armB, float preferred);

// What: where the infinite lines through (a1, a2) and (b1, b2) cross. Returns 0 (and leaves *cross
// unchanged) when they are parallel or a line has zero length.
int BKAngleLineCrossing(BKVec2f a1, BKVec2f a2, BKVec2f b1, BKVec2f b2, BKVec2f *cross);

// What: the corner and the two ray directions of a dynamic angle (segments a1-a2 and b1-b2): the corner
// is where the lines cross; each ray points from the corner towards its segment's far end (the end
// farther from the corner), and if the two rays then make more than 90 degrees, the second ray is turned
// around, so the arc spans the acute angle (the value the dynamic angle shows). The outputs are points
// on the rays (corner + unit direction). Returns 0 when the lines are parallel.
int BKDynamicAngleCorner(BKVec2f a1, BKVec2f a2, BKVec2f b1, BKVec2f b2,
                         BKVec2f *corner, BKVec2f *towardA, BKVec2f *towardB);

#ifdef __cplusplus
}
#endif

#endif
