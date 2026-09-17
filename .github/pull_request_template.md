## What changed

<!-- One or two sentences. What does this PR do, and why? -->

## Which package

<!-- Tick exactly the ones you touched. If you ticked more than one team's
     package, say why — that usually means something belongs in ContourApp.
     Experience owns three packages: ticking ContourFeedback and ContourUI
     together is still two packages, and still worth a sentence. -->

- [ ] `Packages/ContourCore` — **the contract** (see the warning below)
- [ ] `Packages/SurfaceUnderstanding` — Surface Understanding
- [ ] `Packages/Tracking` — Tracking / Spatial
- [ ] `Packages/ContourFeedback` — Experience
- [ ] `Packages/ContourUI` — Experience
- [ ] `Packages/ContourMocks` — shared fakes (Experience)
- [ ] `ContourApp` — app target / wiring
- [ ] `Harness` — macOS test rig (Experience)
- [ ] Repo plumbing (CI, docs, scripts)

## Which lane

<!-- Each junior owns a lane; officers own the rest. Name the lane this PR sits
     in, e.g. "Surface / Panel Reader" or "Experience / Audio & Speech". The
     file headers say which lane a file belongs to. -->

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
> `ContourCore` is frozen from the end of Week 2. Changing it breaks all three
> teams at once, so it needs the leads of **all three teams** to approve —
> Surface Understanding, Tracking / Spatial, and Experience. Not one team, not a
> majority.
>
> - [ ] Tagged the leads of all three teams on this PR
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
