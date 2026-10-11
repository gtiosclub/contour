# Manual reference setup and restart integration

Issue #20's developer setup can be exercised before Surface Understanding is
complete: take a photo of the supplied six-button microwave fixture (print it
or display it on another screen), open **Tracking Diagnostics → Prepare manual
panel reference**, choose that captured photo, and tap the *outer* panel's
TL/TR/BR/BL corners in order. The app orients the photo upright, then builds a
`PanelReference` with `MockSurfaceMaps.microwave`. Only use that supplied layout
with the matching fixture; its button positions are not meaningful on another
appliance. No still-image detector runs in this path.

The debug screen can replace a prepared reference without leaving the screen.
Replacement clears its selected debug target and displayed diagnostics; a
processor result already in flight is discarded if it belongs to the prior
display generation. A failed photo load can be retried from the setup sheet.

The current debug screen reports **prepared**, not **tracking**. The repository's
`PanelTracker.startTracking` and `stopTracking` still call `fatalError`, and
`ContourPipeline` has no cancellation/replacement interface. Do not call those
stubs from the UI or claim live restart works until issue #8 and issue #21 land.

## Interface to agree with Miguel and the integration owners

- Miguel: a repeatable `startTracking(reference)` and `stop/reset` operation,
  including a clear signal when initial registration fails or tracking is lost.
- Integration owners: one replacement entry point that cancels/awaits the old
  processing task, invalidates old results, clears the old target selection,
  stops the old tracker, and starts the new reference. Its result should give
  the debug screen a current status or an error for retry. A monotonically
  increasing session generation can guard delayed old-frame callbacks.
- Aditya: pass the manually prepared reference into that entry point, show
  initialization errors, keep a retry action, and verify that result/target IDs
  belong only to the new reference after replacement.

## Validation once the interfaces land

1. Start using the captured fixture photo and marked corners; see current
   tracking observations from that reference.
2. Cover or move the panel to reach lost state, then prepare a new reference
   and restart without leaving the screen.
3. Replace while old frames are still processing. Check that every displayed
   result after replacement belongs to the new session, and the previous target
   is cleared or reselected from the new layout.
4. Try a bad image or invalid initialization, then retry from the same screen.
