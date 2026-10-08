import ContourCore
import CryptoKit
import Foundation
import Network
import Observation

/// Shared developer transport; the observable UI interface remains unchanged.
@MainActor
@Observable
public final class HarnessPeerConnection {
    public enum Role: String, Sendable { case mac, phone }
    public enum Status: String, Sendable { case stopped, searching, connecting, connected }

    public private(set) var status: Status = .stopped
    public private(set) var peerName: String?
    public private(set) var lastError: String?
    public private(set) var receivedCount = 0
    public private(set) var sentCount = 0
    public private(set) var lastReceivedAt: Date?
    public private(set) var isReceiving = false
    public var onGuidance: (@MainActor (GuidanceState) -> Void)?
    public var onInterrupted: (@MainActor () -> Void)?

    private static let defaultServiceType = "_contour-net._tcp"
    private let serviceType: String
    private static let protocolName = "contour-network-v1"
    private let role: Role
    private let displayName: String
    private var lifecycleID = UUID()
    private var connectionID = UUID()
    private var discoveryTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var endpoints: [Bonjour.Endpoint] = []
    private var retryAt = Date.distantPast
    private var failures = 0
    private var deadline: Date?
    private var restartAt: Date?
    private var lastTransportAt: Date?
    private var runID = UUID()
    private var inbox = HarnessPacketInbox()
    private var nextSequence: UInt64 = 0
    private var latestSnapshot: HarnessPacket?
    private var pendingSnapshot: HarnessPacket?
    private var pendingEvents: [HarnessPacket] = []
    private var wakeWriter: AsyncStream<Void>.Continuation?

    public convenience init(role: Role, displayName: String? = nil) {
        self.init(role: role, displayName: displayName, serviceType: Self.defaultServiceType)
    }

    // Separate service names keep optional local integration tests isolated from running apps.
    init(role: Role, displayName: String?, serviceType: String) {
        self.serviceType = serviceType
        self.role = role
        self.displayName = String((displayName ?? "Contour \(role == .mac ? "Mac" : "Phone") \(ProcessInfo.processInfo.hostName)").prefix(63))
    }

    private static var parameters: NWParametersBuilder<TCP> {
        NWParametersBuilder { TCP().noDelay(true).connectionTimeout(8)
            .keepalive(idleTimeInSeconds: 2, count: 3, intervalInSeconds: 1) }
            .peerToPeerIncluded(true)
    }

