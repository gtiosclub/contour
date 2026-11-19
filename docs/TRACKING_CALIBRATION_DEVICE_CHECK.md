# Tracking calibration device check

The app now requests AR world tracking and uses hybrid alignment on supported devices. Unsupported devices use feature-only tracking. Guidance and Tracking Diagnostics construct independent sessions from the same factory and use the same selected method/options. Vision remains available for comparison.

## Fixes

- Connect hybrid startup and all three method selections to real trackers.
- Surface evidence distinguishes no detected planes from rejected planes. Every rejected plane contributes its first geometry error, counted by reason. A missing fitting count means no selection was attempted this frame; absent AR data is unavailable, not zero planes.
- Reject triangulation behind either camera; do not train persistent features on views discarded for wrong depth.
- Show alignment/corner errors only when measured for the current frame.

## On the phone

1. Build the ContourApp scheme with local signing and select the physical phone.
2. Open Tracking Diagnostics and choose Hybrid. Prepare a manual reference with the real panel corners and target if needed.
3. Keep the full panel and surrounding surface visible in good light. Expand Calibration and recovery. Inspect AR planes, Fitting planes, and Surface rejections.
4. If AR planes is zero, allow surface discovery while viewing the panel and nearby textured surfaces. If the rejection says the plane does not cover the panel, show more of the surrounding surface and let the estimated extent grow. Do not expect movement alone to increase accepted views before a candidate surface exists.
5. Once a candidate exists, translate sideways while keeping the panel in frame. Rotation in place does not prove depth. The existing gates remain at least 8 accepted views spanning 1 second, 6 cm baseline, and 2 degrees parallax, plus image/depth agreement.
6. Verify the matte microwave first, then the reflective one. Record the tracking method, readiness, source, accepted views, plane counts/rejections, baseline, resets, and error metrics with the displayed image. Ready and usable output are separate: stale or conflicting output must still be withheld.
7. Test interruption/retry, replacing the reference, and switching all three comparison methods. Check that settings changes take effect and sessions do not reuse old references.

## Verification

On Xcode 27.0, after incorporating the tested build's lifecycle changes: 208 Tracking tests, 102 app tests, 48 Feedback tests and 123 Surface Understanding tests passed; dependency isolation passed and an unsigned iPhone build succeeded. Tests include real OpenCV matching through the app factory, highlight options, independent sessions, same-frame AR-plane handoff, growing plane coverage, missing data, diverging/converging rays, rejected feature-training views, and stale error measurements.

Physical AR plane discovery, focus at microwave distance, and reflective-surface repeatability are not established by simulator or synthetic-plane tests. The unavailable Drive recordings were not reviewed. These changes expose the reported failure point without claiming that ARKit will always discover a microwave panel.

See [the Issue 97 follow-up](TRACKING_DEVICE_REPORT_FOLLOWUP.md) for the tested-branch reconciliation, manual-menu/loss-speech repairs, measured scanner limitations, and the remaining phone checklist.
