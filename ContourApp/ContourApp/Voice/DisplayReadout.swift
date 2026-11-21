import ContourCore
import SurfaceUnderstanding

nonisolated enum DisplayReadout {
    /// "The display says 0:00.", or nil when the display can't be read.
    static func sentence(for reference: PanelReference) async -> String? {
        let reading = await PanelReadout().readDisplay(
            in: reference.photo,
            panel: reference.detection.quad
        )
        return reading.text == nil ? nil : reading.spoken
    }
}
