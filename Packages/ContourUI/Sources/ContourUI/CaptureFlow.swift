//
//  CaptureFlow.swift
//  ContourUI — Experience / App Flow
//
//  WHAT THIS PACKAGE OWES THE APP
//  The camera experience and the target selection flow: point the phone at a
//  panel, take the shot, hand back a PanelPhoto; then show the SurfaceMap the
//  app gives you and let the user say which button they want.
//
//  WHO OWNS WHAT (see README.md, "Ownership")
//  - The CAMERA stays in ContourApp. Tracking follows the same CameraService
//    stream, and the reference photo and the live frames must share one size
//    and orientation (ContourApp/ContourApp/Camera/PanelPhotoCapture.swift).
//    So CaptureFlow is handed a capture closure rather than opening a camera.
//  - VOICE MATCHING stays in ContourApp. Turning "the start one" into a button
//    is Surface Understanding's TargetMatcher, which this package cannot
//    import. So TargetSelection is handed a `listen` closure.
//  - ContourUI owns the flow, the screens and every word the user hears.
//
//  You never call Surface Understanding's detector yourself — you hand up a
//  `PanelPhoto` and the app target hands you back a `SurfaceMap`.
//
//  COORDINATES
//  `SurfaceMap.Button.bounds` is in normalized panel space: (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. To draw an overlay, multiply by the view's
//  size — and keep that multiplication inside this package. No pixel
//  coordinate goes back out. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation
import Synchronization

// MARK: - Capture

/// Why a capture could not produce a photo.
public enum CaptureFlowError: Error, Hashable, Sendable, LocalizedError {

    /// This flow was built without a camera. The app owns the camera and must
    /// pass one in with `CaptureFlow(capture:)`.
    case noCamera

    public var errorDescription: String? {
        switch self {
        case .noCamera: "No camera is connected to the capture flow."
        }
    }
}

/// Drives capture: viewfinder, shutter, and the still that comes out of it.
///
/// The app supplies the camera, because Tracking must see the same stream.
public struct CaptureFlow: Sendable {

    private let capture: @Sendable () async throws -> PanelPhoto

    /// A flow with no camera: `capturePanelPhoto()` throws
    /// `CaptureFlowError.noCamera`. Use `init(capture:)` in the app.
    public init() {
        self.capture = { throw CaptureFlowError.noCamera }
    }

    /// A flow that takes its stills from `capture` — in the app, the shared
    /// camera's `capturePanelPhoto()`, so Surface and Tracking see one stream.
    public init(capture: @escaping @Sendable () async throws -> PanelPhoto) {
        self.capture = capture
    }

    /// Capture one still of the panel in front of the camera.
    ///
    /// - Returns: the photo, ready to hand to the app target for detection.
    public func capturePanelPhoto() async throws -> PanelPhoto {
        try await capture()
    }
}

// MARK: - Selection

/// Drives target selection: given what is on the panel, which button does the
/// user actually want?
///
/// `selectTarget(in:)` suspends until the selection screen resolves it: a tap
/// on a control (`choose(_:)`), a spoken request (`listenForTarget()`), or
/// backing out (`backOut()`). Copies share one broker, so the copy a view holds
/// resolves the call the app is awaiting.
public struct TargetSelection: Sendable {

    /// Where pending selections wait. Shared by every copy.
    public let broker: TargetSelectionBroker

    private let listen: (@Sendable (SurfaceMap) async throws -> SurfaceMap.Button?)?

    /// Selection by touch only.
    public init() {
        self.broker = TargetSelectionBroker()
        self.listen = nil
    }

    /// Selection by touch and by voice.
    ///
    /// - Parameter listen: hears one request and returns the control it names
    ///   on the map, or `nil` if it names nothing there. The app wires this to
    ///   its speech recognizer and Surface Understanding's `TargetMatcher`.
    public init(
        broker: TargetSelectionBroker = TargetSelectionBroker(),
        listen: @escaping @Sendable (SurfaceMap) async throws -> SurfaceMap.Button?
    ) {
        self.broker = broker
        self.listen = listen
    }

