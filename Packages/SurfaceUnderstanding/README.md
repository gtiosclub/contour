# Surface Understanding

> Detect an appliance interface in a photo and say what is on it.

You are the front of the pipeline. A photo comes in; a `SurfaceMap` goes out.
Nothing downstream can start until you can say *"there are six buttons, here,
and this one says Start"*.

**Leads:** Neel, Aadarsh · **Juniors:** Sanvi, Srinivas

## What you own

`Packages/SurfaceUnderstanding` — and nothing else. You do not own the camera
(Experience), you do not own live frames (Tracking / Spatial), and you do not own
what happens after the map is produced.

## Lanes

Each junior owns a lane. Every file header names its lane; the PR template asks
which lane a change sits in.

| Lane | Owner | Files |
|---|---|---|
| **Panel Reader** | Sanvi | `PanelDetector.swift`, `ButtonDetector.swift`, `LiveSurfaceUnderstanding.swift` |
| **Labels & Target Matching** | Srinivas | `LabelReader.swift`, `TargetMatcher.swift` |
| **Eval & Test Set** *(officers)* | Neel, Aadarsh | `TestSet.swift` |

The two build-out lanes meet in `LiveSurfaceUnderstanding`, which orchestrates
the stages: Panel Reader owns the file, Labels & Target Matching owns what goes
into the `label` field. Agree the hand-off before either of you starts, not
after.

## Your contract

```swift
public protocol SurfaceUnderstanding: Sendable {
    func surfaceMap(from photo: PanelPhoto) async throws -> SurfaceMap
}
```

One method. `PanelPhoto` in — encoded bytes plus dimensions and orientation.
`SurfaceMap` out — an array of `Button(id, label:, bounds:, confidence:)` plus a
panel-level confidence.

**A panel found with poor confidence is a success, not an error.** Return a low
`SurfaceMap.confidence` and let the caller decide. Throw
`SurfaceUnderstandingError` only when there is no answer at all.

> **Naming wrinkle:** this module and the protocol share a name. Inside this
> package, plain `SurfaceUnderstanding` resolves to the module, so conformances
> here must be spelled `ContourCore.SurfaceUnderstanding`. Everywhere else the
> bare name works.

## Weeks 2–3 (Sep 21 – Oct 2)

From the project timeline, your deliverables:

- [ ] **Detect an appliance interface in a photo** → `PanelDetector` *(Panel Reader)*
- [ ] **Identify basic buttons and labels** → `ButtonDetector` *(Panel Reader)*, `LabelReader` *(Labels & Target Matching)*
- [ ] **Produce a basic `SurfaceMap`** → `LiveSurfaceUnderstanding` *(Panel Reader)*
- [ ] **Match a spoken request to a control** → `TargetMatcher` *(Labels & Target Matching)*
- [ ] **Hand-label the test set** → `TestSet` *(Eval & Test Set)*

Every team member owes five photos of appliance panels they can get to. That is
the test set, and it is yours to label.

**Checkpoint:** we can show where a button is, from a still photo, on more than
one appliance.

## Coordinates — read this first

Everything you return is in **normalized panel space**: `(0, 0)` top-left,
`(1, 1)` bottom-right, **`y` increasing downward**. Vision hands you pixels in a
`y`-up space. Convert at your edge — **no pixel coordinate leaves this package**.

Full convention: [`../ContourCore/COORDINATES.md`](../ContourCore/COORDINATES.md).

This is the most likely bug in the project. `ContourCoreTests` has a test that
pins the convention; if you flip an axis, it will not catch you, because your
package is where the flip would happen.

## Files

| File | What goes in it |
|---|---|
| `LiveSurfaceUnderstanding.swift` | The conformance. Orchestrates the stages below. |
| `PanelDetector.swift` | Find the panel's quadrilateral in the photo, rectify it. |
| `ButtonDetector.swift` | Find control-shaped regions inside the rectified panel. |
| `LabelReader.swift` | Read the text on each control. `nil` is a valid answer. |
| `TargetMatcher.swift` | "the popcorn one" → which `Button`, and how sure. `nil` means not on this panel. |
| `TestSet.swift` | Hand-labelled ground truth, and scoring against it. |

Every body is `fatalError("unimplemented — owned by Surface / <lane>")`.
Replace the bodies, keep the signatures.

## Working

```bash
cd Packages/SurfaceUnderstanding
swift test          # seconds, no simulator, no signing
```

Until you ship, the app runs on `ContourMocks.MockSurfaceUnderstanding`, which
returns a hardcoded six-button microwave. Experience is building the selection
flow against that map right now, so when you go live, **match its shape** — two
rows of three, labels present, per-button confidence — or you will surprise them.

Your **test target may `import ContourMocks`**; your source target may not, and
CI fails the PR if it does. Build fixtures from `MockSurfaceMaps.microwave`
rather than hand-rolling a `SurfaceMap` in a test.

## Rules

- This package's **source** depends on **`ContourCore` and nothing else**. Not on
  Tracking, not on ContourFeedback, not on ContourUI, not on ContourMocks.
- This package's **tests** may also use **`ContourMocks`**.
  `Scripts/check-dependencies.sh` enforces both halves in CI.
- `ContourCore` is **frozen at the end of Week 2**. If you need a change there,
  raise it in Week 1 or Week 2 — after that it needs the leads of all three
  teams.
