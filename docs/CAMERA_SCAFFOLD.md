# Camera and tracking development scaffold

The app owns one shared `CameraService`. UI owns preview and capture; Tracking
owns frame analysis. Leaving Diagnostics releases its subscription without
stopping the camera used by the pipeline. The app manages camera lifetime when
backgrounded.

`CameraPreview` shows the full portrait capture with aspect fit. Black bars are
outside the image. Capturing a `PanelPhoto` preserves the full frame rather than
cropping to the preview's container. Keep the phone upright; coordinated physical
rotation remains a separate UI task.

Diagnostics uses `LiveTrackingSource` when a panel reference is available. The
source reports the captured frame, image-space panel/finger observations, and
production `TrackingFrame` together. `FrameImageRenderer` renders that frame off
the UI actor; `TrackingImageView` applies the same aspect-fit transform to pixels
and overlays. Its bounded stream retains the newest sample and draws at most
10 times per second. Without a reference it runs fingertip-only detection.

`CameraFrame` retains a read-only pixel buffer across async boundaries. Never
mutate it. Image coordinates have a top-left origin with y down, after applying
the frame orientation. `PanelHomography` converts between normalized panel and
image coordinates. The production fingertip is smoothed in panel space; the
green diagnostic dot shows the raw same-frame image detection.

Panel follow, manual reference setup, still capture, and live frame emission are
implemented. Metric 3D pose remains unimplemented: the emitted `PanelPose` uses
an identity transform and real panel confidence. See `PANEL_TRACKING.md` and
`TRACKING_MVP_INTEGRATION.md` for integration boundaries.

For current device testing instructions, see
[Tracking visual diagnostics](TRACKING_VISUAL_DIAGNOSTICS.md). Developer navigation
is available only in Debug builds. The separate camera/speech prototype retains
its own original implementation and is labelled accordingly in Developer tools.

## Capture service

`CameraService(worldTracking: true)` captures through ARKit on devices that
support `ARWorldTrackingConfiguration`. Otherwise, and by default until the
upright preview draws from frames, it uses AVFoundation and frames have no
`world`. Under ARKit each `CameraFrame.world` comes from that frame's own
`ARFrame`: camera pose, native-landscape intrinsics and size, tracking
reliability, and its plane anchors (horizontal and vertical) as candidates.
A plane's transform has its origin at the extent center and local x/z along
width/height. Geometry chooses the panel plane.

Every subscriber to `cameraFrames()` gets its own newest-frame buffer and
cancels independently. Stop and failure finish all streams. Each run gets a
fresh session identity and a fresh `ARSession`, so frames, errors and
interruption callbacks from a stopped run are rejected. A failure report is
dropped if a newer run has already begun.

Interruptions (backgrounding, another app taking the camera) set
`CameraStatus.isInterrupted`. AVFoundation resumes the same run. ARKit resumes
with a new session and identity because world coordinates do not survive the
gap. Subscribers stay attached and see the new `sessionID`. Failures set
`CameraStatus.error`. Every successful start, including `retry()`, bumps `revision` so
consumers can resubscribe to the new run.

Exposure presets are 0, −0.7 and −1.3 EV (`CameraService.exposurePresets`).
AVFoundation clamps them to the device's target-bias range and returns the
applied value. Under ARKit only 0 is accepted, because ARKit owns exposure.

Tradeoffs: a new `ARSession` per run costs a little setup time but makes stale
callbacks rejectable by identity, where timestamps alone cannot reject errors.
Restarting world tracking after an interruption gives up relocalization in
exchange for never pairing pixels with an old coordinate frame.
