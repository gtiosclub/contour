//
//  ContourTheme.swift
//  ContourUI — Experience / Accessibility & Launch
//
//  EVERY colour, size, radius, font and animation the screens use, in one
//  place. To restyle Contour to the Figma designs, change values here — no
//  screen hard-codes a number of its own.
//
//  The defaults follow Apple's HIG for a camera app: dark chrome, Liquid Glass
//  controls floating over the preview, SF Pro Rounded for the big words, and
//  targets far larger than the 44 pt minimum. Contrast first: every text
//  colour clears WCAG AA on `Colors.chrome` and `Colors.surface`, and the
//  accent is a warm yellow because it is the colour low-vision users pick out
//  fastest on a dark ground.
//

import ContourCore
import SwiftUI

/// Contour's design tokens.
public enum ContourTheme {

    // MARK: Colour

    public enum Colors {
        /// Behind the camera preview and its letterbox bars.
        public static let chrome = Color.black
        /// Full-screen backgrounds without a camera: selection, outcomes.
        public static let surface = Color(red: 0.05, green: 0.05, blue: 0.06)
        /// Rows and cards on `surface`.
        public static let surfaceRaised = Color(red: 0.13, green: 0.13, blue: 0.15)
        /// Primary text on dark.
        public static let textPrimary = Color.white
        /// Secondary text on dark. Still AA on `surfaceRaised`.
        public static let textSecondary = Color(white: 0.78)
        /// The one brand colour: primary actions, the proximity ring, overlays.
        public static let accent = Color(red: 1.0, green: 0.84, blue: 0.04)
        /// Text and symbols on `accent`.
        public static let onAccent = Color.black
        /// Arrived.
        public static let success = Color(red: 0.20, green: 0.84, blue: 0.40)
        /// Unsure detections, lost tracking, low confidence.
        public static let warning = Color(red: 1.0, green: 0.62, blue: 0.10)
        /// Stop, and nothing else.
        public static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
        /// Not found: an answer, not a failure.
        public static let info = Color(red: 0.40, green: 0.78, blue: 1.0)
        /// Dims a frozen frame or the camera behind text.
        public static let scrim = Color.black.opacity(0.6)
        /// The viewfinder's corner marks.
        public static let cornerGuide = Color.white.opacity(0.85)
        /// A detected control's outline on the photo.
        public static let overlayStroke = accent
        /// An unsure control's dashed outline and chip.
        public static let unsure = warning
        /// Behind the proximity ring, so it reads over any camera image.
        public static let ringBackground = Color.black.opacity(0.45)
        /// The empty part of the proximity ring.
        public static let ringTrack = Color.white.opacity(0.18)

        /// The colour that carries an outcome.
        public static func tint(for outcome: OutcomeSignal) -> Color {
            switch outcome {
            case .arrived: success
            case .lostTracking: warning
            case .notFound: info
            case .lowConfidence: warning
            }
        }
    }

    // MARK: Spacing

    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 48
    }

    // MARK: Radii

    public enum Radius {
        /// Label chips on the overlay.
        public static let chip: CGFloat = 8
        /// A detected control drawn on the photo.
        public static let overlayControl: CGFloat = 10
        /// Rows in the control list.
        public static let row: CGFloat = 22
        /// Glass cards and banners.
        public static let card: CGFloat = 28
        /// Big action buttons.
        public static let action: CGFloat = 32
    }

    // MARK: Sizes

    public enum Size {
        /// Apple's floor. Nothing tappable is smaller.
        public static let minimumTarget: CGFloat = 44
        /// Primary and secondary actions.
        public static let actionHeight: CGFloat = 72
        /// Stop, while guiding. The biggest thing on the screen on purpose.
        public static let stopHeight: CGFloat = 104
        /// The shutter disc on the acquire screen.
        public static let shutter: CGFloat = 96
        /// The ring around the shutter disc.
        public static let shutterRing: CGFloat = 6
        /// Diameter of the proximity ring.
        public static let proximityRing: CGFloat = 220
        /// Stroke of the proximity ring.
        public static let proximityRingLine: CGFloat = 20
        /// The direction arrow inside the ring.
        public static let directionArrow: CGFloat = 88
        /// The outcome symbol.
        public static let outcomeSymbol: CGFloat = 96
        /// The target's name while guiding, before Dynamic Type scaling.
        public static let heroText: CGFloat = 52
        /// Viewfinder corner marks.
        public static let cornerGuideLength: CGFloat = 44
        public static let cornerGuideLine: CGFloat = 5
        /// A detected control's outline on the photo.
        public static let overlayLine: CGFloat = 3
        /// Rows in the control list.
        public static let rowMinHeight: CGFloat = 76
        /// The tallest the panel picture gets on the selection screen.
        public static let selectionPictureMaxHeight: CGFloat = 280
    }

    // MARK: Type

    public enum Typography {
        /// The biggest words on a screen: a target's name, an outcome.
        public static let display = Font.system(.largeTitle, design: .rounded).weight(.heavy)
        /// Screen titles.
        public static let title = Font.system(.title, design: .rounded).weight(.bold)
        /// Instructions over the camera; row titles.
        public static let headline = Font.system(.title2, design: .rounded).weight(.semibold)
        /// Supporting sentences.
        public static let body = Font.system(.title3)
        /// Small print: positions, captions.
        public static let caption = Font.system(.body)
        /// Words on action buttons.
        public static let action = Font.system(.title2, design: .rounded).weight(.bold)
        /// Label chips on the overlay.
        public static let chip = Font.system(.caption, design: .rounded).weight(.bold)
        /// Labels drawn on the panel sketch.
        public static let sketchLabel = Font.system(.footnote, design: .rounded).weight(.semibold)
    }

    // MARK: Motion

    public enum Motion {
        /// Screen-to-screen changes. `nil` under Reduce Motion.
        public static func stageChange(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .smooth(duration: 0.35)
        }
        /// Live guidance: the ring and the arrow. `nil` under Reduce Motion.
        public static func guidance(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .smooth(duration: 0.2)
        }
    }
}
