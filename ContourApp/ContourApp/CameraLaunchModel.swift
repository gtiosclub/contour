import ContourCore
import Foundation
import Observation

/// Coordinates cancellation before the shared camera changes ownership or a new request starts.
@MainActor @Observable
final class CameraLaunchModel {
    let camera: CameraService
    let pipeline: ContourPipeline
    private(set) var status = "Aim at the whole control panel, then scan."
    private(set) var busy = false
    private(set) var ready = false
    private(set) var error: String?
    private(set) var listening = false
    private(set) var guiding = false
    private(set) var scanning = false
    private let listen: @MainActor (SurfaceMap) async throws -> VoiceRequest.Heard
    private var knownReferenceID: UUID?
    private var active = false
    private var work: Task<Void, Never>?
    private var requestID = UUID()
    private var transition: Task<Void, Never>?
    private var lifecycleID = UUID()

    init(camera: CameraService, pipeline: ContourPipeline,
         listen: @escaping @MainActor (SurfaceMap) async throws -> VoiceRequest.Heard = { try await VoiceRequest().listen(for: $0) }) {
        self.camera = camera
        self.pipeline = pipeline
        self.listen = listen
        knownReferenceID = pipeline.panelReference?.photo.id
    }

    var map: SurfaceMap? { pipeline.panelReference?.detection.map }
    var usesCamera: Bool { !pipeline.liveComponents.isEmpty }

    @discardableResult
    func setActive(_ value: Bool) -> Task<Void, Never> {
        active = value
        ready = false
        let previous = transition
        let cleanup = stopWork()
        let id = UUID()
        lifecycleID = id
        let task = Task {
            await previous?.value
            await cleanup.value
            guard lifecycleID == id else { return }
            if !value {
                await camera.stop()
            } else if active {
                do {
                    if usesCamera { try await camera.start() }
                    guard lifecycleID == id, active else { return }
                    ready = true
                    error = nil
                    status = map == nil ? "Aim at the whole control panel, then scan."
                        : "Panel ready. Say a button name or choose one below."
                } catch {
                    guard lifecycleID == id, active else { return }
                    self.error = error.localizedDescription
                    status = "Camera unavailable. Enable camera access in Settings, then retry."
                }
            }
        }
        transition = task
        return task
    }

    func waitForWork() async { await work?.value }

    func referenceChanged() {
        let current = pipeline.panelReference?.photo.id
        guard current != knownReferenceID else { return }
        knownReferenceID = current
        guard !scanning else { return }
        stopWork()
        error = nil
        status = map == nil ? "Aim at the whole control panel, then scan."
            : "Panel ready. Say a button name or choose one below."
    }

    /// Await this barrier before presenting diagnostics or starting replacement work.
    @discardableResult
    func stopWork() -> Task<Void, Never> {
        requestID = UUID()
        let previous = work
        previous?.cancel()
        busy = false
        listening = false
        guiding = false
        scanning = false
        let cleanup = Task {
            await previous?.value
            await pipeline.stopGuidance()
        }
        work = cleanup
        return cleanup
    }

    func stop() {
        stopWork()
        status = "Stopped. Say a button name, choose a button, or scan again."
    }

    func scan() {
        guard ready else { return }
        replaceWork {
            self.scanning = true
            defer { self.scanning = false }
            self.status = "Scanning panel. Hold the phone steady."
            let photo: PanelPhoto
            if self.usesCamera {
                photo = try await self.camera.capturePanelPhoto()
            } else {
                photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 4032, height: 3024), timestamp: Date())
            }
            try Task.checkCancellation()
            let map = try await self.pipeline.detectPanel(in: photo)
            try Task.checkCancellation()
            self.knownReferenceID = self.pipeline.panelReference?.photo.id
            guard !map.buttons.isEmpty else {
                self.status = "No buttons found. Show the whole panel and scan again."
                return
            }
            guard self.pipeline.canGuide else {
                self.status = "Panel outline unclear. Show all four corners and scan again."
                return
            }
            self.status = "Panel ready. Say a button name or choose one below."
        }
    }

    func sayAButton() {
        guard ready, let map, pipeline.canGuide else { return }
        let referenceID = pipeline.panelReference?.photo.id
        replaceWork {
            self.listening = true
            self.status = "Listening. Say the name of a button on the panel."
            let heard = try await self.listen(map)
            self.listening = false
            try Task.checkCancellation()
            guard self.pipeline.panelReference?.photo.id == referenceID else { return }
            guard !heard.text.isEmpty else {
                self.status = "Didn't hear anything. Try speaking again or choose a button below."
                return
            }
            guard let button = heard.button else {
                self.status = "No button matching “\(heard.text)”. Try again or choose a button below."
                return
            }
            await self.guide(button, referenceID: referenceID)
        }
    }

    func choose(_ button: SurfaceMap.Button) {
        guard ready, pipeline.canGuide, map?.buttons.contains(where: { $0.id == button.id }) == true else { return }
        let referenceID = pipeline.panelReference?.photo.id
        replaceWork { await self.guide(button, referenceID: referenceID) }
    }

    private func guide(_ button: SurfaceMap.Button, referenceID: UUID?) async {
        guard pipeline.panelReference?.photo.id == referenceID, !Task.isCancelled else { return }
        guiding = true
        status = "Guiding to \(button.label ?? "selected button"). Keep the panel in view and move your finger toward the target."
        await pipeline.guide(to: button)
        guard !Task.isCancelled, pipeline.panelReference?.photo.id == referenceID else { return }
        guiding = false
        status = pipeline.guidanceArrived ? "Reached \(button.label ?? "the selected button")."
            : "Guidance ended. Choose the button to retry, or scan again."
        error = pipeline.trackingError
    }

    private func replaceWork(_ operation: @escaping @MainActor () async throws -> Void) {
        let cleanup = stopWork()
        let id = UUID()
        requestID = id
        busy = true
        error = nil
        work = Task {
            await cleanup.value
            guard requestID == id, !Task.isCancelled, active else { return }
            defer {
                if requestID == id { busy = false; listening = false; guiding = false }
            }
            do { try await operation() }
            catch is CancellationError { }
            catch {
                guard requestID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                status = "Unable to complete the request. Retry or choose a button below."
            }
        }
    }
}
