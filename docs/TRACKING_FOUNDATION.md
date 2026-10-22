# Shared tracking foundation (S0)

This is the buildable starting point for the independently owned tracking tasks.
Vision remains the working default. OpenCV, ARKit capture, projection helpers,
calibration, hybrid prediction, settings UI, and the final recovery policy are
later tasks, not included implementations or simulated production features.

## Package contracts and ownership

All new tracking contracts live in `Packages/Tracking`, outside the frozen,
framework-free ContourCore API. All diagnostic and snapshot values have public
initializers so app code and tests can supply them without `@testable import`.

| Owner | Implement against | Deliver later |
|---|---|---|
| A — visual features | PanelTracking, CalibratablePanelTracking, FeatureTrackingOptions, FeatureTrackingDiagnostics | FeaturePanelTracker and C++ backend |
| B — world geometry/policy | WorldCameraSnapshot/WorldPlane, PanelAlignmentPolicy, supplied PanelObservations | Ray/projection helpers and HybridAlignment |
| C — camera | CameraFrameSource, optional CameraFrame.world, app CameraControl/CameraStatus | Synchronized AR capture and upright pixel preview |
| D — app experience | App GuidanceTrackingSession/GuidanceSessionFactory, CameraControl, LiveTrackingSample | Settings, diagnostics, stable UI, feedback policy using scripted sessions |
| E — assembly | All interfaces above; injected LiveTrackingSource panel tracker | Hybrid actor, real factory and end-to-end validation |

```swift
public protocol PanelTracking: Sendable {
    func startTracking(_ reference: PanelReference) async throws
    func track(_ frame: CameraFrame) async throws -> PanelObservation
    func stopTracking() async
}

public protocol CalibratablePanelTracking: PanelTracking {
    func observeCalibrationView() async
    func finishCalibration() async -> Int?
    func resetCalibration() async
}
```

`PanelTracker` (Vision) conforms. `LiveTrackingSource` accepts `any PanelTracking`
while preserving its Vision default. A custom actor can report loss and evidence
without invoking Vision. Calls remain sequential; implementations must supersede
in-flight operations when their reference changes or they stop.

`PanelAlignmentPolicy` is a mutating, Sendable geometry-policy contract:
`update(visual:world:) -> PanelObservation`, with read-only `isCalibrated`,
`acceptedCalibrationView`, `didReset`, and `needsFeatureRestore`. Event flags
refer to the most recent update, not sticky historical events. B's implementation
never needs A's concrete actor; E handles calibration feature hooks.

`PanelTrackingMethod` declares Vision, features and hybrid names only. There is
no feature/hybrid factory implementation in the package yet. Feature options
start with highlight exclusion enabled and contrast enhancement disabled.

## Frame and coordinate agreement

- CameraFrame pixels are retained, immutable inputs. Preserve capture time, not
  completion time. Existing producers can omit `world` and get nil.
- CameraFrame.world must describe those exact pixels. CameraToWorld, intrinsics,
  native sensor dimensions, reliability, plane snapshots and session identity
  travel together. Do not pair an image with the latest unrelated camera pose.
- ImagePoint/PanelQuad use normalized upright portrait image coordinates, x right,
  y down. Corners retain their TL/TR/BR/BL identities.
- PanelPoint is normalized panel space, not physical distance. Its existing
  interpretation and the public PanelPose placeholder remain unchanged.
- World intrinsics refer to native landscape sensor pixels before upright
  rotation/downsampling. World units are metres; plane local x/z span its surface,
  local y is its normal, and extent is the full width/height about its center.
- Generate a new world session UUID after any restart that changes the coordinate
  frame. World-plane ray/projection math is B's task, not implemented in S0.

PanelObservation carries optional feature/hybrid evidence. LiveTrackingSource
forwards it and the panel status with the exact input frame in LiveTrackingSample.
A failed final quality check sets hybrid source to unavailable; rejected geometry
is not presented as valid prediction. Each processing attempt clears diagnostic
state so old evidence cannot describe a new frame. Registration/reference changes
also clear diagnostics. `hybridStatus()` returns the most recent report or nil.

A lost frame never carries a stale quad. Diagnostic evidence may be present even
when geometry is unavailable. Confidence is evidence, not a probability of a
correct physical target. Calibration readiness and actual displayed source are
separate values.

## App session and camera seams

