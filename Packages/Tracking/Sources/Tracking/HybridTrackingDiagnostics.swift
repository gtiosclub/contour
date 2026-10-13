import Foundation

/// Calibration readiness is separate from the source of the actual output.
/// Evidence may be absent; none of these values proves touch or a button press.
public struct HybridTrackingDiagnostics: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        case visual = "2D visual", fused = "2D-corrected AR", world = "AR prediction", unavailable = "No usable alignment"
    }
    public enum RepositionReason: String, Hashable, Sendable { case suspectedGlare, weakAlignment }
    public enum Mode: String, Hashable, Sendable {
        case visual = "2D only", calibrating = "Calibrating", corrected = "2D + 3D"
        case predicted = "3D prediction", reacquiring = "Reacquiring"
    }
    public let mode: Mode
    public let message: String
    public let calibrationFrames: Int
    public var stableFeatures: Int?
    public var repositionReason: RepositionReason? = nil
    public var source: Source = .visual
    public var calibrationReady: Bool = false
    public var resetCount: Int = 0
    public var lastResetReason: String? = nil
    public var alignmentError: Double? = nil
    public var cornerError: Double? = nil
    public var baselineCentimeters: Double = 0
    public var visualVerificationAge: TimeInterval? = nil

    public init(
        mode: Mode,
        message: String,
        calibrationFrames: Int,
        stableFeatures: Int? = nil,
        repositionReason: RepositionReason? = nil,
        source: Source = .visual,
        calibrationReady: Bool = false,
        resetCount: Int = 0,
        lastResetReason: String? = nil,
        alignmentError: Double? = nil,
        cornerError: Double? = nil,
        baselineCentimeters: Double = 0,
        visualVerificationAge: TimeInterval? = nil
    ) {
        self.mode = mode
        self.message = message
        self.calibrationFrames = calibrationFrames
        self.stableFeatures = stableFeatures
        self.repositionReason = repositionReason
        self.source = source
        self.calibrationReady = calibrationReady
        self.resetCount = resetCount
        self.lastResetReason = lastResetReason
        self.alignmentError = alignmentError
        self.cornerError = cornerError
        self.baselineCentimeters = baselineCentimeters
        self.visualVerificationAge = visualVerificationAge
    }
}
