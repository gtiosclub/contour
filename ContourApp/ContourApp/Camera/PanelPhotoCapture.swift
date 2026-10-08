//
//  PanelPhotoCapture.swift
//  ContourApp — Officers (integration)
//
//  Turns the live camera into a PanelPhoto for Surface Understanding.
//
//  The photo is a frame from the same CameraService stream that Tracking follows,
//  so the reference photo and the live frames share one size and orientation.
//  Vision's rectangle tracker fails when those differ (see #59).
//

import AVFoundation
import ContourCore
import CoreImage
import Foundation
import ImageIO
import Tracking
import UniformTypeIdentifiers

nonisolated enum PanelPhotoCaptureError: LocalizedError {
    case noFrame, encodingFailed, unsupportedOrientation

    var errorDescription: String? {
        switch self {
        case .noFrame: "The camera didn't deliver a frame."
        case .encodingFailed: "Couldn't turn the camera frame into a photo."
        case .unsupportedOrientation: "The camera frame is mirrored, which a panel photo can't describe."
        }
    }
}

nonisolated extension CameraService {

    /// One photo of what the camera sees right now.
    ///
    /// Starts the camera if needed. A camera that was just started gets half a
    /// second for exposure to settle before a frame is taken.
    func capturePanelPhoto() async throws -> PanelPhoto {
        let wasRunning = session.isRunning
        try await start()
        let notBefore = Date().addingTimeInterval(wasRunning ? 0 : 0.5)

        for await frame in await cameraFrames() where frame.timestamp >= notBefore {
            return try PanelPhoto(frame: frame)
        }
        throw PanelPhotoCaptureError.noFrame
    }
}

nonisolated extension PanelPhoto {

    /// A JPEG of `frame`, keeping its orientation and capture time.
    init(frame: CameraFrame) throws {
        guard let orientation = PhotoOrientation(frame.orientation) else {
            throw PanelPhotoCaptureError.unsupportedOrientation
        }

        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else {
            throw PanelPhotoCaptureError.encodingFailed
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw PanelPhotoCaptureError.encodingFailed }
        CGImageDestinationAddImage(
            destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw PanelPhotoCaptureError.encodingFailed }

        self.init(
            data: data as Data,
            pixelSize: PixelSize(width: cgImage.width, height: cgImage.height),
            orientation: orientation,
            timestamp: frame.timestamp
        )
    }
}

nonisolated private extension PhotoOrientation {
    /// `nil` for mirrored orientations, which the camera path never produces.
    init?(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .right: self = .right
        case .down: self = .down
        case .left: self = .left
        default: return nil
        }
    }
}
