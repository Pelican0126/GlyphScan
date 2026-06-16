import Foundation

private func gsRegex(_ pattern: String) -> NSRegularExpression {
    // Patterns are static literals — a failure here is a programmer error.
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: pattern)
}

public extension ScanText {

    /// Returns the record-number prefix (if any) and the body text after it.
    /// Recognises the common Chinese / Arabic-numeral list forms. The prefix
    /// is normalised so `1.` / `1、` / `（1）` collapse to one fingerprint.
    static func splitNumberAndBody(_ raw: String) -> (number: String?, body: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let patterns: [(NSRegularExpression, (String) -> String)] = [
            (gsRegex(#"^[(（]\s*([0-9]{1,3})\s*[)）]"#), { "(\($0))" }),
            (gsRegex(#"^([0-9]{1,3})\s*[\.、:：]"#),    { "\($0)." }),
            (gsRegex(#"^([①-⑳])"#),                     { String($0) }),
            (gsRegex(#"^([一二三四五六七八九十百千]+)\s*[、\.]"#), { "\($0)、" }),
        ]
        for (re, normalise) in patterns {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let m = re.firstMatch(in: trimmed, range: range), m.range.location == 0 {
                let captureRange = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
                let captured = (trimmed as NSString).substring(with: captureRange)
                let body = (trimmed as NSString).substring(from: m.range.length)
                    .trimmingCharacters(in: .whitespaces)
                return (normalise(captured), body)
            }
        }
        return (nil, trimmed)
    }

    /// Split a body into stem text and the option-block text. The option block
    /// runs from the first `A. / A、 / A）` marker to the end. Returns empty
    /// options for non-MCQ records. Marker punctuation tolerates OCR mangling
    /// (`A.` → `A,`, dropped dots) while requiring a following CJK/space token
    /// so "A300" / "A4" inside a stem isn't mistaken for an option marker.
    static func splitStemAndOptions(_ body: String) -> (stem: String, options: String) {
        let s = body
        let markerRegex = gsRegex(#"(?:^|[\s，。；,;.\)）])([ABCDEFG])\s*[\.、:：）)，,；;]\s*"#)
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        if let m = markerRegex.firstMatch(in: s, range: range) {
            let startIdx = m.range.location
            let nsString = s as NSString
            let stem = nsString.substring(with: NSRange(location: 0, length: startIdx))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let options = nsString.substring(from: startIdx)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (stem, options)
        }
        return (s, "")
    }

    /// Pull every numeric token out of a string: integers, decimals, simple
    /// fractions ("3/4"), with optional sign. Returned sorted-unique. Used by
    /// the false-twin guard in similarity scoring.
    static func extractNumbers(_ s: String) -> [String] {
        let pattern = gsRegex(#"-?\d+(?:[\./]\d+)?"#)
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        let matches = pattern.matches(in: s, range: range)
        var seen = Set<String>()
        var out: [String] = []
        for m in matches {
            let token = (s as NSString).substring(with: m.range)
            if seen.insert(token).inserted { out.append(token) }
        }
        return out.sorted()
    }
}
