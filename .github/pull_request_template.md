## What changed

<!-- One or two sentences. What does this PR do, and why? -->

## Which package

<!-- Tick exactly the ones you touched. If you ticked more than one team's
     package, say why — that usually means something belongs in ContourApp. -->

- [ ] `Packages/ContourCore` — **the contract** (see the warning below)
- [ ] `Packages/SurfaceUnderstanding` — Team 1
- [ ] `Packages/Tracking` — Team 2
- [ ] `Packages/ContourFeedback` — Team 3
- [ ] `Packages/ContourUI` — Team 4
- [ ] `Packages/ContourMocks` — shared fakes
- [ ] `ContourApp` — app target / wiring
- [ ] `Harness` — macOS test rig
- [ ] Repo plumbing (CI, docs, scripts)

## How it was tested

<!-- Be specific. "It builds" is not a test.
     - `swift test` in which package?
     - Ran on device? Which one, which iOS version?
     - Ran in the Harness? What did you do in it?
     - VoiceOver on, if this touches UI? -->

## Does this touch ContourCore?

- [ ] **No** — merge when one reviewer from my team approves.
- [ ] **Yes** — this changes the shared contract.

> ### If you ticked yes
>
> `ContourCore` is frozen from the end of Week 2. Changing it breaks all four
> teams at once, so it needs **all four team leads** to approve.
>
> - [ ] Tagged all four leads on this PR
> - [ ] Said below what breaks and who has to change code
> - [ ] Updated `COORDINATES.md` if this touches the coordinate convention
> - [ ] Updated `ContourMocks` so the fakes still match the contract
>
> **What breaks and who has to change code:**
>
> <!-- Fill this in. -->

## Screenshots / recordings

<!-- UI or feedback changes: a screen recording with the audio on beats any
     description. Delete this section if it does not apply. -->
