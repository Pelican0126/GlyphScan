import Foundation

/// The one seam between GlyphScan and your storage. The matcher generates
/// sliding-window substrings of the cleaned input; the source returns a
/// bounded pool of records whose primary text plausibly contains any of them.
/// Back it with an in-memory scan (`ArrayCandidateSource`) or a SQLite
/// `LIKE` query for large corpora.
public protocol CandidateSource {
    func candidates(matchingAnyOf windows: [String], limit: Int) -> [MatchableRecord]
}

/// Brute-force in-memory source: good for small corpora, tests, and getting
/// started. Precomputes each record's cleaned primary text once.
public struct ArrayCandidateSource: CandidateSource {
    private let records: [MatchableRecord]
    private let haystacks: [String]   // cleaned primary text, index-aligned with `records`

    public init(_ records: [MatchableRecord]) {
        self.records = records
        self.haystacks = records.map { ScanText.cleanForMatching($0.primaryText) }
    }

    public func candidates(matchingAnyOf windows: [String], limit: Int) -> [MatchableRecord] {
        guard !windows.isEmpty, limit > 0 else { return [] }
        var out: [MatchableRecord] = []
        out.reserveCapacity(Swift.min(limit, records.count))
        for i in records.indices {
            let hay = haystacks[i]
            if windows.contains(where: { hay.contains($0) }) {
                out.append(records[i])
                if out.count >= limit { break }
            }
        }
        return out
    }
}
