# Contour

**GT iOS Club — Fall 2026**

Contour helps people who can't see a flat control panel press the right button
on it. Point the phone at a microwave, a lift panel, a washing machine; the app
reads the panel, you say which control you want, and it guides your finger there
with haptics, audio, and speech until you're on it.

The hard part isn't any one of those things. It's that four student teams have
to build them at the same time, on different schedules, without blocking each
other. That's what this repo's shape is for.

---

## The one rule

> **Every package depends on `ContourCore` and nothing else.**

`ContourCore` holds the shared types and the three protocols. It depends on
nothing. The four team packages depend only on it, which means **no team can
import another team's code** — not by accident, not on a deadline, not "just
this once". `ContourApp` and `Harness` are the only places the packages meet.

```
                      ┌──────────────────┐
                      │   ContourCore    │   types + protocols. depends on nothing.
                      └────────▲─────────┘
            ┌──────────┬───────┴──┬──────────┬──────────┐
            │          │          │          │          │
   ┌────────┴───┐ ┌────┴────┐ ┌───┴──────┐ ┌─┴──────┐ ┌─┴──────────┐
   │  Surface   │ │Tracking │ │ Contour  │ │Contour │ │  Contour   │
   │Understanding│ │         │ │ Feedback │ │  UI    │ │   Mocks    │
   │   Team 1   │ │ Team 2  │ │  Team 3  │ │ Team 4 │ │  shared    │
   └────────┬───┘ └────┬────┘ └───┬──────┘ └─┬──────┘ └─┬──────────┘
            └──────────┴──────┬───┴──────────┴──────────┘
                    ┌─────────┴──────────┐
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

**After the freeze, any change to `ContourCore` requires sign-off from all four
team leads.** Not one lead, not a majority — all four. A change there breaks
everyone at once, so the cost of getting it wrong is four teams' week, not one
person's afternoon.

If you open a PR that touches `ContourCore` after the freeze:

1. Tag all four leads.
2. Say in the PR description exactly what breaks and who has to change code.
3. Update `ContourMocks` in the same PR so the fakes still match.
4. Update `COORDINATES.md` if the coordinate convention is affected.

The PR template has a checklist for this. `CODEOWNERS` routes the review.

**So: spend Week 1 and Week 2 arguing about `ContourCore`.** That is the cheapest
time you will ever have to change it.

---

## The four teams

Each package has its own README with that track's Weeks 2–3 deliverables, its
contract, and the specific traps that will bite it. Start there, not here.

| Team | Package | Owns | Produces |
|------|---------|------|----------|
| **Team 1** | [`Packages/SurfaceUnderstanding`](Packages/SurfaceUnderstanding/README.md) | Reading a panel from a photo — detection, OCR, layout | `SurfaceMap` |
| **Team 2** | [`Packages/Tracking`](Packages/Tracking/README.md) | Finding the finger and the panel in live frames, frame to frame | `AsyncStream<TrackingFrame>` |
| **Team 3** | [`Packages/ContourFeedback`](Packages/ContourFeedback/README.md) | Haptics, audio, speech, the four outcome signals | consumes `GuidanceState` |
| **Team 4** | [`Packages/ContourUI`](Packages/ContourUI/README.md) | Camera experience, target selection, accessibility | `PanelPhoto`, target choice |

Shared, owned by the leads:

| | |
|---|---|
| [`Packages/ContourCore`](Packages/ContourCore/README.md) | The contract. Types + three protocols. **Frozen end of Week 2.** |
| [`Packages/ContourMocks`](Packages/ContourMocks/README.md) | Fake implementations of all three protocols. What everyone builds against until Week 4. |
| `ContourApp/` | The iOS app. Wires the packages together and owns no features. |
| `Harness/` | macOS rig for Team 3. Synthetic tracking frames, no phone required. |

There is a fifth track in the timeline — **Design** (state-by-state feel spec,
camera acquisition and target selection flows). It has no Swift package because
its Weeks 2–3 deliverables are specs and flows, not code. It owes Team 3 the feel
spec and Team 4 the flows.

Dates, gates, and every track's deliverables: **[`docs/TIMELINE.md`](docs/TIMELINE.md)**.

### Nobody is blocked

Every protocol has a mock from day one, so each team can build and test its
whole package before any other team has working code:

- **Team 1** gets `PanelPhoto` in, returns a `SurfaceMap`. Doesn't need a camera.
- **Team 2** gets a target and emits frames. Doesn't need detection to work.
- **Team 3** gets `GuidanceState` and nothing else — and gets the Harness, which
  runs on a Mac with no phone and no camera at all.
- **Team 4** gets `MockSurfaceMaps.microwave`, a hardcoded six-button panel, and
  can build the whole selection flow against it.

The mocks are **deterministic** — seeded, no randomness, fixed timestamps. Same
input, same output, every run, every machine. Don't break that; tests across
four teams depend on it.

---

## Coordinates: read this before you write a position

Every position that crosses a package boundary is in **normalized panel space**:

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
- An **iPhone running iOS 26** for anything involving the camera. Teams 1 and 3
  can get a long way without one.

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
3. **Set your signing team.** `DEVELOPMENT_TEAM` is deliberately blank in the
   repo so it doesn't fight with your Apple ID:
   - Select the `ContourApp` target → **Signing & Capabilities**
   - Tick **Automatically manage signing**
   - Pick your personal team (a free Apple ID works)
   - If the bundle ID `edu.gatech.gtiosclub.contour` is taken, append something:
     `edu.gatech.gtiosclub.contour.yourname`
   - **Do not commit either change.** If you do, you break everyone else's build.
4. Run. First launch on a free account needs
   *Settings → General → VPN & Device Management → Trust*.

What you'll see on day one is a status screen listing which components are live
and which are mocked, plus buttons to run the mock pipeline end to end. That's
expected — all four packages are empty rooms.

### Run the Harness

The Harness is a **macOS app**. No iPhone, no camera, no tracking. It builds
synthetic `TrackingFrame`s from sliders and pushes them into whatever
`FeedbackEngine` you inject. Team 3 should live in it.

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
`fatalError("unimplemented — owned by <team>")` and every file has a header
saying what the package owes the app. Replace the bodies; **keep the
signatures** — other teams are compiling against them right now.

When your package is ready to be switched on, move your line from
`ContourPipeline.mock()` into `ContourPipeline.live()` in
`ContourApp/ContourApp/ContourPipeline.swift` and add your `Component` to
`liveComponents`. Mixed configurations — two teams live, two still mocked — are
expected and supported. That's why each protocol is mocked separately.

### Conventions

- **Swift 6 language mode**, strict concurrency. Everything crossing a boundary
  is `Sendable`.
- **`async`/`await` only.** No completion handlers, no delegate protocols in the
  contract.
- **Accessibility is the product, not a pass at the end.** Contour exists for
  people who can't see the panel. Every control gets a label and a trait the day
  it's added, and VoiceOver is how you test UI work.
- **One PR, one package.** If you're touching two teams' packages, something is
  in the wrong place.

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
│   ├── SurfaceUnderstanding/    Team 1 — Surface Understanding
│   ├── Tracking/                Team 2 — Tracking / Spatial
│   ├── ContourFeedback/         Team 3 — Feedback / Guidance
│   ├── ContourUI/               Team 4 — Product / UI
│   └── ContourMocks/            deterministic fakes (Team 4 ships these)
├── Harness/                     macOS rig — Team 3's blindfold tester
├── Scripts/
│   └── check-dependencies.sh    enforces the one rule
└── .github/                     CI, PR template, CODEOWNERS
```

---

## CI

Every PR and every push to `main` runs:

1. **Package isolation** — `Scripts/check-dependencies.sh`. Catches a team
   reaching into another team's package, in the manifest or in an `import`.
2. **`swift test`** for all six packages, in parallel, natively on macOS.
3. **`xcodebuild build`** for `ContourApp` (iOS Simulator) and `Harness` (macOS).

`main` is protected: PR required, CI green required, no force pushes. If CI is
red, it's red for everyone — fix it before you start something new.
