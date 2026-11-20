# Hybrid calibration repairs

Implement the previously proposed startup wiring and surface-rejection diagnostics, as authorized in chat. Use the existing Swift/ARKit/OpenCV architecture. App startup requests AR; live assembly uses hybrid when supported and feature-only tracking otherwise. All three diagnostic comparison methods must construct independent trackers and honor feature options.

Expose same-frame detected-plane count and each rejected plane’s geometry error without relaxing the existing distance, extent, confidence, depth, or movement gates. Unknown world data remains unavailable, not zero detected planes. Surface guidance distinguishes waiting for detection from incomplete plane coverage.

Alternatives: widening extents or accepting an infinite plane could hide genuine depth errors; do not do either without device evidence. Retaining the Vision-only default does not implement the approved integration.

Audit adjacent calibration behavior with regressions. Reject ray intersections behind either camera; do not accept a rejected-depth view into feature-selection training. Preserve same-frame diagnostics and cancellation semantics. Validate Tracking, app tests, dependency isolation, and iPhone build; physical AR repeatability remains a device test.
