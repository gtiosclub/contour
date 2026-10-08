import ContourCore
import Foundation
@testable import HarnessConnectivity
import Testing

/// Opt in on a Mac: HARNESS_NETWORK_INTEGRATION=1 swift test.
/// Uses a unique Bonjour service so the test never pairs with an app user's phone.
@MainActor
struct HarnessNetworkTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < end else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private struct Timeout: Error {}

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_NETWORK_INTEGRATION"] == "1"))
    func discoveryDeliveryAndRestartEitherSide() async throws {
        let service = "_ct-\(UUID().uuidString.prefix(8).lowercased())._tcp"
        let mac = HarnessPeerConnection(role: .mac, displayName: "Test Mac", serviceType: service)
        let phone = HarnessPeerConnection(role: .phone, displayName: "Test Phone", serviceType: service)
        var states: [GuidanceState] = []
        var interruptions = 0
        phone.onGuidance = { states.append($0) }
        phone.onInterrupted = { interruptions += 1 }
        defer { mac.stop(); phone.stop() }
        let position = GuidanceState(timestamp: Date(), vector:
            GuidanceVector(direction: PanelVector(dx: -0.6, dy: 0.2), normalizedDistance: 0.4))
        mac.send(position)
        phone.start(); mac.start()
        do {
            try await waitUntil { mac.status == .connected && phone.status == .connected && phone.isReceiving }
            #expect(mac.peerName == "Test Phone")
            #expect(phone.peerName == "Test Mac")
            #expect(states.last == position)
            mac.send(GuidanceState(timestamp: Date(), vector: nil, outcome: .arrived))
            try await waitUntil { states.contains { $0.outcome == .arrived } }
            try await Task.sleep(for: .milliseconds(600))
            #expect(states.filter { $0.outcome == .arrived }.count == 1)
            mac.send(position)
            try await waitUntil { states.last == position }
            phone.stop()
            try await waitUntil { mac.status != .connected }
            #expect(interruptions == 1)
            phone.start()
            try await waitUntil { mac.status == .connected && phone.status == .connected && phone.isReceiving }
            #expect(states.last == position)
            #expect(states.filter { $0.outcome == .arrived }.count == 1)
            mac.stop()
            try await waitUntil { !phone.isReceiving }
            mac.start()
            try await waitUntil { mac.status == .connected && phone.status == .connected && phone.isReceiving }
            #expect(states.last == position)
            #expect(states.filter { $0.outcome == .arrived }.count == 1)
        } catch {
            Issue.record("Mac: \(mac.status), \(mac.lastError ?? "no error"); Phone: \(phone.status), \(phone.lastError ?? "no error")")
            throw error
        }
    }
}
