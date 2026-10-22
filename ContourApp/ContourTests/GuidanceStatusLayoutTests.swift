import SwiftUI
import UIKit
import XCTest
@testable import ContourApp

@MainActor
final class GuidanceStatusLayoutTests: XCTestCase {
    func testStatusViewportKeepsFollowingControlsInPlace() {
        let short = GuidanceStatusSnapshot.waiting
        let long = GuidanceStatusSnapshot(source: "No usable alignment", calibration: "Calibration ready",
            verification: "Last visual check: unavailable",
            message: String(repeating: "Prediction is paused until the panel can be visually checked. ", count: 12))
        for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
            for width in [CGFloat(320), 430] {
                func fittedHeight(_ snapshot: GuidanceStatusSnapshot) -> CGFloat {
                    let host = UIHostingController(rootView: VStack(spacing: 0) {
                        GuidanceStatusRow(snapshot: snapshot)
                        Button("Stop") {}
                    }.environment(\.dynamicTypeSize, size))
                    return host.sizeThatFits(in: CGSize(width: width, height: 5000)).height
                }
                XCTAssertEqual(fittedHeight(short), fittedHeight(long), accuracy: 1,
                    "Status content moved controls at \(size), width \(width)")
            }
        }
    }
}
