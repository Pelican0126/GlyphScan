import Foundation

/// Stateless text utilities for the scan-matching pipeline. Pure functions on
/// immutable inputs — host-testable, allocation-light.
public enum ScanText {

    /// Lossless-ish OCR-text cleanup: full-width → half-width, drop control
    /// chars, collapse runs of whitespace to a single space. Keeps every
    /// character that could plausibly be part of a record (CJK, ASCII alnum,
    /// option letters, common punctuation).
    public static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            if ch.isNewline || ch.isWhitespace {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            lastWasSpace = false
            let scalar = ch.unicodeScalars.first?.value ?? 0
            if scalar >= 0xFF01 && scalar <= 0xFF5E {
                let mapped = UnicodeScalar(scalar - 0xFEE0)!
                out.append(Character(mapped))
            } else if ch == "\u{3000}" { // ideographic space
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
            } else if ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol {
                out.append(ch)
            } else if scalar >= 0x4E00 && scalar <= 0x9FFF {
                out.append(ch) // explicit CJK include
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cleaner used by similarity scoring and fingerprinting.
    /// Drops whitespace, all punctuation, and single uppercase ASCII letters
    /// (almost always option labels — "A. … B. …"). Keeps CJK, ASCII digits
    /// and lowercase letters (so "f(x)=x2+2x" stays distinguishable), and
    /// Unicode digits / superscripts.
    public static func cleanForMatching(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch.isWhitespace { continue }
            if ch.isPunctuation { continue }
            if ch.isASCII, ch.isLetter, ch.isUppercase { continue }
            out.append(ch)
        }
        return out
    }
}
