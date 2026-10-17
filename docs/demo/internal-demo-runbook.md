# Internal demo runbook (issue #108)

**The goal:** someone who did not build Contour tries it on a real microwave,
and we write down what actually happens. This is a test, not a show. A failure
that gets written down is worth more than a run that went well because someone
coached the tester.

Roles: a **tester** (did not build it, has never used it), a **driver** (sets
up, reads the script, does not help once the run starts), and a **recorder**
(fills in the results table and files the issues). The driver and the recorder
can be the same person, but the tester cannot be either.

Button names and screens below match the app at the time of writing. If the
app has changed, follow the steps that still apply and note what was different.

---

## 1. Pre-flight checklist (driver, about 15 minutes before)

### Build and signing
- [ ] On the commit being demoed, `main` CI is green. Write down the commit hash.
- [ ] Your local `ContourApp/Config/Signing.xcconfig.local` has your team and
      bundle ID (see the root README, "Run on device").
- [ ] Build the **ContourApp** scheme in the **Debug** configuration on the
      device from `Contour.xcworkspace`, not from the `.xcodeproj`.
- [ ] On a free account the developer profile is trusted
      (Settings → General → VPN & Device Management).
- [ ] Launch once. The **Pipeline** section shows every component as **live**.
      If anything says "mocked", you are on the simulator or on the wrong
      build, so stop and fix that first.

### Device
- [ ] iPhone 15 Pro or newer, on iOS 27, charged above 60%, Low Power Mode off.
- [ ] Do Not Disturb or a Focus mode is on, so notifications don't talk over guidance.
- [ ] Auto-Lock is set to Never, or 5 minutes, for the session.
- [ ] The camera lens is clean.

### Permissions (accept them before the tester arrives, then check them)
- [ ] Camera: allowed.
- [ ] Microphone: allowed.
- [ ] Speech Recognition: allowed.
- [ ] If you reinstalled the app, the prompts come back. Accept them again now
      so the tester doesn't see a system dialog first.

### Guidance model
- [ ] Write down the guidance model in use: `ChosenGuidanceModel.kind` in
      `Packages/ContourFeedback/Sources/ContourFeedback/GuidanceModel.swift`.
      If it is `nil`, write down what `LiveFeedbackEngine` actually renders
      (for example, "proximity haptics only").
- [ ] Do one quick run yourself to confirm that you can feel it and hear it.

### Volume, haptics and audio route
- [ ] The ringer switch is not on silent, and system haptics are on
      (Settings → Sounds & Haptics).
- [ ] Media volume is at about 70%. Check it with one spoken prompt.
- [ ] Choose the **speaker** or **headphones** and write down which:
  - Speaker: the room hears it too, so keep the room quiet.
  - Headphones: Bluetooth adds latency to audio and speech, which is worth
    recording separately. Wired or AirPods both count; note which.
- [ ] VoiceOver: decide whether it is on or off and record that. Keep the same
      setting for every run.

### Appliance and room
- [ ] A real microwave with a printed keypad. Note the make, the model and
      whether it has any icon-only buttons.
- [ ] The microwave is **unplugged, or the door is open**, so nothing actually heats.
- [ ] Lighting: write down the conditions (overhead office light, window
      glare, and so on).
- [ ] Mark a standing spot about 40 to 60 cm from the panel.
- [ ] Have a stopwatch ready (a phone is fine) and this table open.

---

## 2. Tester script (the driver reads this aloud)

Say this before starting:

> "This app helps you press a button on a panel you can't see. I'll tell you
> what to say. After that I can't help you. Think out loud: tell me what you
> hear and feel, and when you're confused. There are no wrong answers, because
> we're testing the app, not you."

Ask the tester to close their eyes, or put on a blindfold, once the app is open.

| Step | Driver says / does | The tester does | Expected |
|---|---|---|---|
| 1. Launch | Hand over the phone with Contour open on its main screen. | Holds the phone. | No permission prompts appear. |
| 2. Point | "Point the phone at the microwave, about an arm's length away." | Aims at the panel. | The panel fills most of the camera view. |
| 3. Scan | "Tap **Scan panel**." (Guide their thumb the first time only, and write down that you did.) | Taps. | Buttons are detected. Write down the time from tap to result. |
| 4. Say "Start" | "Tap **Say a button**, then say 'Start'." | Speaks. | The heard text matches **Start** and guidance begins. |
| 5. Follow | "Move your finger toward the button the phone is guiding you to. Keep the phone pointed at the panel." | Follows haptics, audio and speech. | Direction cues point toward Start. Feedback gets more intense as the finger gets closer. |
| 6. Arrival | Say nothing. Watch. | Stops when they think they're there. | The arrival signal plays with the fingertip on Start. Write down where the finger actually is. |

