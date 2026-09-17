# Experience — ContourUI

> Point the phone at the panel, pick a control, and get out of the way.

You own the two hardest human moments in Contour: getting a panel into frame
when you cannot see the screen, and choosing a target when you cannot see the
options. Neither is a layout problem.

**Leads:** Ashwanth, Nancy, Anushka · **Juniors:** Karan, Rishika, Asav

Experience owns three packages — [`ContourFeedback`](../ContourFeedback/README.md),
`ContourUI` and [`ContourMocks`](../ContourMocks/README.md) — plus the `Harness`.
This README covers `ContourUI`.

## What you own here

`Packages/ContourUI`, and — per the timeline — **the mocks in
`Packages/ContourMocks`**, shipped by Monday Sep 21 so the other two teams had
something to build against.

You do not own detection or tracking.

## Lanes

| Lane | Owner | Files |
|---|---|---|
| **App Flow** | Asav | `CaptureFlow.swift`, `GuidanceFlow.swift` |
| **Accessibility & Launch** *(officers)* | Ashwanth, Nancy, Anushka | `PlaceholderViews.swift`, `ContourApp/ContourApp/ContentView.swift` |
| **Mocks & Integration** *(officers)* | Ashwanth, Nancy, Anushka | `Packages/ContourMocks`, `ContourApp/ContourApp/ContourPipeline.swift` |

Accessibility is not a lane that reviews the others' work at the end — it is the
lane that owns launch and the announcement vocabulary. Every lane still labels
its own controls the day it adds them.

## Your contract

`ContourUI` has no protocol to conform to — you are the consumer, not a
producer. What you owe the app:

```swift
public struct CaptureFlow: Sendable {
    func capturePanelPhoto() async throws -> PanelPhoto
}

public struct TargetSelection: Sendable {
    func selectTarget(in map: SurfaceMap) async -> SurfaceMap.Button?
}
```

A `PanelPhoto` up to the app, which hands you back a `SurfaceMap`, from which
the user picks a `Button`.

### You never call another package, including your own team's

`ContourUI` depends on `ContourCore` and nothing else, so Surface Understanding's
detector is not importable from here — and neither is `ContourFeedback`, which
Experience also owns. You hand a photo up to `ContourApp` and it hands you a map
back. If you find yourself wanting to `import SurfaceUnderstanding` or
`import ContourFeedback`, that is the signal to move the wiring into
`ContourApp/ContourApp/ContourPipeline.swift`.

## Weeks 2–3 (Sep 21 – Oct 2)

From the project timeline, your deliverables:

- [ ] **Live camera experience** → `CaptureFlow`, `ContourCameraView` *(App Flow)*
- [ ] **Basic target selection and guidance flow** → `TargetSelection`, `GuidanceFlow` *(App Flow)*
- [ ] **Mocks for all three interfaces, shipped Monday Sep 21** → `Packages/ContourMocks` *(Mocks & Integration)* ✅ *already in the repo — keep it deterministic*
- [ ] **First integration build Friday Oct 2**, even if it's mostly mocks *(Mocks & Integration)*

These are two of Experience's six Weeks 2–3 deliverables; the other four are in
[`ContourFeedback`](../ContourFeedback/README.md).

**Checkpoint:** a user can see the camera, request a target, and watch the flow
run end to end — on mocks, and that is fine.

## Accessibility is the product

Contour exists for people who cannot see a flat control panel. VoiceOver is not
a pass at the end; it is the primary interface. Every control gets a label, a
trait, and a rotor position **the day you add it**, and you test with the screen
off, not with the screen on and VoiceOver running.

Two specific problems that are yours and have no obvious answer:

- **Camera positioning without sight.** How does a user get a panel into frame
  when they cannot see the preview? This shows up as an explicit Weeks 6–7 item
  — start thinking about it now, because it will not be a late polish task.
- **Target selection without sight.** Reading six labels aloud is one answer.
  Speech input is another — and if you go that way, the request string is handed
  to Surface Understanding's `TargetMatcher`, which turns it into a button. You
  own capturing the request; that lane owns resolving it. Spatial browsing of the
  panel is a third answer, and it is literally the Week 8–9 "Explore Panel"
  expansion feature.

## Coordinates

`SurfaceMap.Button.bounds` is in **normalized panel space**: `(0, 0)` top-left,
`(1, 1)` bottom-right, **`y` increasing downward**.

To draw an overlay, multiply by the preview layer's size — and **keep that
multiplication inside this package**. No pixel coordinate goes back out.

Full convention: [`../ContourCore/COORDINATES.md`](../ContourCore/COORDINATES.md).

## Files

| File | What goes in it |
|---|---|
| `CaptureFlow.swift` | Camera session, shutter, and the still that comes out. |
| `GuidanceFlow.swift` | The state machine from "app opened" to "finger on button". |
| `PlaceholderViews.swift` | Throwaway placeholders so the app has something to present. Delete these. |

Every body is `fatalError("unimplemented — owned by Experience / App Flow")`.
Replace the bodies, keep the signatures.

## Working

```bash
cd Packages/ContourUI
swift test          # seconds, no simulator, no signing
```

You can build the entire selection flow today against
`ContourMocks.MockSurfaceMaps.microwave` — a hardcoded six-button panel, two
rows of three, with one deliberately low-confidence button (`Defrost`, at
`0.61`) so you have something to render an uncertainty state for.

`import ContourMocks` works in **`Tests/`**, which is where flow tests belong.
It does **not** work in `Sources/`, and CI fails the PR if you try — a view that
can reach a fake panel will eventually ship one. The real map arrives from
`ContourApp`, which may import anything.

## Rules

- This package's **source** depends on **`ContourCore` and nothing else**. Not on
  SurfaceUnderstanding, not on Tracking, not on ContourFeedback — same-team
  ownership does not change that — and not on ContourMocks.
- This package's **tests** may also use **`ContourMocks`**.
  `Scripts/check-dependencies.sh` enforces both halves in CI.
- **The mocks must stay deterministic** — seeded, no randomness, fixed
  timestamps. Both other teams' tests depend on that, and now so do yours. It is
  the one piece of shared code where a careless change breaks everybody at once.
- `ContourCore` is **frozen at the end of Week 2**.
