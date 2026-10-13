import ContourCore
import CoreGraphics
import SwiftUI
import Tracking

/// Draws image-space overlays on the exact full image, with one aspect-fit
/// transform for pixels, quad, controls, fingertip, and target.
struct TrackingImageView: View {
    let image: CGImage
    var quad: PanelQuad?
    var fingertip: ImagePoint?
    var buttons: [SurfaceMap.Button] = []
    var targetID: UUID?

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
            .overlay {
                Canvas { context, size in
                    func point(_ p: ImagePoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
                    func polygon(_ corners: [ImagePoint]) -> Path {
                        var path = Path()
                        for (index, corner) in corners.enumerated() {
                            if index == 0 { path.move(to: point(corner)) } else { path.addLine(to: point(corner)) }
                        }
                        path.closeSubpath()
                        return path
                    }
                    if let quad {
                        context.stroke(polygon([quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]),
                                       with: .color(.yellow), lineWidth: 3)
                        if let geometry = try? PanelHomography(quad: quad) {
                            for button in buttons {
                                let b = button.bounds
                                let corners = [PanelPoint(x: b.minX, y: b.minY), PanelPoint(x: b.maxX, y: b.minY),
                                               PanelPoint(x: b.maxX, y: b.maxY), PanelPoint(x: b.minX, y: b.maxY)]
                                    .compactMap { geometry.imagePoint(for: $0) }
                                guard corners.count == 4 else { continue }
                                let selected = button.id == targetID
                                context.stroke(polygon(corners), with: .color(selected ? .orange : .cyan), lineWidth: 2)
                                if let center = geometry.imagePoint(for: b.center) {
                                    let location = point(center)
                                    if selected {
                                        context.stroke(Path(ellipseIn: CGRect(x: location.x - 12, y: location.y - 12,
                                                                              width: 24, height: 24)),
                                                       with: .color(.orange), lineWidth: 3)
                                    }
                                    context.draw(Text(button.label ?? "Unlabelled").font(.caption2)
                                        .foregroundColor(selected ? .orange : .cyan),
                                                 at: CGPoint(x: location.x, y: location.y - 15))
                                }
                            }
                        }
                    }
                    if let fingertip {
                        let p = point(fingertip)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                                     with: .color(.green))
                    }
                }
                .allowsHitTesting(false)
            }
            .background(.black)
            .clipped()
    }
}

struct CapturedPanelReviewView: View {
    let reference: PanelReference
    @State private var image: CGImage?
    @State private var renderedPhotoID: UUID?
    private let renderer = FrameImageRenderer()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image, renderedPhotoID == reference.photo.id {
                TrackingImageView(image: image, quad: reference.detection.quad,
                                  buttons: reference.detection.map.buttons)
            } else {
                Text("Captured image unavailable.").foregroundStyle(.secondary)
            }
            Text("Exact captured photo. Yellow: registered panel outline. Cyan: returned controls and labels. The black bars in the live preview are outside the captured image.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: reference.photo.id) {
            let rendered = await renderer.image(for: reference.photo)
            guard !Task.isCancelled else { return }
            image = rendered
            renderedPhotoID = reference.photo.id
        }
    }
}
