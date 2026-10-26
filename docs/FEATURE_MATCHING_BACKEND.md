# OpenCV feature tracking (Visual tracking, #81–#84)

`Packages/Tracking/Sources/ContourFeatureMatcher` locates the registered panel
in a live grayscale frame by matching labels and texture, not the outer
rectangle, so a covered corner or target does not warp the result. Swift image
preparation and normalized coordinates are #82; glare filtering is #83; choosing
persistent features is #84.

## Interface

A C header, `ContourFeatureMatcher.h`. Nothing OpenCV-typed crosses it, and
neither Swift nor ContourCore sees OpenCV. Coordinates are processing-image
pixels of the buffer passed in (x right, y down).

| Call | Purpose |
|---|---|
| `cft_create` / `cft_destroy` | Own one tracker. `NULL` config = starting values below. |
| `cft_register_reference` | Grayscale reference + TL/TR/BR/BL quad → ORB features inside the quad. Replaces any previous reference; any failure, including bad arguments, leaves it unregistered. |
| `cft_match_frame` | One live frame → `CFT_STATUS_OK` with corners and evidence, or `CFT_STATUS_LOST` with a loss reason and zeroed corners. |
| `cft_copy_inlier_points` / `cft_copy_inlier_feature_ids` | Evidence of the most recent attempt only (live points, stable reference IDs). |
| `cft_set_active_features` / `cft_restore_all_features` | Hooks for #84: restrict matching to original feature IDs, or restore all. |
| `cft_reset` | Drop the reference. |
| `cft_observe_calibration_view` / `cft_finish_calibration` / `cft_reset_calibration` | Persistent-feature selection (#84), forwarded by the Swift wrapper. |
| `cft_calibration_view_count` / `cft_copy_active_feature_ids` / `cft_copy_reference_feature_points` | Selection state, for tests and diagnostics overlays. |

Lifecycle rules the wrapper can rely on:

- Each frame is matched against the **original** reference descriptors. Live
  frames never update the reference, so recovery after coverage is always
  against the clean registration. Original IDs and descriptors are immutable.
- A lost frame never carries corners; confidence is 0. Errors
  (`INVALID_BUFFER`, `NOT_REGISTERED`, …) carry no evidence at all.
- Every match, registration, subset change and reset clears the previous
  inlier evidence.
- Buffers are borrowed for the call only. Width/height must be within
  32…4096 and `bytesPerRow >= width`; the caller vouches for the length.
- All entry points catch C++ exceptions (`CFT_STATUS_INTERNAL_ERROR`). A
  tracker is not thread-safe; the #82 actor serializes calls.

## Pipeline and starting values

1. ORB: 1,800 features, 8 pyramid levels, FAST threshold 12. Registration needs
   at least 40 features inside the marked quad.
2. Live → reference 2-NN matching: Hamming ≤ 64, best/second < 0.75, then a
   mutual (cross) check. The ratio test drops features that look like two
   reference features (repeated identical buttons); the mutual check stops one
   repeated pattern from voting many times.
3. RANSAC homography at 2.5 px, then inliers are recounted against the final
   refined model so corners, inliers and error describe the same fit.
4. Accept only with ≥ 20 inliers, inlier ratio ≥ 0.45, and inlier hull covering
   ≥ 12% of the reference panel.
5. Corners are projected by hand. The homography's overall sign is arbitrary, so
   the homogeneous w must have one sign at all four corners and stay clear of
   zero; a sign change means part of the panel maps through the horizon. The
   quad must also be strictly convex with the reference's winding (not folded
   or mirrored), and its area must be 0.5%–400% of the frame.
6. Evidence score: `clamp(0.4 + 0.2·ratio + 0.2·min(1, coverage/0.5) +
   0.15·min(1, inliers/80), 0, 0.95)`. A heuristic, not a probability.

All values come from #81 unchanged and live in `CFTConfig`. They are tuned only
against synthetic cases so far; real microwave recordings may move them.

## Evidence from the tests

`FeatureMatcherBackendTests` builds label-like synthetic panels and warps them
with known homographies (debug build, M-series Mac, 640×480):

| Case | Result |
|---|---|
| Perspective view | tracked, corners within 3 px, ~266/300 inliers, ~11 ms |
| Top-left corner and middle covered | tracked, all four corners within 4 px |
| Panel ~90% covered, then unrelated scene, then clean | lost, lost, recovered within 3 px |
| Unrelated scenes (3 seeds) | lost: too few inliers |
| One reference control tiled across the frame | lost: too few unambiguous matches |
| Panel of identical repeated buttons | lost: too few unambiguous matches |
| All corner w negative (panel far from the reference origin) | tracked, corners within 3 px |
| Padded rows | same result as tight rows |
| Null/short-stride/out-of-range buffers, NaN/folded/outside corners, blank panel | explicit error, no evidence |
| Failed replacement registration (null corners, blank panel) | previous reference and evidence dropped |

