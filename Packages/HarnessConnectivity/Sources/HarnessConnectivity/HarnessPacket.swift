import ContourCore
import Foundation

struct HarnessPacket: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case snapshot, event }
    let version: Int
    let runID: UUID
    let sequence: UInt64
    let kind: Kind
    let state: GuidanceState

    var isValid: Bool {
        guard version == 1, sequence > 0, state.timestamp.timeIntervalSince1970.isFinite,
              (kind == .snapshot) == (state.outcome == nil) else { return false }
        guard let vector = state.vector else { return true }
        return vector.direction.dx.isFinite && vector.direction.dy.isFinite
            && vector.normalizedDistance.isFinite && vector.normalizedDistance >= 0
    }
}

/// State snapshots may arrive out of order. Outcomes have their own reliable
/// sequence and must still be delivered if a newer heartbeat overtakes them.
struct HarnessPacketInbox {
    enum Delivery { case invalid, heartbeat, guidance }
    private var runID: UUID?
    private var snapshotSequence: UInt64 = 0
    private var eventSequence: UInt64 = 0

    mutating func accept(_ packet: HarnessPacket, recovering: Bool = false) -> Delivery {
        guard packet.isValid, runID == nil || runID == packet.runID else { return .invalid }
        runID = packet.runID
        switch packet.kind {
        case .snapshot:
            guard packet.sequence > snapshotSequence
                    || (recovering && packet.sequence == snapshotSequence) else { return .heartbeat }
            snapshotSequence = packet.sequence
        case .event:
            guard packet.sequence > eventSequence else { return .heartbeat }
            eventSequence = packet.sequence
            // Never let pre-outcome geometry reappear after a terminal signal.
            snapshotSequence = max(snapshotSequence, packet.sequence)
        }
        return .guidance
    }
}
