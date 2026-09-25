# Contour

**GT iOS Club — Fall 2026**

Contour helps people who can't see a flat control panel press the right button
on it. Point the phone at a microwave, a lift panel, a washing machine; the app
reads the panel, you say which control you want, and it guides your finger there
with haptics, audio, and speech until you're on it.

The hard part isn't any one of those things. It's that three student teams have
to build them at the same time, on different schedules, without blocking each
other. That's what this repo's shape is for.

---

## The one rule

> **Every package's shipping code depends on `ContourCore` and nothing else.**
> **Test targets may also use `ContourMocks`.**

`ContourCore` holds the shared types and the three protocols. It depends on
nothing. Every other package depends only on it, which means **no team can
import another team's code** — not by accident, not on a deadline, not "just
this once". `ContourApp` and `Harness` are the only places the packages meet.

That holds *within* a team too. Experience owns `ContourFeedback`, `ContourUI`
and `ContourMocks`, and they still can't import each other. Same team, same
rule — the boundary is about what ships linked together, not about who is in
which group chat.

```
                                    ┌──────────────────┐
                                    │   ContourCore    │   types + protocols. depends on nothing.
                                    └─────────▲────────┘
          ┌─────────────────┬─────────────────┴─────────────────┬─────────────────┐
  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
  │    Surface    │ │    Tracking   │ │    Contour    │ │    Contour    │ │    Contour    │
  │ Understanding │ │               │ │    Feedback   │ │       UI      │ │     Mocks     │
  ├───────────────┤ ├───────────────┤ ├───────────────┤ ├───────────────┤ ├───────────────┤
  │    Surface    │ │    Tracking   │ │   Experience  │ │   Experience  │ │   Experience  │
  └───────┬───────┘ └───────┬───────┘ └───────┬───────┘ └───────┬───────┘ └───────┬───────┘
          └─────────────────┴─────────────────┼─────────────────┴─────────────────┘
                                   ┌──────────┴─────────┐
                                   │ ContourApp (iOS)   │   the wiring. may depend on everything.
                                   │ Harness   (macOS)  │
                                   └────────────────────┘
```

`Scripts/check-dependencies.sh` enforces this, and CI runs it on every PR. If it
fails on your branch, the fix is almost never "add the dependency" — it's either
that the type belongs in `ContourCore`, or that the wiring belongs in
`ContourApp`.

---

## ⚠️ ContourCore freezes at the end of Week 2 (Fri Sep 25)

`Packages/ContourCore` is the contract every team builds against. Right now it
is marked **DRAFT** and it is open: argue with it, file issues, bring changes to
a lead. That window closes at the **end of Week 2**.

**After the freeze, any change to `ContourCore` requires sign-off from the leads
of all three teams.** Not one team, not a majority — all three. A change there
breaks everyone at once, so the cost of getting it wrong is three teams' week,
not one person's afternoon.

If you open a PR that touches `ContourCore` after the freeze:

1. Tag the leads of all three teams.
2. Say in the PR description exactly what breaks and who has to change code.
3. Update `ContourMocks` in the same PR so the fakes still match.
4. Update `COORDINATES.md` if the coordinate convention is affected.

The PR template has a checklist for this. `CODEOWNERS` routes the review.

**So: spend Week 1 and Week 2 arguing about `ContourCore`.** That is the cheapest
time you will ever have to change it.

---

## The three teams

Each package has its own README with that track's Weeks 2–3 deliverables, its
contract, its lanes, and the specific traps that will bite it. Start there, not
here.

