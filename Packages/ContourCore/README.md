# ContourCore — the contract

> ⚠️ **DRAFT until the end of Week 2 (Fri Sep 25). Then frozen.**
>
> Gate, from the project timeline: *"End of Week 2: interfaces (`SurfaceMap`,
> `TrackingFrame`, `GuidanceState`) and coordinate convention frozen."*
>
> After that, **a change here needs sign-off from the leads of all three teams.**
> Not one team, not a majority — all three. It breaks everyone at once.

`ContourCore` depends on nothing, and nothing is allowed to change that. It is
the only thing all three teams share, which is exactly why it must stay small.

Owned by the leads: Neel and Aadarsh (Surface Understanding), Remy and Zaynah
(Tracking / Spatial), Ashwanth, Nancy and Anushka (Experience).

## What is in here

| File | Contents |
|---|---|
| [`COORDINATES.md`](COORDINATES.md) | **The coordinate convention. Read this before writing a position.** |
| `Coordinates.swift` | `PanelPoint`, `PanelVector`, `PanelRect`, `PixelSize` |
| `SurfaceMap.swift` | `SurfaceMap`, `SurfaceMap.Button` — Surface Understanding's output |
| `TrackingFrame.swift` | `TrackingFrame`, `PanelPose`, `TrackingQuality` — Tracking's output |
| `GuidanceState.swift` | `GuidanceState`, `GuidanceVector`, `OutcomeSignal` — Experience's input |
| `PanelPhoto.swift` | `PanelPhoto`, `PhotoOrientation`, `SurfaceUnderstandingError` — Experience's output |
| `Protocols.swift` | The three protocols, one per producing team |

## The three protocols

```swift
protocol SurfaceUnderstanding: Sendable {   // Surface Understanding
    func surfaceMap(from photo: PanelPhoto) async throws -> SurfaceMap
}

protocol TrackingSource: Sendable {          // Tracking / Spatial
    func frames() -> AsyncStream<TrackingFrame>
}

protocol FeedbackEngine: Sendable {          // Experience
    func present(_ state: GuidanceState) async
}
```

Async/await and `Sendable` throughout. No completion handlers, no delegates.

## Spend Weeks 1 and 2 arguing about this

That is the cheapest time you will ever have to change it. Every week after the
freeze, a change here costs three teams' time instead of one person's afternoon.

Things worth arguing about **now**:

- Is `PanelPose` the right shape for Tracking? It is currently four
  `SIMD4<Double>` columns plus a confidence.
- Does `GuidanceState` carry everything Experience needs? It is currently a
  vector and an optional outcome, and nothing else.
- Are four `OutcomeSignal` cases enough? Adding a fifth later means growing
  every `switch` in the app.
- Is `PanelPhoto` (encoded bytes) the right handoff from Experience to Surface
  Understanding, or should it be a pixel buffer?
- Does the contract need a target-request type now that `TargetMatcher` exists?
  Today Experience passes a `String` and Surface Understanding returns its own
  `TargetMatch` — that type is deliberately *not* in `ContourCore`. If both teams
  end up needing it, that is a Week 2 conversation, not a Week 6 one.

## If you must change it after the freeze

1. Tag the leads of all three teams on the PR.
2. Say exactly what breaks and who has to change code.
3. Update `ContourMocks` in the same PR so the fakes still match.
4. Update `COORDINATES.md` if the convention is affected.

The PR template has this as a checklist. `CODEOWNERS` routes the review.
