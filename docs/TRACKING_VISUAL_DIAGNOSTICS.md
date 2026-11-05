# Tracking visual diagnostics

Run the Debug app on an iPhone and keep it upright. Open Developer tools →
Tracking Diagnostics. With no usable reference, it shows fingertip-only detection.
With a scanned or manually prepared reference, it runs the production panel,
finger, homography, and quality pipeline.
If the combined tracker cannot use the panel, Diagnostics independently checks
the fingertip on that same displayed image. The green dot can therefore remain
visible during panel loss; it does not imply that panel mapping, target distance,
or guidance is available. The production tracker and detector are unchanged.

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
   **2D distance to target center** reports the smoothed production fingertip's
   straight-line distance to the selected target center in normalized panel
   coordinates. Zero means the center; one unit spans the panel width horizontally
   or height vertically. It is not physical depth or a distance in centimetres.
   Without a selected target or usable panel/finger result it shows **Unavailable**.
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

## Evidence and comparison controls (#94)

The **Tracking evidence** panel reads the diagnostics belonging to the displayed
image. Source, calibration mode/readiness, and supplied reason messages are shown
together. Expand calibration/recovery for sample and stable-feature counts,
baseline, resets, alignment/corner errors, and visual-verification age. Expand
feature matching for reference/frame counts, matches/inliers, coverage,
reprojection error, processing time, and highlight fractions. Missing or invalid
measurements say **Unavailable**. Hybrid fit errors use normalized image units;
feature reprojection error uses processing-image pixels. Neither is physical depth.

Source describes the returned geometry, not AR-capable hardware or readiness.
Absent source evidence stays unavailable. A sample without accepted panel geometry
cannot claim usable alignment even when its calibration remains ready. Possible
glare is a heuristic explanation, not proof that reflections were removed.

The existing tracking-method and highlight/contrast controls request Guidance-owned
settings and start a fresh independent diagnostic session with the same reference.
Camera revision changes restart that subscription too. Repeated starts of an
already-running camera retain its revision; only a new capture generation changes
it, preventing a self-triggered restart loop. Evidence publication uses monotonic
time at no more than 10 Hz, independent of capture-date jumps.

Exposure presets are **0, -0.7, -1.3 EV**. Controls are disabled while diagnostics
is stopped, an exposure request is pending, or ARKit owns exposure. Successful
requests show the actual device-clamped bias; unavailable adjustments and failures
are explicit. Camera restart/navigation clears applied-value claims and ignores
late completions. This is a comparison aid, not a glare-removal algorithm.

Scripted tests cover supplied source/readiness combinations, absent/nonfinite
evidence, glare explanations, forwarded settings, unsupported/clamped/failed
exposure, stale exposure completion, same-frame image/evidence/points, timestamp
jumps, independent replacement sessions, delayed renders, cancellation, and
capture-generation revision identity. A pre-existing shared-setup fixture was
corrected to inspect registration errors during its active stream, then assert
that terminal cleanup clears the status.

Physical-device acceptance remains:

1. Prepare one textured panel; compare Vision, features, and hybrid with the same
   reference. Check that source/readiness explain the displayed result.
2. Move sideways to calibrate, occlude texture, and restore the view. Check
   verification age, prediction/reacquisition, reset reasons, and absent evidence.
3. Compare reflective/matte panels and supported exposure presets. Verify clamped
   values and the unsupported-ARKit message; do not treat glare hints as certainty.
4. Retry capture, change reference/settings, background/foreground, and reopen
   Diagnostics. Verify fresh evidence and aligned overlays without restart loops.

## Earlier responsiveness checks

Diagnostics renders exact processed frames rather than repeatedly updating an
AVCapture preview layer. CameraPreview only sets rotation when it changes.
Detector and image-rendering work have explicit worker actors. Diagnostics no
longer stops the shared camera when leaving the screen. A thread characterization
test did not reproduce main-thread detector execution in the original path, so
that hypothesis is not claimed as the cause of the reported freeze.

Automated checks: Tracking 64 tests and the preceding generic iOS device build
passed; the fingertip diagnostic correction passed all 22 app tests. The app
tests include capture corner landmarks, independent fingertip display during
panel loss, preservation of fused observations, and diagnostic worker
isolation; the Tracking tests check that visual samples match emitted frame
timestamps and clear lost geometry. Actual phone responsiveness, overlay
alignment, and tracker accuracy still require the device checks above.