## Known limits

- Synthetic images only. Real glare, blur, low light and printed-label panels
  need recorded fixtures (with #83/#101).
- The w sign-change and mirrored-quad rejections are not reachable with the
  synthetic warps; they are reviewed but not exercised by a test.
- Frames are not downscaled here. #82 decides processing size; at full camera
  resolution ORB cost grows roughly with pixel count.
- OpenCV is a prebuilt binary (~670 MB unpacked xcframework, all platforms);
  first resolve downloads it. Only the slices for the built platform are linked.

## Dependency

`yeatse/opencv-spm` pinned `exact: "4.13.0"` (Apache 2.0, notices in
`Packages/Tracking/THIRD_PARTY_NOTICES.md`). `Scripts/check-dependencies.sh`
allows that one exact-pinned remote for Tracking and fails if OpenCV is included
outside the matcher's `.cpp` or imported from Swift anywhere.

## Swift wrapper: `FeaturePanelTracker` (#82)

`Packages/Tracking/Sources/Tracking/FeaturePanelTracker.swift` is an actor
conforming to `CalibratablePanelTracking`, so it drops into
`LiveTrackingSource(camera:panelTracker:)` in place of the Vision `PanelTracker`.
Building the production factory is integration's job (#96).

- **Reference.** The photo's raw pixels are decoded, turned upright with
  `PanelPhoto.orientation`, converted to grayscale and downsampled; the
  normalized reference quad is converted to backend pixels and registered.
- **Frames.** Each `CameraFrame` is turned upright with its `orientation`,
  converted and downsampled the same way, then matched. Corners and inlier
  points come back as normalized upright `ImagePoint`s with TL/TR/BR/BL kept.
  Normalized 0 and 1 are the outer pixel edges, so downsampling doesn't move them.
- **Processing size.** Longest side ≤ 640 px (`maximumDimension`), aspect ratio
  preserved, Lanczos downsampling. Preparation runs off the actor.
- **Observations.** The capture timestamp is kept. A loss carries no quad and
  confidence 0, but does carry `FeatureTrackingDiagnostics`. Backend loss
  reasons map onto the shared `LossReason`: too few features, matches or inliers,
  or no homography → `notFound`; low inlier ratio or coverage → `lowConfidence`;
  bad projected shape or size → `invalidGeometry`; backend errors →
  `trackerFailed`. The exact reason is in the diagnostics `message`.
  `processingMilliseconds` covers preparation and matching together.
- **Lifecycle.** `startTracking` drops the old reference first, so any failure
  (`invalidReferenceQuad`, `unreadableReferencePhoto`, `registrationFailed`)
  leaves nothing registered. This differs from the Vision tracker, which keeps
  its old session when a new quad is invalid. A start or stop while a frame
  or reference is being prepared makes that call throw `superseded`, and its
  result is never used. Each registration gets a fresh backend, so old
  calibration state can't leak into a new reference.
- **Calibration.** `observeCalibrationView`, `finishCalibration` and
  `resetCalibration` are forwarded to the backend. The hybrid coordinator decides
  which views count.

Measured on an M-series Mac, a 1920×1440 BGRA frame takes 11–14 ms from
preparation to observation (debug and release builds are similar). Device
timing still needs measuring.

`FeaturePanelTrackerTests` covers upright and rotated camera frames (all four
orientations), rotated reference photos, camera-resolution inputs, corner and
target coverage, loss and recovery, registration failures, stop or replacement
during preparation, calibration forwarding, and injection into
`LiveTrackingSource` with a plain 2D camera and no AR.

## Glare and contrast (#83)

Before ORB extraction, the reference and every frame go through the same
preparation, controlled by `FeatureTrackingOptions` (defaults unchanged:
highlight exclusion on, contrast normalization off). The Swift wrapper copies
the options into `CFTConfig`.

1. **Clipped pixels** are those ≥ 250 in the raw grayscale image. Their share of
   the image is always reported (`saturatedFraction`), even when the frame is lost.
2. **Glare regions** are 8-connected clipped regions of ≥ 256 px that fill
   ≥ 70% of their bounding box and cover ≤ 25% of the image. Their share is
   `excludedHighlightFraction`.
3. **Contrast** (optional): CLAHE with an 8×8 grid and clip limit 2. It runs
   after steps 1–2, so enhancement never changes what counts as clipped.
4. **Features** whose descriptor support touches a glare pixel are dropped
   (`excludedFeatures`). An ORB descriptor samples a rotated 31×31 patch at its
   pyramid scale (`keypoint.size` = 31 × scale), so the check uses a disc of
   radius 0.75 × size around each keypoint. That disc covers the patch at any
   rotation plus ORB's smoothing margin. Matching and the geometry checks are
   unchanged.

**Changed from the issue's starting values:** the bounding-box fill threshold is
0.7, not 0.8. A disc fills π/4 ≈ 78.5% of its box (an axis-aligned ellipse
too), so at 0.8 round specular hotspots never qualified. Rectangles, discs and
ellipses qualify at 0.7; hollow outlines and sparse shapes still don't.

**What it does not do:**
- It doesn't remove reflections. Darker reflections that aren't clipped aren't
  detected at all.
- White controls or white label areas that clip are excluded like glare. The
  synthetic panel has a few, which drops about 10% of its reference features.
- Camera exposure and asking the user to reposition belong outside this backend.

Measured effect on the synthetic fixtures:

| Case | Highlight exclusion on | Off |
|---|---|---|
| Clean view | tracked, 241 inliers (160 reference features excluded as white controls) | tracked, 266 inliers |
| Rectangle and round hotspot on the panel | tracked, 565 frame features dropped, no inlier within 23 px of glare | tracked |
| Hotspot in the reference, a different one in the frame | tracked | tracked |
| Panel mostly washed out (43% of frame clipped) | lost (too few inliers), saturation reported, nothing excluded (region too large) | lost |

In these synthetic cases flat clipped patches don't create false matches, so
exclusion doesn't change whether tracking succeeds; it removes features at
glare boundaries. The case it targets, glare features that shift between views
on a real glossy panel, needs recorded fixtures to measure.

With contrast squeezed into 20 grey levels across the whole scene, registration
fails honestly (too few features) without CLAHE and tracks within 3 px with it.

`FeatureImagePreparationTests` covers clipped patches (excluded area, reported
fractions, inlier distance from glare), disabled filtering, which regions
qualify (lettering, ring, white surface, 249-level patch), contrast leaving the
glare mask unchanged, low contrast, washout, glare in the reference, and invalid
settings. `FeaturePanelTrackerTests` checks the options and diagnostics through
the Swift tracker.

## Persistent features (#84)

After calibration the matcher can prefer original reference features that kept
matching across several accepted views. Printed labels and fixed controls tend
to persist; a hand, or a reflection that moves with the camera, doesn't.
Persistence alone doesn't prove a feature is reflection-free.

- **Observe.** `cft_observe_calibration_view` / `observeCalibrationView()`
  counts the inliers of the latest match as one accepted view. Each original
  feature counts at most once per view. It counts nothing unless that match was
  tracked, and repeating the call for the same match doesn't count twice.
  Processing a frame never counts by itself: the hybrid coordinator decides,
  from camera movement and geometry, which views are accepted.
- **Finish.** `cft_finish_calibration` / `finishCalibration()` needs ≥ 8 accepted
  views. It keeps originals that were inliers in ≥ 60% of them (rounded up, so
  5 of 8) and at least 4 times. The subset is activated only if it has ≥ 40
  features whose convex hull covers ≥ 12% of the reference panel. Otherwise it
  returns -1 / `nil` and every original feature is used.
- **Matching** with a subset still uses the original descriptors and IDs.
  Nothing is learned from live frames.
- **Reset** clears the counts and restores every original feature, so
  calibration can be tried again. Registering a new reference discards all
  selection state (the Swift wrapper creates a fresh backend).

Values are the issue's starting values, unchanged, and live in `CFTConfig`.

**Tradeoff to watch:** the subset is small. On the synthetic panel each view
has ~240 inliers out of ~1,340 reference features, and only 145–175 features
are inliers in 5 of 8 slightly different views. With a small transient patch
(like a moving reflection) hidden in 5 of 8 views, the subset excludes that
patch and tracks clean and partly covered views within ~1.1 px (full set:
~0.5 px). If a third of the panel is hidden in most calibration views, the
subset covers only the rest, and extrapolated corners drift to 3–5 px. The
coverage guard prevents worse cases but not this one. Real calibration sweeps
should be checked for this before the subset is relied on.

`FeatureSelectionTests` covers transient and persistent selection, subset
tracking with unchanged descriptors and IDs, unaccepted, lost and repeated
observations, too few views, count and coverage rejection (including a
naturally persistent small cluster), reset, and replacement.
`FeaturePanelTrackerTests` repeats the end-to-end flow through the Swift actor.

