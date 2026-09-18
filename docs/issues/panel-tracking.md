# Track a known panel between two fixture images

**Lane:** Panel Registration & Lost Tracking (Miguel)

**Goal:** Use Vision's modern `TrackRectangleRequest` to follow a known panel
after a small camera movement.

## Tasks
- Add two images of a printed panel and record the first image's corners as a
  `PanelQuad`. Package test fixtures belong in declared SwiftPM test resources.
- Construct a `PanelReference`; convert its quad to a Vision `RectangleObservation`.
  Initialize one stateful tracking request on the reference image, then process
  the second image sequentially with that same request. Reset between test runs.
- Return a Tracking-owned result containing the updated quad, confidence,
  timestamp, and success/loss status. Handle orientation and Vision-to-Core
  coordinate conversion; preserve logical corner identities.
- Add a debug-only “Run panel fixture” option in ContourApp. Display the second
  fixture image with its returned outline/confidence, not the live camera feed.
  Bundle the fixtures for this screen as well; the app cannot load test resources.
- Add a repeatable package test comparing against manually marked second-image
  corners with a documented tolerance. Include an unusable/blank-image fixture
  and explicitly report tracking failure or any limitation discovered.

**Done when:** The second-image outline aligns with the panel, repeat runs are
consistent, and unusable results are not presented as trustworthy tracking.

**Out of scope:** Automatic detection, live-camera integration, reacquisition,
and 3D pose. No new Core type or separate test app is needed.
