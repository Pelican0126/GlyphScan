import Foundation

/// User-facing tier for the top match's score. Four-band scheme: always show
/// the top-1 candidate (so the user can act on the engine's best guess), but
/// vary the caveat with confidence. In P0 the thresholds are the hand-tuned
/// defaults; a learned scorer (DESIGN.md §9) will emit calibrated cutoffs.
public enum Confidence: Equatable, Sendable {
    case high      // strong match, no caveat
    case medium    // probable, "double-check"
    case low       // weak, "verify carefully"
    case veryLow   // tenuous, "low similarity, reference only"

    public static func tier(for score: Double,
                            high: Double = 0.65,
                            medium: Double = 0.30,
                            low: Double = 0.15) -> Confidence {
        if score >= high { return .high }
        if score >= medium { return .medium }
        if score >= low { return .low }
        return .veryLow
    }
}
