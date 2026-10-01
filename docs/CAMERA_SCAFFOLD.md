# Camera and tracking development scaffold

The app owns one `CameraService` (currently stored by its root ContentView).
UI owns capture/preview; Tracking owns frame analysis. The app's debug screen
connects them. ContourCore now defines the reference handoff described in PANEL_TRACKING.md.

```
CameraService ── session ── CameraPreview
      │
      └─ CameraFrameSource → TrackingFrameProcessor → TrackingDiagnostics
                                                         │
                                              TrackingDebugModel
                                                         │
                                              TrackingDebugView
```

## Run

Run ContourApp's Debug configuration on an iPhone, open **Developer tools →
Tracking Diagnostics**, and allow camera access. Frames processed should increase.
The default `FingertipFrameProcessor` runs Vision index-fingertip detection.
The overlay shows a usable fingertip and clears on missing or low-confidence
detections. Position/confidence diagnostics are logged at most twice per second.
Release builds have no developer navigation. The original mock pipeline remains available.

The scaffold uses a fixed portrait camera basis. Keep the phone upright for
initial experiments; coordinated physical rotation remains a UI task.

## Boundaries

- `ContourApp/Camera/CameraService.swift`: rear camera permission, serial capture
  queue, newest-frame delivery per subscriber, explicit start/stop. Stopping
  finishes all streams. Cancelling one subscriber leaves the camera running.
- `CameraPreview.swift`: preview and image-coordinate overlay conversion.
- `ContourApp/Debug`: observable result model and debug-only screen. Tracking can
  maintain these app-level diagnostics without putting SwiftUI in Tracking.
- `Tracking/CameraFrame.swift`: Apple-platform input adapter, outside Core.
  CVPixelBuffer is retained across the async boundary and strictly read-only.
  Never mutate a shared buffer. Orientation describes how to orient its pixels.
- `TrackingDiagnostics.swift`: replaceable processor and debug data. ImagePoint
  uses oriented image coordinates, top-left origin, y down. It is not PanelPoint.
- `FingertipTracker.detect(in:)` returns a `FingertipObservation` containing the
  capture timestamp, optional image-space fingertip, and optional confidence.
  It uses `DetectHumanHandPoseRequest` with one hand, honors frame orientation,
  and converts Vision coordinates to top-left/y-down coordinates. Confidence
  must exceed 0.3; the existing quality evaluator can still mark a detection
  below 0.5 as degraded. Errors propagate to the caller; the debug adapter logs
  errors and returns `notDetected`. No previous point is reused.
- `LiveTrackingSource` and `PanelTracker` remain unimplemented. The diagnostics
  path does not invoke them or claim usable production tracking. Panel conversion
  remains separate (`PanelHomography`); no approximate 3D projection is used.

Only the app owns camera lifetime. The old tracker comments saying “release the
camera” should be read as release its frame subscription when live integration
is implemented. Do not create another camera session inside Tracking.

Still-photo capture, recording UI, automatic panel initialization, and metric
3D pose remain unimplemented. Shared panel-reference types and app retention
are now defined; see PANEL_TRACKING.md. CameraFrameSource
supports future replay adapters; no replay implementation is included yet.

## Assignable next tasks

1. **Fingertip validation (Tracking):** the detector and debug adapter are wired.
   Validate with recorded pointing hands and on-device center/edge alignment,
   low-confidence loss, hand removal/re-entry, and aspect-fill cropping.
   The integrated pipeline can call `FingertipTracker.detect(in:)` with the same
   `CameraFrame` used by panel detection, preserving the shared capture timestamp.
2. **Manual panel initialization (Tracking + app debug UI):** collect four image
   corners; compute image-to-panel homography; show rectified fingertip coordinates.
3. **Panel follow (Tracking):** prototype feature matching/registration from a
   reference frame. Test moving camera, occlusion, textureless surfaces, loss and
   reacquisition. Do not represent a 2D homography as a metric PanelPose.
4. **Capture integration (Experience):** still photo capture as PanelPhoto, rotation,
   interruptions/recovery, and normal product preview using this same service.
5. **Shared reference (Surface Understanding + Core leads):** implement the PanelDetection handoff
   and verify shared corners/map alignment. Resolve 2D versus 3D geometry before Core freeze.
6. **Live output (Tracking + app):** fuse observations into TrackingFrame,
   preserve timestamps, emit lost frames, and cancel subscriptions on termination.

## Verification on device

- Grant/deny permission; denial must display an explanation.
- Open the screen, confirm frame count rises, leave and reopen it.
- Background the app: the camera stops. Reopen the debug screen to restart.
- Verify all four preview corners and aspect-fill crop; remove and reintroduce
  the hand and check that an unusable detection never leaves the old dot.
- Verify no detection work or debug navigation is enabled in Release.

Current assignable issues: [finger](issues/fingertip-tracking.md) and [panel](issues/panel-tracking.md).
