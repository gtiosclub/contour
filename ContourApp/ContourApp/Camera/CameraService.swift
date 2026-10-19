import ARKit
import AVFoundation
import Foundation
import Tracking

/// Session mutations and delegate callbacks are confined to `queue`.
/// `session` is exposed only for attaching a preview layer on the main actor.
///
/// With world tracking, ARKit owns the camera instead and `session` never runs,
/// so its preview layer stays black until the preview draws from frames.
nonisolated final class CameraService: NSObject, CameraControl,
    AVCaptureVideoDataOutputSampleBufferDelegate, ARSessionDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let status = CameraStatus()
    let usesWorldTracking: Bool
    private let queue = DispatchQueue(label: "edu.gatech.contour.camera")
    private var configured = false
    private let frames = CameraFrameHub()
    private let arSession = ARSession()
    private var arRunning = false

    /// World tracking is opt-in and falls back to AVFoundation on devices
    /// without ARWorldTrackingConfiguration support.
    init(worldTracking: Bool = false) {
        usesWorldTracking = worldTracking && ARWorldTrackingConfiguration.isSupported
        super.init()
        arSession.delegate = self
        arSession.delegateQueue = queue
    }

    enum CameraError: LocalizedError {
        case permissionDenied, unavailable, exposureControlUnavailable
        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Camera access is unavailable. Enable it in Settings."
            case .unavailable: "Rear camera unavailable. Use a physical iPhone or iPad."
            case .exposureControlUnavailable: "Exposure adjustment has not been implemented yet."
            }
        }
    }

    func start() async throws {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard allowed else { throw CameraError.permissionDenied }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self.usesWorldTracking {
                        self.startWorldTracking()
                        continuation.resume()
                        return
                    }
                    try self.configure()
                    if !self.session.isRunning {
                        self.frames.begin()
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    self.frames.end()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                if self.arRunning {
                    self.arSession.pause()
                    self.arRunning = false
                }
                self.frames.end()
                continuation.resume()
            }
        }
    }

    @MainActor func retry() async {
        status.error = nil
        await stop()
        do { try await start() }
        catch { status.error = error.localizedDescription }
        status.revision &+= 1
    }

    /// S0 only declares the control seam; C implements actual bias later.
    /// Automatic exposure remains unchanged, and unsupported requests fail.
    func setExposureBias(_ value: Float) async throws -> Float? {
        guard value == 0 else { throw CameraError.exposureControlUnavailable }
        return nil
    }

    /// Every subscriber gets its own newest-frame buffer. Cancelling one does
    /// not stop the shared camera or steal another subscriber's frames.
    func cameraFrames() async -> AsyncStream<CameraFrame> {
        frames.subscribe()
    }

    /// Every run resets tracking, so world coordinates restart from scratch
    /// and the new generation's identity marks that change.
    private func startWorldTracking() {
        guard !arRunning else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.isAutoFocusEnabled = true
        configuration.planeDetection = [.horizontal, .vertical]
        frames.begin()
        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        arRunning = true
    }

    private func configure() throws {
        guard !configured else { return }
        guard let device = Self.closeFocusingCamera() else { throw CameraError.unavailable }
        try Self.focusNear(device)
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input) else { throw CameraError.unavailable }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.unavailable
        }
        session.addOutput(output)
        // Scaffold uses a fixed portrait image basis, also used by the preview.
        // UI team: replace both with coordinated device rotation support.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        output.setSampleBufferDelegate(self, queue: queue)
        configured = true
    }

    /// The back camera that can focus on a panel a few centimetres away.
    ///
    /// The wide camera alone can't focus much closer than about 20 cm, so the
    /// keypad goes soft when you hold the phone near it. The multi-camera
    /// devices hand off to the ultra-wide's macro focus automatically when the
    /// subject is too close. Falls back to the wide camera on phones without one.
    private static func closeFocusingCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Continuous autofocus and exposure, tuned for something close. On a
    /// multi-camera device, starts at the wide camera's normal 1× framing
    /// rather than the ultra-wide's.
    private static func focusNear(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if let wide = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            device.videoZoomFactor = CGFloat(truncating: wide)
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Convert monotonic capture time to Date without substituting processing time.
        let captureTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let age = CameraFrameHub.hostTime - captureTime
        let frame = CameraFrame(pixelBuffer: buffer,
                                timestamp: Date().addingTimeInterval(-age), orientation: .up)
        // A buffer queued before stop() carries an older capture time, so it
        // is dropped instead of reaching the next run's subscribers.
        frames.publish(frame, capturedAt: captureTime)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARFrame.timestamp uses the same host clock as sample buffers.
        let age = CameraFrameHub.hostTime - frame.timestamp
        let camera = frame.camera
        let normalTracking = if case .normal = camera.trackingState { true } else { false }
        // The frame's own anchors, so planes match these pixels and this pose.
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.map(WorldPlane.init)
        frames.publish(capturedAt: frame.timestamp) { generation in
            // Pose and intrinsics describe these exact pixels in their native
            // landscape orientation; `.right` turns them upright.
            let world = WorldCameraSnapshot(
                sessionID: generation.id,
                cameraToWorld: camera.transform,
                intrinsics: camera.intrinsics,
                imageSize: SIMD2(Float(camera.imageResolution.width), Float(camera.imageResolution.height)),
                normalTracking: normalTracking,
                planes: planes)
            return CameraFrame(pixelBuffer: frame.capturedImage,
                               timestamp: Date().addingTimeInterval(-age), orientation: .right, world: world)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        arRunning = false
        frames.end()
        Task { @MainActor in self.status.error = error.localizedDescription }
    }
}
