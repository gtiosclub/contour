import AVFoundation
import SwiftUI
import ContourCore
import UIKit

/// Preview and diagnostics share the same aspect-fill image transform.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var fingertip: ImagePoint?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.fingertip = fingertip
        view.setNeedsLayout()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var fingertip: ImagePoint?
        private let dot = CALayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            dot.backgroundColor = UIColor.systemYellow.cgColor
            dot.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
            dot.cornerRadius = 8
            layer.addSublayer(dot)
            clipsToBounds = true
            isAccessibilityElement = true
            accessibilityLabel = "Rear camera preview"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            dot.isHidden = fingertip == nil
            guard let fingertip else { return }
            // Captured buffers are portrait. Convert to the native landscape
            // capture-device basis expected by the preview conversion API.
            dot.position = previewLayer.layerPointConverted(fromCaptureDevicePoint:
                CGPoint(x: fingertip.y, y: 1 - fingertip.x))
        }
    }
}
