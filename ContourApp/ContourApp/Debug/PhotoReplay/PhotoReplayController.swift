#if DEBUG
import ContourCore
import Foundation
import Observation
import Tracking

/// Runs the Vision and feature trackers on the same ordered saved photos and
/// keeps each result paired with the exact image it came from.
///
/// Every replay gets fresh tracker instances, registered to the current
/// reference with the current options. Changing the reference, the photos or
/// the options starts a new replay; results from an older one are discarded
/// on arrival, and its trackers are stopped.
@MainActor @Observable
final class PhotoReplayController {
    enum Lane: String, CaseIterable, Identifiable, Sendable {
        case vision = "Vision rectangle"
        case features = "OpenCV features"
        var id: Self { self }
    }

    struct Photo: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let frame: CameraFrame
    }

    /// One tracker's answer for one photo. `quad` is nil whenever the tracker
    /// didn't report one; an earlier outline is never carried forward.
    struct Result: Sendable {
        let photoID: UUID
        let quad: PanelQuad?
        let status: PanelObservation.Status?
        let confidence: Double
        let diagnostics: FeatureTrackingDiagnostics?
        /// Wall time of the `track` call during replay, not live camera latency.
        let replayMilliseconds: Double
        let error: String?
    }

    enum LaneState: Equatable {
        case idle
        case registering
        case running(completed: Int)
        case finished
        case failed(String)
    }

    typealias TrackerFactory = @MainActor (Lane, FeatureTrackingOptions) -> any PanelTracking

    private(set) var reference: PanelReference?
    private(set) var photos: [Photo] = []
    private(set) var options = FeatureTrackingOptions()
    private(set) var results: [Lane: [UUID: Result]] = [:]
    private(set) var laneStates: [Lane: LaneState] = [.vision: .idle, .features: .idle]
    var selectedIndex = 0

    private let makeTracker: TrackerFactory
    /// Bumped by every input change and reset; work from older runs is dropped.
    private var generation: UInt64 = 0
    private var runs: [Task<Void, Never>] = []

    init(makeTracker: @escaping TrackerFactory = PhotoReplayController.liveTracker) {
        self.makeTracker = makeTracker
    }

    static func liveTracker(_ lane: Lane, _ options: FeatureTrackingOptions) -> any PanelTracking {
        switch lane {
        case .vision: PanelTracker()
        case .features: FeaturePanelTracker(options: options)
        }
    }

    var isRunning: Bool {
        laneStates.values.contains { state in
            if case .registering = state { return true }
            if case .running = state { return true }
            return false
        }
    }

    var selectedPhoto: Photo? { photos.indices.contains(selectedIndex) ? photos[selectedIndex] : nil }

    /// The result for `lane` on the selected photo, only if it was produced
    /// for that exact photo by the current replay.
    func result(_ lane: Lane, for photo: Photo? = nil) -> Result? {
        guard let photo = photo ?? selectedPhoto else { return nil }
        return results[lane]?[photo.id]
    }

    // MARK: Inputs — each change starts a fresh replay.

    func setReference(_ reference: PanelReference?) {
        self.reference = reference
        replay()
    }

    func setPhotos(_ photos: [Photo]) {
        self.photos = photos
        selectedIndex = 0
        replay()
    }

    func setOptions(_ options: FeatureTrackingOptions) {
        guard options != self.options else { return }
        self.options = options
        replay()
    }

    /// Run both trackers from the first photo again.
    func replay() {
        retire()
        guard let reference, !photos.isEmpty else { return }
        let generation = generation
        let photos = photos
        for lane in Lane.allCases {
            let tracker = makeTracker(lane, options)
            laneStates[lane] = .registering
            runs.append(Task { [weak self] in
                await self?.run(lane, tracker: tracker, reference: reference, photos: photos, generation: generation)
                await tracker.stopTracking()
            })
        }
    }

    /// Clear every input and result.
    func reset() {
        retire()
        reference = nil
        photos = []
        selectedIndex = 0
    }

    /// Stop the current run. Its trackers are stopped as their tasks unwind,
    /// and anything they still deliver is ignored.
    func retire() {
        generation &+= 1
        for run in runs { run.cancel() }
        runs = []
        results = [:]
        for lane in Lane.allCases { laneStates[lane] = .idle }
    }

    // MARK: - Running

    private func run(_ lane: Lane, tracker: any PanelTracking, reference: PanelReference,
                     photos: [Photo], generation: UInt64) async {
        do {
            try await tracker.startTracking(reference)
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            laneStates[lane] = .failed("Registration failed: \(Self.describe(error))")
            return
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        laneStates[lane] = .running(completed: 0)

        // Frames go in order: the Vision tracker follows the panel from one
        // image to the next, just as it would across camera frames.
        for (index, photo) in photos.enumerated() {
            let started = ContinuousClock.now
            let outcome: Swift.Result<PanelObservation, any Error>
            do {
                outcome = .success(try await tracker.track(photo.frame))
            } catch {
                outcome = .failure(error)
            }
            let elapsed = started.duration(to: .now)
            guard generation == self.generation, !Task.isCancelled else { return }

            let milliseconds = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            switch outcome {
            case .success(let observation):
                let tracked = observation.status == .tracked
                results[lane, default: [:]][photo.id] = Result(
                    photoID: photo.id, quad: tracked ? observation.quad : nil, status: observation.status,
                    confidence: observation.confidence, diagnostics: observation.featureDiagnostics,
                    replayMilliseconds: milliseconds, error: nil)
            case .failure(let error):
                results[lane, default: [:]][photo.id] = Result(
                    photoID: photo.id, quad: nil, status: nil, confidence: 0, diagnostics: nil,
                    replayMilliseconds: milliseconds, error: Self.describe(error))
            }
            laneStates[lane] = .running(completed: index + 1)
        }
        laneStates[lane] = .finished
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case PanelTrackingError.invalidReferenceQuad: "the marked corners don't form a valid panel"
        case PanelTrackingError.unreadableReferencePhoto: "the reference photo couldn't be decoded"
        case PanelTrackingError.registrationFailed: "the tracker couldn't lock onto the panel in the reference"
        case PanelTrackingError.superseded: "superseded by a newer request"
        case PanelTrackingError.frameInFlight: "a previous frame was still being processed"
        default: error.localizedDescription
        }
    }

    static func describe(_ status: PanelObservation.Status?) -> String {
        switch status {
        case .tracked: "Tracked"
        case .lost(let reason): "Lost (\(reason.rawValue))"
        case nil: "No result"
        }
    }
}
#endif
