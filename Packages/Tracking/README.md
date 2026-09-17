# Tracking / Spatial

> Where is the panel, where is the finger, and how sure are we — sixty times a second.

You are the hardest real-time problem in the project and the one everything else
waits on. Experience's haptics are only as good as your fingertip estimate.

**Leads:** Remy, Zaynah · **Juniors:** Miguel, Babitha

## What you own

`Packages/Tracking` — and nothing else. You do not own detection from stills
(Surface Understanding), the camera session, or what the guidance *feels* like
(both Experience). You own the live spatial state and the honesty of its
confidence.

## Lanes

Each junior owns a lane. Every file header names its lane; the PR template asks
which lane a change sits in.

| Lane | Owner | Files |
|---|---|---|
| **Panel Registration & Lost Tracking** | Miguel | `PanelTracker.swift` |
| **Fingertip & Frame Math** | Babitha | `FingertipTracker.swift` |
| **TrackingFrame emitter & latency** *(officers)* | Remy, Zaynah | `LiveTrackingSource.swift` |

The two build-out lanes are independent until `LiveTrackingSource` fuses them,
which is the officers' lane. That file is also where latency and the
never-go-silent rule live — a correct fingertip delivered two frames late is a
finger sent to where the button used to be.

## Your contract

```swift
public protocol TrackingSource: Sendable {
    func frames() -> AsyncStream<TrackingFrame>
}
```

Each `TrackingFrame` carries a timestamp, an optional `fingertip` in panel space,
a `PanelPose` relative to the camera, and a `trackingQuality` of
`.good` / `.degraded` / `.lost`.

### Two rules that will save everyone pain

1. **Never go silent.** When tracking drops, keep emitting
   `TrackingFrame.lost(at:)`. Consumers must be able to tell "no finger" from
   "no source". A silent stream reads as a hang.
2. **Clean up in `onTermination`.** Cancelling the consuming task must stop the
   camera. The `AsyncStream` continuation is where you hook that.

## Weeks 2–3 (Sep 21 – Oct 2)

From the project timeline, your deliverables:

- [ ] **Track the index fingertip** → `FingertipTracker` *(Fingertip & Frame Math)*
- [ ] **Track the panel as the phone moves** → `PanelTracker` *(Panel Registration & Lost Tracking)*
- [ ] **Report finger position relative to a known target** → `LiveTrackingSource` *(TrackingFrame emitter & latency)*

**Checkpoint:** we can separately show where the finger is and where it needs to
move, live, while the phone moves.

## Coordinates — read this first

`fingertip` is in **normalized panel space**: `(0, 0)` top-left, `(1, 1)`
bottom-right, **`y` increasing downward**. Hand tracking gives you camera-space
points — project them onto the panel and normalize before you emit.

**Do not clamp off-panel values.** A fingertip at `y = -0.08` means the finger is
above the top edge, and guidance needs that to say "down and left". Clamping it
to `0` silently tells the user they are on the edge of the panel when they are
not.

`PanelPose` is the one camera-space thing you emit, and it is yours. Everything
else is panel space. Full convention:
[`../ContourCore/COORDINATES.md`](../ContourCore/COORDINATES.md).

## Files

| File | What goes in it |
|---|---|
| `LiveTrackingSource.swift` | The conformance. Fuses the two trackers into a frame stream. |
| `FingertipTracker.swift` | Index fingertip, camera space → panel space. |
| `PanelTracker.swift` | Panel pose across frames as the phone moves. |

Every body is `fatalError("unimplemented — owned by Tracking / <lane>")`.
Replace the bodies, keep the signatures.

## Working

```bash
cd Packages/Tracking
swift test          # seconds, no simulator, no signing
```

Until you ship, the app runs on `ContourMocks.MockTrackingSource`, which walks a
fingertip from a start point to a target on a timer — deterministic, fixed
timestamps, seeded jitter. It also supports scripted dropouts:

```swift
MockTrackingSource(qualityOverrides: [12: .degraded, 13: .lost, 14: .lost])
```

Use it to check that your consumers handle loss before your real tracker can
produce it.

Your **test target may `import ContourMocks`**; your source target may not, and
CI fails the PR if it does.

## Rules

- This package's **source** depends on **`ContourCore` and nothing else**. Not on
  SurfaceUnderstanding, not on ContourFeedback, not on ContourUI, not on
  ContourMocks.
- This package's **tests** may also use **`ContourMocks`**.
  `Scripts/check-dependencies.sh` enforces both halves in CI.
- `ContourCore` is **frozen at the end of Week 2**. `PanelPose` is the type most
  likely to need a change — if its shape is wrong for you, say so in Week 1 or
  Week 2, not Week 4. After the freeze it needs the leads of all three teams.
