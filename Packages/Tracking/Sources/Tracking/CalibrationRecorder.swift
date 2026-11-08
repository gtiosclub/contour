//
//  CalibrationRecorder.swift
//  Tracking
//
//  Debug tooling. Records what the hybrid alignment policy would be fed —
//  each frame's visual observation and its same-frame world snapshot — so an
//  incident can be replayed on a Mac. Not part of the production frame loop.
//

import ContourCore
import Foundation

/// Records a calibration trace from a camera and a visual tracker.
///
/// Subscribes to the frame source it is given; it never opens a camera of its
/// own. Frames are kept in a bounded in-memory buffer and nothing touches the
/// disk while recording: `encodedTrace(notes:)` serializes once it is over.
public actor CalibrationRecorder {
    public struct Configuration: Sendable {
        /// Frames kept. When full, the oldest is evicted, so the buffer holds
        /// the moments just before recording stopped. 1800 is 60 s at 30 Hz.
        public var capacity: Int
        /// Keep one frame in this many; 1 keeps every frame the tracker handles.
        public var everyNthFrame: Int

        public init(capacity: Int = 1800, everyNthFrame: Int = 1) {
            self.capacity = max(1, capacity)
            self.everyNthFrame = max(1, everyNthFrame)
        }
    }

    public enum RecorderError: Error, Equatable {
        case alreadyRecording
        /// `record` has not returned yet. Cancel its task and await it first.
        case stillRecording
    }

    private var buffer: TraceBuffer
    private var isRecording = false

    public init(configuration: Configuration = Configuration()) {
        buffer = TraceBuffer(capacity: configuration.capacity, everyNthFrame: configuration.everyNthFrame)
    }

    /// Track `reference` in `camera`'s frames and record each one, until the
    /// stream finishes or the calling task is cancelled.
    ///
    /// `tracker` should be a fresh instance: tracking is a chain of frames, so
    /// sharing one with the live loop would split that chain between them.
    public func record(camera: any CameraFrameSource, tracker: any PanelTracking,
                       reference: PanelReference) async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        isRecording = true
        defer { isRecording = false }
        try await tracker.startTracking(reference)
        let referenceID = reference.photo.id
        for await frame in await camera.cameraFrames() {
            if Task.isCancelled { break }
            guard buffer.offer() else { continue }
            guard let observation = try? await tracker.track(frame) else {
                // The live loop feeds alignment nothing for a failed frame; nor does the trace.
                buffer.dropOffered()
                continue
            }
            buffer.append(TraceFrame(index: buffer.lastOffered, timestamp: frame.timestamp,
                                     orientation: frame.orientation, referenceID: referenceID,
                                     visual: observation, world: frame.world))
        }
        await tracker.stopTracking()
    }

    /// Frames currently held, for a recording indicator.
    public var recordedFrames: Int { buffer.frames.count }

    /// The recording as trace-file bytes. Throws `stillRecording` until `record`
    /// has returned: the actor is reentrant, so mid-recording a frame can be
    /// counted as offered while its tracking is still in flight.
    public func encodedTrace(notes: TraceNotes) throws -> Data {
        guard !isRecording else { throw RecorderError.stillRecording }
        return try buffer.trace(notes: notes).encoded()
    }
}

/// The recorder's bookkeeping, separate so it can be tested without a camera.
/// Every offered frame ends up either in `frames` or in `dropped`.
struct TraceBuffer {
    let capacity: Int
    let everyNthFrame: Int
    private(set) var frames: [TraceFrame] = []
    private(set) var offered = 0
    private(set) var dropped = 0

    init(capacity: Int, everyNthFrame: Int) {
        self.capacity = capacity
        self.everyNthFrame = everyNthFrame
        frames.reserveCapacity(capacity)
    }

    /// Index of the most recently offered frame: its capture sequence number.
    var lastOffered: Int { offered - 1 }

    /// Count one delivered frame. False when sampling skips it.
    mutating func offer() -> Bool {
        offered += 1
        guard lastOffered % everyNthFrame == 0 else {
            dropped += 1
            return false
        }
        return true
    }

    /// An offered frame that will not be appended.
    mutating func dropOffered() {
        dropped += 1
    }

    mutating func append(_ frame: TraceFrame) {
        if frames.count == capacity {
            // O(capacity), but only once full, and at camera rate on a debug path.
            frames.removeFirst()
            dropped += 1
        }
        frames.append(frame)
    }

    func trace(notes: TraceNotes) -> CalibrationTrace {
        CalibrationTrace(
            notes: notes,
            sampling: .init(framesOffered: offered, framesDropped: dropped, everyNthFrame: everyNthFrame),
            frames: frames)
    }
}
