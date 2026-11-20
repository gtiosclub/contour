# Hybrid Calibration Implementation Plan

> Execute inline with regression tests before fixes.

Goal: Assemble real hybrid tracking and make calibration failures actionable.
Spec: ../specs/2026-11-05-hybrid-calibration-design.md
Tech: Swift 6.4, iOS 27, ARKit, existing OpenCV dependency.

## Task 1: Live assembly
- [x] Add regressions for real factories (Vision/features/hybrid), feature options, callback delivery, independent sessions, and unsupported-AR fallback.
- [x] Observe failing tests, wire app camera and live pipeline to the real factory, then run app tests.
Files: ContourApp.swift, ContourPipeline.swift, GuidanceTrackingSession.swift, SharedTrackingSetupTests.swift.

## Task 2: Calibration evidence and geometry
- [x] Add regressions for missing/too-small/mixed planes and stale diagnostics, diverging rays, and rejected-depth view training.
- [x] Observe failures, add structured same-frame surface diagnostics and presentation, reject non-forward triangulation, clear rejected view acceptance.
- [x] Run full Tracking suite and app evidence tests.
Files: HybridAlignment.swift, HybridTrackingDiagnostics.swift, PanelWorldGeometry.swift, TrackingEvidence.swift and corresponding tests.

## Task 3: Verification and review
- [x] Run dependency isolation, all app and Tracking tests, iPhone build.
- [x] Request an independent review, repair material findings with regression tests.
- [x] Document actual results and remaining physical-device checks; leave changes on codex/fix-hybrid-calibration.

Review focus: absent AR support; comparison changes after reference registration; unknown diagnostics; invalid/behind-camera rays; rejected view flags; reset/session replacement.

## Results

- 204 Tracking tests passed twice after the final source change.
- 94 app tests passed after the final source change; the preceding app tree also passed twice.
- Unsigned generic iPhone build passed; dependency isolation and git diff --check passed.
- Independent reviewer found no actionable production issues. Suggested extra factory/world coverage was added and passed.
- Additional regressions fixed forward-only triangulation, rejected-depth view training, and stale per-frame error metrics.
- Hardware plane discovery and close-focus behavior remain device checks; no plane/depth thresholds were relaxed.
