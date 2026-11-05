#if DEBUG
import ContourCore
import PhotosUI
import SwiftUI
import Tracking
import UniformTypeIdentifiers

/// Developer tool: run the Vision and feature trackers on saved photos and
/// step through each tracker's result on the exact input image.
struct PhotoReplayView: View {
    @State private var controller = PhotoReplayController()
    @State private var unmarkedReference: PanelPhoto?
    @State private var referenceItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingReference = false
    @State private var importingPhotos = false
    @State private var importError: String?
    @State private var excludeHighlights = FeatureTrackingOptions().excludeHighlights
    @State private var normalizeContrast = FeatureTrackingOptions().normalizeContrast

    var body: some View {
        List {
            Section {
                Text("Replays saved photos through both 2D panel trackers in order. Ordinary photos carry no world data, so hybrid tracking isn't replayed here.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Load built-in example") { loadExample() }
            }
            referenceSection
            photosSection
            Section("Feature options") {
                Toggle("Exclude clipped highlights", isOn: $excludeHighlights)
                Toggle("Normalize contrast", isOn: $normalizeContrast)
            }
            Section("Replay") {
                ForEach(PhotoReplayController.Lane.allCases) { lane in
                    LabeledContent(lane.rawValue, value: Self.describe(controller.laneStates[lane] ?? .idle,
                                                                      total: controller.photos.count))
                }
                Button("Replay from the first photo") { controller.replay() }
                    .disabled(controller.reference == nil || controller.photos.isEmpty)
                Button("Reset everything", role: .destructive) {
                    controller.reset()
                    unmarkedReference = nil
                    importError = nil
                }
            }
            if !controller.photos.isEmpty, controller.reference != nil {
                ReplayResultsSection(controller: controller)
            }
        }
        .navigationTitle("Tracking photo replay")
        .onChange(of: excludeHighlights) { applyOptions() }
        .onChange(of: normalizeContrast) { applyOptions() }
        .onChange(of: referenceItem) { _, item in Task { await loadReference(item) } }
        .onChange(of: photoItems) { _, items in Task { await loadPhotos(items) } }
        .fileImporter(isPresented: $importingReference, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { importReference(url) }
            if case .failure(let error) = result { importError = error.localizedDescription }
        }
        .fileImporter(isPresented: $importingPhotos, allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importPhotos(urls)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .sheet(item: $unmarkedReference) { photo in
            NavigationStack {
                ReplayCornerMarkingView(photo: photo) { reference in
                    controller.setReference(reference)
                    unmarkedReference = nil
                }
            }
        }
        .onDisappear { controller.retire() }
    }

    private var referenceSection: some View {
        Section("Reference") {
            if let reference = controller.reference {
                CapturedPanelReviewView(reference: reference)
            } else {
                Text("Choose a clear photo of the panel, then mark its four corners.").foregroundStyle(.secondary)
            }
            PhotosPicker("Choose from Photos", selection: $referenceItem, matching: .images)
            Button("Choose from Files") { importingReference = true }
            if let importError { Text(importError).foregroundStyle(.red) }
        }
    }

    private var photosSection: some View {
        Section("Test photos, in replay order") {
            ForEach(Array(controller.photos.enumerated()), id: \.element.id) { index, photo in
                Text("\(index + 1). \(photo.name)")
            }
            PhotosPicker("Choose from Photos", selection: $photoItems, matching: .images)
            Button("Choose from Files") { importingPhotos = true }
            Text("Photos picker keeps your selection order. Files are replayed in name order.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Loading

    private func applyOptions() {
        controller.setOptions(FeatureTrackingOptions(excludeHighlights: excludeHighlights,
                                                     normalizeContrast: normalizeContrast))
    }

    private func loadExample() {
        importError = nil
        do {
            let reference = ReplayExample.reference()
            let photo = try ReplayImageLoader.referencePhoto(from: reference.data, name: reference.name)
            controller.setReference(try ManualPanelReferenceBuilder.make(
                photo: photo, corners: ReplayExample.corners, layout: SurfaceMap(buttons: [], confidence: 1)))
            controller.setPhotos(try ReplayExample.testPhotos().enumerated().map { index, photo in
                PhotoReplayController.Photo(name: photo.name,
                                            frame: try ReplayImageLoader.frame(from: photo.data, name: photo.name, index: index))
            })
        } catch {
            importError = error.localizedDescription
        }
    }

    private func loadReference(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        importError = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ReplayImageLoader.LoadError.unreadable("The selected photo")
            }
            unmarkedReference = try ReplayImageLoader.referencePhoto(from: data, name: "The selected photo")
        } catch {
            importError = error.localizedDescription
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        importError = nil
        var photos: [PhotoReplayController.Photo] = []
        do {
            for (index, item) in items.enumerated() {
                let name = "Photo \(index + 1)"
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ReplayImageLoader.LoadError.unreadable(name)
                }
                photos.append(.init(name: name, frame: try ReplayImageLoader.frame(from: data, name: name, index: index)))
            }
            controller.setPhotos(photos)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importReference(_ url: URL) {
        importError = nil
        do {
            unmarkedReference = try ReplayImageLoader.referencePhoto(from: try read(url), name: url.lastPathComponent)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importPhotos(_ urls: [URL]) {
        importError = nil
        do {
            let ordered = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            controller.setPhotos(try ordered.enumerated().map { index, url in
                .init(name: url.lastPathComponent,
                      frame: try ReplayImageLoader.frame(from: try read(url), name: url.lastPathComponent, index: index))
            })
        } catch {
            importError = error.localizedDescription
        }
    }

    private func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    static func describe(_ state: PhotoReplayController.LaneState, total: Int) -> String {
        switch state {
        case .idle: "Not running"
        case .registering: "Registering reference…"
        case .running(let completed): "\(completed) of \(total)"
        case .finished: "Finished"
        case .failed(let message): message
        }
    }
}

/// The selected photo with each tracker's own outline and evidence.
private struct ReplayResultsSection: View {
    @Bindable var controller: PhotoReplayController
    @State private var image: CGImage?
    @State private var renderedPhotoID: UUID?
    private let renderer = FrameImageRenderer()

    var body: some View {
        Section("Results") {
            if let photo = controller.selectedPhoto {
                HStack {
                    Button("Previous") { controller.selectedIndex -= 1 }
                        .disabled(controller.selectedIndex == 0)
                    Spacer()
                    Text("Photo \(controller.selectedIndex + 1) of \(controller.photos.count)").monospacedDigit()
                    Spacer()
                    Button("Next") { controller.selectedIndex += 1 }
                        .disabled(controller.selectedIndex >= controller.photos.count - 1)
                }
                .buttonStyle(.borderless)
                Text(photo.name).font(.headline)
                ForEach(PhotoReplayController.Lane.allCases) { lane in
                    lanePanel(lane, photo: photo)
                }
                Text("Times are replay processing time on this device, not live camera latency. A tracked result is the tracker's claim, not proof the outline is right: check it against the image.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: controller.selectedPhoto?.id) {
            guard let photo = controller.selectedPhoto else { return }
            let rendered = await renderer.previewImage(for: photo.frame)
            guard !Task.isCancelled, controller.selectedPhoto?.id == photo.id else { return }
            image = rendered
            renderedPhotoID = photo.id
        }
    }

    @ViewBuilder
    private func lanePanel(_ lane: PhotoReplayController.Lane, photo: PhotoReplayController.Photo) -> some View {
        let result = controller.result(lane, for: photo)
        VStack(alignment: .leading, spacing: 6) {
            Text(lane.rawValue).font(.subheadline.bold())
            if let image, renderedPhotoID == photo.id {
                // Only this tracker's outline for this exact photo; none if it reported none.
                TrackingImageView(image: image, quad: result?.quad,
                                  acceptedFeaturePoints: result?.diagnostics?.inlierPoints ?? [])
            } else {
                ProgressView()
            }
            if let result {
                Text(result.error.map { "Error: \($0)" } ?? PhotoReplayController.describe(result.status))
                    .foregroundStyle(result.status == .tracked ? .green : .orange)
                Text(String(format: "Confidence %.2f · replay %.1f ms", result.confidence, result.replayMilliseconds))
                    .font(.caption).monospacedDigit()
                if let evidence = result.diagnostics {
                    Text("\(evidence.message) · features \(evidence.frameFeatures) · matches \(evidence.matchCount) · inliers \(evidence.inlierCount) · coverage \(Int(evidence.coverage * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                    if evidence.saturatedFraction > 0 {
                        Text(String(format: "Clipped %.1f%% · excluded as glare %.1f%%",
                                    evidence.saturatedFraction * 100, evidence.excludedHighlightFraction * 100))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if case .failed(let message) = controller.laneStates[lane] ?? .idle {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Waiting for this tracker…").foregroundStyle(.secondary)
            }
        }
    }
}

/// Four taps on the upright reference photo: TL, TR, BR, BL.
private struct ReplayCornerMarkingView: View {
    let photo: PanelPhoto
    let onMarked: @MainActor (PanelReference) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var marks: [ImagePoint] = []
    @State private var error: String?

    private let instructions = ["top-left", "top-right", "bottom-right", "bottom-left"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = UIImage(data: photo.data) {
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    ZStack {
                        Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                        Canvas { context, canvas in
                            var outline = Path()
                            for (index, mark) in marks.enumerated() {
                                let point = CGPoint(x: mark.x * canvas.width, y: mark.y * canvas.height)
                                if index == 0 { outline.move(to: point) } else { outline.addLine(to: point) }
                                context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                                             with: .color(.yellow))
                            }
                            if marks.count == 4 { outline.closeSubpath() }
                            context.stroke(outline, with: .color(.yellow), lineWidth: 2)
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard marks.count < 4 else { return }
                        let point = ImagePoint(x: tap.location.x / size.width, y: tap.location.y / size.height)
                        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
                        marks.append(point)
                        error = nil
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(.black)
                Text(marks.count < 4 ? "Tap the panel's \(instructions[marks.count]) corner (\(marks.count + 1) of 4)."
                                     : "Check the yellow outline.")
                HStack {
                    Button("Undo") { if !marks.isEmpty { marks.removeLast() }; error = nil }
                    Button("Clear") { marks.removeAll(); error = nil }
                    Spacer()
                    Button("Use reference") { use() }.buttonStyle(.borderedProminent).disabled(marks.count != 4)
                }
                .buttonStyle(.bordered)
            } else {
                Text("This photo couldn't be displayed.").foregroundStyle(.red)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding()
        .navigationTitle("Mark panel corners")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func use() {
        do {
            onMarked(try ManualPanelReferenceBuilder.make(photo: photo, corners: marks,
                                                          layout: SurfaceMap(buttons: [], confidence: 1)))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension PanelPhoto: @retroactive Identifiable {}
#endif
