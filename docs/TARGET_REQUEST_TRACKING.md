# Target requests (#171)

TargetRequestTracker lives in ContourApp. One guide call is one attempt, with a fresh ID, its button, and the photo ID of the reference used. Repeating the same button doesn't repeat the request ID.

A scripted caller can run four steps on one prepared panel:

~~~swift
tracker.use(reference)
for target in [one, zero, zero, start] {
    let result = await tracker.guide(to: target)
    guard result.status == .reached else { break }
    // This request reached its target. The caller chooses the next step.
}
~~~

The injected operation returns .arrived only on confirmed arrival, and .endedWithoutArrival if guidance simply ends. ContourPipeline already uses GuidanceArrivalHold for its 1.25-second dwell; don't add a second timer.

For the current guidance path, this is a temporary adapter:

~~~swift
let tracker = TargetRequestTracker { request in
    await pipeline.guide(to: request.target)
    return pipeline.guidanceArrived ? .arrived : .endedWithoutArrival
}
tracker.use(reference)
~~~

Here the pipeline's confirmed arrival state is just evidence for the operation. The result belongs to request.id; the caller never uses the shared Boolean to decide which step finished. When integration exposes a per-request result from the pipeline, replace only this adapter.

Call tracker.stop() along with the pipeline Stop action. Call tracker.use(newReference) on panel replacement before guiding any new button. These calls invalidate old requests immediately, but do not replace the pipeline's own cancellation. The component does not own the camera, plan queue, UI, or speech.

The scripted tests cover A/B/C, [1, 0, 0, Start], interrupted holds and retry, targets outside the reference, and arrivals delayed past Stop, supersession, cancellation, or replacement.