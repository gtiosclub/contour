//
//  ContourUITests.swift
//  ContourUI — Team 4
//
//  One structural test so CI is green on day one. Team 4: delete this and write
//  real tests. Note that this is a `swift test` target, not an XCUITest bundle —
//  the app's XCUITests live in ContourApp/ContourUITests.
//

import ContourCore
import Testing
@testable import ContourUI

@Test("the selection placeholder accepts a SurfaceMap without touching pixels")
func selectionViewTakesAMap() {
    let map = SurfaceMap(
        buttons: [
            SurfaceMap.Button(
                label: "Start",
                bounds: PanelRect(x: 0.6, y: 0.6, width: 0.2, height: 0.15),
                confidence: 0.9
            )
        ],
        confidence: 0.9
    )

    _ = TargetSelectionView(map: map)
    #expect(map.buttons.count == 1)
}
