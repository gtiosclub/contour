# Arrival hold and feedback lifecycle (#148)

The app pipeline and Test Experience feed geometry through the same
`GuidanceArrivalHold` policy in ContourFeedback. This is a guidance policy,
not a timer owned by the renderer. ContourCore is unchanged.

- Keep MockGuidance's existing 0.05 panel-unit arrival radius as the geometric
  candidate boundary. This is separate from the pulse/continuous boundary.
- Emit `vector: .onTarget, outcome: nil` while holding. Confirm with one
  `.arrived` only after 1,250 ms of valid target samples.
- A retreat, low confidence, tracking loss or non-increasing monotonic time
  resets the policy. So does going 500 ms without a sample that sees the finger
  on the target. Shorter stalls, and frames where hand pose missed the
  fingertip, keep a pending hold (the missed frames still read as on target)
  but can never complete it.
- Completion requires a fresh sample. A stalled stream never confirms arrival.
  The feedback renderer checks freshness every 50 ms and silences stale output.
- A new guidance loop owns a new policy. Stop, replacement, backgrounding,
  audio interruption, and headphone removal invalidate the previous loop.
  Resumption requires fresh guidance; there is no automatic replay.

On-target haptics reuse the continuous Core Haptics player at the selected
maximum intensity, with sharpness 0.12. This produces a smooth texture distinct
from the existing approach curve (sharpness reaches 0.85 at zero distance).
On entering the target, one 80 ms maximum-strength pulse (intensity/sharpness 1)
marks contact while speech immediately says Stop;
subsequent target samples maintain the smooth hold without repeating the tap.
Audio proximity beats stop during the hold; Stop interrupts directional speech
once on entry and is not repeated on subsequent target samples. After the
1,250 ms dwell, the continuous player is stopped before the arrival chime/voice
and standard iOS success haptic begin. Confirmed speech says Target reached
without repeating Stop. The success haptic is a confirmation
signal, separate from both the entry tap and the continuous hold.
The strength slider controls the sustained hold; contact uses maximum strength
whenever haptic intensity is nonzero. Channel switches remain independent; muting haptics does not change the dwell.

The 500 ms freshness budget (the same as the hold's dropout limit) and on-target
texture constants are explicit initial settings, not a claim of physical-device
tuning. Reconcile the selected experiment
with #112 and validate texture, strength, and timing on a phone. The existing
0.25/0.30 approach-mode boundaries are unchanged by this work.

The pipeline explicitly clears a concrete LiveFeedbackEngine even when the
previous guidance task already completed. This cancels remaining confirmation
speech/audio and queued outcome taps. Session generation guards prevent late
tracking reads or superseded replacement tasks from confirming an old hold.

Validation covers pure dwell timing/reset rules, on-target rendering and mute,
freshness expiry, and pipeline scenarios for arrival, interruption, stop, and
reference replacement. Phone checks remain necessary for physical texture and
combined playback with actual camera/audio interruptions.
