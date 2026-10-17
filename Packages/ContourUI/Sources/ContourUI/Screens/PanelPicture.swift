//
//  PanelPicture.swift
//  ContourUI — Experience / App Flow
//
//  The captured photo with the detected controls drawn over it — or, when
//  there is no photo (the mock pipeline sends a zero-byte one), a drawing of
//  the panel from its map.
//
//  COORDINATES — the only place in Contour that turns panel space into points.
//  Button bounds are normalized against Surface's panel quad, not the whole
//  photo. So a panel point goes:
//      PanelPoint ──(PanelImageMapping, the quad's homography)──▶ ImagePoint
//                 ──(× the fitted image rect, here)──────────────▶ view points
//  Both spaces are top-left origin, y DOWN. Nothing here leaves this file as a
//  pixel. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation
import ImageIO
import SwiftUI

// MARK: - Panel space → image space

/// Maps normalized panel space into the upright photo through Surface's quad.
///
/// The projective transform that sends the unit square's corners (0,0), (1,0),
/// (1,1), (0,1) to the quad's top-left, top-right, bottom-right, bottom-left.
public struct PanelImageMapping: Hashable, Sendable {

    private let a, b, c, d, e, f, g, h: Double

    /// `nil` when the quad is degenerate (three corners in a line).
    public init?(quad: PanelQuad) {
        let (x0, y0) = (quad.topLeft.x, quad.topLeft.y)
        let (x1, y1) = (quad.topRight.x, quad.topRight.y)
        let (x2, y2) = (quad.bottomRight.x, quad.bottomRight.y)
        let (x3, y3) = (quad.bottomLeft.x, quad.bottomLeft.y)
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        let denominator = dx1 * dy2 - dx2 * dy1
        guard denominator.isFinite, abs(denominator) > 1e-12 else { return nil }
        g = (dx3 * dy2 - dx2 * dy3) / denominator
        h = (dx1 * dy3 - dx3 * dy1) / denominator
        a = x1 - x0 + g * x1
        b = x3 - x0 + h * x3
        c = x0
        d = y1 - y0 + g * y1
        e = y3 - y0 + h * y3
        f = y0
    }

    /// Where `point` on the panel falls in the photo. `nil` if it maps to infinity.
    public func imagePoint(for point: PanelPoint) -> ImagePoint? {
        let w = g * point.x + h * point.y + 1
        guard abs(w) > 1e-12 else { return nil }
        let x = (a * point.x + b * point.y + c) / w
        let y = (d * point.x + e * point.y + f) / w
        guard x.isFinite, y.isFinite else { return nil }
        return ImagePoint(x: x, y: y)
    }

    /// The four corners of `rect` in the photo, clockwise from top-left.
    public func corners(of rect: PanelRect) -> [ImagePoint]? {
        let points = [PanelPoint(x: rect.minX, y: rect.minY), PanelPoint(x: rect.maxX, y: rect.minY),
                      PanelPoint(x: rect.maxX, y: rect.maxY), PanelPoint(x: rect.minX, y: rect.maxY)]
            .compactMap(imagePoint(for:))
        return points.count == 4 ? points : nil
    }
}

// MARK: - Decoding

/// A decoded photo, upright, ready to draw.
struct DecodedPhoto: @unchecked Sendable {
    // CGImage is immutable once created; it is safe to hand across actors.
    let image: CGImage
    let orientation: Image.Orientation
    /// Width over height, after orientation.
    let aspectRatio: CGFloat

    /// Decodes `photo` off the main actor, downsampled to `maxPixel` on its
    /// long edge. `nil` for the mock pipeline's zero-byte photo.
    static func decode(_ photo: PanelPhoto, maxPixel: Int = 1600) async -> DecodedPhoto? {
        guard !photo.data.isEmpty else { return nil }
        let data = photo.data
        let orientation = photo.orientation
        return await Task.detached(priority: .userInitiated) { () -> DecodedPhoto? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                      // PanelPhoto.orientation is the truth, not EXIF.
                      kCGImageSourceCreateThumbnailWithTransform: false,
                  ] as CFDictionary) else { return nil }
            let swaps = orientation == .left || orientation == .right
            let width = CGFloat(swaps ? image.height : image.width)
            let height = CGFloat(swaps ? image.width : image.height)
            guard width > 0, height > 0 else { return nil }
            return DecodedPhoto(image: image, orientation: Image.Orientation(orientation),
                                aspectRatio: width / height)
        }.value
    }
}

