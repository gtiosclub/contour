# ContourCore — the contract

> ⚠️ **DRAFT until the end of Week 2 (Fri Oct 2 — see below). Then frozen.**
>
> Gate, from the project timeline: *"End of Week 2: interfaces (`SurfaceMap`,
> `TrackingFrame`, `GuidanceState`) and coordinate convention frozen."*
>
> After that, **a change here needs sign-off from all four team leads.** Not one,
> not a majority — all four. It breaks everyone at once.

`ContourCore` depends on nothing, and nothing is allowed to change that. It is
the only thing all four teams share, which is exactly why it must stay small.

## What is in here

| File | Contents |
|---|---|
| [`COORDINATES.md`](COORDINATES.md) | **The coordinate convention. Read this before writing a position.** |
| `Coordinates.swift` | `PanelPoint`, `PanelVector`, `PanelRect`, `PixelSize` |
| `SurfaceMap.swift` | `SurfaceMap`, `SurfaceMap.Button` — Team 1's output |
| `TrackingFrame.swift` | `TrackingFrame`, `PanelPose`, `TrackingQuality` — Team 2's output |
| `GuidanceState.swift` | `GuidanceState`, `GuidanceVector`, `OutcomeSignal` — Team 3's input |
| `PanelPhoto.swift` | `PanelPhoto`, `PhotoOrientation`, `SurfaceUnderstandingError` — Team 4's output |
| `Protocols.swift` | The three protocols, one per producing team |

## The three protocols

```swift
protocol SurfaceUnderstanding: Sendable {   // Team 1
    func surfaceMap(from photo: PanelPhoto) async throws -> SurfaceMap
}

protocol TrackingSource: Sendable {          // Team 2
    func frames() -> AsyncStream<TrackingFrame>
}

protocol FeedbackEngine: Sendable {          // Team 3
    func present(_ state: GuidanceState) async
}
```

Async/await and `Sendable` throughout. No completion handlers, no delegates.

## Spend Weeks 1 and 2 arguing about this

That is the cheapest time you will ever have to change it. Every week after the
freeze, a change here costs four teams' time instead of one person's afternoon.

Things worth arguing about **now**:

- Is `PanelPose` the right shape for Team 2? It is currently four `SIMD4<Double>`
  columns plus a confidence.
- Does `GuidanceState` carry everything Team 3 needs? It is currently a vector
  and an optional outcome, and nothing else.
- Are four `OutcomeSignal` cases enough? Adding a fifth later means growing
  every `switch` in the app.
- Is `PanelPhoto` (encoded bytes) the right handoff from Team 4 to Team 1, or
  should it be a pixel buffer?

## If you must change it after the freeze

1. Tag all four leads on the PR.
2. Say exactly what breaks and who has to change code.
3. Update `ContourMocks` in the same PR so the fakes still match.
4. Update `COORDINATES.md` if the convention is affected.

The PR template has this as a checklist. `CODEOWNERS` routes the review.
