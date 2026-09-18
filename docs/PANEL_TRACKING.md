# Panel handoff and continuous tracking

## Implemented contract

1. App retains a `PanelPhoto`, including its stable capture ID and orientation.
2. Surface Understanding implements `detectPanel(from:) -> PanelDetection`.
   It returns the same photo ID, an image-space `PanelQuad`, and a `SurfaceMap`
   whose button bounds were normalized against exactly that quad.
3. App constructs `PanelReference(photo:detection:)`. Mismatched IDs throw,
   including during decoding. The pipeline retains this reference and returns
   its map to target selection.
4. Tracking's `PanelTracker.startTracking(_ reference: PanelReference)` now takes
   the full initialization rather than a layout alone. Its body remains a stub.

`ImagePoint` and `PanelQuad` belong to ContourCore. `CameraFrame` remains the
Apple-platform input adapter in Tracking. Core imports no camera framework.
The old SurfaceUnderstanding-local PanelQuad and Tracking-local ImagePoint are
removed. This is a draft-contract migration; conformers now implement
`detectPanel(from:)`, not `surfaceMap(from:)`. Mocks echo the input photo identity
and provide configurable synthetic corners; they do not analyze image pixels.

Corners refer to the full upright, unmirrored reference image BEFORE panel
rectification, not the preview crop. Their semantic identities are panel
TL/TR/BR/BL, corresponding to (0,0)/(1,0)/(1,1)/(0,1). Preserve identities while
tracking. Normalize using oriented image dimensions (swap width/height for a
quarter-turn), and convert Vision's y-up coordinates at the package boundary.

The app does not yet call the unimplemented live tracker. The debug frame
processor and production mock guidance remain separate. A reference identity
check catches mismatched captures, not an incorrectly detected quad or map.

## What continuous tracking actually needs

- **Initialization:** Decode/orient the reference pixels and seed the tracker
  from its quad. A live frame must not be substituted for the older reference
  without alignment: still detection takes time and the phone may have moved.
- **State across frames:** Keep one stateful TrackRectangleRequest per session. Process
  frames serially; reuse the request for subsequent frames. The
  current camera stream drops old waiting frames, so evaluate tolerance to gaps.
- **Panel motion estimate:** Return a current-image quad with frame timestamp and
  quality. Preserve the reference corner identities. Keep this 2D diagnostic
  output distinct from metric `PanelPose`.
- **Geometry checks:** Reject degenerate/crossed quads, implausible jumps and poor
  confidence; calibrate thresholds against fixtures rather than inventing certainty.
- **Finger alignment:** Use the panel estimate for the same frame as the finger.
  An image-to-panel homography then maps the fingertip into the map's unit square.
  A hovering finger can still have parallax error; this does not measure contact.
- **Loss and restart:** Do not draw stale geometry as current. Initially stop and
  ask for a new reference on loss. Automatic reacquisition is a later feature.
- **Session lifecycle:** Cancel work, reset state when the reference changes, and
  let the app own capture lifetime. LiveTrackingSource fusion remains future work.

## First approach to investigate

Apple provides **TrackRectangleRequest**, a Swift-native stateful request available
from iOS 18 (supported by our iOS 26 minimum). Initialize it with a
RectangleObservation made from the shared quad and perform requests sequentially
on the reference and subsequent images. Retain the same request for the sequence;
create a fresh one when resetting. Its optional RectangleObservation result
contains four corners and confidence. No second detector is necessary.

This replaces the older VNTrackRectangleRequest/VNSequenceRequestHandler recipe
in our task drafts. A newer interface is not proof of a more accurate algorithm;
validate it on the actual panel fixtures before committing to it.

Alternative: VNHomographicImageRegistrationRequest estimates a perspective warp
between two images. Its warp direction and image-coordinate basis must be
verified before transforming corners. Whole-image alignment can follow the
background rather than the panel; cropping/masking introduces another coordinate
transform. Use it only if rectangle tracking proves insufficient.

## Recommended smaller assignment

See [Track a known panel between two fixture images](issues/panel-tracking.md).
This proves initialization and one update before adding a live frame loop,
reacquisition, or fingertip fusion. Keep the image fixtures and known corners
repeatable, and inspect the overlay on the actual second image.

## Sources

- [Apple: TrackRectangleRequest](https://developer.apple.com/documentation/vision/trackrectanglerequest)
- [Apple: VNHomographicImageRegistrationRequest](https://developer.apple.com/documentation/vision/vnhomographicimageregistrationrequest)

The installed iOS 26 Vision Swift interface confirms iOS 18 availability,
RectangleObservation initialization from corners, and the stateful request API.
