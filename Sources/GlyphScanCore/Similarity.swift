import Foundation

/// Recall-anchored similarity between a noisy OCR input and a candidate
/// record. This is the "heuristic" (OCR-agnostic) scorer — the baseline a
/// learned, glyph-aware scorer must beat. See DESIGN.md §9.
public enum Similarity {

    public static func bigrams(of s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [String(chars[0])] }
        var r = Set<String>()
        r.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) { r.insert(String(chars[i...(i + 1)])) }
        return r
    }

    /// Classic Levenshtein edit distance, two-row DP. Exposed for consumers;
    /// the scorer itself uses bigram-recall + LCS.
    public static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + Swift.min(prev[j - 1], prev[j], curr[j - 1])
                }
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    /// Recall-anchored fragment similarity:
    ///   bigramRecall = |inputBigrams ∩ candidateBigrams| / |candidateBigrams|
    ///   lcsRatio     = LCS(input, candidate) / |candidate|
    /// Score = 0.65 × bigramRecall + 0.35 × lcsRatio. Anchored on the
    /// candidate so a record present verbatim inside a noisy full-page scan
    /// still scores ~1.0 instead of being diluted by surrounding noise.
    public static func pairSim(_ a: String, _ b: String) -> Double {
        let ca = ScanText.cleanForMatching(a)
        let cb = ScanText.cleanForMatching(b)
        guard !ca.isEmpty, !cb.isEmpty else { return 0 }
        let aArr = Array(ca)
        let bArr = Array(cb)
        let bg1 = bigrams(of: ca)
        let bg2 = bigrams(of: cb)
        guard !bg2.isEmpty else { return 0 }
        let bigramRecall = Double(bg1.intersection(bg2).count) / Double(bg2.count)
        let lcs = longestCommonSubstring(aArr, bArr)
        let lcsRatio = Double(lcs) / Double(bArr.count)
        return 0.65 * bigramRecall + 0.35 * lcsRatio
    }

    /// Score an OCR input against a candidate record, in [0, 1].
    /// Primary and secondary field blocks are scored separately and combined
    /// 0.4 / 0.6 because the secondary block (options) carries most of an
    /// MCQ-style record's identity. False-twin guard: penalise only when the
    /// candidate has ≥2 numbers the input doesn't (directional — input being a
    /// numeric superset, e.g. a textbook page with extra dates, is harmless).
    public static func heuristicScore(input: String, candidate: MatchableRecord) -> Double {
        let cdStem = candidate.primaryText
        let cdOpts = candidate.secondaryText
        let candidateText = cdStem + " " + cdOpts
        let (inStem, inOpts) = ScanText.splitStemAndOptions(input)

        let stemSim = pairSim(inStem, cdStem)
        let optSim: Double
        if cdOpts.isEmpty || inOpts.isEmpty {
            optSim = stemSim
        } else {
            optSim = pairSim(inOpts, cdOpts)
        }
        let blended: Double = cdOpts.isEmpty ? stemSim : 0.4 * stemSim + 0.6 * optSim

        let inNums = Set(ScanText.extractNumbers(input))
        let cdNums = Set(ScanText.extractNumbers(candidateText))
        if cdNums.count >= 2 {
            let cdOnly = cdNums.subtracting(inNums)
            if cdOnly.count >= 2,
               Double(cdOnly.count) / Double(cdNums.count) >= 0.5 {
                return blended * 0.7
            }
        }
        return blended
    }

    /// Length of the longest contiguous common substring of two char arrays —
    /// how much of the candidate appears verbatim inside the (often much
    /// longer) input. Two-row DP.
    static func longestCommonSubstring(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var curr = [Int](repeating: 0, count: b.count + 1)
        var best = 0
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1] + 1
                    if curr[j] > best { best = curr[j] }
                } else {
                    curr[j] = 0
                }
            }
            swap(&prev, &curr)
            for k in 0..<curr.count { curr[k] = 0 }
        }
        return best
    }
}
