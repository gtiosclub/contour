//
//  PanelPhoto+Decoding.swift
//  SurfaceUnderstanding — Surface / Officers (shared helper)
//
//  `PanelPhoto` carries encoded bytes so ContourCore compiles everywhere. Every
//  lane in this package needs pixels. This is the one place we decode, so
//  nobody re-invents it and everybody gets the same upright image.
//
//  Vision and Core Image both take a `CGImage`. Start from `photo.cgImage()`.
//

import ContourCore
import CoreGraphics
import Foundation
import ImageIO

extension PanelPhoto {

    /// The decoded, upright image.
    ///
    /// Applies `orientation` so the result is always upright — every lane works
    /// in upright image space and never has to think about rotation again.
    ///
    /// - Throws: `SurfaceUnderstandingError.undecodableImage`.
    public func cgImage() throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let raw = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw SurfaceUnderstandingError.undecodableImage
        }
        return try raw.rotated(to: orientation)
    }
}

extension CGImage {

    /// Rotate by a right angle so a photo taken in `orientation` becomes upright.
    fileprivate func rotated(to orientation: PhotoOrientation) throws -> CGImage {
        guard orientation != .up else { return self }

        let w = width, h = height
        let swap = orientation == .left || orientation == .right
        let outW = swap ? h : w
        let outH = swap ? w : h

        guard
            let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: outW, height: outH,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw SurfaceUnderstandingError.undecodableImage
        }

        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        switch orientation {
        case .up: break
        case .right: ctx.rotate(by: -.pi / 2)   // photo's top is on the right → turn it back
        case .down: ctx.rotate(by: .pi)
        case .left: ctx.rotate(by: .pi / 2)
        }
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let out = ctx.makeImage() else {
            throw SurfaceUnderstandingError.undecodableImage
        }
        return out
    }
}