The app-local `GuidanceTrackingSession` extends TrackingSource with async
`use(_:)`, `registrationError()` and `hybridStatus()`. LiveTrackingSource conforms
at app composition; pipeline reference handoff and error/status access use the
capability interface rather than a concrete LiveTrackingSource cast.

`GuidanceSessionFactory` is an injected MainActor **throwing** closure:

```swift
(any CameraFrameSource, PanelTrackingMethod, FeatureTrackingOptions,
 (@Sendable (LiveTrackingSample) -> Void)?) throws -> any GuidanceTrackingSession
```

Each call must return a fresh independent session. The sample callback runs on
the worker: enqueue promptly; never render or mutate UI in the callback. Throwing
is intentional: the baseline `GuidanceSessionFactories.vision` rejects features
or hybrid with `GuidanceSessionFactoryError.unimplemented`, rather than silently
running Vision under another name. Later assembly supplies their real factory.

Existing `ContourPipeline.live(camera: CameraService)` keeps its working Vision
configuration. Independent app tests can use:

```swift
let pipeline = try ContourPipeline.live(
    camera: fakeCamera,
    sessionFactory: scriptedFactory,
    method: .hybrid
)
```

The pipeline retains the supplied factory, selected method and options for later
settings/session replacement work. TrackingDebugView supplies that same factory to TrackingDebugModel;
`TrackingDebugModel(processor:sessionFactory:)` and `run(camera:reference:method:options:)`
can run against a fake CameraControl without camera permission or hardware.
Existing initializers and default diagnostic behavior are preserved.

`CameraControl` extends CameraFrameSource with start/stop, retry, world-tracking
availability, MainActor CameraStatus (error/revision), and exposure bias. Baseline
CameraService conforms and still uses AVFoundation. Retry stops/restarts the
service and increments revision; consuming revision for automatic resubscription
is part of C's preview work. Nonzero exposure bias throws an explicit unavailable
error until C implements it; zero leaves existing automatic exposure unchanged.
No unsupported control reports a false success.

## Independent component acceptance

- A: generated/recorded images in CameraFrames; return valid observations or loss.
- B: synthetic immutable snapshots and supplied 2D observations; no ARSession or
  OpenCV implementation required.
- C: real device capture plus image fixtures; no panel algorithm required.
- D: a scripted GuidanceTrackingSession, factory and fake CameraControl; no
  permission prompts or another team's unfinished implementation required.
- E: combine real implementations only after their component demonstrations.

Working examples are in TrackingContractTests and SharedTrackingSetupTests.
Tests validate external construction, custom tracker injection, exact-frame lost
samples, protocol-based reference/error handoff, explicit unavailable modes, and
independent diagnostic processing. Existing tests still cover Vision, coordinate
mapping, reference replacement, guidance cancellation, and manual setup.

No doubles or unfinished algorithm implementations are shipped as real tracking.
The new test doubles stay in test targets. No OpenCV dependency or ARKit session
is introduced by this foundation.

LiveTrackingSource retains its existing cancellation behavior: termination cancels
the producing task and releases its camera subscription. Coordinating explicit
stopTracking() cleanup with reference/restart races belongs to the assembly task;
S0 does not claim to change that lifecycle policy.

## Guidance settings and session handoff (#90)

`ContourPipeline.requestTrackingSettings(method:options:)` accepts a requested
configuration synchronously and returns a task to await for completion. Its
observable `trackingSettings` is the single in-memory choice for guidance and
the diagnostics view. The view requests changes through that method and builds
its own diagnostic session with the same factory, method and options; it never
shares the guidance tracker. Highlight exclusion starts on and contrast
enhancement off.

Each settings or reference request cancels active guidance, clears old error and
hybrid evidence, and asks the injected factory for a fresh guidance session.
The latest request alone may activate its session after async registration;
unsupported methods leave guidance unavailable with an explicit error. A
failed selection can be retried with the same settings. `stopGuidance()` also
invalidates pending registration without discarding the requested reference.
The default injected live configuration is hybrid for the future integrated
factory. The current device-only `live(camera:)` stays on its actual Vision
implementation until Integration installs a hybrid-capable factory; it never
labels Vision output as hybrid. `LiveTrackingSource` itself still defaults to
Vision. Status presentation and brief-loss feedback are follow-up tasks #91
and #92.
