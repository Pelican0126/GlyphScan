# GlyphScan

**English** | [中文](README.zh-CN.md)

**On-device, OCR-aware fuzzy matching that finds the one record your camera is pointed at — inside a haystack of noisy OCR text.**

Pure Swift, zero runtime dependencies. GlyphScan understands *how CJK OCR actually fails* — because it has looked at the glyphs.

> **Status: early implementation.** `GlyphScanCore` — the recall-anchored two-stage matcher with a pluggable scorer and candidate source — is implemented and tested (`swift test`, 15 passing). The glyph-confusion model and learned scorer ([DESIGN.md](docs/DESIGN.md) §8–9) are next.

---

## The problem

Point a phone camera at a printed page and run OCR, and you get back a blob of a few hundred characters — headers, footers, several records' worth of text, and a misread character roughly every ten. Now find *which single record* in your local corpus the user is actually pointing at, in real time, on-device, and tell them *how much to trust the answer*.

Standard fuzzy matching (Jaccard, edit distance) collapses in this regime: the noise dominates the set union, so a record that is present verbatim still scores low; and a single misread CJK character shatters the longest common run. GlyphScan is built for exactly this case.

## What makes it interesting

- **Recall-anchored similarity** — the score is anchored on the *candidate*, not the input. A record that appears verbatim inside a noisy full-page scan scores ~1.0 instead of being diluted toward zero by surrounding noise.
- **Glyph-derived confusion — one table, three consumers.** GlyphScan renders each character to a bitmap, compares shapes, and derives a 形近字 (visually-confusable character) table *automatically*. The **same** table powers (1) an OCR-aware similarity metric, (2) realistic synthetic-noise generation for training, and (3) confidence calibration. It knows 未／末 look alike because it has actually looked at them.
- **Learned, calibrated scoring** — a tiny logistic regression over interpretable features replaces hand-tuned weights and confidence cutoffs, and emits a real probability that drives a four-tier confidence display. Ships as ~10 coefficients; inference is a dot product + sigmoid, no heavyweight ML runtime.
- **Pluggable by design** — bring your own OCR (Apple Vision or anything else), your own candidate store (in-memory, or SQLite behind one protocol), and your own corpus.

## Use cases

Any "scan a printed thing, match it to a short record" task:

- flashcards and quiz banks
- invoice / receipt line items
- medication identification
- menu items and price tags
- library shelf lookup
- "find this paragraph in my notes"

## Architecture at a glance

Runtime matching pipeline (on-device, per scan):

```
[OCR text + bbox]              ← your OCR (Vision or anything; engine-agnostic)
   │  preprocess: normalize / segment / split weighted fields
   ▼
Stage 1 · coarse recall        sliding-window substrings → CandidateSource → pool ≤ 300
   │                           (CandidateSource is the only pluggable seam)
   ▼
Stage 2 · fine scoring         OCR-aware features → LogisticScorer → calibrated probability
   ▼
[ top-k records + probability + 4-tier confidence ]
```

The glyph-confusion table is the shared hub:

```
                 render glyphs → compare shapes → k-NN → cost ∈ [0,1]
                                  glyph confusion table
                    ┌───────────────────┼───────────────────┐
            OCR-aware similarity   synthetic noise +    confidence
              (runtime)            hard negatives        calibration
                                   (training)            (eval)
```

Full details, data model, and the training pipeline are in [docs/DESIGN.md](docs/DESIGN.md).

## Quick start

```swift
import GlyphScanCore

let corpus = [
    SimpleRecord(id: 1, stem: "光合作用的主要场所是叶绿体", options: ["线粒体", "叶绿体", "细胞核"]),
    // … your records (any type conforming to MatchableRecord)
]

let matcher = GlyphScanMatcher(source: ArrayCandidateSource(corpus))

// Feed it a noisy OCR dump — even a whole page with the record buried inside:
let hits = matcher.bestMatches(for: ocrText)
if let top = hits.first {
    print(top.record.id, top.score, top.confidence)   // e.g. 1  0.92  .high
}
```

Bring your own OCR (Apple Vision or anything that yields text), and for large
corpora back `CandidateSource` with a SQLite `LIKE` query instead of the
in-memory `ArrayCandidateSource`.

## Build & test

```sh
swift build
swift test
```

## Design principles

- **Pure Swift, zero runtime deps** in the core (Foundation only). The learned model is a few coefficients, not a framework.
- **Reproducible from your own data** — a synthetic-data + training CLI bootstraps a model from any corpus with `swift run`. No manual labeling.
- **CJK-first.** Most fuzzy-match libraries are Latin-centric; GlyphScan models the error structure of Chinese OCR directly.

## License

[MIT](LICENSE).
