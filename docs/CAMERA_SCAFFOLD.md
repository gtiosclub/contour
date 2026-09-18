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
“Detector not implemented” is intentional. The overlay toggle is ready for a
processor that returns a fingertip; no fake dot is displayed. Release builds
have no developer navigation. The original mock pipeline remains available.

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
- `LiveTrackingSource` and both existing trackers remain unimplemented. The
  diagnostics path does not invoke them or claim usable production tracking.

Only the app owns camera lifetime. The old tracker comments saying “release the
camera” should be read as release its frame subscription when live integration
is implemented. Do not create another camera session inside Tracking.

Still-photo capture, recording UI, automatic panel initialization, and metric
3D pose remain unimplemented. Shared panel-reference types and app retention
are now defined; see PANEL_TRACKING.md. CameraFrameSource
supports future replay adapters; no replay implementation is included yet.

## Assignable next tasks

1. **Fingertip processor (Tracking):** implement TrackingFrameProcessor using
   Vision; honor CameraFrame.orientation, convert to ImagePoint, return confidence
   and explicit notDetected. Inject it into TrackingDebugModel. Test with recorded
   pointing hands and verify overlays on device.
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
- Once a detector is added, verify all four preview corners and aspect-fill crop.
- Verify no detection work or debug navigation is enabled in Release.

Current assignable issues: [finger](issues/fingertip-tracking.md) and [panel](issues/panel-tracking.md).
