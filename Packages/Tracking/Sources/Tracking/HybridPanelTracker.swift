import ContourCore
import Foundation

/// Coordinates feature selection with geometry, without sharing a backend
/// between references or allowing actor reentrancy to reorder visual mutations.
public actor HybridPanelTracker: PanelTracking {
    private let visual: any CalibratablePanelTracking
    private let makeAlignment: @Sendable () -> any PanelAlignmentPolicy
    private var alignment: any PanelAlignmentPolicy
    private var tail: Task<Void, Never>?
    private(set) var generation: UInt64 = 0
    private var registered = false
    private var frameInFlight: UUID?
    private var selectedCount: Int?

    public init(visual: any CalibratablePanelTracking = FeaturePanelTracker(),
                makeAlignment: @escaping @Sendable () -> any PanelAlignmentPolicy = { HybridAlignment() }) {
        self.visual = visual
        self.makeAlignment = makeAlignment
        alignment = makeAlignment()
    }

    public func startTracking(_ reference: PanelReference) async throws {
        generation &+= 1
        let request = generation
        registered = false
        try await enqueue { try await self.register(reference, request: request) }
    }

    public func stopTracking() async {
        generation &+= 1
        let request = generation
        registered = false
        // Cleanup must run even when its consumer is already cancelled.
        try? await enqueue(cancellable: false) { await self.retire(request: request) }
    }

    public func track(_ frame: CameraFrame) async throws -> PanelObservation {
        guard registered else { return .lost(.notStarted, at: frame.timestamp) }
        guard frameInFlight == nil else { throw PanelTrackingError.frameInFlight }
        let token = UUID()
        let request = generation
        frameInFlight = token
        defer { if frameInFlight == token { frameInFlight = nil } }
        return try await enqueue { try await self.process(frame, request: request) }
    }

    private func register(_ reference: PanelReference, request: UInt64) async throws {
        try check(request)
        do {
            try await visual.startTracking(reference)
            try check(request)
            alignment = makeAlignment()
            selectedCount = nil
            registered = true
        } catch {
            if generation == request { registered = false }
            throw error
        }
    }

    private func retire(request: UInt64) async {
        guard generation == request else { return }
        await visual.stopTracking()
        guard generation == request else { return }
        alignment = makeAlignment()
        selectedCount = nil
    }

    private func process(_ frame: CameraFrame, request: UInt64) async throws -> PanelObservation {
        do {
            try check(request)
            let visualResult = try await visual.track(frame)
            try check(request)
            var policy = alignment
            let wasReady = policy.isCalibrated
            var result = policy.update(visual: visualResult, world: frame.world)
            var count = selectedCount
            if policy.didReset || policy.needsFeatureRestore {
                await visual.resetCalibration()
                try check(request)
                count = nil
            }
            if policy.acceptedCalibrationView {
                await visual.observeCalibrationView()
                try check(request)
            }
            if !wasReady && policy.isCalibrated {
                count = await visual.finishCalibration()
                try check(request)
            }
            // Policy chooses geometry; matching evidence still describes this frame.
            result.featureDiagnostics = visualResult.featureDiagnostics
            result.hybridDiagnostics?.stableFeatures = count
            alignment = policy
            selectedCount = count
            return result
        } catch {
            // A cancelled hook may have mutated the backend; require explicit
            // re-registration rather than reuse a partially committed selection.
            if generation == request { registered = false }
            throw error
        }
    }

    private func check(_ request: UInt64) throws {
        guard generation == request else { throw PanelTrackingError.superseded }
        try Task.checkCancellation()
    }

    private func enqueue<T: Sendable>(cancellable: Bool = true,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task {
            await previous?.value
            if cancellable { try Task.checkCancellation() }
            return try await operation()
        }
        tail = Task { _ = await job.result }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            if cancellable { job.cancel() }
        }
    }
}
