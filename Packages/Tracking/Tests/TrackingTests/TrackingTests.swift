//
//  TrackingTests.swift
//  Tracking — Team 2
//
//  One structural test so CI is green on day one. Team 2: delete this and write
//  real tests — a recorded-frame fixture replayed through the projection maths
//  is the obvious first one.
//

import ContourCore
import Testing
@testable import Tracking

@Test("LiveTrackingSource still satisfies the ContourCore contract")
func conformsToContract() {
    let subject: any TrackingSource = LiveTrackingSource()
    #expect(subject is LiveTrackingSource)
}
