# Mac Harness to iPhone

The Mac generates `GuidanceState` using the existing `HarnessModel` and
`MockGuidance`. `HarnessConnection` implements `FeedbackEngine` by sending these
states to a nearby iPhone. The shared `HarnessConnectivity` package handles
discovery, encrypted sessions, encoding, delivery, and reconnecting using Apple's
modern async Network framework APIs (`NetworkBrowser`, `NetworkListener`,
`NetworkConnection<TCP>`). Network is supplied by the SDK; no third-party
networking package is downloaded.

Both apps start the connection when active and stop it in the background. The
iPhone integration is enabled only in DEBUG builds. On relaunch both sides start
discovery automatically. Keep both apps in the foreground for blindfold tests.
The phone advertises a Bonjour service; the Mac connects to one matching phone. With several phones
running this developer service, stop the receiver on the phones you do not want
to use. There is no device picker yet.

## Mac UI

The existing `HarnessView` receives its `HarnessModel`. To observe connectivity:

```swift
@Environment(HarnessConnection.self) private var connection
```

Display `connection.peer.status` (`stopped`, `searching`, `connecting`,
`connected`), `peerName`, and `lastError`. A Retry button may call
`connection.reconnect()`; normal restarts do not need a button.

For dot dragging, convert the pointer into normalized panel coordinates and call
`model.moveFingertip(to: PanelPoint(x: x, y: y))`. The origin is top-left and y
increases downward. This method updates both axes together and cancels an
auto-walk. Do not send network messages from the view or assign x and y
separately for one drag update. Existing sliders, target selection, quality
selection, auto-walk, and outcome buttons already feed the remote engine.

Preserve the existing ability to put the fingertip outside 0...1; it is a useful
guidance test. `model.fire(_:)` sends a one-off outcome reliably.

## iPhone UI

Implement `Debug/HarnessReceiverView.swift`, then add a NavigationLink from
`DebugMenu`. The root already owns the receiving controller and supplies it to
the environment:

```swift
@Environment(HarnessConnection.self) private var connection
```

Show connection status, peer name, last error, and whether
`connection.peer.isReceiving` is true. For diagnostics you can display
`connection.lastState`, `connection.lastOutcome`,
`connection.peer.receivedCount`, and `connection.peer.lastReceivedAt`.
`isReceiving` becomes false if no valid packet arrives for two seconds, even if
the network session still reports connected.

Optional controls call `start()`, `stop()`, or `reconnect()` on the controller.
`setFeedbackEnabled(_:)` pauses feedback while leaving reception and inspection
running. Re-enabling resumes the current geometry without repeating an old
outcome. The root handles foreground/background transitions; do not create a
second connection in the page or run the camera pipeline into the same feedback
engine during a Harness session.

## Feedback integration

The current default is `HarnessTemporaryHaptics`: a light UIKit pulse for each
new geometry update (limited to one per 120 ms), and a success/warning pulse for
terminal outcomes. It does not encode direction or proximity, and does not play
audio. English TODO comments mark the future ContourFeedback integration.
`HarnessConsoleFeedback` remains available for previews and log-only testing.
Preview roots inject the controller without starting networking.
`lastState` and `lastOutcome` remain available to the UI.

When the real implementation is ready, construct the root controller with
`HarnessConnection(feedback: LiveFeedbackEngine())` and import ContourFeedback.
Do not make that switch while `LiveFeedbackEngine` still contains `fatalError`.
The injected engine must return promptly from `present(_:)`; the receiver
serializes calls, coalesces pending geometry, and preserves outcome order.
Disconnect or a two-second receive timeout delivers `.lostTracking`; pausing
feedback delivers a state with no vector and no outcome, which the real engine
should interpret as stopping continuous feedback.

## Wire protocol and configuration

Both targets link the same package and declare `_contour-net._tcp` in
`Config/Harness-Info.plist`, together with the local network usage description.
Allow Local Network access when the OS asks. Both apps must run the Network
version: the legacy Multipeer implementation uses a different Bonjour service.
Peer-to-peer Wi-Fi is enabled on the listener, browser, and connection parameters.
There is no server or internet dependency; Network does not provide the old
Multipeer Bluetooth transport.

