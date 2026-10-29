# Guidance loss feedback (#92)

A frame assessed as lost sends nil-vector/nil-outcome feedback immediately.
The loss announcement follows only after 400 ms of continuous loss and plays
once per episode. Recovery clears the episode. A missing fingertip on usable
panel tracking stays quiet without a loss announcement; valid AR prediction and
arrival use the existing guidance calculation.

`GuidanceLossEpisode` belongs to one guidance loop. Its clock is monotonic,
with an injected clock reading for deterministic tests. No timer survives Stop
or reference replacement. The tracker must keep emitting lost frames during a
gap, as required by the shared stream contract.

The haptics logger records elapsed engine creation/start attempts in milliseconds.
This measures startup cost; it does not change the haptic implementation.

Simulator regressions cover immediate quiet feedback, brief recovery, one
sustained-loss announcement, Stop/replacement, prediction, missing fingers, and
arrival. Device haptic timing still needs a phone. Merge #104 (#91) before this
PR as listed in the issue dependency.
