#if DEBUG
import ContourCore
import PhotosUI
import SwiftUI
import UIKit

/// Reference setup for a photo the developer took of the *supplied* panel
/// fixture. No still-image detection or live tracking happens in this view.
struct ManualReferenceSetupView: View {
    let layout: SurfaceMap
    let layoutName: String
    let onPrepared: @MainActor (PanelReference) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var photo: PanelPhoto?
    @State private var corners: [ImagePoint] = []
    @State private var confirmsLayout = false
    @State private var error: String?

    private let cornerNames = ["top-left", "top-right", "bottom-right", "bottom-left"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a photo you captured of the supplied \(layoutName) panel. Mark its outer corners in order. The layout has \(layout.buttons.count) buttons.")
                    .font(.subheadline)
                PhotosPicker("Choose captured photo", selection: $selectedItem, matching: .images)
                    .buttonStyle(.borderedProminent)

                if let image {
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width / image.size.width,
                                        geometry.size.height / image.size.height)
                        let fitted = CGSize(width: image.size.width * scale,
                                            height: image.size.height * scale)
                        ZStack {
                            Image(uiImage: image).resizable()
                                .frame(width: fitted.width, height: fitted.height)
                            Canvas { context, size in
                                var line = Path()
                                for (index, corner) in corners.enumerated() {
                                    let point = CGPoint(x: corner.x * size.width, y: corner.y * size.height)
                                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                                    context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6,
                                                                        width: 12, height: 12)),
                                                 with: .color(.yellow))
                                    context.draw(Text("\(index + 1)").foregroundColor(.yellow),
                                                 at: CGPoint(x: point.x + 15, y: point.y - 15))
                                }
                                if corners.count == 4 {
                                    line.closeSubpath()
                                }
                                context.stroke(line, with: .color(.yellow), lineWidth: 2)
                            }
                            .frame(width: fitted.width, height: fitted.height)
                            .allowsHitTesting(false)
                        }
                        .frame(width: fitted.width, height: fitted.height)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { gesture in
                            guard corners.count < 4 else { return }
                            corners.append(ImagePoint(x: Double(gesture.location.x / fitted.width),
                                                      y: Double(gesture.location.y / fitted.height)))
                            error = nil
                        })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: 350)
                    .background(.black)
                    Text(corners.count < 4
                         ? "Tap the \(cornerNames[corners.count]) corner (\(corners.count + 1) of 4)."
                         : "Four corners marked. Check the yellow outline.")
                    HStack {
                        Button("Undo corner") { if !corners.isEmpty { corners.removeLast() } }
                            .disabled(corners.isEmpty)
                        Button("Clear corners") { corners.removeAll() }
                            .disabled(corners.isEmpty)
                    }
                    .buttonStyle(.bordered)
                }

                Toggle("The marked panel matches the supplied \(layoutName) layout", isOn: $confirmsLayout)
                    .disabled(photo == nil)
                Button("Prepare PanelReference") { prepare() }
                    .buttonStyle(.borderedProminent)
                    .disabled(photo == nil || corners.count != 4 || !confirmsLayout)
                if let error {
                    Text(error).foregroundStyle(.red)
                    if let selectedItem {
                        Button("Retry loading photo") { Task { await load(selectedItem) } }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Manual reference setup")
        .onChange(of: selectedItem) { _, item in
            Task { await load(item) }
        }
    }

    @MainActor private func load(_ item: PhotosPickerItem?) async {
        image = nil
        photo = nil
        corners.removeAll()
        confirmsLayout = false
        error = nil
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let source = UIImage(data: data), let sourcePixels = source.cgImage,
                  sourcePixels.width > 0, sourcePixels.height > 0 else {
                throw ManualPanelReferenceBuilder.BuildError.invalidPhoto
            }
            guard selectedItem == item else { return }
            // Draw through UIKit so pixels and displayed corners share an
            // upright, unmirrored image basis regardless of EXIF orientation.
            let quarterTurn: Bool
            switch source.imageOrientation {
            case .left, .right, .leftMirrored, .rightMirrored: quarterTurn = true
            default: quarterTurn = false
            }
            let size = quarterTurn
                ? CGSize(width: sourcePixels.height, height: sourcePixels.width)
                : CGSize(width: sourcePixels.width, height: sourcePixels.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let upright = renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
            guard let cgImage = upright.cgImage, let jpeg = upright.jpegData(compressionQuality: 0.95) else {
                throw ManualPanelReferenceBuilder.BuildError.invalidPhoto
            }
            image = upright
            photo = PanelPhoto(data: jpeg,
                               pixelSize: PixelSize(width: cgImage.width, height: cgImage.height),
                               orientation: .up, timestamp: Date())
        } catch {
            self.error = "Could not load photo: \(error.localizedDescription)"
        }
    }

    private func prepare() {
        guard let photo, confirmsLayout else { return }
        do {
            let reference = try ManualPanelReferenceBuilder.make(
                photo: photo, corners: corners, layout: layout)
            error = nil
            onPrepared(reference)
            dismiss()
        } catch {
            self.error = "Could not prepare reference: \(error.localizedDescription)"
        }
    }
}
#endif
