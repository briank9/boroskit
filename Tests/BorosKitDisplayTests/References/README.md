# ROI reference values (recorded, not copied)

`roi-reference-2026-11-16.json` was written by Boros 6's debug recorder (`BorosROIRecorder.m`, user default
`BorosRecordROIReferencePath`) running the OLD Horos ROI code (ROI.m / DCMPix.m) on a synthetic 64 x 48
float image (value = 7.25 x + 1.5 y + 100 sinf(0.37 x) cosf(0.21 y) - 300, pixel size 0.5 x 0.7 mm,
origin -12.5, 30.25, 100) with 18 ROIs of every kind. For each ROI: points / rect, roiArea (cm2),
centroid, spline points, lengths (mm, px), angle, computeROI mean / total / SD / min / max, the pixels
inside (getROIValue locations + values), isInROI hits on a probe grid. Non-finite numbers are written as
"nan" / "inf". These are the exact expectations of the licence-free BorosKit ROI core (BKROICore) -
behaviour recorded, no code copied. clickInROI was not recordable without a live view (empty).