Then repeat steps 3 to 6 for **two more targets**: one that is easy (large and
well labelled) and one that is hard (small, icon-only or poorly printed). Note
which buttons you chose.

**Stop the run** (and record why) if the tester has followed guidance for 60 s
without arriving, if the app crashes, or if the tester asks to stop.

---

## 3. What to observe and record

Write down what happened, not what you think caused it. Times come from the
stopwatch.

- **Direction errors:** the cue sent the finger the wrong way. Note which
  axis, because a consistent up/down swap points at a y-axis or coordinate bug
  (see `Packages/ContourCore/COORDINATES.md`). Also note left/right mirroring
  and "it said down but the target was up".
- **Position errors at arrival:** "arrived" played, but the finger was not on
  the target. Note which button it was really on, or how far away it was in
  cm.
- **Latency:** the time from tap to scan result, and from "Start" spoken to the
  first guidance cue. Also note any visible lag between a finger movement and
  the feedback changing. Note the audio route if it was Bluetooth.
- **Lost tracking:** how often it happened, what caused it (the hand covered
  the panel, the phone drifted, glare), and whether it recovered on its own.
- **Recognition misses:** the panel was not found, a button was missing or
  mislabelled, or speech was misheard. Write down exactly what the app heard.
- **Confusing speech or feedback:** quote the prompt the tester didn't
  understand, and note any cues that overlapped or that talked over the tester.
- **Tester quotes:** write down anything they say about feel, confidence or
  trust, word for word.
- **Crashes or hangs:** the time, the step, and whether there was a crash log
  (Xcode → Devices and Simulators → View Device Logs).

---

## 4. Results table (one row per attempt)

Copy this table into the demo notes. Leave the cells empty until something
actually happens.

Session details: date, commit hash, device and iOS version, microwave
make/model, lighting, audio route, VoiceOver on or off, and guidance model.

| # | Tester | Target | Scan OK? (time) | Heard as | First cue (s) | Direction errors | Lost tracking (count, recovered?) | Arrived? (time) | Finger really on target? | Notes and quotes | Issue # |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 |  | Start |  |  |  |  |  |  |  |  |  |
| 2 |  |  |  |  |  |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |  |  |  |  |  |

**Summary** (fill in after the session): attempts N, arrived on the correct
button M, median time to arrival, and the top three problems in the Week 10
fix order (incorrect guidance → crashes → tracking or recognition failures →
speed → confusing UX → polish).

---

## 5. File one issue per failure

One failure, one issue, filed on the same day while the details are fresh.
Link the issue number back in the results table. Don't group failures
together, because each one goes to a different team.

**Labels** (these exist in the repo today): `bug`, plus the team that owns the
symptom: `Surface Understanding` for scan, button or label misses, `Tracking`
for the fingertip or panel being lost or misplaced, and `Experience` for
feedback, speech, flow or confusing UX. If you can't tell which team owns it,
use `bug` + `question` and a lead will triage it. Put `[demo-108]` and the
category from the Week 10 fix order (wrong guidance / crash / tracking /
recognition / latency / UX) in the title, since there are no labels for those.

```markdown
**Title:** [demo-108][<category>] <what went wrong, in one line> — e.g. "[demo-108][wrong guidance] Says 'down' when Start is above the finger"
**Labels:** bug, <Surface Understanding | Tracking | Experience>
**Related:** #108

**Attempt:** results-table row #<n>, tester <initials>, target "<button>"
**Build:** <commit hash>, Debug, <device> / iOS <version>
**Setup:** <microwave make/model>, <lighting>, <speaker|headphones (type)>, VoiceOver <on|off>, guidance model <kind>

**What happened**
<Factual, step by step. Use the tester's words in quotes.>

**What should have happened**
<The expected result, from the tester script.>

**How often**
<n of m attempts. Was it reproducible by the driver afterwards? yes/no>

**Evidence**
<Screen recording, photo of finger position, console log, crash log — attach or link.>

**Suspected area** (optional — a guess, not a diagnosis)
<e.g. coordinate convention (y-down), TargetMatcher, LiveTrackingSource, SpeechQueue>
```