private extension Image.Orientation {
    init(_ orientation: PhotoOrientation) {
        switch orientation {
        case .up: self = .up
        case .right: self = .right
        case .down: self = .down
        case .left: self = .left
        }
    }
}

// MARK: - Picture

/// The panel as the user pointed at it, with its controls marked.
///
/// Shows `photo` when it decodes, otherwise a drawing of `map`. Controls are
/// tappable when `onChoose` is set. The picture is decorative for VoiceOver:
/// the selection list beside it carries the same controls in reading order.
struct PanelPicture: View {
    var photo: PanelPhoto?
    var quad: PanelQuad?
    var map: SurfaceMap?
    var showsControls = true
    var highlightedID: UUID?
    var fingertip: PanelPoint?
    var onChoose: ((SurfaceMap.Button) -> Void)?

    @State private var decoded: DecodedPhoto?
    @State private var decodedID: UUID?

    var body: some View {
        Group {
            if let decoded, decodedID == photo?.id {
                PhotoWithControls(decoded: decoded, mapping: quad.flatMap(PanelImageMapping.init(quad:)),
                                  map: showsControls ? map : nil, highlightedID: highlightedID,
                                  onChoose: onChoose)
            } else if let map {
                PanelSketch(map: map, showsControls: showsControls, highlightedID: highlightedID,
                            fingertip: fingertip, onChoose: onChoose)
            } else {
                Color.clear
            }
        }
        .task(id: photo?.id) {
            guard let photo else { decoded = nil; decodedID = nil; return }
            let result = await DecodedPhoto.decode(photo)
            guard !Task.isCancelled else { return }
            decoded = result
            decodedID = photo.id
        }
    }
}

/// The decoded photo, aspect-fit, with each control's quad drawn over it.
private struct PhotoWithControls: View {
    let decoded: DecodedPhoto
    let mapping: PanelImageMapping?
    let map: SurfaceMap?
    let highlightedID: UUID?
    let onChoose: ((SurfaceMap.Button) -> Void)?

    var body: some View {
        Image(decorative: decoded.image, scale: 1, orientation: decoded.orientation)
            .resizable()
            .aspectRatio(decoded.aspectRatio, contentMode: .fit)
            .overlay {
                if let map, let mapping {
                    GeometryReader { geometry in
                        ControlOverlay(map: map, size: geometry.size, highlightedID: highlightedID,
                                       onChoose: onChoose) { rect in
                            mapping.corners(of: rect)?.map {
                                CGPoint(x: $0.x * geometry.size.width, y: $0.y * geometry.size.height)
                            }
                        }
                    }
                }
            }
    }
}

/// A drawing of the panel from its map: the picture when there is no photo.
struct PanelSketch: View {
    let map: SurfaceMap
    var showsControls = true
    var highlightedID: UUID?
    /// Outline only the highlighted control (the guide placeholder).
    var outlinesOnlyHighlighted = false
    var fingertip: PanelPoint?
    var onChoose: ((SurfaceMap.Button) -> Void)?

