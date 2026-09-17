//
//  TestSet.swift
//  SurfaceUnderstanding — Surface / Eval & Test Set
//
//  Weeks 2–3 deliverable: "Hand-label the test set."
//
//  Every club member owes five photos of appliance panels they can reach. That
//  is the corpus. This file is how a labelled example is written down and how
//  detection is scored against it.
//
//  Scoring matters more than it sounds. Weeks 6–7 are "make recognition work
//  across different appliances", and you cannot tell whether a change helped
//  without a number. Build this early and cheaply.
//
//  COORDINATES: ground-truth bounds are in normalized panel space — (0,0)
//  top-left, y DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// One hand-labelled photo: what a human says is on this panel.
public struct LabelledSample: Identifiable, Hashable, Sendable, Codable {

    /// Stable name for the sample — use the image filename.
    public var id: String

    /// What kind of appliance, for slicing results ("microwave", "lift").
    public var appliance: String

    /// Lighting the photo was taken in, for slicing results. Weeks 6–7 test
    /// across at least two lighting conditions, so record it now.
    public var lighting: String

    /// The truth: what a human says is on this panel, in panel space.
    public var expected: SurfaceMap

    public init(
        id: String,
        appliance: String,
        lighting: String,
        expected: SurfaceMap
    ) {
        self.id = id
        self.appliance = appliance
        self.lighting = lighting
        self.expected = expected
    }
}

/// How well a detected map matched the ground truth for one sample.
public struct SampleScore: Hashable, Sendable {

    /// Ground-truth buttons that were found, as a fraction of all of them.
    public var recall: Double

    /// Detected buttons that were real, as a fraction of all detections.
    public var precision: Double

    /// Of the buttons found, the fraction whose label was read correctly.
    public var labelAccuracy: Double

    public init(recall: Double, precision: Double, labelAccuracy: Double) {
        self.recall = recall
        self.precision = precision
        self.labelAccuracy = labelAccuracy
    }
}

/// The hand-labelled corpus and the scoring that runs against it.
public enum TestSet {

    /// The labelled samples.
    ///
    /// Empty until Week 2. Add one entry per photo as it is labelled — keep
    /// them in source rather than in a JSON blob while the set is small, so
    /// that a bad label shows up in a diff.
    public static let samples: [LabelledSample] = []

    /// Score one detection against its ground truth.
    ///
    /// - Parameter overlapThreshold: how much a detected box must overlap a
    ///   ground-truth box to count as the same button, as intersection over
    ///   union. `0.5` is the usual starting point.
    public static func score(
        detected: SurfaceMap,
        against expected: SurfaceMap,
        overlapThreshold: Double = 0.5
    ) -> SampleScore {
        fatalError("unimplemented — owned by Surface / Eval & Test Set")
    }
}
