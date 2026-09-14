# Contour — timeline and gates

Distilled from [`Contour.pdf`](Contour.pdf), the club timeline doc. Eleven weeks from kickoff; Week 1 starts **Monday
Sep 14**. Week 11 lands on Thanksgiving week (Nov 23–27), so the club needs to
confirm Demo Day and shift the last two weeks if needed.

## At a glance

| Week | Dates | Focus | What exists by the end |
|---|---|---|---|
| 1 | Sep 14–18 | Setup + teams | Teams assigned, repo ready, everyone can build |
| 2–3 | Sep 21 – Oct 2 | Core systems | Basic panel parsing, finger and panel tracking, guidance, camera UI — each working alone |
| 4–5 | Oct 5–16 | Working prototype | A finger is guided to a detected button on a real appliance |
| 6–7 | Oct 19–30 | Reliable core | Works across realistic conditions with clear errors; outside testers can use it |
| 8–9 | Nov 2–13 | Product expansion | The highest-value features the core can support |
| 10 | Nov 16–20 | Testing + stabilization | Demo build works repeatedly on real appliances |
| 11 | Nov 23–27 | Freeze + Demo Day | Feature freeze, polish, rehearsal, backup plan |

## Week boundaries

Week 1 starts Monday Sep 14, so each week runs Monday to Friday:

| Week | Mon | Fri |
|---|---|---|
| 1 | Sep 14 | Sep 18 |
| 2 | Sep 21 | **Sep 25 ← interfaces freeze, guidance model chosen** |
| 3 | Sep 28 | Oct 2 |

"Weeks 2–3" in the table above spans Sep 21 – Oct 2, but the **end-of-Week-2
gate is Friday Sep 25**, not Oct 2. Easy to misread; it costs a week.

## The four gates that don't slip

1. **End of Week 1** — everyone builds and runs the project on a device. If not,
   that gets fixed before anything else.
2. **End of Week 2** — interfaces (`SurfaceMap`, `TrackingFrame`,
   `GuidanceState`) and the coordinate convention are **frozen**. Guidance model
   chosen from the bake-off.
3. **End of Week 5** — the vertical slice works on a real appliance. If it
   doesn't, Weeks 6–7 are spent making it work and Weeks 8–9 shrink.
4. **Start of Week 8** — expansion features chosen based on what guidance can
   actually do. If guidance is still unreliable, we improve it instead.

## Weeks 2–3 deliverables by track

Each team's own README expands on these.

**[Surface Understanding](../Packages/SurfaceUnderstanding/README.md)** — detect
an appliance interface in a photo · identify basic buttons and labels · produce a
basic `SurfaceMap` · hand-label the test set

**[Tracking / Spatial](../Packages/Tracking/README.md)** — track the index
fingertip · track the panel as the phone moves · report finger position relative
to a known target

**[Feedback / Guidance](../Packages/ContourFeedback/README.md)** — run the
guidance model bake-off (Week 2) and pick one · prototype proximity haptics ·
prototype directional audio · define success and lost-tracking feedback with
Design

**[Product / UI](../Packages/ContourUI/README.md)** — live camera experience ·
basic target selection and guidance flow · mocks for all three interfaces
(shipped Mon Sep 21) · first integration build Fri Oct 2

**Design** — state-by-state feel spec, agreed with Feedback and Product · camera
acquisition and target selection flows. *No Swift package: Design's Weeks 2–3
deliverables are specs and flows, not code. If Design ends up owning shipped
assets or a design system, give it a folder then.*

**Checkpoint for Weeks 2–3:** we can separately show where a button is, where the
finger is, where it needs to move, and how that movement is communicated.

## Everyone, Week 1

- Clone, build, and run on a **physical device**. Signing problems get solved in
  Slack, not alone.
- Send **five photos of appliance panels** you have access to. That is the first
  test set, and Team 1 hand-labels it.
- Device inventory: anyone without an iPhone 15 Pro or newer gets paired with
  someone who has one.

## Later, worth knowing now

**Weeks 4–5** — mocks come out one at a time. Expect coordinate-system, latency,
and lost-tracking problems; write down what gets decided. Internal demo Fri Oct
16: someone who didn't build it tries it on a real microwave.

**Weeks 6–7** — reliability and accessibility. Testing with people outside the
team; reach out to CIDI in Week 6 for testers in Week 7. At least five
appliances, two lighting conditions.

**Weeks 8–9** — candidate expansions, *not* a commitment to all of them: Explore
Panel · Read Display · Low-Vision Mode · Onboarding tutorial · Saved Appliances ·
Simple Task Mode. One owner each, one-week cut line. **If guidance is still
unreliable, improve it instead of adding features.**

**Week 10** — fix in this order: incorrect guidance → crashes → tracking or
recognition failures → speed → confusing UX → polish.

**Week 11** — feature freeze. Rehearse twice, once with the real appliance and
projector. Ideally the person holding the phone at the demo is from the audience,
with their eyes closed.
