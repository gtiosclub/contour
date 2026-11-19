import ContourCore
import Foundation

/// A request is one attempt at one button, not the button itself.
struct TargetGuidanceRequest: Sendable {
    let id: UUID
    let target: SurfaceMap.Button
    let reference: PanelReference
}

enum TargetGuidanceEvidence: Sendable {
    case arrived
    case endedWithoutArrival
}

enum TargetRequestStatus: Equatable {
    case reached
    case endedWithoutArrival
    case cancelled
    case invalidTarget
}

struct TargetRequestResult: Equatable {
    let requestID: UUID
    let target: SurfaceMap.Button
    let referenceID: UUID?
    let status: TargetRequestStatus
}

/// Runs one target at a time. The operation must report confirmed arrival,
/// not just return when its frame stream ends.
@MainActor
final class TargetRequestTracker {
    typealias Operation = @MainActor (TargetGuidanceRequest) async -> TargetGuidanceEvidence

    private let operation: Operation
    private(set) var reference: PanelReference?
    private var revision: UInt64 = 0
    private var active: (id: UUID, task: Task<TargetGuidanceEvidence, Never>)?

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func use(_ reference: PanelReference?) {
        invalidate()
        self.reference = reference
    }

    func stop() {
        invalidate()
    }

    func guide(to target: SurfaceMap.Button) async -> TargetRequestResult {
        let id = UUID()
        invalidate()
        let current = reference
        guard let current, current.detection.map.buttons.contains(target) else {
            return TargetRequestResult(requestID: id, target: target,
                                       referenceID: current?.photo.id, status: .invalidTarget)
        }

        let request = TargetGuidanceRequest(id: id, target: target, reference: current)
        let token = revision
        let operation = self.operation
        let task = Task { await operation(request) }
        active = (id, task)

        let evidence = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        // A previous task can finish even after cancellation. Its result is
        // never allowed to complete the next request (including the same key).
        guard revision == token, active?.id == id,
              !task.isCancelled, !Task.isCancelled else {
            return TargetRequestResult(requestID: id, target: target,
                                       referenceID: current.photo.id, status: .cancelled)
        }
        active = nil
        return TargetRequestResult(requestID: id, target: target,
                                   referenceID: current.photo.id,
                                   status: evidence == .arrived ? .reached : .endedWithoutArrival)
    }

    private func invalidate() {
        revision &+= 1
        active?.task.cancel()
        active = nil
    }
}
