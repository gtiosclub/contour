# Launch experience integration

Ported the launch presentation from `origin/110-demo-ready-launch-screen`
(commit `12a4a01`) onto the current tracking and feedback implementation.
The previous branch's package deletions, project settings, and older tracking
implementation were not brought over.

## Current ownership

- ContentView owns one CameraLaunchModel and the app/scene lifetime. The camera
  and pipeline still come from ContourApp; views never construct a second live
  camera or tracking session.
- LiveCameraView retains the launch glass transitions, scan control and
  expandable named/unlabelled button selection. Its background now consumes
  CameraFeedView's shared, upright frame stream, including the ARKit path.
  Aspect-fit preserves the capture field of view instead of cropping it.
- CameraLaunchModel cancels and awaits previous work before scan, selection,
  speech or diagnostics handoff. It silences the current LiveFeedbackEngine
  immediately while the previous operation unwinds.
- ButtonLookup and VoiceRequest use the current surface matcher. Recognition
  handles microphone denial, cancellation and recoverable errors; VoiceOver's
  listening prompt finishes before the microphone opens. Timeout state is
  synchronized for Swift 6 concurrency checks.
- ContourPipeline remains the guidance authority, including tracking settings,
  reference replacement, loss episodes and the single 1.25-second arrival hold.
  guidanceArrived is a result of confirmed guidance, never a UI timer.
- LiveFeedbackEngine supplies current visual instructions, sound, voice and
  haptics. Entry feedback remains strong contact + Stop, then the continuous
  hold, then confirmed success. VoiceOver does not repeat the arrival message
  when the integrated voice channel already announces it.
- Feedback preferences persist across launch and Test Experience. The launch
  options menu exposes channel switches and strength; the message sheet also
  shows current tracking evidence during guidance.
- Developer tools retain tracking diagnostics/settings, manual reference setup,
  captured-image review, tracking status scenarios and Test Experience. All use
  the app-owned camera/pipeline, except the isolated feedback test engine.

Simulator startup continues to use ContourPipeline.mock(), as before. It does
not claim to provide live camera/tracking or hardware feedback. Test Experience
is available from Developer tools for isolated feedback work.

## Validation

- Feedback package tests and package-isolation checks.
- iOS Debug and Release source checks against the SDK, including current
  default MainActor isolation and the launch/pipeline test sources.
- Launch tests cover spoken/manual selection, confirmed dwell, stream ending
  without arrival, stale selection rejection, reference replacement,
  background/cancellation/recovery, and immediate feedback cleanup.

Device follow-up: launch and scan a real panel, choose both named and unlabelled
controls, speak a target, verify Stop/contact/hold/success, rescan, enter and leave
tracking diagnostics, toggle each channel, interrupt and background the app.
Check compact and accessibility layouts, Reduce Motion and VoiceOver. These
checks require a running app; static SDK checks do not establish visual or
hardware correctness.
