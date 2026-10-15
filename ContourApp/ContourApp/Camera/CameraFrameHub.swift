import CoreMedia
import Foundation
import Synchronization
import Tracking

/// Fans one capture producer out to independent subscribers.
///
/// Each subscriber has its own newest-frame buffer, so a slow preview never
/// delays tracking, and cancelling one stream leaves the others running. A
/// capture run is a `Generation`: `end()` finishes every stream, and a frame
/// captured before the current generation began is dropped, so a callback
/// still queued from a stopped session cannot reach the restarted one.
nonisolated final class CameraFrameHub: Sendable {
    /// One capture run. `id` doubles as the world session identity: every
    /// restart gets a fresh one, because AR world coordinates do not survive it.
    nonisolated struct Generation: Sendable, Equatable {
        let id: UUID
        /// Host-clock seconds, the clock behind sample buffer and ARFrame timestamps.
        let startTime: TimeInterval
    }

    private struct State {
        var generation: Generation?
        var subscribers: [UUID: AsyncStream<CameraFrame>.Continuation] = [:]
    }

    private let state = Mutex(State())

    var current: Generation? { state.withLock { $0.generation } }
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// Host-clock time now, comparable with capture timestamps.
    static var hostTime: TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    @discardableResult
    func begin(at startTime: TimeInterval = hostTime) -> Generation {
        let generation = Generation(id: UUID(), startTime: startTime)
        state.withLock { $0.generation = generation }
        return generation
    }

    /// Stop or failure: finish every stream and reject frames until `begin`.
    func end() {
        let finished = state.withLock { state in
            state.generation = nil
            defer { state.subscribers.removeAll() }
            return Array(state.subscribers.values)
        }
        // Outside the lock: finishing runs onTermination, which takes it again.
        finished.forEach { $0.finish() }
    }

    func subscribe() -> AsyncStream<CameraFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CameraFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        state.withLock { $0.subscribers[id] = continuation }
        return stream
    }

    /// Delivers `frame` if it was captured during the current generation.
    @discardableResult
    func publish(_ frame: CameraFrame, capturedAt captureTime: TimeInterval) -> Bool {
        publish(capturedAt: captureTime) { _ in frame }
    }

    /// Builds the frame only once it is known to belong to the current
    /// generation, so world data is stamped with that generation's identity.
    @discardableResult
    func publish(capturedAt captureTime: TimeInterval, _ makeFrame: (Generation) -> CameraFrame) -> Bool {
        let accepted = state.withLock { state -> (Generation, [AsyncStream<CameraFrame>.Continuation])? in
            guard let generation = state.generation, captureTime >= generation.startTime else { return nil }
            return (generation, Array(state.subscribers.values))
        }
        guard let (generation, targets) = accepted else { return false }
        // If end() races this, those streams are already finished and drop it.
        let frame = makeFrame(generation)
        targets.forEach { $0.yield(frame) }
        return true
    }
}
