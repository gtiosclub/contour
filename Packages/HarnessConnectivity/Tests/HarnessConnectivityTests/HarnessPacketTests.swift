import ContourCore
import Foundation
@testable import HarnessConnectivity
import Testing

struct HarnessPacketTests {
    private let run = UUID()
    private func packet(_ sequence: UInt64, outcome: OutcomeSignal? = nil) -> HarnessPacket {
        HarnessPacket(version: 1, runID: run, sequence: sequence,
                      kind: outcome == nil ? .snapshot : .event,
                      state: GuidanceState(timestamp: Date(timeIntervalSince1970: 100),
                        vector: outcome == nil ? GuidanceVector(direction: PanelVector(dx: 0, dy: 1), normalizedDistance: 0.4) : nil,
                        outcome: outcome))
    }

    @Test func wireRoundTripPreservesDownwardDirectionAndOutcome() throws {
        for original in [packet(1), packet(2, outcome: .arrived)] {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(HarnessPacket.self, from: data)
            #expect(decoded.state == original.state)
            #expect(decoded.runID == original.runID)
            #expect(decoded.sequence == original.sequence)
            #expect(decoded.isValid)
        }
    }

    @Test func ignoresDuplicatesAndOlderGeometryButRecoversCurrentSnapshot() {
        var inbox = HarnessPacketInbox()
        #expect(inbox.accept(packet(5)) == .guidance)
        #expect(inbox.accept(packet(5)) == .heartbeat)
        #expect(inbox.accept(packet(3), recovering: true) == .heartbeat)
        #expect(inbox.accept(packet(5), recovering: true) == .guidance)
    }

    @Test func outcomesArriveOnceEvenWhenOvertakenBySnapshot() {
        var inbox = HarnessPacketInbox()
        #expect(inbox.accept(packet(4)) == .guidance)
        #expect(inbox.accept(packet(3, outcome: .arrived)) == .guidance)
        #expect(inbox.accept(packet(3, outcome: .arrived)) == .heartbeat)
        #expect(inbox.accept(packet(2)) == .heartbeat)
        #expect(inbox.accept(packet(5, outcome: .lostTracking)) == .guidance)
        #expect(inbox.accept(packet(4), recovering: true) == .heartbeat)
    }

    @Test func rejectsWrongProtocolSessionAndNonfiniteGeometry() {
        var inbox = HarnessPacketInbox()
        #expect(inbox.accept(packet(1)) == .guidance)
        let otherRun = HarnessPacket(version: 1, runID: UUID(), sequence: 2, kind: .snapshot, state: packet(2).state)
        #expect(inbox.accept(otherRun) == .invalid)
        let wrongVersion = HarnessPacket(version: 2, runID: run, sequence: 2, kind: .snapshot, state: packet(2).state)
        #expect(inbox.accept(wrongVersion) == .invalid)
        let nan = GuidanceState(timestamp: Date(), vector: GuidanceVector(direction: .zero, normalizedDistance: .nan))
        #expect(!HarnessPacket(version: 1, runID: run, sequence: 3, kind: .snapshot, state: nan).isValid)
    }
}
