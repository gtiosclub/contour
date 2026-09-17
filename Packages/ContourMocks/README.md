# ContourMocks — the shared fakes

> **Owned by Experience**, in the Mocks & Integration lane. From the timeline,
> Weeks 2–3: *"Mocks for all three interfaces, shipped by Monday Sep 21 so
> everyone has something to build against."*

One fake per protocol, so all three teams can build and test before any other
team has working code. This is what the app runs on until the real packages come
online, one at a time, in Weeks 4–5.

## How to reach these from your package

`import ContourMocks` in your package's **test target**. Every team package's
manifest already declares the dependency, so it just works:

```swift
import ContourMocks          // in Tests/, fine
@testable import Tracking
```

In `Sources/` it is an error, and `Scripts/check-dependencies.sh` fails the PR.
That asymmetry is the whole point: everybody tests against the fakes, nobody
ships them. `ContourApp` and `Harness` are the exception — they are the wiring
and may import anything, which is how the mock pipeline runs in the app on day
one.

## What is in here

| Type | Stands in for | Behaviour |
|---|---|---|
| `MockSurfaceUnderstanding` | Surface Understanding | Returns a hardcoded six-button microwave. Ignores the photo entirely. Can be made to throw. |
| `MockTrackingSource` | Tracking / Spatial | Walks a fingertip from a start point to a target on a timer. Supports scripted dropouts. |
| `PrintingFeedbackEngine` | Experience | Prints each `GuidanceState` and records it. An actor, so tests can read it mid-stream. |
| `MockGuidance` | *nobody* | Placeholder wiring: turns `TrackingFrame` + target into `GuidanceState`. See below. |
| `SeededGenerator` | — | SplitMix64. The only permitted source of variation. |

## ⚠️ Determinism is the product here

**Seeded, no randomness, fixed timestamps.** Same input, same output, on every
machine, every run. All three teams' tests depend on it.

That means, in this package: no `Double.random(in:)`, no `Date()`, no system
RNG. If you want variation, take it from `SeededGenerator` with an explicit seed.
If a reviewer cannot predict the output from reading the call site, it does not
belong here.

`ContourMocksTests` exists to protect this. If you change the canned microwave or
the walk, change those numbers deliberately and say so in the PR — you are
changing all three teams' fixtures.

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

It is deliberately naive — no smoothing, no hysteresis, no dwell time.
**Experience's Week 2 guidance-model bake-off is what replaces it.** It lives in
`ContourMocks` precisely so that deleting it breaks nothing but mocks.

## Rules

- Depends on **`ContourCore` and nothing else** — that is what makes it safe for
  all three teams' test targets to depend on at once without a cycle. It
  implements all three protocols without importing any team's package.
- Keep it deterministic.
- Review here is Experience **plus the leads**: it is the one package where a
  careless change turns three teams' suites red at the same time.
