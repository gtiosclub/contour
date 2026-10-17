# Guidance model bake-off

> **Status: PROVISIONAL — pending the blindfold runs.** No trials have been run.
> `ChosenGuidanceModel.kind` is set to `.continuousProximity` so the app and the
> Harness have a sensible default, but that is a pick from the feel spec and
> tester feedback, not a bake-off result. Fill in the results table below, then
> confirm or change the pick in
> `Packages/ContourFeedback/Sources/ContourFeedback/GuidanceModel.swift`.
> Issues: #54 (this decision), #17 (the models), #120 (sustained vibration).

## The candidates

A guidance model is the *haptic* half of guidance: how distance to the target is
felt. Directional audio, speech and the directional haptic hint are separate
switches on `LiveFeedbackEngine` and in the Harness, so either model can be
tested with or without them. Every tuning number for both is in `GuidanceTuning`
at the top of `GuidanceModel.swift`.

| | `continuousProximity` | `pulsedProximity` |
|---|---|---|
| What you feel | One sustained buzz, like an incoming call | Separate pulses, like a Geiger counter |
| Far edge of the panel | Steady buzz, intensity 0.35, dull (sharpness 0.2) | One soft pulse every 600 ms (intensity 0.35, sharpness 0.3) |
| Getting closer | Buzz gets stronger and crisper, smoothly | Pulses get faster, stronger and crisper |
| Last stretch (< 0.12) | Buzz throbs strong/weak, from every 400 ms speeding up to every 120 ms | Pulses keep speeding up |
| On the button | Intensity 1, sharpness 0.8, throbbing every 120 ms | Sharp pulses every 70 ms, intensity 1, sharpness 0.9 |
| Direction | Not encoded (use audio or the hint) | Not encoded (use audio or the hint) |

The starting list in `GuidanceModel.swift` also had `discreteDirectional`,
`continuousAudioField` and `spokenCorrections`. The first two are now the
directional-hint and audio switches, so they combine with either model rather
than competing with it. Spoken corrections were dropped: speech is the slowest
channel and a correction is stale by the time it is said (see `SpeechQueue.swift`).

## Protocol

Run it in the Harness (`Harness` scheme, My Mac) or on a phone with the
`ContourApp` debug screens. The Harness has an engine picker (choose
`LiveFeedbackEngine`) and a model picker; switching stops the old model first.
The Mac has no haptics, so the haptic comparison itself needs a phone. The
Harness on a Mac is for the audio-assisted runs and for rehearsing the protocol.

1. **At least 3 people**, none of whom built the models. Blindfolded, or eyes
   closed with the screen turned away.
2. **Alternate the order**: half start with `continuousProximity`, half with
   `pulsedProximity`, so learning the task doesn't favour whichever model comes
   second.
3. **5 runs per model per person.** A run: the driver picks a target the tester
   doesn't know, places the finger at a random start, and the tester moves until
   they think they are on the button and says "there".
4. Keep the other switches fixed for every run of the comparison: audio
   **off**, speech **on** (outcomes only), directional hint **off**. A second
   round with audio on is worth doing if time allows; record it separately.
5. Record per run: **arrived?** (finger inside the button when they said
   "there"), **time to "there"**, and any overshoots. After each model, ask:
   *how clear was it?* (1–5) and *how annoying was it?* (1–5).

## How to decide

In this order — a later criterion only breaks a tie in an earlier one:

1. **Arrival accuracy** — share of runs that ended on the button.
2. **Clarity** — mean clarity score, then mean time to "there".
3. **Annoyance** — lower is better. A model people can't stand for a whole
   session loses even if it is a little faster.

## Results

*Empty until the runs happen. Do not fill this in from memory or estimates.*

| Tester | Order (first model) | Model | Runs | Arrived (of 5) | Mean time (s) | Overshoots | Clarity (1–5) | Annoyance (1–5) | Notes |
|---|---|---|---|---|---|---|---|---|---|
| | | `continuousProximity` | 5 | | | | | | |
| | | `pulsedProximity` | 5 | | | | | | |
| | | `continuousProximity` | 5 | | | | | | |
| | | `pulsedProximity` | 5 | | | | | | |
| | | `continuousProximity` | 5 | | | | | | |
| | | `pulsedProximity` | 5 | | | | | | |

**Totals**

| Model | Arrived (of 15+) | Mean time (s) | Mean clarity | Mean annoyance |
|---|---|---|---|---|
| `continuousProximity` | | | | |
| `pulsedProximity` | | | | |

## Provisional pick: `continuousProximity`

**Why, until there is data:**

- Testers asked for it. #120: guidance "only ever feels like taps, never a
  sustained buzz like an incoming call". The continuous model is exactly that.
- It is the only one of the two that can say "how close" at every moment. The
  pulsed model only updates once per pulse, every 600 ms at the far edge, so a
  quick movement can go unnoticed until the next beat.
- The throb in the last stretch keeps the "almost there" cue that the pulses do
  well, where a steady buzz near full strength can't get much stronger.

**Risks to check in the runs:**

- A sustained buzz is more tiring than pulses; watch the annoyance score.
- Directional-hint taps may be harder to feel over a sustained buzz than
  between pulses.
- Small intensity changes in a continuous buzz may be harder to tell apart than
  pulse rates. If arrival accuracy suffers, that is the reason to switch.

If the runs favour `pulsedProximity`, change `ChosenGuidanceModel.kind` and
replace this section with the result. Either way, record the final decision and
the date here and remove the **PROVISIONAL** banner.
