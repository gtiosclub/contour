//
// MLButtonDetection.swift
// ContourFeedback — Experience / Evan (experimental model adapter)
//
// Opt-in only: no existing pipeline is changed by adding this file.
// ContourApp can supply MLButtonDetection() as SurfaceUnderstanding directly.
// The default reference comes from a padded group of model detections. Do not import
// SurfaceUnderstanding or Tracking into this package.
//
// Bundled model: DetectButtonsForContour 2, Create ML Transfer Learning,
// 74,000 iterations, Household Appliance Interface Elements v0.91.
// Model labels: knob, pushbutton, slider, toggle, touch.
// Source: https://github.com/FlorianLa/dataset-interfaces-household-appliances
// Source declares GPLv3 with possible file-specific exceptions. This bundled
// experimental model's redistribution permissions still need review.
// Model resource: Resources/ButtonDetection.mlmodel, loaded via Bundle.module.
// Model SHA-256: 88279280d8c6e4b2af89ee26c5f0f8cae03df7a48395bd2e7d23e3f00e257c25

import ContourCore
import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO
import Vision

/// Detects operable controls, reads their labels, and returns ContourCore geometry.
///
/// `knob`, `pushbutton`, and `touch` share one output category. This does not
/// imply that reaching a knob completes a rotation action. OCR only names model
/// detections: unrelated printed words never become additional controls.
///
/// Inference runs on this actor, not the main actor. An individual synchronous
/// Vision request cannot be interrupted; cancellation is checked at each stage.
/// One instance should be retained across scans to reuse the loaded model.
public actor MLButtonDetection: ContourCore.SurfaceUnderstanding {
    public typealias PanelLocator = @Sendable (PanelPhoto) async throws -> (quad: PanelQuad, confidence: Double)

    public enum InferenceMode: String, CaseIterable, Sendable {
        case wholeImage
        case wholeImageAndTiles
    }

    /// Image-space diagnostics, before panel projection. "Raw" means Vision's
    /// returned observations, after any suppression already inside the model.
    public struct Candidate: Sendable {
        public var bounds: PanelRect
        public var confidence: Double
        public var category: String
        public var source: String
        public var accepted: Bool
        public var objectConfidence: Double = 1
        public var classificationConfidence: Double = 1
        public var rejectionReason: String? = nil
    }

    public struct Review: Sendable {
        public let photoID: UUID
        public let raw: [Candidate]
        public let merged: [Candidate]
        public let refined: [Candidate]
        public let warnings: [String]
        public let detection: PanelDetection?
        public let selectionError: SurfaceUnderstandingError?
        public let modelConfidenceFloor: Double?
        public let inferenceCount: Int
        public let elapsedSeconds: Double
    }

    public struct Configuration: Sendable {
        /// Initial experimental values, not calibrated production thresholds.
        public var inferenceMode: InferenceMode
        public var minimumConfidence: Float
        public var duplicateIntersectionOverUnion: Double
        public var readsLabels: Bool
        public var refinesGeometry: Bool
        /// Reject single detections by default; opt into one-control references explicitly.
        public var minimumControls: Int
        /// Image-space grouping uses pixel aspect ratio and this median-size multiplier.
        public var groupGapMultiplier: Double
        /// Gap limits are fractions of the upright image's longest side.
        public var minimumGroupGap: Double
        public var maximumGroupGap: Double
        /// A runner-up with this fraction of the winning confidence sum is ambiguous.
        public var ambiguityRatio: Double
        /// Padding is relative to each axis of the selected controls' envelope.
        public var referencePaddingFraction: Double
        /// Minimum padding on each side, in normalized image coordinates.
        public var minimumReferencePadding: Double
        public var minimumReferenceArea: Double

        public init(minimumConfidence: Float = 0.1,
                    inferenceMode: InferenceMode = .wholeImage,
                    duplicateIntersectionOverUnion: Double = 0.45,
                    readsLabels: Bool = true, refinesGeometry: Bool = true, minimumControls: Int = 2,
                    groupGapMultiplier: Double = 2.5,
                    minimumGroupGap: Double = 0.04, maximumGroupGap: Double = 0.16,
                    ambiguityRatio: Double = 0.8,
                    referencePaddingFraction: Double = 0.12,
                    minimumReferencePadding: Double = 0.015,
                    minimumReferenceArea: Double = 0.0025) {
            self.inferenceMode = inferenceMode
            self.minimumConfidence = minimumConfidence
            self.duplicateIntersectionOverUnion = duplicateIntersectionOverUnion
            self.readsLabels = readsLabels
            self.refinesGeometry = refinesGeometry
            self.minimumControls = minimumControls
            self.groupGapMultiplier = groupGapMultiplier
            self.minimumGroupGap = minimumGroupGap
            self.maximumGroupGap = maximumGroupGap
            self.ambiguityRatio = ambiguityRatio
            self.referencePaddingFraction = referencePaddingFraction
            self.minimumReferencePadding = minimumReferencePadding
            self.minimumReferenceArea = minimumReferenceArea
        }
    }

    struct Control {
        var bounds: PanelRect
        var confidence: Double
    }
    private struct Word {
        var text: String
        var bounds: PanelRect
    }

    private let panelLocator: PanelLocator?
    private let configuration: Configuration
    private let suppliedModelURL: URL?
    private var loadedModel: VNCoreMLModel?
    private var modelConfidenceFloor: Double?
    private static let acceptedLabels: Set<String> = ["knob", "pushbutton", "touch"]

    /// With no locator, detects controls on the whole upright image, selects a
    /// spatial group, and builds a padded reference around that group. This is
    /// an estimated planar tracking region, not a measured physical panel edge.
    /// A supplied locator remains supported and must use this exact upright photo.
    /// `modelURL` optionally overrides the bundled model (.mlmodel/.mlpackage/
    /// .mlmodelc); leaving it nil uses the bundled ButtonDetection model.
    public init(panelLocator: PanelLocator? = nil,
                configuration: Configuration = .init(), modelURL: URL? = nil) {
        self.panelLocator = panelLocator
        self.configuration = configuration
        self.suppliedModelURL = modelURL
    }

    public func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        do {
            try Self.checkCancellation()
            if let panelLocator {
                let panel = try await panelLocator(photo)
                return try analyze(photo, panel: panel.quad, panelConfidence: panel.confidence)
            }
            return try analyze(photo, panel: nil)
        } catch {
            if Task.isCancelled || error is CancellationError { throw SurfaceUnderstandingError.cancelled }
            if let error = error as? SurfaceUnderstandingError { throw error }
            throw SurfaceUnderstandingError.underlying(error.localizedDescription)
        }
    }

    /// For callers that already have a panel quad. No guessed full-frame panel.
    public func detectPanel(from photo: PanelPhoto, panel: PanelQuad,
                            panelConfidence: Double) async throws -> PanelDetection {
        do {
            return try analyze(photo, panel: panel, panelConfidence: panelConfidence)
        } catch {
            if Task.isCancelled || error is CancellationError { throw SurfaceUnderstandingError.cancelled }
            if let error = error as? SurfaceUnderstandingError { throw error }
            throw SurfaceUnderstandingError.underlying(error.localizedDescription)
        }
    }

    /// Debug callers retain raw candidates even when group selection fails.
    /// Threshold/mode overrides apply only to this request, never shared settings.
    public func review(from photo: PanelPhoto, minimumConfidence: Float = 0.1,
                       mode: InferenceMode = .wholeImage, refinesGeometry: Bool = true) throws -> Review {
        var settings = configuration
        settings.minimumConfidence = minimumConfidence
        settings.inferenceMode = mode
        settings.refinesGeometry = refinesGeometry
        return try evaluate(photo, panel: nil, configuration: settings)
    }

    private func analyze(_ photo: PanelPhoto, panel: PanelQuad?,
                         panelConfidence: Double = 0.6) throws -> PanelDetection {
        let result = try evaluate(photo, panel: panel, panelConfidence: panelConfidence,
                                  configuration: configuration)
        guard let detection = result.detection else {
            throw result.selectionError ?? SurfaceUnderstandingError.noPanelFound
        }
        return detection
    }

    private func evaluate(_ photo: PanelPhoto, panel: PanelQuad?, panelConfidence: Double = 0.6,
                          configuration c: Configuration) throws -> Review {
        let started = ContinuousClock.now
        try Self.checkCancellation()
        try Self.validate(c)
        guard panelConfidence.isFinite, (0...1).contains(panelConfidence) else {
            throw SurfaceUnderstandingError.underlying("Invalid panel confidence")
        }
        let image = try Self.uprightImage(photo)
        let regions = Self.inferenceRegions(width: image.width, height: image.height, mode: c.inferenceMode)
        let visionModel = try model()
        if modelConfidenceFloor != nil {
            // Keep the runtime model floor below the caller's score threshold,
            // including custom thresholds lower than the debug presets.
            let floor = min(0.05, Double(c.minimumConfidence))
            visionModel.featureProvider = try MLDictionaryFeatureProvider(dictionary: [
                "confidenceThreshold": MLFeatureValue(double: floor)
            ])
            modelConfidenceFloor = floor
        }
        var raw: [Candidate] = []
        for (index, region) in regions.enumerated() {
            try Self.checkCancellation()
            guard let crop = image.cropping(to: region) else { throw SurfaceUnderstandingError.undecodableImage }
            let request = VNCoreMLRequest(model: visionModel)
            request.imageCropAndScaleOption = .scaleFill
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
            try Self.checkCancellation()
            let observations = request.results ?? []
            guard observations.allSatisfy({ $0 is VNRecognizedObjectObservation }) else {
                throw SurfaceUnderstandingError.underlying("Model did not return recognized-object observations")
            }
            for case let object as VNRecognizedObjectObservation in observations {
                guard let label = object.labels.first,
                      let score = Self.detectionScore(object: Double(object.confidence),
                                                     classification: Double(label.confidence)),
                      let bounds = Self.imageBounds(object.boundingBox, crop: region,
                                                    width: image.width, height: image.height) else { continue }
                // A tile-cut control is incomplete; keep it visible in diagnostics
                // but rely on the overlapping tile or whole image for its geometry.
                let cut = Self.touchesInternalEdge(object.boundingBox, crop: region,
                                                   width: image.width, height: image.height)
                let reason: String?
                if !Self.acceptedLabels.contains(label.identifier) { reason = "Excluded class" }
                else if score < Double(c.minimumConfidence) { reason = "Below score threshold" }
                else if cut { reason = "Cut by crop edge" }
                else { reason = nil }
                raw.append(Candidate(bounds: bounds, confidence: score,
                                     category: label.identifier, source: index == 0 ? "Full" : "Tile \(index)",
                                     accepted: reason == nil,
                                     objectConfidence: Double(object.confidence),
                                     classificationConfidence: Double(label.confidence), rejectionReason: reason))
            }
        }
        let merged = Self.mergeCandidates(raw.filter(\.accepted), threshold: c.duplicateIntersectionOverUnion)
        var warnings: [String] = []
        var refined = merged
        if c.refinesGeometry {
            do {
                let edges = try Self.rectangleEdges(image)
                // Refine before suppression so an inaccurate full-image box
                // cannot erase a better tile hypothesis before edge matching.
                refined = Self.refineCandidates(raw.filter(\.accepted), edges: edges)
            } catch {
                try Self.checkCancellation()
                warnings.append("Edge refinement unavailable; kept ML geometry: " + error.localizedDescription)
            }
            refined = Self.mergeCandidates(refined, threshold: c.duplicateIntersectionOverUnion)
            refined = Self.removeWeakOutliers(refined, imageSize: CGSize(width: image.width, height: image.height))
        }
        var selectionError: SurfaceUnderstandingError?
        var detection: PanelDetection?
        do {
            detection = try Self.finish(photo: photo, image: image,
                                        controls: refined.map { Control(bounds: $0.bounds, confidence: $0.confidence) },
                                        panel: panel, panelConfidence: panelConfidence, configuration: c)
        } catch let error as SurfaceUnderstandingError {
            if error == .cancelled { throw error }
            selectionError = error
        }
        try Self.checkCancellation()
        let elapsed = started.duration(to: .now).components
        return Review(photoID: photo.id, raw: raw, merged: merged, refined: refined, warnings: warnings, detection: detection,
                      selectionError: selectionError, modelConfidenceFloor: modelConfidenceFloor, inferenceCount: regions.count,
                      elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    private static func finish(photo: PanelPhoto, image: CGImage, controls: [Control],
                               panel: PanelQuad?, panelConfidence: Double,
                               configuration c: Configuration) throws -> PanelDetection {
        let reference = try makeReference(controls, imageSize: CGSize(width: image.width, height: image.height),
                                          panel: panel, panelConfidence: panelConfidence, configuration: c)
        let transform = try Projection(reference.quad)
        var controls = reference.controls.compactMap { control -> Control? in
            guard let bounds = transform.mapImageRect(control.bounds), bounds.center.isOnPanel else { return nil }
            return Control(bounds: bounds, confidence: control.confidence)
        }
        // SurfaceMap expects non-overlapping hit regions. Preserve geometry:
        // discard a conflicting lower-score box instead of squeezing both boxes.
        controls = removeConflictingControls(controls)
        guard controls.count >= c.minimumControls else { throw SurfaceUnderstandingError.noPanelFound }
        controls.sort { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
        let words: [Word]
        if c.readsLabels && !controls.isEmpty {
            do { words = try readWords(image, transform: transform) }
            catch {
                try checkCancellation()
                words = []
            }
        } else { words = [] }
        try checkCancellation()
        let labels = assign(words, to: controls.map(\.bounds))
        let buttons = zip(controls, labels).map { control, label in
            SurfaceMap.Button(label: label, bounds: control.bounds, confidence: control.confidence)
        }
        return PanelDetection(referencePhotoID: photo.id, quad: reference.quad,
                              map: SurfaceMap(buttons: buttons, confidence: reference.confidence))
    }

    /// Square crops retain aspect ratio and enlarge small controls. A 25%
    /// overlap covers seams. Cap at nine crops for extremely elongated inputs.
    static func inferenceRegions(width: Int, height: Int, mode: InferenceMode) -> [CGRect] {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard mode == .wholeImageAndTiles, width > 0, height > 0 else { return [full] }
        let side = max(1, floor(Double(min(width, height)) * 0.8))
        func origins(_ length: Int) -> [Double] {
            let travel = Double(length) - side
            let count = min(9, max(2, Int(ceil(travel / (side * 0.75))) + 1))
            return (0..<count).map { (Double($0) * travel / Double(count - 1)).rounded() }
        }
        // Ordinary phone photos use 2 × 3 or 2 × 4 crops. Very long images
        // use the whole short side, keeping the number of requests bounded.
        let xs = origins(width), ys = origins(height)
        if xs.count * ys.count <= 9 {
            return [full] + ys.flatMap { y in xs.map { x in CGRect(x: x, y: y, width: side, height: side) } }
        }
        let largerSide = Double(min(width, height))
        let travel = Double(max(width, height)) - largerSide
        let count = min(9, max(2, Int(ceil(travel / (largerSide * 0.75))) + 1))
        return [full] + (0..<count).map { index in
            let offset = (Double(index) * travel / Double(count - 1)).rounded()
            return CGRect(x: width > height ? offset : 0, y: height > width ? offset : 0,
                          width: largerSide, height: largerSide)
        }
    }

    private static func rectangleEdges(_ image: CGImage) throws -> [PanelRect] {
        try checkCancellation()
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.08
        request.maximumAspectRatio = 1
        request.minimumSize = 0.008
        request.minimumConfidence = 0.65
        request.quadratureTolerance = 20
        request.maximumObservations = 128
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try checkCancellation()
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return (request.results ?? []).compactMap {
            imageBounds($0.boundingBox, crop: full, width: image.width, height: image.height)
        }
    }

    /// Match geometry only with a nearby, similarly sized edge. Never create
    /// buttons from text or rectangles alone. Ambiguous matches remain unchanged.
    static func refineCandidates(_ candidates: [Candidate], edges: [PanelRect]) -> [Candidate] {
        candidates.map { candidate in
            // Knobs may contain decorative rectangles; preserve their ML geometry.
            guard candidate.category != "knob" else { return candidate }
            let a = candidate.bounds
            let matches: [(PanelRect, Double)] = edges.compactMap { b in
                let wr = b.width / a.width, hr = b.height / a.height
                guard (0.6...1.8).contains(wr), (0.35...1.8).contains(hr),
                      abs(a.center.x - b.center.x) <= a.width * 0.45,
                      abs(a.center.y - b.center.y) <= a.height * 0.6 else { return nil }
                let overlap = intersection(a, b)
                let union = a.width * a.height + b.width * b.height - overlap
                guard union > 0, overlap / union >= 0.25 else { return nil }
                return (b, overlap / union)
            }.sorted { $0.1 > $1.1 }
            guard let best = matches.first else { return candidate }
            // Nested/double borders are one edge hypothesis. Different adjacent
            // controls with similar support are genuinely ambiguous.
            let rival = matches.dropFirst().first {
                let overlap = intersection($0.0, best.0)
                let union = $0.0.width * $0.0.height + best.0.width * best.0.height - overlap
                return overlap / union < 0.75
            }
            guard rival == nil || best.1 > rival!.1 * 1.3 else { return candidate }
            var result = candidate
            result.bounds = best.0
            result.source += " + edge"
            return result
        }
    }

    /// A lone weak display/text detection must not enlarge a strong control
    /// cluster. Low-score neighbours remain eligible; all-weak scenes are unchanged.
    static func removeWeakOutliers(_ candidates: [Candidate], imageSize: CGSize) -> [Candidate] {
        let strong = candidates.filter { $0.confidence >= 0.5 }
        guard strong.count >= 2 else { return candidates }
        let longest = max(imageSize.width, imageSize.height)
        guard longest > 0 else { return candidates }
        let sx = imageSize.width / longest, sy = imageSize.height / longest
        return candidates.filter { candidate in
            guard candidate.confidence < 0.25 else { return true }
            let a = candidate.bounds
            return strong.contains { anchor in
                let b = anchor.bounds
                let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX)) * sx
                let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY)) * sy
                return hypot(dx, dy) <= hypot(b.width * sx, b.height * sy)
            }
        }
    }

    /// Vision normalizes classification confidences to sum to one. They are
    /// conditional class scores, not the certainty that this box is an object.
    /// See VNRecognizedObjectObservation in the Vision SDK headers.
    static func detectionScore(object: Double, classification: Double) -> Double? {
        guard object.isFinite, classification.isFinite,
              (0...1).contains(object), (0...1).contains(classification) else { return nil }
        return object * classification
    }

    static func imageBounds(_ box: CGRect, crop: CGRect, width: Int, height: Int) -> PanelRect? {
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0 else { return nil }
        return clippedToImage(PanelRect(x: (crop.minX + box.minX * crop.width) / Double(width),
                                        y: (crop.minY + (1 - box.maxY) * crop.height) / Double(height),
                                        width: box.width * crop.width / Double(width),
                                        height: box.height * crop.height / Double(height)))
    }

    static func touchesInternalEdge(_ box: CGRect, crop: CGRect, width: Int, height: Int) -> Bool {
        let margin = 0.02
        return (crop.minX > 0 && box.minX < margin)
            || (crop.maxX < Double(width) && box.maxX > 1 - margin)
            || (crop.minY > 0 && box.maxY > 1 - margin)
            || (crop.maxY < Double(height) && box.minY < margin)
    }

    private static func validate(_ c: Configuration) throws {
        guard c.minimumConfidence.isFinite, (0...1).contains(c.minimumConfidence),
              c.duplicateIntersectionOverUnion.isFinite, (0...1).contains(c.duplicateIntersectionOverUnion),
              c.minimumControls >= 1,
              c.groupGapMultiplier.isFinite, c.groupGapMultiplier > 0,
              c.minimumGroupGap.isFinite, c.maximumGroupGap.isFinite,
              c.minimumGroupGap > 0, c.maximumGroupGap >= c.minimumGroupGap, c.maximumGroupGap <= 1,
              c.ambiguityRatio.isFinite, c.ambiguityRatio > 0, c.ambiguityRatio <= 1,
              c.referencePaddingFraction.isFinite, (0...1).contains(c.referencePaddingFraction),
              c.minimumReferencePadding.isFinite, (0...0.5).contains(c.minimumReferencePadding),
              c.minimumReferenceArea.isFinite, (1e-6...1).contains(c.minimumReferenceArea) else {
            throw SurfaceUnderstandingError.underlying("Invalid ML detection configuration")
        }
    }

    private static func clippedToImage(_ r: PanelRect) -> PanelRect? {
        guard [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite), r.width > 0, r.height > 0,
              r.center.isOnPanel else { return nil }
        let left = max(0, r.minX), top = max(0, r.minY)
        let right = min(1, r.maxX), bottom = min(1, r.maxY)
        guard right > left, bottom > top else { return nil }
        return PanelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Groups by edge-to-edge distance in aspect-corrected image space.
    /// The connection radius is capped to limit merging separated controls;
    /// a false box spanning two appliances can still require a clearer scan.
    private static func makeReference(_ controls: [Control], imageSize: CGSize,
                                      panel: PanelQuad?, panelConfidence: Double,
                                      configuration c: Configuration) throws
        -> (quad: PanelQuad, confidence: Double, controls: [Control]) {
        try checkCancellation()
        try validate(c)
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { throw SurfaceUnderstandingError.undecodableImage }
        if let panel {
            let projection = try Projection(panel)
            let inside = controls.filter { projection.mapImageRect($0.bounds)?.center.isOnPanel == true }
            guard inside.count >= c.minimumControls else { throw SurfaceUnderstandingError.noPanelFound }
            return (panel, panelConfidence, inside)
        }
        guard controls.count >= c.minimumControls else { throw SurfaceUnderstandingError.noPanelFound }
        let longest = max(imageSize.width, imageSize.height)
        let sx = Double(imageSize.width / longest), sy = Double(imageSize.height / longest)
        let sizes = controls.map { hypot($0.bounds.width * sx, $0.bounds.height * sy) }.sorted()
        let median = sizes[sizes.count / 2]
        let gap = min(c.maximumGroupGap, max(c.minimumGroupGap, median * c.groupGapMultiplier))
        var groups: [[Control]] = []
        var remaining = Array(controls.indices)
        while let seed = remaining.popLast() {
            var members = [seed]
            var cursor = 0
            while cursor < members.count {
                let a = controls[members[cursor]].bounds
                let neighbours = remaining.filter { index in
                    let b = controls[index].bounds
                    let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX)) * sx
                    let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY)) * sy
                    return hypot(dx, dy) <= gap
                }
                let added = Set(neighbours)
                remaining.removeAll { added.contains($0) }
                members += neighbours
                cursor += 1
            }
            groups.append(members.map { controls[$0] })
        }
        // Ignore isolated outliers before ranking plausible reference groups.
        let ranked = groups.filter { $0.count >= c.minimumControls }.sorted {
            $0.reduce(0) { $0 + $1.confidence } > $1.reduce(0) { $0 + $1.confidence }
        }
        guard let selected = ranked.first else { throw SurfaceUnderstandingError.noPanelFound }
        let score = selected.reduce(0) { $0 + $1.confidence }
        if ranked.count > 1, ranked[1].reduce(0, { $0 + $1.confidence }) >= score * c.ambiguityRatio {
            // Two plausible appliances: ask for a clearer scan instead of guessing.
            throw SurfaceUnderstandingError.noPanelFound
        }
        let left = selected.map { $0.bounds.minX }.min()!, right = selected.map { $0.bounds.maxX }.max()!
        let top = selected.map { $0.bounds.minY }.min()!, bottom = selected.map { $0.bounds.maxY }.max()!
        let px = max(c.minimumReferencePadding, (right - left) * c.referencePaddingFraction)
        let py = max(c.minimumReferencePadding, (bottom - top) * c.referencePaddingFraction)
        let l = max(0, left - px), r = min(1, right + px)
        let t = max(0, top - py), b = min(1, bottom + py)
        guard (r - l) * (b - t) >= c.minimumReferenceArea else { throw SurfaceUnderstandingError.noPanelFound }
        let quad = PanelQuad(topLeft: .init(x: l, y: t), topRight: .init(x: r, y: t),
                             bottomRight: .init(x: r, y: b), bottomLeft: .init(x: l, y: b))
        _ = try Projection(quad)
        // Object confidence cannot establish a physical plane or tracking quality.
        // Actual registration remains owned by ContourPipeline's tracking session.
        return (quad, min(0.6, score / Double(selected.count)), selected)
    }

    private func model() throws -> VNCoreMLModel {
        if let loadedModel { return loadedModel }
        try Self.checkCancellation()
        let url: URL
        if let suppliedModelURL {
            url = suppliedModelURL
        } else {
            guard let bundledURL = Bundle.module.url(forResource: "ButtonDetection", withExtension: "mlmodelc")
                    ?? Bundle.module.url(forResource: "ButtonDetection", withExtension: "mlmodel") else {
                throw SurfaceUnderstandingError.underlying("Bundled ButtonDetection model is missing")
            }
            url = bundledURL
        }
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let coreModel = try MLModel(contentsOf: compiled, configuration: configuration)
        let result = try VNCoreMLModel(for: coreModel)
        // Create ML's NMS stage may otherwise discard low-score observations
        // before our 0.10/0.15/0.25 review filter can see them. This is a runtime
        // input override, not a change to the model weights or resource file.
        if coreModel.modelDescription.inputDescriptionsByName["confidenceThreshold"]?.type == .double {
            result.featureProvider = try MLDictionaryFeatureProvider(dictionary: [
                "confidenceThreshold": MLFeatureValue(double: 0.05)
            ])
            modelConfidenceFloor = 0.05
        }
        let classes = Set(coreModel.modelDescription.classLabels?.compactMap { $0 as? String } ?? [])
        guard Self.acceptedLabels.isSubset(of: classes) else {
            throw SurfaceUnderstandingError.underlying("Model is missing knob, pushbutton, or touch labels")
        }
        try Self.checkCancellation()
        loadedModel = result
        return result
    }

    private static func uprightImage(_ photo: PanelPhoto) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SurfaceUnderstandingError.undecodableImage
        }
        let orientation: CGImagePropertyOrientation
        switch photo.orientation {
        case .up: orientation = .up
        case .right: orientation = .right
        case .down: orientation = .down
        case .left: orientation = .left
        }
        // PanelPhoto.orientation is authoritative; do not apply EXIF twice.
        let upright = CIImage(cgImage: image).oriented(orientation)
        guard let result = CIContext().createCGImage(upright, from: upright.extent) else {
            throw SurfaceUnderstandingError.undecodableImage
        }
        return result
    }

    private static func readWords(_ image: CGImage, transform: Projection) throws -> [Word] {
        func recognize(_ level: VNRequestTextRecognitionLevel) throws -> [VNRecognizedTextObservation] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return request.results ?? []
        }
        let observations: [VNRecognizedTextObservation]
        do { observations = try recognize(.accurate) }
        catch { try checkCancellation(); observations = try recognize(.fast) }
        try checkCancellation()
        return observations.flatMap { observation -> [Word] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            let text = candidate.string
            return text.split(whereSeparator: \.isWhitespace).compactMap { token in
                let box = (try? candidate.boundingBox(for: token.startIndex..<token.endIndex))?.boundingBox
                    ?? observation.boundingBox
                guard let bounds = transform.map(box), bounds.center.isOnPanel else { return nil }
                return Word(text: String(token), bounds: bounds)
            }
        }
    }

    private static func assign(_ words: [Word], to regions: [PanelRect]) -> [String?] {
        var assigned = Array(repeating: [Word](), count: regions.count)
        var unused: [Word] = []
        for word in words {
            if let index = regions.indices.filter({ regions[$0].contains(word.bounds.center) })
                .min(by: { regions[$0].width * regions[$0].height < regions[$1].width * regions[$1].height }) {
                assigned[index].append(word)
            } else { unused.append(word) }
        }
        // Each outside word can name at most one control; only a nearby caption
        // below an otherwise unlabelled control is eligible.
        let captionRegions = Set(regions.indices.filter { assigned[$0].isEmpty })
        for word in unused {
            let candidates = regions.indices.filter { index in
                let r = regions[index]
                return captionRegions.contains(index)
                    && (assigned[index].isEmpty || assigned[index].contains { $0.bounds.minY < word.bounds.maxY && word.bounds.minY < $0.bounds.maxY })
                    && word.bounds.center.x >= r.minX - r.width * 0.25
                    && word.bounds.center.x <= r.maxX + r.width * 0.25
                    && word.bounds.minY >= r.maxY - r.height * 0.1
                    && word.bounds.minY <= r.maxY + r.height * 0.75
            }
            if let index = candidates.min(by: { regions[$0].center.distance(to: word.bounds.center) < regions[$1].center.distance(to: word.bounds.center) }) {
                assigned[index].append(word)
            }
        }
        return assigned.map { group in
            guard !group.isEmpty else { return nil }
            var lines: [[Word]] = []
            for word in group.sorted(by: { $0.bounds.minY < $1.bounds.minY }) {
                if let index = lines.firstIndex(where: { line in
                    guard let first = line.first else { return false }
                    return abs(first.bounds.center.y - word.bounds.center.y) <= min(first.bounds.height, word.bounds.height) * 0.5
                }) { lines[index].append(word) } else { lines.append([word]) }
            }
            return lines.flatMap { $0.sorted { $0.bounds.minX < $1.bounds.minX } }.map(\.text).joined(separator: " ")
        }
    }

    private static func intersection(_ a: PanelRect, _ b: PanelRect) -> Double {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) * max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    /// Class-agnostic suppression: retain the strongest original geometry.
    /// Containment only counts as a duplicate when centres are close, so a
    /// large false box does not swallow a row of neighbouring controls.
    static func mergeCandidates(_ candidates: [Candidate], threshold: Double) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = kept.contains { other in
                let a = candidate.bounds, b = other.bounds
                let overlap = intersection(a, b)
                guard overlap > 0 else { return false }
                let smallArea = min(a.width * a.height, b.width * b.height)
                let union = a.width * a.height + b.width * b.height - overlap
                let close = abs(a.center.x - b.center.x) <= min(a.width, b.width) * 0.25
                    && abs(a.center.y - b.center.y) <= min(a.height, b.height) * 0.25
                return overlap / union >= threshold || (close && overlap / smallArea >= 0.8)
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }

    static func removeConflictingControls(_ controls: [Control]) -> [Control] {
        var kept: [Control] = []
        for control in controls.sorted(by: { $0.confidence > $1.confidence }) {
            if !kept.contains(where: { intersection(control.bounds, $0.bounds) > 1e-12 }) {
                kept.append(control)
            }
        }
        return kept
    }

    /// Inverse planar homography: upright image coordinates -> panel unit square.
    /// Vision's lower-left bounding boxes are flipped before this projection.
    private struct Projection {
        var h: [Double]
        init(_ quad: PanelQuad) throws {
            let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
            let targets = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw SurfaceUnderstandingError.noPanelFound }
            let crosses = (0..<4).map { i in
                let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
                return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            }
            guard crosses.allSatisfy({ $0 > 1e-9 }) else {
                throw SurfaceUnderstandingError.noPanelFound
            }
            let twiceArea = (0..<4).reduce(0.0) { total, i in
                total + points[i].x * points[(i + 1) % 4].y - points[(i + 1) % 4].x * points[i].y
            }
            guard twiceArea / 2 >= 1e-6 else { throw SurfaceUnderstandingError.noPanelFound }
            var matrix: [[Double]] = []
            for (p, target) in zip(points, targets) {
                let (u, v) = target
                matrix.append([p.x, p.y, 1, 0, 0, 0, -u * p.x, -u * p.y, u])
                matrix.append([0, 0, 0, p.x, p.y, 1, -v * p.x, -v * p.y, v])
            }
            for column in 0..<8 {
                let pivot = (column..<8).max { abs(matrix[$0][column]) < abs(matrix[$1][column]) }!
                guard abs(matrix[pivot][column]) > 1e-12 else { throw SurfaceUnderstandingError.noPanelFound }
                matrix.swapAt(column, pivot)
                let divisor = matrix[column][column]
                for j in column..<9 { matrix[column][j] /= divisor }
                for row in 0..<8 where row != column {
                    let factor = matrix[row][column]
                    for j in column..<9 { matrix[row][j] -= factor * matrix[column][j] }
                }
            }
            h = matrix.map { $0[8] }
        }
        func point(_ x: Double, _ y: Double) -> PanelPoint? {
            let denominator = h[6] * x + h[7] * y + 1
            guard denominator.isFinite, abs(denominator) > 1e-12 else { return nil }
            let p = PanelPoint(x: (h[0] * x + h[1] * y + h[2]) / denominator,
                               y: (h[3] * x + h[4] * y + h[5]) / denominator)
            return p.x.isFinite && p.y.isFinite ? p : nil
        }
        func map(_ box: CGRect) -> PanelRect? {
            guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0 else { return nil }
            return mapImageRect(PanelRect(x: Double(box.minX), y: Double(1 - box.maxY),
                                          width: Double(box.width), height: Double(box.height)))
        }
        func mapImageRect(_ rect: PanelRect) -> PanelRect? {
            let points = [(rect.minX, rect.minY), (rect.maxX, rect.minY),
                          (rect.maxX, rect.maxY), (rect.minX, rect.maxY)].compactMap { point($0.0, $0.1) }
            guard points.count == 4 else { return nil }
            return PanelRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                             width: points.map(\.x).max()! - points.map(\.x).min()!,
                             height: points.map(\.y).max()! - points.map(\.y).min()!)
        }
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw SurfaceUnderstandingError.cancelled }
    }

}