    /// The phone advertises Bonjour; the Mac automatically connects to one phone.
    public func start() {
        guard status == .stopped else { return }
        lifecycleID = UUID()
        let lifecycle = lifecycleID
        runID = UUID()
        nextSequence = 0
        if let old = latestSnapshot { latestSnapshot = makePacket(old.state, kind: .snapshot) }
        status = .searching
        lastError = nil
        retryAt = .distantPast
        failures = 0
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                if role == .mac {
                    let browser = NetworkBrowser(for: .bonjour(serviceType), using: Self.parameters.parameters)
                    try await browser.run { [weak self] found in
                        guard let self, lifecycleID == lifecycle else { return }
                        endpoints = found.sorted { $0.name < $1.name }
                        connectIfPossible()
                    }
                } else {
                    let listener = try NetworkListener(for: .bonjour(name: displayName, type: serviceType),
                                                       using: Self.parameters)
                    try await listener.run { [weak self] connection in
                        guard let self, lifecycleID == lifecycle, connectionTask == nil else { return }
                        let id = beginConnection()
                        let task = Task<Void, Never> { [weak self] in
                            guard let self else { return }
                            await serve(connection, id: id)
                        }
                        connectionTask = task
                        await withTaskCancellationHandler {
                            await task.value
                        } onCancel: { task.cancel() }
                    }
                }
            } catch {
                guard lifecycleID == lifecycle, !Task.isCancelled else { return }
                lastError = error.localizedDescription
                restartAt = Date().addingTimeInterval(3)
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                self?.tick()
            }
        }
    }

    public func stop() {
        lifecycleID = UUID()
        connectionID = UUID()
        ticker?.cancel(); ticker = nil
        discoveryTask?.cancel(); discoveryTask = nil
        connectionTask?.cancel(); connectionTask = nil
        wakeWriter?.finish(); wakeWriter = nil
        endpoints.removeAll()
        pendingEvents.removeAll()
        pendingSnapshot = nil
        deadline = nil
        restartAt = nil
        lastTransportAt = nil
        inbox = HarnessPacketInbox()
        peerName = nil
        lastReceivedAt = nil
        interrupt()
        status = .stopped
    }

    public func reconnect() { stop(); start() }

    /// Drag updates replace unsent geometry; terminal outcomes retain their order.
    public func send(_ state: GuidanceState) {
        guard role == .mac, state.timestamp.timeIntervalSince1970.isFinite else { return }
        if let vector = state.vector {
            guard vector.direction.dx.isFinite, vector.direction.dy.isFinite,
                  vector.normalizedDistance.isFinite, vector.normalizedDistance >= 0 else { return }
        }
        if state.outcome != nil {
            enqueue(makePacket(state, kind: .event))
            latestSnapshot = makePacket(GuidanceState(timestamp: Date(), vector: nil), kind: .snapshot)
            if status == .connected { pendingSnapshot = latestSnapshot; wakeWriter?.yield(()) }
        } else {
            latestSnapshot = makePacket(state, kind: .snapshot)
            if let latestSnapshot { enqueue(latestSnapshot) }
        }
    }

    private func makePacket(_ state: GuidanceState, kind: HarnessPacket.Kind) -> HarnessPacket {
        nextSequence += 1
        return HarnessPacket(version: 1, runID: runID, sequence: nextSequence, kind: kind, state: state)
    }

    private func enqueue(_ packet: HarnessPacket) {
        guard status == .connected else { return }
        if packet.kind == .event {
            guard pendingEvents.count < 64 else {
                lastError = "Connection cannot keep up with feedback events."
                connectionTask?.cancel()
                return
            }
            pendingEvents.append(packet)
            pendingSnapshot = nil
        } else { pendingSnapshot = packet }
        wakeWriter?.yield(())
    }

    private func beginConnection() -> UUID {
        connectionID = UUID()
        status = .connecting
        deadline = Date().addingTimeInterval(8)
        return connectionID
    }

    private func connectIfPossible() {
        guard role == .mac, status == .searching, connectionTask == nil,
              Date() >= retryAt, let endpoint = endpoints.first else { return }
        let id = beginConnection()
        peerName = endpoint.name
        connectionTask = Task { [weak self] in
            do {
                try await withNetworkConnection(to: endpoint.nwEndpoint, using: Self.parameters) { connection in
                    await self?.serve(connection, id: id)
                }
            } catch { self?.finishConnection(id: id, error: error) }
        }
    }

    private func serve(_ connection: NetworkConnection<TCP>, id: UUID) async {
        do {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let hello = HarnessWire.Hello(protocolName: Self.protocolName, role: role.rawValue,
                name: displayName, publicKey: privateKey.publicKey.rawRepresentation)
            let localData = try JSONEncoder().encode(hello)
            try await HarnessWire.write(localData, to: connection)
            let remoteData = try await HarnessWire.read(from: connection)
            let remote = try JSONDecoder().decode(HarnessWire.Hello.self, from: remoteData)
            guard remote.protocolName == Self.protocolName,
                  remote.role == (role == .mac ? "phone" : "mac"),
                  !remote.name.isEmpty, remote.name.utf8.count <= 252 else {
                throw HarnessWire.Failure.incompatiblePeer
            }
            let cipher = try HarnessWire.Cipher(privateKey: privateKey, remoteKey: remote.publicKey,
                macHello: role == .mac ? localData : remoteData,
                phoneHello: role == .phone ? localData : remoteData, isMac: role == .mac)
            // Confirm both sides derived the same keys before exposing "connected".
            try await HarnessWire.write(cipher.seal(Data([0])), to: connection)
            let confirmation = try await HarnessWire.read(from: connection)
            guard try cipher.open(confirmation) == Data([0]) else { throw HarnessWire.Failure.incompatiblePeer }
            try Task.checkCancellation()
            guard connectionID == id else { return }
            status = .connected
            peerName = remote.name
            lastError = nil
            failures = 0
            deadline = nil
            lastTransportAt = Date()
            inbox = HarnessPacketInbox()
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            wakeWriter = continuation
            pendingSnapshot = role == .mac ? latestSnapshot : nil
            continuation.yield(())
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    try await self?.readLoop(connection, cipher: cipher, id: id)
                }
                group.addTask { [weak self] in
                    try await self?.writeLoop(connection, cipher: cipher, id: id, stream: stream)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            finishConnection(id: id, error: nil)
        } catch { finishConnection(id: id, error: error) }
    }

    private func readLoop(_ connection: NetworkConnection<TCP>, cipher: HarnessWire.Cipher, id: UUID) async throws {
        while !Task.isCancelled {
            let record = try await HarnessWire.read(from: connection)
            let payload = try cipher.open(record)
            guard connectionID == id else { return }
            lastTransportAt = Date()
            if payload == Data([0]) { continue }
            guard role == .phone else { throw HarnessWire.Failure.incompatiblePeer }
            try receive(payload)
        }
    }

    private func writeLoop(_ connection: NetworkConnection<TCP>, cipher: HarnessWire.Cipher,
                           id: UUID, stream: AsyncStream<Void>) async throws {
        for await _ in stream {
            try Task.checkCancellation()
            guard connectionID == id else { return }
            while let packet = nextPendingPacket() {
                try await HarnessWire.write(cipher.seal(JSONEncoder().encode(packet)), to: connection)
                guard connectionID == id else { return }
                sentCount += 1
            }
            try await HarnessWire.write(cipher.seal(Data([0])), to: connection)
        }
    }

    private func nextPendingPacket() -> HarnessPacket? {
        if !pendingEvents.isEmpty { return pendingEvents.removeFirst() }
        defer { pendingSnapshot = nil }
        return pendingSnapshot
    }

    private func receive(_ data: Data) throws {
        let packet = try JSONDecoder().decode(HarnessPacket.self, from: data)
        let delivery = inbox.accept(packet, recovering: !isReceiving)
        guard delivery != .invalid else { throw HarnessWire.Failure.invalidRecord }
        lastReceivedAt = Date()
        isReceiving = true
        if delivery == .guidance { receivedCount += 1; onGuidance?(packet.state) }
    }

    private func interrupt() {
        let wasReceiving = isReceiving
        isReceiving = false
        if wasReceiving { onInterrupted?() }
    }

    private func finishConnection(id: UUID, error: (any Error)?) {
        guard connectionID == id, status != .stopped else { return }
        connectionID = UUID()
        connectionTask = nil
        wakeWriter?.finish(); wakeWriter = nil
        pendingEvents.removeAll()
        pendingSnapshot = nil
        deadline = nil
        peerName = nil
        lastTransportAt = nil
        inbox = HarnessPacketInbox()
        interrupt()
        status = .searching
        if let error, !(error is CancellationError) { lastError = error.localizedDescription }
        failures = min(failures + 1, 4)
        retryAt = Date().addingTimeInterval(pow(2, Double(failures - 1)))
    }

    private func tick() {
        let now = Date()
        if let restartAt, now >= restartAt { reconnect(); return }
        if let deadline, now >= deadline { connectionTask?.cancel() }
        if status == .connected {
            if role == .mac { pendingSnapshot = latestSnapshot }
            wakeWriter?.yield(())
            if let lastTransportAt, now.timeIntervalSince(lastTransportAt) > 4 { connectionTask?.cancel() }
        } else { connectIfPossible() }
        if isReceiving, let lastReceivedAt, now.timeIntervalSince(lastReceivedAt) > 2 { interrupt() }
    }
}
