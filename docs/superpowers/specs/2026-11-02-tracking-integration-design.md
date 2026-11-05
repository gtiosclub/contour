# Tracking integration 1 and 2 — proposed design

Status: approved by the user in chat on November 2, 2026; #175 visual prerequisite merged at main a09426d. The original design below is retained as the implementation reference.

## Outcome

Make the delivered feature tracker and hybrid geometry drive the existing app. Guidance and Tracking Diagnostics should genuinely run Vision, features, or hybrid, use the requested options, and report the source of each accepted result honestly. Keep current Surface selection, coordinates, feedback behavior, and arrival dwell.

This covers integration issues #95 and #96. The senior developer's physical-device acceptance remains #97. It does not implement the juniors' new components (#170–174), the Surface request router/planner, Feedback's plan controller, or physical button-press detection.

## Verified starting point

Reviewed main at `d160fa1` (November 2, 2026). Diagnostics 2, PR #168, is merged and its CI passed. The reviewed feature worktree has the same tracked file contents as that main revision; local task drafts remain separate.

- `FeaturePanelTracker`, `HybridAlignment`, world geometry, optional same-frame AR capture, diagnostic samples, and injected app factories exist.
- `HybridPanelTracker` does not exist. The production factory remains Vision-only; app capture does not request world tracking by default.
- `LiveTrackingSource` already maps same-frame fingertip/panel observations and applies quality checks, but does not explicitly retire its tracker and re-registers on every new stream.
- Important prerequisite: PR #156 (#83) merged into `82-feature-panel-tracker`; PR #157 (#84) merged into `83-glare-and-contrast`. Their delivered changes are not in main. Main ignores feature preprocessing options, reports zero highlight fractions, and `cft_finish_calibration` returns -1 without selection.
- Existing tests provide substantial algorithm coverage. Integration tests should exercise coordination, lifetime, and actual app construction rather than duplicate those suites.

## Approach and delivery

Recommended: bring the missing visual delivery forward, then deliver the coordinator, then the source/app wiring. Three reviewable PRs implement the two integration issues:

1. **Visual delivery sync** — prerequisite for #95: integrate the existing #83/#84 implementation and tests.
2. **Hybrid coordinator** — closes #95 after the prerequisite is available.
3. **Production tracking integration** — closes #96 after the coordinator is available.

Each PR starts from main plus its required predecessor, with a baseline check and focused regression tests before implementation. Use feature-named branches without a Codex prefix. Do not mix local task drafts or junior implementation into these PRs. The user reviews/merges; no automatic merge.

A single large PR would combine delivered C++ changes, new orchestration, and app lifetime changes, making failures harder to isolate. Enabling features first without the coordinator is possible, but the proposed sequence delivers both requested integration issues without an interim product configuration to maintain.

## Integration 1: deliver the visual dependencies and hybrid coordinator (#95)

### A. Bring the actual visual delivery onto main

Port the scoped changes from Justin's commits `3821141` (highlight exclusion/CLAHE), `d658928` (persistent selection), and `51a2319` (60% boundary fix), preserving authorship where possible. Compare against the delivered branch to ensure no logic/tests are omitted; resolve conflicts against current main rather than restoring an old app checkout.

Files: `Packages/Tracking/Sources/ContourFeatureMatcher/ContourFeatureMatcher.cpp`, its public C header, `Sources/Tracking/FeaturePanelTracker.swift`, the corresponding feature/image-preparation/selection tests and fixtures, and `docs/FEATURE_MATCHING_BACKEND.md`.

Acceptance: options affect both registration and live extraction; highlight evidence is measured on lost attempts too; only accepted calibration views contribute; selection uses the delivered count/coverage rules and exact 60% boundary; reset/replacement restores the intended original feature set. Run the imported tests and all Tracking tests. Do not retune algorithms during this import.

### B. Add `HybridPanelTracker`

New production file: `Packages/Tracking/Sources/Tracking/HybridPanelTracker.swift`. Conform to existing `PanelTracking`, compose `any CalibratablePanelTracking` and `any PanelAlignmentPolicy`, and retain default real implementations. Use an injected policy factory to make fresh policy state for each reference: the protocol does not expose `HybridAlignment.invalidate`, so do not introduce a concrete downcast or require a shared protocol change just to reset it.

For a frame:

