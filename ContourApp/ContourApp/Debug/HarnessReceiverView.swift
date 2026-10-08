import ContourCore
import HarnessConnectivity
import SwiftUI

struct HarnessReceiverView: View {
    @Environment(HarnessConnection.self) private var connection

    var body: some View {
        List {
            Section("Harness Receiver") {
                LabeledContent("Connection Status") {
                    Label(statusTitle, systemImage: statusSymbol)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(statusColor)
                }
                LabeledContent("Connected Mac", value: connection.peer.peerName ?? "Not connected")
                LabeledContent("Currently Receiving", value: connection.peer.isReceiving ? "Yes" : "No")
                if let error = connection.peer.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Connection Error", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                LabeledContent("Guidance", value: guidanceTitle)
                LabeledContent("Direction X", value: number(currentVector?.direction.dx))
                LabeledContent("Direction Y", value: number(currentVector?.direction.dy))
                LabeledContent("Normalized Distance", value: number(currentVector?.normalizedDistance))
                LabeledContent("Latest Outcome", value: outcomeTitle(connection.lastOutcome))
            } header: {
                Text("Tracking Information")
            } footer: {
                Text("Positive X points right; positive Y points down. Distance is 0 at the target and may exceed 1 outside the panel. Values show — when guidance is unavailable.")
            }

            Section {
                Toggle("Vibration Feedback", isOn: Binding(
                    get: { connection.feedbackEnabled },
                    set: { connection.setFeedbackEnabled($0) }
                ))
            } header: {
                Text("Feedback")
            } footer: {
                Text("Simple vibration is available on a real iPhone. Directional haptics and audio will be connected later. Turning this off keeps receiving data.")
            }

            Section("Reception Details") {
                LabeledContent("Received Updates", value: connection.peer.receivedCount.formatted())
                LabeledContent("Last Received", value: timestamp(connection.peer.lastReceivedAt))
                LabeledContent("State Timestamp", value: timestamp(connection.lastState?.timestamp))
            }

            Section {
                Button {
                    connection.start()
                } label: {
                    Label("Start Receiver", systemImage: "play.circle")
                }
                .disabled(connection.peer.status != .stopped)

                Button {
                    connection.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .disabled(connection.peer.status == .stopped)

                Button {
                    connection.stop()
                } label: {
                    Label("Stop Receiver", systemImage: "stop.circle")
                }
                .disabled(connection.peer.status == .stopped)
            } header: {
                Text("Connection Controls")
            } footer: {
                Text("Keep both apps open for testing. The receiver normally starts automatically when the app becomes active and reconnects if either app restarts.")
            }
        }
        .navigationTitle("Harness Receiver")
        .navigationBarTitleDisplayMode(.inline)
    }

    // Hide old geometry after interruption rather than presenting it as live guidance.
    private var currentVector: GuidanceVector? {
        connection.peer.isReceiving ? connection.lastState?.vector : nil
    }

    private var guidanceTitle: String {
        if connection.peer.status == .stopped { return "Receiver stopped" }
        guard connection.peer.isReceiving else { return "Waiting for guidance" }
        if let outcome = connection.lastState?.outcome { return outcomeTitle(outcome) }
        return currentVector == nil ? "No guidance available" : "Guiding"
    }

    private var statusTitle: String {
        switch connection.peer.status {
        case .stopped: "Stopped"
        case .searching: "Searching for Mac"
        case .connecting: "Connecting"
        case .connected: "Connected"
        }
    }

    private var statusSymbol: String {
        switch connection.peer.status {
        case .stopped: "stop.circle"
        case .searching: "magnifyingglass"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch connection.peer.status {
        case .stopped: .secondary
        case .searching, .connecting: .orange
        case .connected: .green
        }
    }

    private func number(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(3)))
    }

    private func timestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.hour().minute().second())
    }

    private func outcomeTitle(_ outcome: OutcomeSignal?) -> String {
        switch outcome {
        case .arrived: "Arrived"
        case .lostTracking: "Lost tracking"
        case .notFound: "Target not found"
        case .lowConfidence: "Low confidence"
        case nil: "None yet"
        }
    }
}

#Preview {
    NavigationStack {
        HarnessReceiverView()
    }
    // Supply the environment dependency without starting networking or haptics.
    .environment(HarnessConnection(feedback: HarnessConsoleFeedback()))
}
