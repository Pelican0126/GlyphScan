import Foundation

/// Pluggable scoring strategy. The matcher ranks candidates by `score` and
/// derives the displayed confidence from the top score. `HeuristicScorer` is
/// the deterministic baseline; a `LogisticScorer` (DESIGN.md §9) will load
/// learned coefficients and emit calibrated probabilities + cutoffs.
public protocol Scorer {
    func score(input: String, candidate: MatchableRecord) -> Double
    func confidence(forTopScore score: Double) -> Confidence
}

/// The OCR-agnostic recall-anchored formula. Always available, no model file,
/// fully deterministic — the fallback and the bar a learned scorer must clear.
public struct HeuristicScorer: Scorer {
    public init() {}

    public func score(input: String, candidate: MatchableRecord) -> Double {
        Similarity.heuristicScore(input: input, candidate: candidate)
    }

    public func confidence(forTopScore score: Double) -> Confidence {
        Confidence.tier(for: score)
    }
}