1. Run the visual tracker against that frame.
2. Update the alignment policy with that observation and **that frame's** world snapshot.
3. If reset/restoration is requested, restore the visual tracker's original feature set and clear any retained selected-count claim.
4. Count the view only if the policy accepted it.
5. On a newly-ready transition, finish feature selection **after** counting that final accepted view, once per calibration cycle.
6. Return the chosen current observation, retaining its visual evidence and attaching actual selected-feature count when the backend reports one. Nil means no selected subset claim; do not invent zero or a count.

Frame processing must not overlap. Use request generations and serialized access to all visual mutations. Replacing/stopping invalidates old output immediately; a new registration cannot start while an old awaited selection/restoration operation could still mutate the shared visual tracker. Generation checks after awaits alone do not undo backend side effects. Choose a small serialized-operation implementation, with controllable test doubles proving ordering. Policy changes from a cancelled/obsolete operation cannot be committed into the new reference.

Tests: new `HybridPanelTrackerTests.swift` plus test utilities. Cover accepted/rejected views, restore → observe → finish order, final accepted view, one finish per ready transition, nil selection count, reset/recalibration, missing world data (visual output), limited world tracking, overlap rejection, and cancellation/Stop/replacement during registration, tracking, restoration, observation, and selection. Add one real feature-tracker/policy composition test using existing image fixtures and synthetic synchronized world snapshots; do not claim this establishes phone accuracy.

## Integration 2: source lifetime, production factories, and app capture (#96)

### A. Define reference-session lifetime explicitly

There are two lifetimes: the panel tracking session (reference, matcher, calibration) and an individual guidance consumer (selected target, arrival hold). Moving to another button on the same panel should not silently re-register the panel or discard valid calibration.

Proposed behavior:

| Event | Spatial tracker/reference | Guidance/output |
|---|---|---|
| Arrival / next target on the same panel | Retain registration and valid calibration; drain old in-flight work before reuse | New consumer/run identity; new arrival/loss state; require a fresh frame |
| Explicit Stop | Retire processing and clear calibration, retaining the requested reference for a later restart | Cancel guidance and feedback; next run registers afresh |
| Reference or method/options change | Retire the old source; create a fresh independent source | Clear old status/target results; latest request wins |
| Camera stream ends/restarts | Clear obsolete tracking/calibration; fresh registration when resumed | No frozen spatial output; invalidate old stream work |
| World-session identity changes | Let the existing geometry policy invalidate its world model and restore features | Current visual fallback or honest unavailable output |
| Leave Diagnostics | Retire its independent source completely | Clear displayed and pending results |

Implement an explicit async `LiveTrackingSource.stop()` retirement capability and expose it through the app-local `GuidanceTrackingSession`. Update scripted sessions/tests as needed; no `ContourCore` changes. Consumer termination must cancel/release its camera subscription and drain work. Keeping bounded reference/calibration state after arrival is intentional; true retirement must invoke `stopTracking()` after old operations finish. A later source run after Stop can re-register its retained reference.

Each source supports only one active processing run. Separate source/run/reference generations prevent an old completion or cleanup from stopping a newer run. New subscriptions await retirement of old processing before invoking the same tracker again. Do not run concurrent frame loops over the same matcher. Update the existing test that assumes every stream re-registers to distinguish resume-after-arrival from explicit retirement/restart.

Files: `LiveTrackingSource.swift`; `ContourApp/ContourApp/GuidanceTrackingSession.swift`, `ContourPipeline.swift`, `Debug/TrackingDebugModel.swift`; focused source/app lifecycle tests. Do not implement #171's request controller or plan progression; this supplies the retained spatial-session behavior it can use later.

### B. Wire the real factories and camera

Add a production factory alongside the existing Vision-only test/baseline factory. Every invocation builds an independent source and tracker: Vision → `PanelTracker`, features → `FeaturePanelTracker(options:)`, hybrid → `HybridPanelTracker` with requested feature options. Forward the exact sample callback without rendering inside it. Keep standalone `LiveTrackingSource` defaulting to Vision.

Use one production construction path from `ContourPipeline.live(camera:)`; install the production factory for later settings/reference replacements and explicitly select hybrid by default. Avoid duplicated setup or force-try initialization. Keep the existing injected-factory initializer for scripted tests.

Keep the simulator's normal app launch mocked, as it is today. Tests exercise real production factories explicitly with injected frame sources; a mocked simulator launch is not evidence that phone capture or hybrid tracking works.

