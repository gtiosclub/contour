# Device report follow-up

Approved scope: reconcile the exact tested build (470e79c) with PR #183, fix manual menu recovery and interrupted loss speech, investigate scanning/focus/reflection reports, and validate the combined tree. Existing geometry thresholds stay unchanged.

- [x] Merge 470e79c into fix-hybrid-calibration. Preserve retirement/barriers and reuse its production factory, retaining unsupported-AR fallback. Run combined baseline tests.
- [x] Regression: after a failed scan, a valid manual reference becomes selectable without rescanning; subsequent failed scans cannot expose an older panel. Make the current reference/readiness authoritative for menu availability.
- [x] Regression: pre-announcement losses silence spatial output; post-announcement loss frames leave the one-shot announcement alone; recovery, Stop, replacement and interruption still cancel playback. Keep the 400 ms delay.
- [x] Inspect automatic control detection, coordinate mapping, AR focus and glare policy; document reproduced defects versus missing device evidence without speculative tuning.
- [x] Run full app, Tracking, Feedback and SurfaceUnderstanding suites as applicable, dependency isolation, iPhone build and independent review. Update PR #183 with the combined results and remaining device checks.
