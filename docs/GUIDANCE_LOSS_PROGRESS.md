# Guidance loss feedback — #92 progress

The current loop debounces loss by skipping feedback for 0.3 seconds. That can
leave the previous directional vibration active during a brief gap. The loss
announcement and immediate quiet feedback need separate decisions.

This draft adds `GuidanceLossEpisode`, a loop-local monotonic policy. The first
unusable observation returns `quiet`; at 400 ms it returns `announceLoss` once.
Usable evidence resets the episode, and a new session owns a new policy value.
It spawns no delayed task that could announce in a later session. Tests use
synthetic instants and do not sleep.

Still pending: wire decisions into the pipeline, send nil vector/outcome on
actual unusable tracking immediately, preserve arrival and current usable AR
prediction, extend the existing end-to-end loss/cancellation regression, and
add small haptic creation/start duration logs with the feedback owner. No app
feedback behavior changes in this draft. #91 is the preceding dependency.