    /// Panel width over height. The map is a unit square; this is just how it looks.
    static let aspectRatio: CGFloat = 1.45

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: ContourTheme.Radius.card)
                    .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: ContourTheme.Radius.card)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5))
                // The keys themselves, as they would look on the appliance.
                ForEach(map.buttons) { button in
                    let rect = Self.rect(button.bounds, in: size)
                    RoundedRectangle(cornerRadius: ContourTheme.Radius.overlayControl)
                        .fill(Color(white: 0.32))
                        .overlay {
                            Text(button.label ?? "")
                                .font(ContourTheme.Typography.sketchLabel)
                                .foregroundStyle(Color(white: 0.9))
                                .minimumScaleFactor(0.5)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .padding(4)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                if showsControls {
                    let outlined = outlinesOnlyHighlighted
                        ? SurfaceMap(buttons: map.buttons.filter { $0.id == highlightedID }, confidence: map.confidence)
                        : map
                    ControlOverlay(map: outlined, size: size, highlightedID: highlightedID,
                                   onChoose: onChoose, drawsChips: false) { bounds in
                        let r = Self.rect(bounds, in: size)
                        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                    }
                }
                if let fingertip {
                    let point = CGPoint(x: fingertip.x * size.width, y: fingertip.y * size.height)
                    Circle()
                        .fill(ContourTheme.Colors.textPrimary)
                        .overlay(Circle().strokeBorder(ContourTheme.Colors.chrome, lineWidth: 3))
                        .frame(width: 28, height: 28)
                        .position(point)
                }
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
    }

    /// `bounds` in points, in a panel drawn `size` big. Panel space is y-down,
    /// like SwiftUI, so this is a straight scale.
    static func rect(_ bounds: PanelRect, in size: CGSize) -> CGRect {
        CGRect(x: bounds.minX * size.width, y: bounds.minY * size.height,
               width: bounds.width * size.width, height: bounds.height * size.height)
    }
}

/// Outlines, label chips and tap targets for every control, given a way to
/// place a panel rectangle's corners in this view.
private struct ControlOverlay: View {
    let map: SurfaceMap
    let size: CGSize
    let highlightedID: UUID?
    let onChoose: ((SurfaceMap.Button) -> Void)?
    var drawsChips = true
    let corners: (PanelRect) -> [CGPoint]?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(map.buttons) { button in
                if let points = corners(button.bounds) {
                    control(button, points: points)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func control(_ button: SurfaceMap.Button, points: [CGPoint]) -> some View {
        let unsure = PanelLayout.isUnsure(button)
        let highlighted = button.id == highlightedID
        let colour = highlighted ? ContourTheme.Colors.success
            : unsure ? ContourTheme.Colors.unsure : ContourTheme.Colors.overlayStroke
        let box = Self.boundingBox(points)
        let outline = Self.outline(points, box: box)

        outline
            .stroke(colour, style: StrokeStyle(lineWidth: ContourTheme.Size.overlayLine * (highlighted ? 1.6 : 1),
                                               lineJoin: .round, dash: unsure ? [8, 6] : []))
            .background(outline.fill(colour.opacity(highlighted ? 0.25 : 0.08)))

        if drawsChips {
            chip(button, unsure: unsure, colour: colour)
                .position(x: box.midX, y: max(box.minY - 14, 12))
        }

        if let onChoose {
            Button { onChoose(button) } label: {
                Color.clear
                    .frame(width: max(box.width, ContourTheme.Size.minimumTarget),
                           height: max(box.height, ContourTheme.Size.minimumTarget))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .position(x: box.midX, y: box.midY)
        }
    }

    private func chip(_ button: SurfaceMap.Button, unsure: Bool, colour: Color) -> some View {
        HStack(spacing: 3) {
            if unsure { Image(systemName: "questionmark") }
            Text(button.label ?? "Unlabelled")
        }
        .font(ContourTheme.Typography.chip)
        .lineLimit(1)
        .foregroundStyle(ContourTheme.Colors.onAccent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(colour, in: .rect(cornerRadius: ContourTheme.Radius.chip))
        .fixedSize()
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// A rounded rectangle when the corners are axis-aligned, else the quad.
    private static func outline(_ points: [CGPoint], box: CGRect) -> Path {
        let aligned = abs(points[0].y - points[1].y) < 0.5 && abs(points[1].x - points[2].x) < 0.5
            && abs(points[2].y - points[3].y) < 0.5 && abs(points[3].x - points[0].x) < 0.5
        if aligned {
            return Path(roundedRect: box, cornerRadius: min(ContourTheme.Radius.overlayControl,
                                                            box.width / 2, box.height / 2))
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}
