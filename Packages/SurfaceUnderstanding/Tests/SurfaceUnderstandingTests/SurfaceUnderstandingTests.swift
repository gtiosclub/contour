//
//  SurfaceUnderstandingTests.swift
//  SurfaceUnderstanding — Team 1
//
//  One structural test so CI is green on day one. It asserts that the package
//  builds and still satisfies the contract — nothing about detection, because
//  there is no detection yet. Team 1: delete this and write real tests.
//

import ContourCore
import Testing
@testable import SurfaceUnderstanding

@Test("LiveSurfaceUnderstanding still satisfies the ContourCore contract")
func conformsToContract() {
    let subject: any ContourCore.SurfaceUnderstanding = LiveSurfaceUnderstanding()
    #expect(subject is LiveSurfaceUnderstanding)
}
