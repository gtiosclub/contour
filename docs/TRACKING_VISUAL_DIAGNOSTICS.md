# Tracking visual diagnostics

Run the Debug app on an iPhone and keep it upright. Open Developer tools →
Tracking Diagnostics. With no usable reference, it shows fingertip-only detection.
With a scanned or manually prepared reference, it runs the production panel,
finger, homography, and quality pipeline.

To bypass the Surface detector:

1. Tap **Capture manual panel and target**.
2. Mark the actual panel's top-left, top-right, bottom-right, and bottom-left
   corners, then the target center. Use a panel with visible texture/controls.
3. Use the reference. Yellow outlines the tracked panel, cyan outlines mapped
   controls, orange marks the selected target, and green marks the detected finger.
4. Move the phone slightly. The outline and target should stay attached to the
   physical panel. Point near the target and watch normalized finger coordinates
   approach its location. Quality/confidence and capture-to-display age help
   distinguish a usable lock from stale or unreliable results.
5. Remove the hand or hide the panel. Unusable results should disappear; an old
   dot or outline must not remain frozen. Leave/reopen Diagnostics and background/
   foreground the app to check responsiveness and subscription recovery.
6. Return to the pipeline and guide to the manual target to test guidance/haptics.

The manual target is a small approximate region around the marked point, not
automatic button recognition. The Advanced fixture option is appropriate only
for the supplied six-button layout.

The main pipeline preview now displays the full capture with black bars where
needed. After a scan, expand **Review exact capture** to inspect the actual photo
with the registered panel and returned controls/labels. A full-image Surface
fallback remains visible here, and still cannot start live guidance. This view
helps identify unwanted detections without changing the Surface algorithm.

The former **Enter LiveCameraView** link is now **Camera and speech prototype**.
That is the separate Experience prototype, not a prerequisite for the integrated
scan/guide flow.

## Responsiveness changes and verification limits

Diagnostics renders exact processed frames rather than repeatedly updating an
AVCapture preview layer. CameraPreview only sets rotation when it changes.
Detector and image-rendering work have explicit worker actors. Diagnostics no
longer stops the shared camera when leaving the screen. A thread characterization
test did not reproduce main-thread detector execution in the original path, so
that hypothesis is not claimed as the cause of the reported freeze.

Automated checks: Tracking 64 tests, app 20 tests, and generic iOS device build
passed. The app tests include capture corner landmarks and diagnostic worker
isolation; the Tracking tests check that visual samples match emitted frame
timestamps and clear lost geometry. Actual phone responsiveness, overlay
alignment, and tracker accuracy still require the device checks above.