The TCP connection uses `noDelay(true)`. Each record has a four-byte big-endian
length prefix; zero-length and records over 65,536 bytes are rejected before
reading the body. The initial hello verifies transport protocol, opposite role,
and device name. Ephemeral Curve25519 keys derive separate directional AES-GCM
keys; the encrypted confirmation verifies matching keys before showing connected.
Guidance and heartbeats are encrypted. Automatic discovery does not authenticate
the device identity: use this developer tool on a trusted local network, as with
the previous automatic invitations. No certificates, stored shared password, or
custom OS trust settings are required.

Each JSON packet carries a version, a sender run UUID, a sequence number, a kind,
and a Codable `GuidanceState`. TCP delivers reliably and in order. Drag updates
send immediately; unsent geometry is coalesced to the latest position. Outcomes
retain their order, with a bounded pending queue; overflow closes the connection
rather than silently dropping outcomes. Outcomes are never replayed after
reconnecting. The current snapshot repeats every 250 ms; duplicate snapshots
refresh reception health without replaying feedback. Both sides send encrypted
heartbeats. The receiver stops feedback after two seconds without valid guidance;
a connection with no incoming traffic for four seconds is restarted. Connection
and handshake attempts time out after eight seconds. Mac connection failures
back off from one to eight seconds; discovery failures restart after three seconds.

## Restore the old MultipeerConnectivity implementation

`Legacy/HarnessConnectivity-MultipeerConnectivity.zip` is the pre-migration
snapshot, including the package, tests, both service plists, and previous guide.
It is outside all compilation targets, so it introduces no deprecated symbols.
Its `RESTORE.md` describes restoration. Remove the current package's source
directory before extracting at the repository root: the new Network helper file
must not remain alongside the old implementation. Both app controllers and your
UI retain the same public API. Commit the archive along with the migration if
you want teammates to have the backup after pulling the repository.

## On-device acceptance checks

1. Launch Harness on the Mac and a DEBUG ContourApp build on the iPhone. Allow
   local network access and verify automatic connection.
2. Move the sliders/dot; verify received geometry and direction, including y-down
   and off-panel positions. With real feedback integrated, feel/hear the changes
   immediately. The 250 ms resend is recovery, not a delay on ordinary updates.
3. Fire each outcome and verify it plays once.
4. Restart the phone app, then restart Harness, and verify automatic reconnection
   and restoration of current geometry without replaying previous outcomes.
5. Interrupt connectivity or background one app. Verify the phone does not keep
   guiding from stale geometry and resumes when the apps reconnect.

Protocol unit tests cover Codable compatibility, duplicate/out-of-order
snapshots, timeout recovery of an unchanged position, separately ordered outcomes,
invalid protocol/session/geometry data, bounded TCP framing, directional encryption,
and tamper detection. Network discovery, physical feedback,
and perceived latency still require a Mac and iPhone test.

## Migration validation (2026-10-04)

- Xcode DEBUG builds: ContourApp / iPhone 18 Pro Max (iOS 27 simulator) and
  Harness / My Mac both completed with `No issues`.
- All six protocol/framing/encryption unit tests passed.
- The opt-in local Bonjour integration test passed: automatic discovery, encrypted
  guidance delivery, one-shot outcomes, restart of the phone-side receiver, and
  restart of the Mac-side sender without replaying old outcomes.
- To rerun the integration test on a Mac with local network access:
  `HARNESS_NETWORK_INTEGRATION=1 swift test --package-path Packages/HarnessConnectivity`.
  It uses a unique temporary service and is skipped by ordinary CI test runs.
- Actual iPhone/Mac radio behavior, perceived latency, and physical haptics/audio
  still require an on-device test; the current temporary engine only provides simple UIKit pulses, without audio
  or the team's intended guidance patterns.
