#if DEBUG
import ContourCore
import SwiftUI
import UIKit

/// Uses the exact upright frame captured from the tracking camera. Five taps
/// supply a real panel reference and one target without invoking Surface.
struct ManualTrackingSetupView: View {
    let photo: PanelPhoto
    let onPrepared: @MainActor (PanelReference) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var marks: [ImagePoint] = []
    @State private var error: String?
    @State private var preparation: Task<Void, Never>?
    @State private var preparing = false

    private let instructions = ["top-left panel corner", "top-right panel corner",
                                "bottom-right panel corner", "bottom-left panel corner",
                                "center of the button you want to reach"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Mark the panel's four outer corners, then a target button's center. This bypasses Surface detection; tracking and vibration remain live. Keep the phone upright and return it to this view of the panel after marking.")
                if let image = UIImage(data: photo.data), photo.orientation == .up {
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width / image.size.width,
                                        geometry.size.height / image.size.height)
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        ZStack {
                            Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                            Canvas { context, canvas in
                                var outline = Path()
                                for (index, mark) in marks.enumerated() {
                                    let point = CGPoint(x: mark.x * canvas.width, y: mark.y * canvas.height)
                                    if index < 4 {
                                        if index == 0 { outline.move(to: point) } else { outline.addLine(to: point) }
                                    }
                                    context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6,
                                                                       width: 12, height: 12)),
                                                 with: .color(index == 4 ? .red : .yellow))
                                    context.draw(Text(index == 4 ? "Target" : "\(index + 1)")
                                        .foregroundColor(index == 4 ? .red : .yellow),
                                                 at: CGPoint(x: point.x + 18, y: point.y - 16))
                                }
                                if marks.count >= 4 { outline.closeSubpath() }
                                context.stroke(outline, with: .color(.yellow), lineWidth: 2)
                            }
                            .allowsHitTesting(false)
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            guard marks.count < 5, !preparing else { return }
                            let point = ImagePoint(x: tap.location.x / size.width, y: tap.location.y / size.height)
                            guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
                            marks.append(point)
                            error = nil
                        })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: 430)
                    .background(.black)
                    Text(marks.count < 5 ? "Tap the \(instructions[marks.count]) (\(marks.count + 1) of 5)."
                         : "Check the yellow panel outline and red target.")
                    HStack {
                        Button("Undo") { if !marks.isEmpty { marks.removeLast() }; error = nil }
                        Button("Clear marks") { marks.removeAll(); error = nil }
                    }
                    .buttonStyle(.bordered)
                    .disabled(marks.isEmpty || preparing)
                    Button(preparing ? "Preparing…" : "Use manual reference") { prepare() }
                        .buttonStyle(.borderedProminent)
                        .disabled(marks.count != 5 || preparing)
                    Text("The target is an approximate region around your tap, not a detected button outline. This tests tracking and guidance, not Surface accuracy.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This camera frame could not be displayed upright. Cancel and capture again.")
                        .foregroundStyle(.red)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .padding()
        }
        .navigationTitle("Manual tracking test")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onDisappear { preparation?.cancel() }
    }

    private func prepare() {
        guard marks.count == 5 else { return }
        preparing = true
        preparation = Task {
            defer { preparing = false }
            do {
                let reference = try ManualTrackingReferenceBuilder.make(photo: photo,
                    corners: Array(marks.prefix(4)), target: marks[4])
                try await onPrepared(reference)
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                // The setup was dismissed or superseded.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
