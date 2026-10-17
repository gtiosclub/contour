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
| **Accessibility & Launch** *(officers)* | Ashwanth, Nancy, Anushka | `ContourTheme.swift`, `PanelLayout.swift`, `Screens/`, `ContourApp/ContourApp/ContentView.swift` |
| **Mocks & Integration** *(officers)* | Ashwanth, Nancy, Anushka | `Packages/ContourMocks`, `ContourApp/ContourApp/ContourPipeline.swift` |

Accessibility is not a lane that reviews the others' work at the end — it is the
lane that owns launch and the announcement vocabulary. Every lane still labels
its own controls the day it adds them.

## Your contract

`ContourUI` has no protocol to conform to — you are the consumer, not a
producer. What you owe the app:

```swift
public struct CaptureFlow: Sendable {
    init(capture: @escaping @Sendable () async throws -> PanelPhoto)
    func capturePanelPhoto() async throws -> PanelPhoto
}

public struct TargetSelection: Sendable {
    init(listen: @escaping @Sendable (SurfaceMap) async throws -> SurfaceMap.Button?)
    func selectTarget(in map: SurfaceMap) async -> SurfaceMap.Button?   // suspends until chosen
    func choose(_ button: SurfaceMap.Button) -> Bool                    // a tap resolves it
    func listenForTarget() async throws -> SurfaceMap.Button?           // a spoken request resolves it
    func backOut() -> Bool                                               // nil
}

public struct GuidanceFlow: Sendable {
    init(announce: @escaping @Sendable (String) async -> Void)
    func currentStage() async -> GuidanceFlowStage
    func advance(to stage: GuidanceFlowStage) async
    func advanceIfLegal(to stage: GuidanceFlowStage) async -> Bool
    func cancel() async -> Bool
    func stages() -> AsyncStream<GuidanceFlowStage>
    func announcement(for stage: GuidanceFlowStage) -> String
}
```

A `PanelPhoto` up to the app, which hands you back a `SurfaceMap`, from which
the user picks a `Button`. The transition table is at the top of
`GuidanceFlow.swift`.

### Ownership: the app keeps the camera and voice matching

Two things a "camera experience" package might be expected to own stay in
`ContourApp`, on purpose:

- **The camera.** Tracking follows the same `CameraService` stream the scan
  photo comes from, and the reference photo and the live frames must share one
  size and orientation or Vision's tracker fails (see
  `ContourApp/ContourApp/Camera/PanelPhotoCapture.swift`). One camera, owned by
  the app, handed to both. So `CaptureFlow` is given a capture closure;
  `CaptureFlow()` with no camera throws `CaptureFlowError.noCamera`. The live
  preview is likewise passed into the screens as a view.
- **Voice matching.** Turning "the start one" into a button is Surface
  Understanding's `TargetMatcher`, which this package cannot import. The app
  records the request and resolves it; `TargetSelection` is given a `listen`
  closure that returns the matched button.

`ContourUI` owns everything else the user perceives on screen and hears from
the flow: the stage machine, every announcement, and the screens themselves
(`AcquireScreen`, `DetectingScreen`, `SelectScreen`, `GuideScreen`,
`OutcomeScreen`). The screens take plain data and closures, so they render the
same against `MockSurfaceMaps.microwave` in a test or a preview as against a
real panel. Colours, type, spacing and radii all live in `ContourTheme.swift`
so the team can restyle to the Figma designs in one place.

### You never call another package, including your own team's

`ContourUI` depends on `ContourCore` and nothing else, so Surface Understanding's
detector is not importable from here — and neither is `ContourFeedback`, which
Experience also owns. You hand a photo up to `ContourApp` and it hands you a map
back. If you find yourself wanting to `import SurfaceUnderstanding` or
`import ContourFeedback`, that is the signal to move the wiring into
`ContourApp/ContourApp/ContourPipeline.swift`.

## Weeks 2–3 (Sep 21 – Oct 2)

From the project timeline, your deliverables:

- [x] **Live camera experience** → `CaptureFlow`, `AcquireScreen` *(App Flow)*
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
| `CaptureFlow.swift` | `CaptureFlow` (capture through the app's camera) and `TargetSelection` (suspends until a tap or a spoken request resolves it). |
| `GuidanceFlow.swift` | The state machine from "app opened" to "finger on button", its transition table, and every announcement. |
| `PanelLayout.swift` | Reading order, rows/columns, "top left", confidence wording, and guidance in words (+dy is down). |
| `ContourTheme.swift` | Every colour, size, radius, font and animation. Restyle here. |
| `Screens/AcquireScreen.swift` | Full-bleed camera, instruction, the bottom third is the shutter. |
| `Screens/DetectingScreen.swift` | The frozen, dimmed photo while the panel is read; Cancel. |
| `Screens/SelectScreen.swift` | The photo with controls drawn on it, the control list (rotor-friendly), Say a button. |
| `Screens/GuideScreen.swift` | Target name, proximity ring, direction arrow, Stop. |
| `Screens/OutcomeScreen.swift` | One full-screen result per `OutcomeSignal`, with next steps. |
| `Screens/PanelPicture.swift` | Panel space → photo space (the quad's homography) and the overlay; draws the panel from its map when there is no photo. |
| `Screens/ViewfinderPlaceholder.swift` | Stands in for the camera in the Simulator and screenshots. |
| `Screens/ContourControls.swift` | Shared glass actions, cards, banners and corner guides. |

Every screen takes plain data and closures — the camera preview is passed in
as a view — so all of them build and test against `MockSurfaceMaps.microwave`.
In the app, `ContentView` launches straight into them; launch with
`-ContourDemoStage acquire|detecting|select|guide|arrived|lostTracking|notFound|lowConfidence`
(DEBUG) to open on any stage for screenshots.

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
