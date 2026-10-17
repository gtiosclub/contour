# Outcome signals: what each ending feels, sounds and says

> **v1 — to be confirmed with Design (Kaylee).** This is Experience's proposal
> for issue #55 (and the earcons for #115). Nothing here has been through a
> blindfold test yet. Change it with Design, then update
> `Packages/ContourFeedback/Sources/ContourFeedback/OutcomeAnnouncer.swift` and the
> tests in `OutcomeSignalTests.swift` together.

Contour has exactly four endings (`OutcomeSignal`, frozen in ContourCore). Each
one is presented on three channels at once, so it still gets through with the
sound off, in a loud kitchen, or with VoiceOver talking:

1. **Haptics** — a short pattern of taps. Works when nothing else does.
2. **Earcon** — a sound under half a second long, played through the same audio
   engine as the guidance tone. The notes land with the taps.
3. **Speech** — one short sentence, sent to `SpeechQueue`. It waits for the earcon
   to finish (`Utterance.leadIn`) so the first word isn't masked by the chime.

When an outcome arrives, guidance stops first: the haptic guidance (buzz or
pulses) and the directional tone are both silenced, because a proximity signal
running under a success chime reads as "keep going".

## The four signals

| Outcome | Haptics | Earcon | Speech |
|---|---|---|---|
| `arrived` | Three strong, sharp taps 100 ms apart (intensity 1, sharpness 0.9) | Bright, rising two-note chime: A5 (880 Hz) for 100 ms, then E6 (1319 Hz) ringing out for 300 ms | "You're on it." |
| `lostTracking` | Three dull taps 250 ms apart, fading out (0.9 → 0.6 → 0.3, sharpness 0.2) | One tone gliding down an octave (660 → 330 Hz) over 500 ms while fading away | "Lost the panel. Point the camera at it again." |
| `notFound` | Two heavy, dull taps 320 ms apart (0.9 and 0.8, sharpness 0.1) | Low double "no-pe": 233 Hz for 150 ms, then 196 Hz (a step lower) for 200 ms, landing with the taps | "That button isn't on this panel." |
| `lowConfidence` | Four light, crisp taps 90 ms apart, a flutter (0.4, sharpness 0.7) | Mid-pitch wavering trill: D5/E5 (587/659 Hz) alternating every 45 ms for 360 ms | "I'm not sure I see it. Try aiming again." |

All four interrupt whatever is playing, and their speech is queued at
`.interrupting` priority with a 3-second lifetime, so a line from one session
cannot land in the next.

A guidance pipeline reports the same outcome on every frame while it holds
(`MockGuidance` sends `arrived` at camera rate while the finger is on the button).
`LiveFeedbackEngine` announces an outcome once, and again only after guidance
has resumed in between and at least two seconds have passed. That stops a
finger wobbling on the edge of the button from re-announcing on every frame.

## Why these

- **arrived** is the one happy ending, so it is the brightest, highest, most
  "finished" sound: a rising interval that resolves and rings. The taps are the
  strongest and sharpest in the vocabulary.
- **lostTracking** is "something slipped away": a falling glide that fades, and
  taps that fade with it. Nothing is wrong with the request; the camera just
  needs re-aiming, and the words say so.
- **notFound** is a definite, calm *no*. Two low, heavy, evenly spaced notes,
  the second lower — the shape of "no-pe" or "uh-uh". It should feel final.
- **lowConfidence** is *maybe*. A light, quick, wavering trill in the middle
  register, never settling, with fluttering taps to match. It should feel
  unfinished, inviting another try.

## How notFound is kept apart from lowConfidence

These two send the user to opposite next actions — give up on that control vs
re-aim and try again — so they differ on every dimension we control, not just
one:

| | `notFound` | `lowConfidence` |
|---|---|---|
| Register | Low (~215 Hz) | Mid (~620 Hz), almost 1.5 octaves higher |
| Rhythm | Two slow notes with a gap | Eight fast, even notes with no gaps |
| Contour | One falling step, then stops | Wavers up and down, never settles |
| Touch | Two heavy, dull taps | Four light, crisp taps |
| Words | "isn't on this panel" (final) | "not sure… try aiming again" (retry) |

`OutcomeSignalTests` pins this: the earcons must differ in at least two of
register, rhythm and contour (today they differ in all three), and the haptics
must differ in count, sharpness and intensity.

## Open questions for Design

- Are the sentences right? They are written to be heard, not read, and kept
  short because VoiceOver may already be talking.
- Should `lowConfidence` and `notFound` interrupt, or wait for a line in
  progress? Today all four interrupt.
- Is the `arrived` chime too bright on a phone speaker at full volume?
- The low `notFound` notes rely on their harmonics to come through a phone
  speaker. Check it on a device, speaker and headphones, before signing off.
