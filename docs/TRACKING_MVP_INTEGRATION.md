# Tracking MVP integration

This work was developed in an isolated worktree and is now available in the
main local checkout on `tracking-mvp-integration`. No teammate branch or GitHub
PR is changed. The original checkout's local project edit is backed up in a Git
stash. Original authors and commit history are preserved through merges.

## Included work

- Main at `adf772c`.
- `origin/neel/live-app`: PRs #61/#62/#63 and #64/#65, including the panel tracker
  that #64 originally depended on. Camera scan, Surface map, same-frame panel
  and finger fusion, 2D homography, quality assessment, and haptic guidance.
- `origin/8-track-registered-panel`, including `225db02`: Miguel's latest
  appearance-matching recovery change from #59.
- `origin/20-initialize-and-manually-restart-panel-tracking`: Aditya's #48 setup,
  debug reset, actor-isolation fix, tests, and CI app-test step.

Voice #66 and Surface improvements #67/#68 are intentionally outside this first
integration pass. Core contracts and teammate algorithms are unchanged.

## Integration behavior

`ContourPipeline` owns its guidance task. A rescan or manual reference replacement
cancels and waits for old guidance before handing off a new reference. Generation
checks reject delayed scan results. Old targets are rejected when their ID is not
in the current map. Live full-frame fallback detections cannot start guidance.

`replaceReference(with:)` is the app integration handoff for Aditya's prepared
reference. `stopGuidance()` cancels the current session while preserving the
reference for retry. These methods do not implement reference-setup UI or promise
that Vision can register the image: actual registration still occurs on the first
tracking frame.

`LiveTrackingSource` checks the reference generation after both panel tracking and
fingertip detection, preventing an old-reference fingertip from being emitted as
current. The app clears old scan display state and protects newer UI tasks from
completion of older tasks. Navigation/backgrounding cancels work; the shared
camera is stopped on backgrounding.

The MVP remains 2D. The identity PanelPose transform is not measured metric pose.
The app still uses MockGuidance's simple center-distance policy.

## Remaining work and owners

- Remy/Zaynah: physical-phone end-to-end validation and latency measurement.
  Combined visual diagnostics are now implemented. Validate small phone movement,
  finger disappearance, partial panel occlusion, Stop/restart, and replacement
  while busy. Integration follow-up: expose panel-loss reasons for reproducible
  occlusion reports.
- Aditya: no new task from this integration. Both manual setup callbacks now use
  the shared reference handoff; replacement clears target/output state and
  registration errors are surfaced. His original fixture setup remains intact.
- Miguel: investigate the reported panel loss when a finger partially covers
  the panel, identify the failure reason, and improve occlusion tolerance and
  recovery. Validate real panels and distracting rectangles. His algorithm is
  retained, not rewritten in this integration change.
- Puranjay: finish #43's assessed button-relative output; current simple guidance
  is only a demo fallback.
- Justin: no new implementation required unless geometry validation finds a bug.
- Babitha: no new fix from the panel-occlusion report; investigate only if device
  validation identifies an independent fingertip detection failure.

## Verification

Run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on this machine,
whose global developer selection currently points to CommandLineTools. Do not
change the user's global Xcode selection.

- All six package suites.
- ContourApp simulator tests, including rescan cancellation, delayed scan versus
  manual replacement, and blocking full-frame live guidance.
- Tracking regression: replacement while fingertip detection is suspended.
- Harness macOS build, package isolation, and `git diff --check`.

Simulator/package success is not physical-device validation of Vision alignment,
recovery, capture-to-output latency, or haptic usability.

Latest review on October 8, 2026: Core 11, Mocks 13, Surface 58, Tracking 64,
Feedback 25, UI 3 (174 package tests total); app simulator 20 tests passed.
Package isolation and diff whitespace checks passed. The preceding visual
diagnostics implementation also passed Harness and generic iOS device builds.
Independent review of all integration changes found no confirmed major
correctness regression. Physical-phone validation remains required.

Compatibility limits: reference initialization currently recognizes the concrete
`LiveTrackingSource`; a future wrapper/replacement will need an initialization
interface. The optional visual sample callback is additive and defaults to nil;
its consumer must enqueue promptly because it runs on the tracking actor.
Diagnostics use a separate tracker subscription and do not stop the shared
camera on exit. The camera/speech prototype implementation is unchanged, but
its renamed navigation entry is now Debug-only. Core contracts and panel,
finger, and homography algorithms are unchanged.

## Follow-up: independent manual tracking test

The main screen now has a Debug-only manual camera capture path for arbitrary
panels, with four marked corners and one marked target. It calls the shared
reference handoff and uses live tracking/haptics. Registration errors are shown.
See `SURFACE_FALLBACK_AND_MANUAL_TEST.md` for usage and the reproduced Surface
fallback defect. Aditya's original fixture-layout setup remains unchanged.
See `TRACKING_VISUAL_DIAGNOSTICS.md` for same-frame overlays, exact capture
review, and normalized finger-to-target distance.
