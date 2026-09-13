# ContourMocks — the shared fakes

> **Owned by Team 4 (Product / UI).** From the timeline, Weeks 2–3: *"Mocks for
> all three interfaces, shipped by Monday Sep 21 so everyone has something to
> build against."*

One fake per protocol, so all four teams can build and test before any other
team has working code. This is what the app runs on until the real packages come
online, one at a time, in Weeks 4–5.

## What is in here

| Type | Stands in for | Behaviour |
|---|---|---|
| `MockSurfaceUnderstanding` | Team 1 | Returns a hardcoded six-button microwave. Ignores the photo entirely. Can be made to throw. |
| `MockTrackingSource` | Team 2 | Walks a fingertip from a start point to a target on a timer. Supports scripted dropouts. |
| `PrintingFeedbackEngine` | Team 3 | Prints each `GuidanceState` and records it. An actor, so tests can read it mid-stream. |
| `MockGuidance` | *nobody* | Placeholder wiring: turns `TrackingFrame` + target into `GuidanceState`. See below. |
| `SeededGenerator` | — | SplitMix64. The only permitted source of variation. |

## ⚠️ Determinism is the product here

**Seeded, no randomness, fixed timestamps.** Same input, same output, on every
machine, every run. Three other teams' tests depend on it.

That means, in this package: no `Double.random(in:)`, no `Date()`, no system
RNG. If you want variation, take it from `SeededGenerator` with an explicit seed.
If a reviewer cannot predict the output from reading the call site, it does not
belong here.

`ContourMocksTests` exists to protect this. If you change the canned microwave or
the walk, change those numbers deliberately and say so in the PR — you are
changing four teams' fixtures.

## The canned microwave

```
       x=0                                  x=1
  y=0   +----------------------------------+
        |  [Popcorn ] [Beverage] [Defrost] |   <- y 0.18 ... 0.38
        |  [Add 30s ] [ Start  ] [ Stop  ] |   <- y 0.52 ... 0.72
  y=1   +----------------------------------+
```

Button ids are hardcoded, so you can assert against a specific one. Confidences
are deliberately uneven — `Defrost` is the scuffed one at `0.61`, so anything
filtering on per-button confidence has something to filter. Panel confidence is
`0.94`.

## `MockGuidance` is placeholder wiring, not a feature

Something has to turn a `TrackingFrame` plus a target into the `GuidanceState`
that `FeedbackEngine` consumes, or the Harness has nothing to emit and
`ContourApp` has nothing to wire. `MockGuidance` is the smallest thing that
does it: subtract two points, normalize, check for arrival.

It is deliberately naive — no smoothing, no hysteresis, no dwell time. **Team 3's
Week 2 guidance-model bake-off is what replaces it.** It lives in `ContourMocks`
precisely so that deleting it breaks nothing but mocks.

## Rules

- Depends on **`ContourCore` and nothing else** — that is what makes it safe for
  all four teams to depend on at once. It implements all three protocols without
  importing any team's package.
- Keep it deterministic.