Request world-enabled capture once at app composition (`ContourApp.swift`), using the existing `CameraService(worldTracking: true)` capability fallback. On AR-capable phones, Vision and feature modes can consume the same AR camera frames; selecting a 2D algorithm does not imply switching camera ownership. On unsupported devices, the existing AV camera supplies no world snapshot, and the hybrid policy honestly returns visual-only tracking. Do not silently substitute Vision for requested feature/hybrid tracking.

Consequence: manual exposure presets remain unavailable while the shared camera is ARKit-owned, including when a 2D algorithm is selected. The existing diagnostics message already explains this. Dynamic AR/AV camera switching solely for exposure comparisons is outside these two issues.

Files: app `GuidanceTrackingSession.swift`, `ContourPipeline.swift`, `ContourApp.swift`, and tests. Reuse camera code; change it only if focused integration tests demonstrate a necessary defect.

### C. Preserve output and diagnostics honesty

Retain existing same-frame panel/finger mapping, smoothing, quality thresholds, timestamps, normalized distances, and arrival dwell. On rejected geometry, clear accepted quad/target distance and report source unavailable even if hybrid calibration remains ready. Missing fingertip cannot produce a spatial vector or arrival.

Publish accepted samples and current status from the same frame; clear obsolete evidence before processing each attempt and on session retirement. Vision/features may lack hybrid evidence, but do not present them as active AR prediction. Display throttling stays separate from tracking/feedback throughput.

Do not introduce junior #170's new spatial component or #174's reason API in this PR. Keep existing public behavior and leave clear composition points for their later adapters.

## Verification and completion gates

### Coordinator gate (#95)

- Imported preprocessing/selection suites and all Tracking tests pass.
- Hook ordering and lifecycle tests prove old awaited work cannot mutate a replacement reference.
- The real composed tracker returns timestamped visual/hybrid evidence and honest unavailable output.
- Review the C boundary, actor reentrancy, and selected-count semantics before merging.

### Production gate (#96)

- Source tests cover same-frame mapping, stale/jump rejection, missing finger/panel, retained state across target consumers, explicit Stop, and old-cleanup/new-run races.
- Factory tests exercise all three real choices, requested options, callback forwarding, and independent sessions. App tests verify hybrid default and the same selected configuration for Diagnostics and guidance.
- Existing reference/settings/diagnostic/arrival/loss tests continue to pass. Add camera-revision restart checks so subscriptions do not create restart loops.
- Demonstrate missing world data and world-session replacement with synthetic snapshots. Do not relax freshness/quality thresholds to make composition tests pass; use controlled clocks or timestamp rebasing that preserves relative capture age.
- Run all six package suites, the full ContourApp simulator suite, Debug/Release simulator builds, Harness build, package-isolation checks, and diff whitespace checks on the final assembled revision. Report any baseline failures rather than presenting a partial green run as complete.
- Update the foundation/diagnostic handoff docs to describe actual production modes, lifetime rules, and remaining limits. Open the PR for user review; no automatic merge.

Physical phone acceptance, real glare/occlusion accuracy, performance/haptic timing, and accessibility remain #97. Passing these integration gates establishes assembled code behavior, not universal panel robustness or press detection.

## Scope and decisions for approval

- Include the missing #83/#84 delivery as a prerequisite, preserving delivered algorithms instead of rewriting them.
- Use the three-PR sequence above for the two integration issues.
- Preserve calibration across arrival/target changes; clear it on explicit Stop, reference/settings replacement, or invalid world identity.
- Use one capability-falling-back world-enabled camera, not dynamic camera switching per tracking mode.
- Leave all five junior assignments and Feedback's multi-step/confirmation policy outside this implementation.

After design approval, write the executable TDD plan with exact interfaces, test fixtures, and per-commit verification, then implement on fresh feature branches based on current main. This document is the design-level plan for approval; it is not a claim that any integration implementation or validation has already been completed.

## Design review

A fresh Swift concurrency/tracking reviewer checked this proposal against the current code. No important unanswered design questions were found. In particular, the review checked serialized feature hooks, consumer-versus-reference lifetime, stale cleanup, prerequisite delivery, camera fallback, and boundaries with junior assignments. Exact synchronization primitives remain an implementation-plan choice subject to the specified lifecycle tests.
