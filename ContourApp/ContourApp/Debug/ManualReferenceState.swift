#if DEBUG
import ContourCore
import Foundation

/// The debug screen's current prepared reference and target choice. Button IDs
/// are scoped to one layout, so every replacement drops the previous choice.
struct ManualReferenceState {
    private(set) var reference: PanelReference?
    private(set) var selectedTargetID: UUID?

    var selectedTarget: SurfaceMap.Button? {
        guard let selectedTargetID else { return nil }
        return reference?.detection.map.buttons.first { $0.id == selectedTargetID }
    }

    mutating func replace(with reference: PanelReference) {
        self.reference = reference
        selectedTargetID = nil
    }

    mutating func selectTarget(_ id: UUID?) {
        guard let id, reference?.detection.map.buttons.contains(where: { $0.id == id }) == true
        else {
            selectedTargetID = nil
            return
        }
        selectedTargetID = id
    }
}
#endif
