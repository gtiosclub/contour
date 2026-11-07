# Calibration traces (#173)

Record a real hybrid-calibration or recovery incident once on a phone, then
replay it through `HybridAlignment` on a Mac as often as needed. Debug tooling
only: nothing here runs in the production frame loop.

## Pieces

| Type | File | Job |
|---|---|---|
| `CalibrationRecorder` | `CalibrationRecorder.swift` | Subscribes to a `CameraFrameSource`, runs a visual tracker on each frame, keeps a bounded buffer |
| `CalibrationTrace`, `TraceFrame`, `TraceNotes` | `CalibrationTrace.swift` | The file format and its validation |
| `TraceReplay` | `TraceReplay.swift` | Feeds a trace through `HybridAlignment`; reports steps, transitions, unmet expectations |

## What a frame records

Exactly what `HybridAlignment.update(visual:world:)` receives, from the same
camera frame:

- index (capture sequence number; a gap is a dropped frame), timestamp, orientation
- reference photo ID (a change replays as `invalidate()`, as the coordinator would)
- the visual observation: quad, confidence, tracked/lost and loss reason, and
  `saturatedFraction` (the glare check reads it)
- the world snapshot: session ID, camera-to-world pose, intrinsics, native image
  size, tracking reliability, planes

Matrices are flattened column-major. Production types are not made `Codable`;
the trace has its own representation, versioned by `formatVersion`.

Malformed or incomplete files fail on load, never silently: wrong array lengths,
unknown enum values, a quad that disagrees with tracked/lost, an observation
stamped with another frame's time, indices or timestamps out of order, an
unknown format version, or sampling counts that don't add up.

## Recording on a phone (handoff to ContourApp)

The recorder takes the app's existing world-enabled camera; it must not open a
second session. Give it a **fresh** tracker: tracking is a chain of frames, and
sharing the live tracker would split that chain.

```swift
let recorder = CalibrationRecorder()                    // 1800 frames, every frame
let task = Task {
    try await recorder.record(camera: sharedCamera,     // the app's CameraFrameSource
                              tracker: FeaturePanelTracker(), reference: reference)
}
// ...operator performs the movement, then:
task.cancel()
let data = try await recorder.encodedTrace(notes: TraceNotes(
    synthetic: false, device: "iPhone 16 Pro", system: "iOS 26.1",
    conditions: "kitchen, overhead light", operatorNotes: "...",
    expectedEvents: [/* written down during the recording, see below */]))
// write `data` off the tracking path, e.g. to Documents/, and AirDrop it
```

Wiring this behind a debug-only control lives in ContourApp, outside this
package, and is a separate handoff.

## Writing down what happened

Each `ExpectedEvent` is a change label and a window in seconds since the first
recorded frame. Write them from what you saw while recording, **never** from a
replay of the same trace.

| Label | Meaning |
|---|---|
| `ready.true` / `ready.false` | calibration approved / withdrawn |
| `source.visual`, `source.fused`, `source.world`, `source.unavailable` | where the output came from |
| `mode.visual`, `mode.calibrating`, `mode.corrected`, `mode.predicted`, `mode.reacquiring` | policy mode |
| `reset` | the model was discarded (session change, reference change, conflict) |

Set `occurs: false` for "this must not happen in the window", e.g. no `ready.true`
in an insufficient-movement trace.

## Adding a phone trace as a regression

Drop the `.json` into `Tests/TrackingTests/Fixtures/Traces/`. The
"Recorded phone traces" suite replays every file there and fails if any expected
event is unmet, if the trace is marked synthetic, or if it has no expectations.
Shorten long traces by trimming frames before committing (keep `sampling`
consistent: `framesOffered == frames + framesDropped`).

## Duration, sampling and drops

- Default capacity 1800 frames: 60 s at 30 Hz, all frames. When full the oldest
  frame is evicted, so the buffer holds the last minute before recording stopped.
- `everyNthFrame` keeps one frame in N. It changes the timing the policy sees
  (fewer, wider-spaced views), so prefer 1 for incidents and use N > 1 only for
  long sessions; the value is stored in the trace.
- Every delivered frame is either recorded or counted in `framesDropped`:
  sampling skips, frames the tracker threw on (the live loop feeds alignment
  nothing for these either), and evictions.
- Frames the camera delivered while the recorder was busy are dropped by the
  frame source's own buffering policy, upstream of the recorder, and are not
  counted. Index gaps only cover what the recorder saw.

## Overhead

- Size: about 750 bytes per frame with two planes (measured on synthetic
  frames), so ~1.4 MB for a full default buffer. More planes cost roughly 150 B
  each per frame.
- Nothing is written to disk while recording; encoding happens once, in
  `encodedTrace`.
- Appending is O(1) until full; eviction is O(capacity) per frame after that.
- **Not yet measured on device:** CPU and frame-rate cost of running a second
  visual tracker alongside the live loop. Record this with the first phone trace.

## Limitations

- No images are stored. Visual evidence can't be re-detected, only replayed as
  recorded observations; tracker changes need their own fixtures.
- Of the feature diagnostics, only `saturatedFraction` is kept. Replayed
  observations carry zeroed counts with a message saying so.
- The recorder runs its own tracker instance, so its observations can differ
  slightly from the live loop's in the same session.
- Replay drives `HybridAlignment` directly; it does not exercise the (unfinished)
  hybrid coordinator or feature restoration.
- Synthetic traces in tests are marked `synthetic: true`. No phone trace exists
  yet; the success and insufficient-movement recordings are still to be made.
