import Foundation
import Testing
@testable import ContourApp

@MainActor
@Suite("Guidance loss episode groundwork")
struct GuidanceLossEpisodeTests {
    @Test("A brief gap quiets immediately and recovery starts a new episode")
    func briefRecovery() {
        var episode = GuidanceLossEpisode()
        let start = ContinuousClock.now
        #expect(episode.update(isUsable: false, at: start) == .quiet)
        #expect(episode.update(isUsable: false, at: start.advanced(by: .milliseconds(200))) == .quiet)
        #expect(episode.update(isUsable: true, at: start.advanced(by: .milliseconds(250))) == .resume)
        #expect(episode.update(isUsable: false, at: start.advanced(by: .seconds(1))) == .quiet)
    }

    @Test("Sustained loss announces once after 400 ms and reset discards the old episode")
    func sustainedLossAndReset() {
        var episode = GuidanceLossEpisode()
        let start = ContinuousClock.now
        #expect(episode.update(isUsable: false, at: start) == .quiet)
        #expect(episode.update(isUsable: false, at: start.advanced(by: .milliseconds(399))) == .quiet)
        #expect(episode.update(isUsable: false, at: start.advanced(by: .milliseconds(400))) == .announceLoss)
        #expect(episode.update(isUsable: false, at: start.advanced(by: .seconds(1))) == .quiet)
        episode.reset()
        #expect(episode.update(isUsable: false, at: start.advanced(by: .seconds(2))) == .quiet)
    }
}
