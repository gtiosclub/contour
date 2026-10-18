# OpenCV feature matching backend (Visual tracking 1, #81)

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
| `cft_register_reference` | Grayscale reference + TL/TR/BR/BL quad → ORB features inside the quad. Replaces any previous reference; failure leaves it unregistered. |
| `cft_match_frame` | One live frame → `CFT_STATUS_OK` with corners and evidence, or `CFT_STATUS_LOST` with a loss reason and zeroed corners. |
| `cft_copy_inlier_points` / `cft_copy_inlier_feature_ids` | Evidence of the most recent attempt only (live points, stable reference IDs). |
| `cft_set_active_features` / `cft_restore_all_features` | Hooks for #84: restrict matching to original feature IDs, or restore all. |
| `cft_reset` | Drop the reference. |

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
5. Corners are projected by hand: every corner needs homogeneous w > 0 (in front
   of the camera), the quad must be strictly convex with the reference's winding
   (not folded or mirrored), and its area must be 0.5%–400% of the frame.
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
| Padded rows | same result as tight rows |
| Null/short-stride/out-of-range buffers, NaN/folded/outside corners, blank panel | explicit error, no evidence |

## Known limits

- Synthetic images only. Real glare, blur, low light and printed-label panels
  need recorded fixtures (with #83/#101).
- The w > 0 and mirrored-quad guards are not reachable with the synthetic
  warps; they are reviewed but not exercised by a test.
- Frames are not downscaled here. #82 decides processing size; at full camera
  resolution ORB cost grows roughly with pixel count.
- OpenCV is a prebuilt binary (~670 MB unpacked xcframework, all platforms);
  first resolve downloads it. Only the slices for the built platform are linked.

## Dependency

`yeatse/opencv-spm` pinned `exact: "4.13.0"` (Apache 2.0, notices in
`Packages/Tracking/THIRD_PARTY_NOTICES.md`). `Scripts/check-dependencies.sh`
allows that one exact-pinned remote for Tracking and fails if OpenCV is included
outside the matcher's `.cpp` or imported from Swift anywhere.