| Team | Leads | Packages | Owns | Produces |
|------|-------|----------|------|----------|
| **Surface Understanding** | Neel, Aadarsh | [`SurfaceUnderstanding`](Packages/SurfaceUnderstanding/README.md) | Reading a panel from a photo — detection, OCR, layout, matching a spoken request to a control | `SurfaceMap`, `TargetMatch` |
| **Tracking / Spatial** | Remy, Zaynah | [`Tracking`](Packages/Tracking/README.md) | Finding the finger and the panel in live frames, frame to frame | `AsyncStream<TrackingFrame>` |
| **Experience** | Ashwanth, Nancy, Anushka | [`ContourFeedback`](Packages/ContourFeedback/README.md), [`ContourUI`](Packages/ContourUI/README.md), [`ContourMocks`](Packages/ContourMocks/README.md) | Everything the user perceives: haptics, audio, speech, the camera experience, target selection, accessibility | `PanelPhoto`, target choice; consumes `GuidanceState` |

Experience is the two old Feedback/Guidance and Product/UI teams, merged. The
packages did not merge with them — see [the one rule](#the-one-rule).

Shared, owned by the leads:

| | |
|---|---|
| [`Packages/ContourCore`](Packages/ContourCore/README.md) | The contract. Types + three protocols. **Frozen end of Week 2.** |
| `ContourApp/` | The iOS app. Wires the packages together and owns no features. |

`Packages/ContourMocks` and `Harness/` sit with Experience but serve everyone;
a change to either is reviewed by the leads as well.

There is a fourth track in the timeline — **Design** (Kaylee): state-by-state
feel spec, camera acquisition and target selection flows. It has no Swift package
because its Weeks 2–3 deliverables are specs and flows, not code. It owes
Experience both the feel spec and the flows.

### Lanes

Every junior owns a lane. A lane is a named slice of a package with one owner,
so that "who is doing the haptics" has an answer that isn't "Experience".

| Team | Lane | Owner | Files |
|---|---|---|---|
| Surface Understanding | Panel Reader | Sanvi | `PanelDetector`, `ButtonDetector`, `LiveSurfaceUnderstanding` |
| Surface Understanding | Labels & Target Matching | Srinivas | `LabelReader`, `TargetMatcher` |
| Surface Understanding | Eval & Test Set | Neel, Aadarsh | `TestSet` |
| Tracking / Spatial | Panel Registration & Lost Tracking | Miguel | `PanelTracker` |
| Tracking / Spatial | Fingertip & Frame Math | Babitha | `FingertipTracker` |
| Tracking / Spatial | TrackingFrame emitter & latency | Remy, Zaynah | `LiveTrackingSource` |
| Experience | Haptics | Karan | `ProximityHaptics`, `ChosenGuidanceModel` |
| Experience | Audio & Speech | Rishika | `DirectionalAudio`, `SpeechQueue` |
| Experience | App Flow | Asav | `CaptureFlow`, `GuidanceFlow` |
| Experience | Outcome Signals & Harness | Ashwanth, Nancy, Anushka | `OutcomeAnnouncer`, `LiveFeedbackEngine`, `Harness/` |
| Experience | Accessibility & Launch | Ashwanth, Nancy, Anushka | `PlaceholderViews`, `ContourApp/ContentView` |
| Experience | Mocks & Integration | Ashwanth, Nancy, Anushka | `Packages/ContourMocks`, `ContourApp/ContourPipeline` |

Each source file's header names its lane. The PR template asks which lane a
change sits in — that is the question, not which package.

Dates, gates, and every track's deliverables: **[`docs/TIMELINE.md`](docs/TIMELINE.md)**.

### Nobody is blocked

Every protocol has a mock from day one, so each team can build and test its
whole package before any other team has working code:

- **Surface Understanding** gets `PanelPhoto` in, returns a `SurfaceMap`.
  Doesn't need a camera.
- **Tracking / Spatial** gets a target and emits frames. Doesn't need detection
  to work.
- **Experience** gets `GuidanceState` and nothing else for feedback — and gets
  the Harness, which runs on a Mac with no phone and no camera at all. For the
  UI side it gets `MockSurfaceMaps.microwave`, a hardcoded six-button panel, and
  can build the whole selection flow against it.

**How you actually reach the mocks:** `import ContourMocks` in your package's
**test target**, which every team package's manifest already allows. Your
package's *source* target still cannot see them, and CI fails the PR if it does —
that is what keeps fake microwaves off a user's phone. So a mock-driven test
lives in `Tests/`, and the app gets its mocks from `ContourApp`, which may import
anything.

The mocks are **deterministic** — seeded, no randomness, fixed timestamps. Same
input, same output, every run, every machine. Don't break that; tests across all
three teams depend on it.

---

## Coordinates: read this before you write a position

Button and guidance positions are in **normalized panel space**:

```
    x = 0                        x = 1
y=0  +---------------------------+
     |  (0,0) top-left           |
     |                           |    y increases DOWNWARD
     |                    (1,1)  |             |
y=1  +---------------------------+             v
```

- Origin is **top-left**, `(1, 1)` is bottom-right.
- **`y` increases downward** — like UIKit, not like SceneKit.
- Values outside `0...1` are legal and mean "off the panel". Don't clamp them.
- **No pixel coordinates cross a package boundary.** Convert at your edge.

Full convention, with the reasoning: **[`Packages/ContourCore/COORDINATES.md`](Packages/ContourCore/COORDINATES.md)**.

Getting `y` backwards sends every user's finger the wrong way, and it is the
single most likely bug in this project. There's a test in `ContourCoreTests`
that pins it.

---

## Getting started

### What you need

- **macOS 26** or later
- **Xcode 26** (Swift 6, iOS 26 SDK) — the project will not open in Xcode 25
- An **iPhone running iOS 26** for anything involving the camera. Surface
  Understanding, and Experience's feedback lanes, can get a long way without one.

### Clone and open

```bash
git clone git@github.com:gtiosclub/contour.git
cd contour
open Contour.xcworkspace     # the workspace, NOT ContourApp.xcodeproj
```

Always open **`Contour.xcworkspace`**. It contains both app targets and all six
packages. Opening a single `.xcodeproj` works for a quick build but you won't
see the other team's packages.

### Run on device

The camera work needs a real phone — the simulator has no rear camera worth
pointing at a microwave.

1. Plug in an iPhone running iOS 26 and trust the Mac.
2. Select the **`ContourApp`** scheme and your device.
3. **Set up local signing once.** Sign into Xcode's Apple Accounts settings.
   Copy the template from the repo root (edit instead if the local file exists):

   ```bash
   cp ContourApp/Config/Signing.example.xcconfig ContourApp/Config/Signing.xcconfig.local
   ```

   Set `CONTOUR_DEVELOPMENT_TEAM` to your 10-character team ID and
   `CONTOUR_BUNDLE_ID` to a unique ID such as `edu.gatech.contour.yourname`.
   Edit this Git-ignored file instead of changing the team in the project's
   Signing tab. Debug and Release use it; the test bundle gets a `.tests` suffix.
   Automatic signing is enabled. Without the local file, simulator builds work;
   device builds require your valid team and provisioning. Your team ID is in
   Apple Developer membership details or the DEVELOPMENT_TEAM setting from a
   project where you have already selected the team.
4. Run. First launch on a free account needs
   *Settings → General → VPN & Device Management → Trust*.

What you'll see on day one is a status screen listing which components are live
and which are mocked, plus buttons to run the mock pipeline end to end. That's
expected — the four team packages are still empty rooms.

### Run the Harness

The Harness is a **macOS app**. No iPhone, no camera, no tracking. It builds
synthetic `TrackingFrame`s from sliders and pushes them into whatever
`FeedbackEngine` you inject. Experience should live in it.

1. Open `Contour.xcworkspace`.
2. Select the **`Harness`** scheme and **My Mac**.
3. Run (`⌘R`).

You get:

- **Fingertip x/y sliders**, ranging past `0…1` so you can push the finger off
  the panel — a real case guidance has to handle.
- **Tracking quality** picker: `good` / `degraded` / `lost`.
- **Target** picker over the canned six-button microwave.
- **Four outcome buttons**: `arrived`, `lostTracking`, `notFound`, `lowConfidence`.
- **Walk to target**, which replays the deterministic mock approach so you can
  feel a whole run rather than scrub one frame.

To feel your own engine instead of the printing mock, change one line in
`Harness/Harness/HarnessApp.swift`:

```swift
import ContourFeedback
@State private var model = HarnessModel(engine: LiveFeedbackEngine())
```

Then put on a blindfold and have someone else drive the sliders. That is the
actual test.

### Run the tests

```bash
# Everything, the way CI does it
./Scripts/check-dependencies.sh
for p in Packages/*/; do (cd "$p" && swift test); done

# Just your package — seconds, no simulator, no signing
cd Packages/ContourFeedback && swift test
```

Package tests run natively on macOS. Put your tests in your package, not in the
app target — they'll run in seconds instead of minutes.

---

## Working in your package

Your package is an **empty room**. Every function body is
`fatalError("unimplemented — owned by <team> / <lane>")` and every file has a
header naming its lane and what the package owes the app. Replace the bodies;
**keep the signatures** — other teams are compiling against them right now.

When your package is ready to be switched on, move your line from
`ContourPipeline.mock()` into `ContourPipeline.live()` in
`ContourApp/ContourApp/ContourPipeline.swift` and add your `Component` to
`liveComponents`. Mixed configurations — one team live, two still mocked — are
expected and supported. That's why each protocol is mocked separately.

### Conventions

- **Swift 6 language mode**, strict concurrency. Everything crossing a boundary
  is `Sendable`.
- **`async`/`await` only.** No completion handlers, no delegate protocols in the
  contract.
- **Accessibility is the product, not a pass at the end.** Contour exists for
  people who can't see the panel. Every control gets a label and a trait the day
  it's added, and VoiceOver is how you test UI work.
- **One PR, one lane.** If you're touching two teams' packages, something is in
  the wrong place. Experience owns three packages, so "one team" isn't a tight
  enough rule there — name the lane instead.

---

## Repo layout

```
contour/
├── Contour.xcworkspace          ← open this
├── ContourApp/                  iOS app. The wiring. Owns no features.
├── docs/TIMELINE.md             11 weeks, four gates, deliverables per track
├── Packages/                    every package has its own README — read yours
│   ├── ContourCore/             the contract — FROZEN END OF WEEK 2
│   │   └── COORDINATES.md       the coordinate convention. read it.
│   ├── SurfaceUnderstanding/    Surface Understanding
│   ├── Tracking/                Tracking / Spatial
│   ├── ContourFeedback/         Experience
│   ├── ContourUI/               Experience
│   └── ContourMocks/            deterministic fakes (Experience ships these)
├── Harness/                     macOS rig — Experience's blindfold tester
├── Scripts/
│   └── check-dependencies.sh    enforces the one rule
└── .github/                     CI, PR template, CODEOWNERS
```

---

## CI

The org's free GitHub Actions minutes don't stretch to macOS runners (they bill
at 10x), so CI is deliberately thin:

1. **Every PR** — `Scripts/check-dependencies.sh` on Linux. Catches a team
   reaching into another team's package, and `ContourMocks` leaking into a
   shipping target. Free, ten seconds.
2. **On demand** — Actions → CI → Run workflow. One macOS job that runs
   `swift test` in all six packages and builds `ContourApp` and `Harness`. A
   lead kicks this off before a merge to `main` matters (integration Fridays,
   Demo Day builds), not on every PR.

The real gate is `swift test` on your own Mac before you open the PR. The PR
template asks which package you ran it in. Reviewers: if the template says
"it builds," send it back.

## Camera and panel-reference integration

The app owns shared capture and debug UI; Tracking consumes frames. Surface
Understanding returns `PanelDetection` (reference photo ID, image-space quad,
and button map). Core's `PanelReference` pairs it with the matching photo.
See [the handoff](docs/PANEL_TRACKING.md), [camera scaffold](docs/CAMERA_SCAFFOLD.md),
and the [finger](docs/issues/fingertip-tracking.md) / [panel](docs/issues/panel-tracking.md)
starting tasks. Live algorithms remain lane assignments, not scaffold features.
