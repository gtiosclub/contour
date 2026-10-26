import SwiftUI
import UIKit
import XCTest
@testable import ContourApp

@MainActor
final class GuidanceStatusLayoutTests: XCTestCase {
    func testEveryDetailScalesDespiteAnInheritedFixedFont() {
        for field in 0..<3 {
            func height(at size: DynamicTypeSize, populated: Bool) -> CGFloat {
                let text = populated ? String(repeating: "Tracking detail ", count: 12) : ""
                let snapshot = GuidanceStatusSnapshot(source: "", calibration: field == 0 ? text : "",
                    verification: field == 1 ? text : "", message: field == 2 ? text : "")
                let host = UIHostingController(rootView: GuidanceStatusDetails(snapshot: snapshot)
                    .font(.system(size: 17))
                    .environment(\.dynamicTypeSize, size)
                    .fixedSize(horizontal: false, vertical: true))
                return host.sizeThatFits(in: CGSize(width: 320, height: 10000)).height
            }
            let normal = height(at: .large, populated: true) - height(at: .large, populated: false)
            for size in [DynamicTypeSize.accessibility3, .accessibility5] {
                let enlarged = height(at: size, populated: true) - height(at: size, populated: false)
                XCTAssertGreaterThan(enlarged, normal * 1.5, "Detail field \(field) did not scale at \(size)")
            }
        }
    }

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
