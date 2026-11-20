# Tracking diagnostics evidence and comparison controls

Implements issue #94 on `tracking-diagnostics-evidence-controls`, based on current main. Leave merging to the user.

## Intent

Explain the evidence behind the exact displayed tracking sample and let developers compare tracking settings on the same prepared panel.

## Approach

Extend the existing diagnostics screen with a focused evidence panel and a small testable presentation model. Reuse its exact-frame display, renderer, injected session factory, and Guidance-owned settings. A separate comparison screen would duplicate reference/session state; putting presentation in the tracking package would cross the existing ownership boundary. The proposed approach keeps this feature app-local.

## Behavior

- Show supplied source with text and distinct colors: 2D visual, 2D-corrected AR, AR prediction, or no usable alignment. Never infer prediction from camera capability. Mark unknown evidence unavailable.
- Separately show calibration mode/readiness, progress, stable features, movement/depth blockers, resets/reason, baseline, alignment/corner errors, and visual-verification age.
- Show feature/reference counts, matches/inliers, coverage, reprojection error, processing latency, highlight/excluded fractions, and supplied reason messages. Missing or nonfinite measurements remain unavailable. Label suspected glare as a heuristic.
- Derive evidence from the displayed frame's sample, so image, overlays, and explanations update together at no more than 10 Hz.
- Keep existing algorithm/options requests routed through Guidance-owned callbacks. Each diagnostic restart keeps its reference and creates an independent session; camera revision changes also restart it.
- Provide exposure presets 0, -0.7, and -1.3 EV through CameraControl. Disable manual adjustments when ARKit owns exposure, report actual applied/clamped values, and display errors honestly.
- Preserve manual setup and existing overlay behavior. Tracking algorithms and shared contract changes are outside scope.

## Verification

Script supplied source/readiness combinations, absent/nonfinite evidence, glare explanations, forwarded settings, unsupported/failed/clamped exposure, and replacement sessions. Verify delayed old samples cannot overwrite a replacement display, evidence is paired with its image, and publication is throttled. Run focused tests, the app test suite, simulator builds, and package isolation. Review the final diff and link the PR to #94; do not merge it. Physical camera/glare comparisons remain device acceptance.

## Workspace

Use an isolated workspace based on main to preserve the original checkout's unrelated edits. No Codex prefix in the feature branch name.
