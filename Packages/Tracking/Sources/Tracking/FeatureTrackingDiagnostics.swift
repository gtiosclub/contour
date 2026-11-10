import ContourCore

/// Evidence from the current frame, including rejected attempts. Confidence is
/// a heuristic evidence score, not a calibrated probability of correctness.
public struct FeatureTrackingDiagnostics: Hashable, Sendable {
    public let referenceFeatures: Int
    public let frameFeatures: Int
    public let matchCount: Int
    public let inlierCount: Int
    public let coverage: Double
    public let reprojectionError: Double
    public let processingMilliseconds: Double
    public let message: String
    public let inlierPoints: [ImagePoint]
    public let saturatedFraction: Double
    public let excludedHighlightFraction: Double

    public init(
        referenceFeatures: Int,
        frameFeatures: Int,
        matchCount: Int,
        inlierCount: Int,
        coverage: Double,
        reprojectionError: Double,
        processingMilliseconds: Double,
        message: String,
        inlierPoints: [ImagePoint],
        saturatedFraction: Double,
        excludedHighlightFraction: Double
    ) {
        self.referenceFeatures = referenceFeatures
        self.frameFeatures = frameFeatures
        self.matchCount = matchCount
        self.inlierCount = inlierCount
        self.coverage = coverage
        self.reprojectionError = reprojectionError
        self.processingMilliseconds = processingMilliseconds
        self.message = message
        self.inlierPoints = inlierPoints
        self.saturatedFraction = saturatedFraction
        self.excludedHighlightFraction = excludedHighlightFraction
    }
}
