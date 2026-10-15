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
