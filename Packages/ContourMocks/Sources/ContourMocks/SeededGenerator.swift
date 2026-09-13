//
//  SeededGenerator.swift
//  ContourMocks
//
//  Determinism is the whole product here. Everything in ContourMocks is a pure
//  function of its inputs, and where variation is wanted it comes from this
//  generator and a seed you can write down — never from `Double.random(in:)`,
//  never from `Date()`, never from the system RNG.
//
//  If you are adding to ContourMocks: if a reviewer cannot predict the output
//  from reading the call site, it does not belong here.
//

import Foundation

/// A seeded SplitMix64 generator. Same seed, same sequence, on every machine
/// and every run.
public struct SeededGenerator: RandomNumberGenerator, Sendable {

    /// The seed every Contour mock defaults to — "Contour" in ASCII.
    public static let contourSeed: UInt64 = 0x436F_6E74_6F75_72

    private var state: UInt64

    public init(seed: UInt64 = SeededGenerator.contourSeed) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `-magnitude...magnitude`, drawn from this generator.
    public mutating func symmetric(_ magnitude: Double) -> Double {
        guard magnitude != 0 else { return 0 }
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)  // [0, 1)
        return (unit * 2 - 1) * magnitude
    }
}
