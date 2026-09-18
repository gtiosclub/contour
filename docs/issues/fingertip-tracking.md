# Track the index fingertip and display diagnostics

**Lane:** Fingertip & Frame Math (Babitha)

**Goal:** Locate the index fingertip in live frames using Vision's modern
`DetectHumanHandPoseRequest` API.

## Tasks
- Implement `TrackingFrameProcessor` using the existing shared camera input.
- Return normalized `ImagePoint` coordinates, confidence, and the original frame
  timestamp. Handle orientation and convert Vision coordinates to Core's
  top-left origin with y increasing downward.
- Log position/confidence at a readable rate (for example, twice per second).
- Inject the processor into `TrackingDebugModel` and use the existing overlay.
  Return `notDetected` with a nil fingertip when no usable point exists.

**Done when:** On a physical device, the dot follows a pointing finger, aligns
near preview edges despite cropping, and disappears when the hand leaves view.

**Out of scope:** Panel-coordinate conversion, gesture recognition, and 3D pose.
The current camera scaffold uses portrait capture; test upright. Debug UI stays
in ContourApp, while the detector stays in Tracking.
