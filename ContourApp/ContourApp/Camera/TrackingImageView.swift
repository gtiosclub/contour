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
    var acceptedFeaturePoints: [ImagePoint] = []

    var body: some View {
        GeometryReader { geometry in
            let viewSize = geometry.size
            let imageWidth = CGFloat(image.width)
            let imageHeight = CGFloat(image.height)

            let scale = min(
                viewSize.width / imageWidth,
                viewSize.height / imageHeight
            )

            let fittedWidth = imageWidth * scale
            let fittedHeight = imageHeight * scale

            let imageRect = CGRect(
                x: (viewSize.width - fittedWidth) / 2,
                y: (viewSize.height - fittedHeight) / 2,
                width: fittedWidth,
                height: fittedHeight
            )

            ZStack {
                Color.black

                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(
                        width: imageRect.width,
                        height: imageRect.height
                    )
                    .position(x: imageRect.midX, y: imageRect.midY)

                Canvas { context, _ in
                    // Convert normalized image coordinates to the displayed
                    // image rectangle, excluding the black bars.
                    func point(_ p: ImagePoint) -> CGPoint {
                        CGPoint(
                            x: imageRect.minX + p.x * imageRect.width,
                            y: imageRect.minY + p.y * imageRect.height
                        )
                    }

                    func polygon(_ corners: [ImagePoint]) -> Path {
                        var path = Path()

                        for (index, corner) in corners.enumerated() {
                            let mapped = point(corner)

                            if index == 0 {
                                path.move(to: mapped)
                            } else {
                                path.addLine(to: mapped)
                            }
                        }

                        path.closeSubpath()
                        return path
                    }

                    // NEW: draw supplied accepted feature points in purple.
                    for feature in acceptedFeaturePoints {
                        let p = point(feature)
                        let radius: CGFloat = 3

                        context.fill(
                            Path(
                                ellipseIn: CGRect(
                                    x: p.x - radius,
                                    y: p.y - radius,
                                    width: radius * 2,
                                    height: radius * 2
                                )
                            ),
                            with: .color(.purple)
                        )
                    }

                    // Existing panel outline.
                    if let quad {
                        context.stroke(
                            polygon([
                                quad.topLeft,
                                quad.topRight,
                                quad.bottomRight,
                                quad.bottomLeft
                            ]),
                            with: .color(.yellow),
                            lineWidth: 3
                        )

                        // Existing control and target overlays.
                        if let homography = try? PanelHomography(quad: quad) {
                            for button in buttons {
                                let bounds = button.bounds

                                let corners = [
                                    PanelPoint(x: bounds.minX, y: bounds.minY),
                                    PanelPoint(x: bounds.maxX, y: bounds.minY),
                                    PanelPoint(x: bounds.maxX, y: bounds.maxY),
                                    PanelPoint(x: bounds.minX, y: bounds.maxY)
                                ].compactMap {
                                    homography.imagePoint(for: $0)
                                }

                                guard corners.count == 4 else { continue }

                                let selected = button.id == targetID

                                context.stroke(
                                    polygon(corners),
                                    with: .color(selected ? .orange : .cyan),
                                    lineWidth: 2
                                )

                                if let center = homography.imagePoint(
                                    for: bounds.center
                                ) {
                                    let location = point(center)

                                    if selected {
                                        context.stroke(
                                            Path(
                                                ellipseIn: CGRect(
                                                    x: location.x - 12,
                                                    y: location.y - 12,
                                                    width: 24,
                                                    height: 24
                                                )
                                            ),
                                            with: .color(.orange),
                                            lineWidth: 3
                                        )
                                    }

                                    context.draw(
                                        Text(button.label ?? "Unlabelled")
                                            .font(.caption2)
                                            .foregroundColor(
                                                selected ? .orange : .cyan
                                            ),
                                        at: CGPoint(
                                            x: location.x,
                                            y: location.y - 15
                                        )
                                    )
                                }
                            }
                        }
                    }

                    // Existing raw fingertip overlay.
                    if let fingertip {
                        let p = point(fingertip)
                        let radius: CGFloat = 6

                        context.fill(
                            Path(
                                ellipseIn: CGRect(
                                    x: p.x - radius,
                                    y: p.y - radius,
                                    width: radius * 2,
                                    height: radius * 2
                                )
                            ),
                            with: .color(.green)
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(width: viewSize.width, height: viewSize.height)
            .clipped()
        }
        .background(.black)
        .aspectRatio(
            CGFloat(image.width) / CGFloat(image.height),
            contentMode: .fit
        )
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
