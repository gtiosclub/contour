import ContourCore
import Foundation
import Testing
@testable import SurfaceUnderstanding

@Test("Panel detection runs in under 2 seconds on the synthetic panel")
func panelDetectorIsFast() async throws {
    let photo = try SyntheticPanel.photo()
    let clock = ContinuousClock()
    let elapsed = try await clock.measure {
        _ = try await PanelDetector().detectPanel(in: photo)
    }
    print("PanelDetector synthetic 900x600: \(elapsed)")
    #expect(elapsed < .seconds(2))
}
