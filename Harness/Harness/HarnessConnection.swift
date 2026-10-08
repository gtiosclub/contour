import ContourCore
import HarnessConnectivity
import Observation

/// Injected into HarnessModel in place of local feedback.
@MainActor
@Observable
final class HarnessConnection: FeedbackEngine {
    let peer = HarnessPeerConnection(role: .mac)

    func start() { peer.start() }
    func stop() { peer.stop() }
    func reconnect() { peer.reconnect() }

    func present(_ state: GuidanceState) async {
        peer.send(state)
    }
}
