import ContourUI
import Testing
@testable import ContourApp

@MainActor
@Suite("Missing finger announcement")
struct MissingFingerEpisodeTests {
    private let epoch = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { epoch.advanced(by: .milliseconds(ms)) }
    private func announce(_ episode: inout MissingFingerEpisode, _ now: ContinuousClock.Instant) -> Bool {
        episode.check(at: now)
    }

    @Test("Announced once after 3 s without a finger")
    func announcesOnce() {
        var episode = MissingFingerEpisode()
        episode.phaseChanged(to: .findingFinger, at: at(0))
        #expect(episode.nextCheck == at(3000))
        #expect(!announce(&episode, at(2999)))
        #expect(announce(&episode, at(3000)))
        #expect(episode.nextCheck == nil)
        #expect(!announce(&episode, at(6000)))
    }

    @Test("Brief detections do not restart the 3 s")
    func briefDetectionsIgnored() {
        var episode = MissingFingerEpisode()
        episode.phaseChanged(to: .findingFinger, at: at(0))
        for start in stride(from: 1000, through: 2000, by: 1000) {
            episode.phaseChanged(to: .guiding, at: at(start))
            #expect(!announce(&episode, at(start + 300)))
            episode.phaseChanged(to: .findingFinger, at: at(start + 300))
        }
        #expect(episode.nextCheck == at(3000))
        #expect(announce(&episode, at(3000)))
    }

    @Test("Not announced while the finger is showing at the 3 s mark")
    func notWhileSeen() {
        var episode = MissingFingerEpisode()
        episode.phaseChanged(to: .findingFinger, at: at(0))
        episode.phaseChanged(to: .holding, at: at(2900))
        #expect(!announce(&episode, at(3000)))
        // Lost again before recovery: announced straight away.
        episode.phaseChanged(to: .findingFinger, at: at(3100))
        #expect(announce(&episode, at(3100)))
    }

    @Test("Half a second with the finger ends the stretch")
    func recoveryEndsEpisode() {
        var episode = MissingFingerEpisode()
        episode.phaseChanged(to: .findingFinger, at: at(0))
        episode.phaseChanged(to: .guiding, at: at(1000))
        #expect(episode.nextCheck == at(1500))
        #expect(!announce(&episode, at(1500)))
        #expect(episode.nextCheck == nil)
        episode.phaseChanged(to: .findingFinger, at: at(2000))
        #expect(episode.nextCheck == at(5000))
    }

    @Test("Stop, endings and lost tracking cancel a pending announcement",
          arguments: [GuidancePhase?.none, .stopped, .arrived, .lostTracking])
    func endings(phase: GuidancePhase?) {
        var episode = MissingFingerEpisode()
        episode.phaseChanged(to: .findingFinger, at: at(0))
        episode.phaseChanged(to: phase, at: at(1000))
        #expect(episode.nextCheck == nil)
        #expect(!announce(&episode, at(4000)))
    }

    @Test("A short panel gap leaves the stretch running")
    func panelGapIsNeutral() {
        var episode = MissingFingerEpisode()
        episode.phaseChanged(to: .findingFinger, at: at(0))
        episode.phaseChanged(to: .searching, at: at(1000))
        #expect(announce(&episode, at(3000)))
    }
}
