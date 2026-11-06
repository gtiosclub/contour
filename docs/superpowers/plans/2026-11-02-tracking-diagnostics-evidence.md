# Tracking Diagnostics Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete issue #94 with exact-frame explanations and safe comparison controls.
**Architecture:** App-local presentation values consume LiveTrackingSample. An observable comparison model forwards injected settings and exposure requests, without owning Guidance settings. The existing diagnostics model retains independent factory sessions and same-frame rendering.
**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, Xcode 27.
**Spec:** docs/superpowers/specs/2026-11-02-tracking-diagnostics-evidence-design.md (approved in chat).

## Global Constraints
- Branch: tracking-diagnostics-evidence-controls; linked to #94. User merges.
- No tracking algorithm or shared package contract changes; preserve original checkout edits.
- Evidence publication <=10 Hz. Exposure presets 0, -0.7, -1.3 EV.

## Review Focus
- Ready calibration without usable alignment must not imply AR prediction.
- Absent or nonfinite measurements must not become fabricated zeroes.
- Camera restart must not leave old diagnostics or applied exposure claims.
- Delayed old sample/exposure completions must not override newer state.
- Settings must retain the reference while diagnostics gets an independent session.

### Task 1: Evidence presentation
Files: create Debug/TrackingEvidence.swift, Debug/TrackingEvidenceView.swift, ContourTests/TrackingEvidenceTests.swift.
Interfaces: TrackingEvidence(sample: LiveTrackingSample?) exposes source and labeled evidence sections to TrackingEvidenceView.
- [x] Add tests for source versus readiness, missing evidence, loss, and invalid metrics; run to see missing behavior.
- [x] Implement evidence formatting and the SwiftUI panel, consuming supplied diagnostics only.
- [x] Run focused TrackingEvidenceTests; expect zero failures.
- [x] Include evidence presentation in the feature commit.

### Task 2: Comparison requests and safe sessions
Files: create Debug/TrackingComparisonModel.swift, ContourTests/TrackingComparisonTests.swift; modify Debug/TrackingDebugModel.swift, Debug/TrackingDebugView.swift; add ContourTests/TrackingDiagnosticSessionTests.swift.
Interfaces: TrackingComparisonModel forwards injected settings and async exposure callbacks; camera capability comes from CameraControl. TrackingDebugView composes it with pipeline callbacks. TrackingDebugModel continues consuming GuidanceSessionFactory.
- [x] Test unsupported exposure, clamping, errors, and superseded completion; settings forwarding and camera revision identity.
- [x] Test exact-frame evidence with scripted sessions, replacing a delayed old render and cancelling pending work.
- [x] Implement comparison controls, revision restart, and monotonic publication throttling while preserving sample pairing.
- [x] Run focused diagnostics and existing settings tests; expect zero failures.
- [x] Include safe comparison/session behavior in the feature commit.

### Task 3: Integration verification and handoff
Files: docs/TRACKING_VISUAL_DIAGNOSTICS.md; PR body.
- [x] Run all ContourApp tests, app simulator build, package isolation, and diff whitespace check; report any failure by name.
- [x] Review full branch diff with fresh context; resolve actionable defects and rerun affected checks.
- [x] Document automated evidence and remaining physical-device acceptance.
- [ ] Commit, push feature branch, open PR with Closes #94 and attach it to chat. Leave merge to user.

## Execution record
- Approved design: extend existing screen using app-local presentation and injected comparison callbacks.
- Pre-flight: Task 2 consumes Task 1's TrackingEvidence; both read the same displayed sample. No conflicting contracts.
- Baseline: SharedTrackingSetupTests.pipelineUsesInjectedSession failed before implementation because it checked a registration error after the source ended. The fixture now holds its stream open for the error assertion and separately verifies terminal cleanup.
- Review: one important defect found and fixed. CameraService.start previously published a revision on every call, which would loop with revision-driven diagnostic tasks. CameraStatus now publishes once per capture-generation UUID. CameraStatusRevisionTests covers repeated starts and genuine new runs.
- Ruling: retain app-local work and correct the camera's revision publication at its existing status boundary, rather than introducing a second camera-start owner in the diagnostic view. Repeated consumers share one run; true restarts still invalidate sessions.
- Ruling: use existing docs/TRACKING_VISUAL_DIAGNOSTICS.md; the originally named experiment document is not present on main.
- Verification before handoff: full simulator app suite 91 tests / 105 parameterized runs, zero failures; Release simulator build and package isolation pass. Existing sendable-capture warning in ContourTests.swift remains unchanged. Physical camera/glare acceptance is documented and not claimed as completed.
- Regression proof: temporarily removed capture-generation deduplication; CameraStatusRevisionTests.repeatedStartIsIdempotent failed. Restored the guard and reran the full app suite successfully.
