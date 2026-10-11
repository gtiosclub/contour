# Surface fallback investigation and independent tracking test

## Reproduced Surface defect

The app blocks guidance when the `PanelDetection.quad` returned by Surface is
`.fullFrame`. It does not replace valid detected corners with `.fullFrame`.
Camera capture preserves the same portrait pixels, orientation, and size as
live tracking; existing capture tests pass.

A direct `PanelDetector` probe (no camera, pipeline, or app) reproduced a fully
visible panel returning `.fullFrame` with confidence 0.6. A 900 x 600 image has
a light 400 x 270 panel at x=250, y=160, surrounded by dark background. Six dark
100 x 70 keys lie inside it. Vision found seven rectangles. The panel covers
20% of the photo, so `PanelDetector.analyze`'s `area < 0.25 && count >= 3` rule
substitutes `.fullFrame` even though the actual outer edges are visible.

Surface should fix this heuristic and validate against both cropped panels and
fully visible smaller panels. This integration change does not change detection
thresholds, candidate selection, or OCR behavior.

Reproduction: `docs/repros/SurfaceInsetPanelProbe.swift` is an intentionally
failing probe saved outside the package test target. Copy it into the Surface
package's tests, run `swift test --filter probeSmallInsetPanel`, then remove the
copy. It expects the visible outer panel to be retained. The probe also writes
its generated image to `/tmp/contour-surface-inset-panel.png`.

The separate `LiveSurfaceUnderstanding` fallback can also substitute `.fullFrame`
when a detected rectangle contains no keys but the whole image has keys. New
`SurfaceScan` logs show the initial panel quad, in-panel key count, fallback,
and final handoff. Logs distinguish these cases on the actual phone. We have
not yet confirmed which one occurs in Remy's real microwave scans.

## Manual tracking test (Debug builds, physical phone)

1. Aim the preview at the actual panel, with all its outer corners visible.
2. Tap **Manual tracking test**. This captures a fresh frame from the same camera
   used by live tracking and bypasses Surface entirely.
3. On the captured image, mark TL, TR, BR, BL, then the center of the button you
   want to reach. The displayed image is aspect-fit; marks use its full image
   coordinates rather than preview crop coordinates.
4. Tap **Use manual reference**. Return the phone to approximately the original
   framing and keep it upright.
5. Tap **Guide to manual target**. Tracking, quality assessment, finger mapping,
   and haptics run through the existing live pipeline.
6. Test finger disappearance, small phone movements, Stop/restart, and replacing
   the reference with another manual capture.

The one-button map is explicitly manual. Its target region is approximate;
this validates tracking/guidance, not real button detection, labels, metric pose,
or physical contact. No canned microwave layout is assigned to the real panel.
Vision still has to be able to register and follow the manually marked panel.
A registration failure now appears on the main screen with a retry suggestion.
The simulator remains mocked; it does not exercise this camera path.

Aditya's existing fixture-layout setup remains intact. This focused manual
capture path supplies a way to test arbitrary real panels while Surface is
being fixed; it does not replace his fixture/reference setup deliverable.

## Verification

Tracking: 63 tests passed. Surface's existing suite: 58 tests passed. App:
18 simulator tests passed, including manual target normalization, invalid-mark
rejection, and guidance with Surface deliberately configured to fail. The
synthetic Surface probe failed as expected and is retained outside CI for the
Surface owner. Physical-device interaction still needs Remy's validation.
