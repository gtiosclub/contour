# Tracking MVP integration — first pass

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

- Remy/Zaynah: physical-phone end-to-end validation, latency measurement, and
  combined panel/fingertip/quality diagnostics. Validate small phone movement,
  finger disappearance, panel loss, Stop/restart, and replacement while busy.
- Aditya, with integration owners: call `replaceReference(with:)` from manual
  setup, clear target selection, run live initialization/restart, and expose
  registration errors/retry. Current #48 UI still prepares a reference only.
- Miguel: review the appearance-learning failure path (restarted tracking can
  proceed unchecked), decide whether automatic recovery is suitable for MVP,
  and validate recovery on real panels/distracting rectangles. His algorithm is
  retained, not rewritten in this integration change.
- Puranjay: finish #43's assessed button-relative output; current simple guidance
  is only a demo fallback.
- Justin: no new implementation required unless geometry validation finds a bug.
- Babitha: device validation of the merged fingertip detector; fixes only if needed.

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

Verified on October 8, 2026: Core 11, Mocks 13, Surface 58, Tracking 63,
Feedback 25, UI 3 (173 package tests total); app simulator 14 tests passed;
Harness build succeeded; package isolation and diff whitespace checks passed.
Independent review found no confirmed critical/important defect. Overlapping
guidance starts, wrong-map target rejection, and old UI-task completion deserve
additional regression coverage; these were review coverage suggestions, not
reproduced failures.

## Follow-up: independent manual tracking test

The main screen now has a Debug-only manual camera capture path for arbitrary
panels, with four marked corners and one marked target. It calls the shared
reference handoff and uses live tracking/haptics. Registration errors are shown.
See `SURFACE_FALLBACK_AND_MANUAL_TEST.md` for usage and the reproduced Surface
fallback defect. Aditya's original fixture-layout setup remains unchanged.
