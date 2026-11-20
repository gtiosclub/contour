# Issue 97 device-report follow-up

The report was tested on hybrid-tracking-coordinator at 470e79c (iPhone 16, iOS 27.0.1), not main c9bb74c. That branch already enabled hybrid startup. PR #183 originally fixed main's wiring but could not identify that tested build; its startup fix does not explain the reported zero-view run.

## Reconciled and repaired

The PR now includes 470e79c's session retirement, cancellation serialization, repeated-interruption readiness and diagnostic cleanup. One production factory supplies all real tracking modes; the unsupported-AR feature-only fallback is retained. Tests inspect diagnostic samples before natural stream termination, since retirement intentionally clears session status.

- Manual target menu: a failed scan latched scanRequiresRetry even after a valid manual reference was installed. Menu availability now derives from the current reference/readiness. A regression scans unsuccessfully, installs a manual reference without rescanning, verifies target availability, and checks that a subsequent failed scan cannot expose old targets.
- Loss speech: after the 400 ms loss outcome, the next lost frame sent an empty state that stopped all playback. Continued loss now leaves the one-shot outcome alone while spatial output stays stopped. Recovery, explicit Stop, reference replacement, backgrounding and stream cleanup retain their interruption paths. Regression coverage includes brief gaps, continued loss, episode recovery/reset, and stopping/replacing before and after the announcement starts.
- Existing calibration repairs remain: detected/fitting plane counts and rejection causes, forward-only triangulation, no rejected-depth feature training, and same-frame error measurements. No thresholds were weakened.

## Still unresolved: automatic scanning quality

The Surface Understanding suite passes, but its local Vision scoreboard is a report rather than a minimum-quality assertion. On Xcode 27.0, ten repository microwave photos produced:

- 142 center hits out of 246 labeled controls: 57.7% recall.
- 142 center hits out of 212 detections: 67.0% precision.
- 35 detections passed the IoU >= 0.5 match count; 106/142 center matches had correct labels.
- Start was found correctly on six photos and not found on four; zero wrong Start targets in this dataset.

These numbers support the reported missing/merged controls as a real remaining limitation. They are not measurements of the tester's two microwaves. Existing code attempts to split frame regions holding several labels and infer printed-only controls; its word grouping also intentionally combines nearby words into multiword labels. Without the reported reference images and intermediate boxes/OCR words, changing these heuristics could split valid labels such as Add 30 Sec. No speculative scanner tuning was made.

Next evidence: save the original captured photo, marked/detected panel quad, returned button boxes and labels for the Popcorn/Potato/Veggies failure and the same panel via manual setup. Use these as fixtures before changing detection or label grouping.

## Still needs physical-phone checks

- B1/B2: use the new plane counts/rejections to distinguish absent plane discovery from extent/distance/geometry rejection. Reproduce still/rotation-only and sideways movement after a fresh reference. The code repairs do not establish reliable ARKit plane discovery.
- B9/B11-B13: after Ready, test brief prediction and reverification, known wrong-depth setup, limited world tracking, and movement of a lightweight labeled panel. Visual-only passes do not cover these.
- C1-C8: repeat mode/options changes, Stop while busy, reference replacement, background/foreground, camera retry and Diagnostics entry/exit on the combined commit.
- Focus: AR capture already enables autofocus. Its path does not use the AVFoundation multi-camera/near-focus configuration. Compare a clear and blurred same-scene run and record current tracking source, losses, finger confidence/assessment and feedback. Blurred preview alone does not prove accepted alignment is wrong; no blur-triggered rejection rule was added.
- Reflection: clipped-highlight exclusion and optional contrast enhancement are tested, but they do not remove general moving reflections. Test glare and reflection separately with the phone held steady, recording whether incorrect geometry is accepted versus output becoming unavailable.
- Loss audio and the manual menu: retest on device; simulator routing tests do not prove audibility or rendered SwiftUI behavior on this phone.

## Automated verification

The combined tree passed 208 Tracking tests, 102 app tests, 48 Feedback tests and 123 Surface Understanding tests, dependency isolation, and an unsigned iPhone build. An independent read-only review found no actionable production issue. Hardware acceptance remains open; neither this document nor green unit tests marks Issue 97 complete.
