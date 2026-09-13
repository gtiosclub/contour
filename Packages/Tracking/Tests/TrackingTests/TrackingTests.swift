//
//  TrackingTests.swift
//  Tracking — Team 2
//
//  Structural tests so CI is green on day one.
//
//  Team 2: your real tests replay a recorded frame fixture through the
//  projection maths and assert on panel-space output. Record the fixture early —
//  a tracking bug you cannot replay is a tracking bug you cannot fix.
//

import ContourCore
import Foundation
import Testing
@testable import Tracking

@Test("LiveTrackingSource still satisfies the ContourCore contract")
func conformsToContract() {
    let subject: any TrackingSource = LiveTrackingSource()
    #expect(subject is LiveTrackingSource)
}

@Test("the trackers are constructible")
func trackersExist() {
    _ = FingertipTracker()
    _ = PanelTracker()
}

@Test("a lost frame reports no fingertip rather than the origin")
func lostFrameIsNotTheOrigin() {
    let frame = TrackingFrame.lost(at: Date(timeIntervalSince1970: 0))

    #expect(frame.fingertip == nil, "nil means not seen — never (0, 0)")
    #expect(frame.trackingQuality == .lost)
}
