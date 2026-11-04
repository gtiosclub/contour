# Tracking Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Execute the tasks in order with failing tests before implementation.

**Goal:** Deliver #95 and #96 with real hybrid coordination, reusable reference sessions, safe cleanup, and production mode selection.
**Architecture:** A serialized hybrid actor composes the existing visual tracker and policy. LiveTrackingSource owns reference state separately from cancellable consumer runs. App-local factories and lifecycle handoffs install independent real sessions.
**Tech Stack:** Swift 6.4, Swift Testing, SwiftUI/ARKit, existing OpenCV C bridge, Xcode 27.
**Spec:** docs/superpowers/specs/2026-11-02-tracking-integration-design.md (approved in chat; #175 prerequisite merged).

## Global Constraints
- No ContourCore, algorithm-threshold, Surface, or Feedback behavior changes.
- No junior #170–174 implementation; no automatic merge; feature branch names omit Codex.
- Same-frame timestamps/world evidence; independent guidance/diagnostic sessions.
- Retain calibration between target consumers, retire on explicit Stop/reference/settings/camera termination.

## Review Focus
- A delayed visual hook must finish before new registration can mutate that backend.
- Cancelled consumer cleanup must not stop a replacement source/run.
- A new target must require a fresh frame without destroying valid calibration.
- Missing world/finger or rejected geometry cannot claim usable prediction/arrival.
- Actual app construction must use all three real modes and requested options.

### Task 1: Hybrid actor (#95)
Files: create Tracking/HybridPanelTracker.swift and TrackingTests/HybridPanelTrackerTests.swift; add coordinator documentation.
Interfaces: public HybridPanelTracker(visual: any CalibratablePanelTracking = FeaturePanelTracker(), makeAlignment: @escaping @Sendable () -> any PanelAlignmentPolicy = { HybridAlignment() }); existing startTracking/track/stopTracking.
- [x] Write hook-order/accepted-view/readiness/reset/nil-count tests and controllable lifecycle tests; run red.
- [x] Serialize visual operations; reject overlapping frames; invalidate generations before queued start/stop; commit policy/count only for current noncancelled operations.
- [x] Add real FeaturePanelTracker + HybridAlignment fallback/composition tests; run all Tracking tests.
- [x] Review, commit, push, and open #95 PR against main.

### Task 2: Source reference/run lifetime (#96)
Files: LiveTrackingSource.swift, existing source tests, new LiveTrackingLifecycleTests.swift.
Interfaces: public async LiveTrackingSource.stop(); existing use/frames/status APIs remain. Source retirement awaits old processing; each consumer has a distinct run identity.
- [x] Test same-reference consumer resume, explicit Stop, camera termination, replacement during detection, overlapping subscriptions, and old cleanup races; run red.
- [x] Implement serialized engine operations and managed worker replacement. Preserve reference calibration on consumer cancellation; reset per-run assessment/smoothing and require new input. Natural camera termination and stop perform real tracker cleanup.
- [x] Run all Tracking tests; commit.

### Task 3: Production factories and app lifecycle (#96)
Files: GuidanceTrackingSession.swift, ContourPipeline.swift, ContourApp.swift, TrackingDebugModel.swift; production factory/session tests and updated scripted sessions.
Interfaces: app session stop() async; GuidanceSessionFactories.production retains existing injected factory signature; nonthrowing production helper constructs real sources.
- [x] Test modes/options/callbacks/independence, hybrid app default, and retirement on Stop/replacement/diagnostic exit; run red.
- [x] Install real factory and world-enabled camera; retire actual old/candidate source instances without stale cleanup affecting newer state. Preserve baseline Vision factory for scripted tests and simulator mocks.
- [x] Run full app tests and Tracking tests; commit.

### Task 4: Final verification and #96 PR
- [x] Run all six package suites; full app simulator tests; Debug/Release simulator and Harness builds; isolation/diff checks.
- [x] Fresh whole-branch review; resolve important defects with regressions.
- [x] Update lifetime/factory documentation, push production branch stacked on coordinator, open #96 PR and attach both. Leave merges to user and phone acceptance to #97.

## Execution record
- Baseline: main a09426d includes #175. Local assignment drafts are excluded.
- Pre-flight: source session stop capability is consumed by app retirement; coordinator only uses existing Tracking protocols. No junior deliverable is a prerequisite.
- Task 1 implementation: serialized visual operations and generation checks implemented. Scripted hook tests and actual feature/policy calibration → prediction composition pass; full Tracking suite 197 tests. Fresh coordinator review found no actionable defects. The synthetic composition fixture preserves reference texture aspect ratio; thresholds are unchanged.

- Task 1 delivered in PR #176 (`hybrid-tracking-coordinator`), based on main.
- Tasks 2–3: source operations drain before replacement, consumer cancellation preserves registration, and real production factories own independent sessions. Source lifecycle regressions cover resubscription, overlapping consumers, retirement, natural camera termination, and successful retry after failed registration. Fresh review found a stale registration error; its regression failed before clearing the error on successful registration. Errors remain visible until retry succeeds or explicit Stop/reference replacement.
- Final verification: Tracking 201, Core 11, Mocks 13, Surface 123, Feedback 48, UI 3 tests passed. The first Surface run failed its plain-panel OCR fixture under concurrent suite load; exact-test and full-suite reruns passed without Surface changes. Full simulator app suite: 97 tests passed. Debug simulator app build (test action), Release simulator app build, and macOS Harness build passed.
- Simulator limitation: real Vision frame processing reproducibly crashes within Apple's Vision framework on iOS 27. The factory test still constructs the real Vision session on simulator, but returns before invoking that framework. Features/hybrid real-frame tests pass; real Vision processing remains a physical-device check in #97. Initial app crashes also interrupted unrelated tests; the full suite passed after isolating this call.
- Scope checks: no Core, Surface, Feedback, algorithm-threshold, or junior-task implementations changed. Local task drafts excluded. Production PR is stacked on #176; merges and physical-device acceptance remain with the user/senior developer.

- Pre-merge review: found repeated interruption/Stop could restore temporary false readiness and permanently disable guidance. A new regression reproduced the failure. Readiness now separates the underlying session from its cleanup gate; the full app suite passes 98 tests, and fresh fix review found no additional defects.
- CI exposed wall-clock dependence in a scripted lifecycle fixture. Its injected evaluator now disables age thresholds, matching existing scripted-source tests; production freshness thresholds and dedicated stale-capture tests are unchanged. Full Tracking rerun: 201 tests passed.