    /// Ask the user which control on `map` they want to be guided to.
    ///
    /// Suspends until the user chooses or backs out. Cancelling the calling task,
    /// or a newer `selectTarget(in:)`, ends this one with `nil`.
    ///
    /// - Returns: the chosen button, or `nil` if the user backed out. A request
    ///   for something that is not on the panel is `nil` here plus an
    ///   `OutcomeSignal.notFound` raised by the app target — not an error.
    public func selectTarget(in map: SurfaceMap) async -> SurfaceMap.Button? {
        await broker.wait(for: map)
    }

    /// Choose `button` for the pending selection.
    ///
    /// - Returns: `false` if nothing is waiting or `button` is not on the map
    ///   being chosen from; nothing changes in that case.
    @discardableResult
    public func choose(_ button: SurfaceMap.Button) -> Bool {
        broker.choose(button)
    }

    /// Back out of the pending selection; it returns `nil`.
    @discardableResult
    public func backOut() -> Bool {
        broker.backOut()
    }

    /// Whether this selection can listen for a spoken request.
    public var canListen: Bool { listen != nil }

    /// Listen for one spoken request against the map being chosen from. If it
    /// names a control, that control resolves the pending selection.
    ///
    /// - Returns: the control heard, or `nil` if nothing is pending, there is
    ///   no listener, or the request named nothing on the panel — in which case
    ///   the selection stays pending, and the app decides whether that is
    ///   `OutcomeSignal.notFound`.
    public func listenForTarget() async throws -> SurfaceMap.Button? {
        guard let listen, let map = broker.pendingMap else { return nil }
        guard let button = try await listen(map), broker.choose(button) else { return nil }
        return button
    }
}

/// The meeting point between an awaiting `selectTarget(in:)` and the screen
/// that resolves it. Thread-safe; at most one selection is pending.
public final class TargetSelectionBroker: Sendable {

    private struct Pending {
        let id: UUID
        let map: SurfaceMap
        let continuation: CheckedContinuation<SurfaceMap.Button?, Never>
    }

    private let pending = Mutex<Pending?>(nil)

    public init() {}

    /// The map currently being chosen from, if a selection is pending.
    public var pendingMap: SurfaceMap? {
        pending.withLock { $0?.map }
    }

    /// Whether a `selectTarget(in:)` call is waiting.
    public var isAwaiting: Bool { pendingMap != nil }

    func wait(for map: SurfaceMap) async -> SurfaceMap.Button? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let superseded = pending.withLock { pending in
                    defer { pending = Pending(id: id, map: map, continuation: continuation) }
                    return pending
                }
                superseded?.continuation.resume(returning: nil)
                // Cancelled before we registered: the handler already ran.
                if Task.isCancelled { resolve(id: id, with: nil) }
            }
        } onCancel: {
            resolve(id: id, with: nil)
        }
    }

    @discardableResult
    func choose(_ button: SurfaceMap.Button) -> Bool {
        let taken: Pending? = pending.withLock { pending in
            guard let current = pending,
                  current.map.buttons.contains(where: { $0.id == button.id }) else { return nil }
            pending = nil
            return current
        }
        // Return the map's own copy, not whatever the caller constructed.
        let chosen = taken?.map.buttons.first { $0.id == button.id }
        taken?.continuation.resume(returning: chosen)
        return taken != nil
    }

    @discardableResult
    func backOut() -> Bool {
        resolve(id: nil, with: nil)
    }

    /// Resolves the pending selection — only if it is `id`, when given.
    @discardableResult
    private func resolve(id: UUID?, with button: SurfaceMap.Button?) -> Bool {
        let taken: Pending? = pending.withLock { pending in
            guard let current = pending, id == nil || current.id == id else { return nil }
            pending = nil
            return current
        }
        taken?.continuation.resume(returning: button)
        return taken != nil
    }
}
