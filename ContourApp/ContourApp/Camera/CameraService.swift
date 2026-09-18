import AVFoundation
import Foundation
import Tracking

/// Session mutations and delegate callbacks are confined to `queue`.
/// `session` is exposed only for attaching a preview layer on the main actor.
nonisolated final class CameraService: NSObject, CameraFrameSource,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "edu.gatech.contour.camera")
    private var configured = false
    private var continuations: [UUID: AsyncStream<CameraFrame>.Continuation] = [:]

    enum CameraError: LocalizedError {
        case permissionDenied, unavailable
        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Camera access is unavailable. Enable it in Settings."
            case .unavailable: "Rear camera unavailable. Use a physical iPhone or iPad."
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
                    try self.configure()
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.continuations.values.forEach { $0.finish() }
                self.continuations.removeAll()
                continuation.resume()
            }
        }
    }

    /// Every subscriber gets its own newest-frame buffer. Cancelling one does
    /// not stop the shared camera or steal another subscriber's frames.
    func cameraFrames() async -> AsyncStream<CameraFrame> {
        let id = UUID()
        let pair = AsyncStream<CameraFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuations[id] = pair.continuation
                continuation.resume()
            }
        }
        pair.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.continuations.removeValue(forKey: id) }
        }
        return pair.stream
    }

    private func configure() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CameraError.unavailable }
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Convert monotonic capture time to Date without substituting processing time.
        let age = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            - CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let frame = CameraFrame(pixelBuffer: buffer,
                                timestamp: Date().addingTimeInterval(-age), orientation: .up)
        continuations.values.forEach { $0.yield(frame) }
    }
}
