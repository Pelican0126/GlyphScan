import Foundation

/// One ranked match: the record, its score, and the displayed confidence tier.
public struct MatchResult {
    public let record: MatchableRecord
    public let score: Double
    public let confidence: Confidence

    public init(record: MatchableRecord, score: Double, confidence: Confidence) {
        self.record = record
        self.score = score
        self.confidence = confidence
    }
}

/// Two-stage fuzzy matcher tuned for noisy OCR text.
///
/// Stage 1 — coarse recall: sliding-window substrings of the cleaned input are
///   handed to the `CandidateSource`, which returns a bounded candidate pool.
///   Falls back to 3-char windows (short input / empty pool) then a leading
///   4-char probe (typo at position 0) so one bad window doesn't sink the scan.
/// Stage 2 — fine ranking: each candidate is scored by the `Scorer`; results
///   above `minScore` are sorted and the top `limit` returned with tiers.
public struct GlyphScanMatcher {
    public let source: CandidateSource
    public let scorer: Scorer
    public var poolCap: Int
    public var minScore: Double

    public init(source: CandidateSource,
                scorer: Scorer = HeuristicScorer(),
                poolCap: Int = 300,
                minScore: Double = 0.30) {
        self.source = source
        self.scorer = scorer
        self.poolCap = poolCap
        self.minScore = minScore
    }

    public func bestMatches(for raw: String, limit: Int = 3) -> [MatchResult] {
        let cleaned = ScanText.cleanForMatching(raw)
        guard cleaned.count >= 4 else { return [] }

        let candidates = gatherCandidates(cleaned: cleaned)
        guard !candidates.isEmpty else { return [] }

        // Coarse length filter — lenient enough to keep partial scans alive,
        // strict enough to drop a two-char query from matching a long stem.
        let inLen = Double(cleaned.count)
        let lengthFiltered = candidates.filter { record in
            let qLen = Double(ScanText.cleanForMatching(record.primaryText).count)
            guard qLen > 0 else { return false }
            let ratio = qLen / inLen
            return ratio >= 0.3 && ratio <= 3.0
        }
        let pool = lengthFiltered.isEmpty ? candidates : lengthFiltered

        let scored = pool.map { (record: $0, score: scorer.score(input: raw, candidate: $0)) }
        return scored
            .filter { $0.score >= minScore }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { MatchResult(record: $0.record,
                               score: $0.score,
                               confidence: scorer.confidence(forTopScore: $0.score)) }
    }

    // MARK: - Stage 1

    private func gatherCandidates(cleaned: String) -> [MatchableRecord] {
        let chars = Array(cleaned)
        guard chars.count >= 3 else { return [] }

        var seen = Set<RecordID>()
        var result: [MatchableRecord] = []
        func add(_ recs: [MatchableRecord]) {
            for r in recs {
                if result.count >= poolCap { return }
                if seen.insert(r.id).inserted { result.append(r) }
            }
        }

        // Primary: 5-char windows, stride 1, so a single OCR-mangled char
        // doesn't wipe out the only window covering its neighbourhood.
        let primarySize = Swift.min(5, chars.count)
        if primarySize >= 3 {
            add(source.candidates(matchingAnyOf: slidingWindows(chars, size: primarySize),
                                  limit: poolCap))
        }

        // Fallback A: short input or empty primary pool — augment with 3-char.
        if (chars.count < 8 || result.isEmpty), chars.count >= 3 {
            add(source.candidates(matchingAnyOf: slidingWindows(chars, size: 3),
                                  limit: poolCap))
        }

        // Fallback B: nothing matched — try the leading 4 chars as one probe.
        if result.isEmpty {
            let prefix = String(chars.prefix(4))
            add(source.candidates(matchingAnyOf: [prefix], limit: poolCap))
        }

        return result
    }

    private func slidingWindows(_ chars: [Character], size: Int) -> [String] {
        guard size >= 1 else { return [] }
        guard size <= chars.count else { return chars.isEmpty ? [] : [String(chars)] }
        var windows: [String] = []
        windows.reserveCapacity(chars.count - size + 1)
        var i = 0
        while i + size <= chars.count {
            windows.append(String(chars[i..<(i + size)]))
            i += 1
        }
        return windows
    }
}
