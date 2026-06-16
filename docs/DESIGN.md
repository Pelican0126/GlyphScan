# GlyphScan — Design Document

**English** | [中文](DESIGN.zh-CN.md)

| | |
|---|---|
| Status | Draft (design stage) |
| Date | 2026-06-16 |
| Authors | Pelican0126 + Claude |

---

## 1. In one sentence

> **GlyphScan** — an on-device, camera-OCR, needle-in-a-haystack **short-record fuzzy matcher**: given a frame of noisy OCR text and a corpus of short records, find in real time which record the camera is pointed at, and return a *trustworthy probability*. Pure Swift, zero runtime dependencies, with a matching core that **understands how Chinese OCR actually fails** — because it has looked at the glyphs.

This is not an OCR library (anyone can call Vision). The hard, worthwhile part is the second half: pushing the correct record's score to the top inside a page of hundreds of characters, staying robust to real-device OCR noise, and emitting a calibrated confidence — with that "sense of noise" **learned automatically from the glyphs**, not hand-listed as rules.

## 2. Background and motivation

Camera-OCR short-record matching is an underrated hard problem. Point a phone at a printed page and run OCR, and you get back a blob of a few hundred characters — headers, footers, several records' worth of text mixed together, and roughly one misread character in ten. You must locate, in real time and on-device, which single record in the local corpus the user is pointing at, and tell them how much to trust it.

Three pain points of the naive approach:

1. **Similarity collapse**: Jaccard / edit distance fail outright in this regime — noise blows up the set union, a verbatim-present record is diluted to ~0.2, and one misread CJK character cuts the longest common run in half.
2. **Hand-tuned magic numbers**: similarity weights, field weighting, confidence cutoffs, and penalties are all guesswork — no data backing, no adaptation to the corpus.
3. **Helpless against the #1 failure mode**: real-device OCR misreads ~1 CJK char in 10, yet naive similarity treats every misread equally — one mistaken look-alike (未→末) drags a true hit from 0.7 down to 0.4.

GlyphScan answers these head-on with two designs:

- **Glyph-confusion-driven OCR-aware similarity** (§7, §8): make "how OCR fails" the protagonist.
- **A learned, calibrated scorer** (§9): replace all the hand-tuned magic numbers with a small logistic regression that emits a real probability.

## 3. Goals and non-goals

### Goals
- The matching core is a standalone SwiftPM package, **depending only on Foundation** (runtime core).
- Decoupled from concrete storage (SQLite, etc.) via the `CandidateSource` protocol — one and only one pluggable seam.
- Centered on a generic `Record`, so the engine works for flashcards / quiz banks / invoice line items / medications / menus / note retrieval, etc.
- A glyph-confusion table that uniformly drives **similarity scoring, synthetic noise, and confidence calibration**.
- A learned, calibrated scorer that replaces hand-tuned weights and confidence cutoffs and emits a calibrated probability.
- Synthetic-data bootstrap + a pure-Swift training/eval CLI, so **anyone can reproduce it on their own corpus** and it works out of the box.

### Non-goals (YAGNI)
- ❌ No bundled OCR engine. BYO-OCR; only an optional, ultra-thin Vision adapter target.
- ❌ No camera / UI.
- ❌ Streaming cross-frame tracking is **out of scope** this round (a future optional module `GlyphScanStream`).
- ❌ No GBT / neural-net ranker (logistic regression only this round).
- ❌ No online learning / bandit (on-device feedback is a "collection hook" only this round, retrained offline; online adaptation is future work).
- ❌ No server, no cloud training.

## 4. Positioning: a general record-matching primitive

The engine is centered on a generic `Record`, bound to no specific domain:

```swift
public typealias RecordID = Int64                 // consumer-defined; the library never interprets it

public enum FieldRole { case primary, secondary } // primary fields weigh more, secondary less

public struct MatchField {
    public let text: String
    public let role: FieldRole
}

public protocol MatchableRecord {
    var id: RecordID { get }
    var fields: [MatchField] { get }               // a record's searchable fields
}
```

- Fields are weighted by primary/secondary (default 0.4/0.6, configurable, ultimately handed to the learner).
- Unit segmentation (splitting a frame into multiple units by numbering markers) and field-role labeling are **domain-specific logic that degrades into pluggable strategies** (§6 `Segmenter` protocol); the generic core defaults to "the whole frame is one unit."
- A consumer writes one `YourType: MatchableRecord` adapter to plug in (primary field → primary, secondary fields → secondary).

> This generalization makes the core simpler: the core only understands "weighted-field records + OCR-aware similarity + learned scoring," and all domain specificity lives in the adapter layer.

## 5. Overall architecture

Two pipelines, plus one shared hub (the glyph-confusion table).

### 5.1 Runtime matching pipeline (on-device, per scan)

```
[OCR text + bbox]            ← consumer: Vision or any OCR (engine-agnostic)
   │
   ▼  GlyphScanCore
preprocess: normalize / cleanForMatching / Segmenter splits units / split primary·secondary fields
   │
   ▼  Stage 1 · coarse recall
generate sliding-window substrings (5-char stride 1, 3-char / leading-4 fallback)
   │  └──▶ CandidateSource protocol ──▶ bounded candidate pool ≤ 300   ← only pluggable seam (consumer injects storage)
   │
   ▼  Stage 2 · fine scoring                                  ← ML
extract a feature vector per candidate (OCR-aware soft bigramRecall / twin-LCS / number overlap / length ratio + formula score)
   │  └──▶ LogisticScorer (loads default-coefficients.json) ──▶ calibrated probability
   │
   ▼  output                                                  ← ML
top-k(record, probability) + four-tier Confidence (cutoffs learned from data)
```

### 5.2 Offline training pipeline (dev / CI, `swift run`, into CI not into shipped artifact)

```
[corpus (your Records)]
   │  GlyphScanLearn
   ├─▶ build glyph-confusion table: CoreText renders each char → compare shapes → k-NN → cost∈[0,1]
   │        │ (the same table also feeds runtime similarity, see §8)
   ▼        ▼
OCR noise generation (corrupt via the table + neighbor bleed + hard-negative mining)
   │
   ▼
labeled synthetic set (noisyScan, trueRecordID), positive + negative
   │
   ▼
LogisticTrainer (pure-Swift gradient descent + temperature calibration)
   │
   ▼
default-coefficients.json  ──coefficients──▶ LogisticScorer (runtime Stage 2)
   │
   ▼
Benchmark (top-1 / top-3 / AUC / ECE / per-tier precision) ── CI quality gate
```

### 5.3 The shared hub: one table, three consumers

| Consumer | Use |
|---|---|
| Runtime · OCR-aware similarity | soft bigram recall + twin-aware LCS: a misread look-alike costs a little, no longer halves the run |
| Training · synthetic noise + hard negatives | corrupt by real visual-confusion probability; mine records that "differ only by a look-alike" as the hardest negatives |
| Eval · confidence calibration | twin hits as a feature in calibration; the four-tier cutoffs are steadier |

## 6. Package structure and repository layout

```
GlyphScan/
├── Package.swift
├── Sources/
│   ├── GlyphScanCore/                  # runtime core, Foundation only
│   │   ├── Record.swift                # MatchableRecord / MatchField / FieldRole / RecordID
│   │   ├── Normalize.swift             # normalize / cleanForMatching
│   │   ├── Segmenter.swift             # Segmenter protocol + WholeFrameSegmenter (default)
│   │   ├── GlyphConfusion.swift        # ConfusionTable (load/query, sparse)
│   │   ├── Similarity.swift            # OCR-aware softBigramRecall / twinLCS / pairSim
│   │   ├── Features.swift              # (input, candidate) → FeatureVector
│   │   ├── Scorer.swift                # Scorer protocol + HeuristicScorer + LogisticScorer
│   │   ├── CandidateSource.swift       # protocol + ArrayCandidateSource (brute-force in-memory)
│   │   ├── GlyphScanMatcher.swift      # two-stage orchestration (window generation here)
│   │   └── Confidence.swift            # four-tier (probability cutoffs from the coefficients file)
│   ├── GlyphScanLearn/                 # training/eval tools, into CI not into shipped artifact
│   │   ├── GlyphRenderer.swift         # CoreText renders a char → normalized bitmap (#if canImport(CoreText))
│   │   ├── ConfusionBuilder.swift      # bitmap → k-NN → ConfusionTable
│   │   ├── OCRNoiseModel.swift         # look-alike substitution / dropout / full-half-width / neighbor bleed
│   │   ├── SyntheticDataset.swift      # corpus → (noisyScan, trueID) labeled samples
│   │   ├── LogisticTrainer.swift       # gradient-descent fit + temperature calibration
│   │   └── Metrics.swift               # top-1/top-3 / AUC / ECE / per-tier precision
│   └── glyphscan-cli/                  # executable: build-confusion / gen / train / bench
├── Sources/GlyphScanVision/            # optional, Apple-only: VNRecognizedText → [Observation]
├── Tests/
│   ├── GlyphScanCoreTests/             # similarity / features / scorer / decoupling end-to-end
│   └── GlyphScanLearnTests/            # confusion assertions (未/末 are twins, 我/你 not) + noise model + training convergence
├── Resources/
│   ├── default-coefficients.json       # bundled default coefficients + per-tier cutoffs (trained on the sample corpus)
│   ├── default-confusions.json         # default look-alike confusion table (sample-corpus charset + common seed)
│   └── sample-corpus.csv               # small sample corpus (tests + out-of-box training demo)
├── Benchmarks/                         # benchmark fixtures + expected metric thresholds
├── README.md / docs/DESIGN.md
└── LICENSE (MIT)
```

Key points:
- `GlyphScanCore` has **zero third-party dependencies**; logistic-regression inference = dot product + sigmoid, pure Swift, no CoreML, cheap enough to run over hundreds of candidates per frame.
- `GlyphScanLearn` renders glyphs with CoreText — exactly why training is in Swift, not Python: rendering is right there on Apple platforms, `swift run` end-to-end, zero external deps.
- The confusion table is only **loaded** at runtime (sparse JSON); generation is offline.

## 7. Data model and output

```swift
public struct MatchResult {
    public let record: MatchableRecord
    public let probability: Double          // calibrated probability from LogisticScorer, [0,1]
    public let confidence: Confidence
}

public enum Confidence: Equatable {         // cutoffs come from the coefficients file, no longer hard-coded
    case high, medium, low, veryLow
    // always shows top-1; color/caveat conveys how much to trust it
}
```

## 8. Glyph-confusion model (the core idea)

### 8.1 Generation (offline, `GlyphScanLearn` / `glyphscan-cli build-confusion`)

1. **Determine the charset**: all characters present in the corpus ∪ an optional common-look-alike seed set. A typical corpus has a few thousand distinct characters — tractable.
2. **Render**: CoreText renders each char to an N×N (default 32×32) grayscale bitmap, centered and ink-normalized (so glyph size differences are removed).
3. **Features**: flatten the normalized bitmap to a vector (default 32×32=1024 dims; optionally downsampled to 16×16).
4. **Neighbors**: find each char's visual nearest neighbors. Naive O(n²) is sub-second at a few thousand chars; for larger charsets, bucket-prune by ink density / bounding-box aspect ratio and compare only within adjacent buckets.
5. **Distance → cost**: `cost = clamp(1 - cosine(a,b), 0, 1)`; keep only each char's top-k (default 8) neighbors with `cost ≤ τ` (default 0.35).
6. **Output** a sparse table: `char → [(neighbor, cost)]`, written to `default-confusions.json`.

Determinism: fixed font, size, and render params → reproducible builds (CI can verify a hash).

Optional **on-device regeneration**: run the same pipeline on-device with the current UI font, producing a confusion table consistent with this machine's rendering ("it looks at the glyphs on *your* device"). The prebuilt table still ships by default; on-device regeneration is opt-in.

### 8.2 Validation (a unit test that should make you smile)

```
assert twin(未, 末) && twin(已, 己) && twin(田, 由) && twin(干, 千)
assert !twin(我, 你) && !twin(山, 海)
```

Turn "it really understands look-alikes" into an assertion that runs in CI, not a boast in the README.

### 8.3 The digit exception (an important correction)

Look-alike softening applies **only to CJK and letters, not to digits**. Even though 3 and 8 aren't look-alikes, their **values** must be matched exactly — softening a digit misread would make "3/4" and "8/4" collide as the same record. Therefore:
- Digits are matched **exactly** in similarity.
- The false-twin digit guard (penalize only when the candidate has ≥2 numbers the input doesn't and they make up ≥50%) is kept and fed to the learner as a discrete feature (§9).

## 9. OCR-aware similarity

Define `twinCost(a,b)`: `a==b → 0`; `(a,b)` in the table → its cost; otherwise → 1 (digits are always exact, see §8.3).

- **soft bigram recall**: expand each input bigram, together with its look-alike variants (weighted `1-cost`), into a weighted multimap; for each candidate bigram take the best matching weight, summed ÷ |candidate bigrams|. Expansion is bounded by k² (k≈8 → ≤64), still cheap. A verbatim char-for-char hit → 1.0; an all-look-alike hit → ≈∏(1-cost).
- **twin-aware LCS**: contiguous-substring DP with the match condition relaxed to `twinCost ≤ τ`, accumulating `1-cost` rather than integer 1. A single misread look-alike no longer cuts the contiguous run in half — hitting the §2 #1 failure mode directly.
- **combine**: `pairSim = 0.65·softBigramRecall + 0.35·softLcsRatio` (these two weights are also ultimately handed to the learner as features, no longer fixed magic numbers).
- primary/secondary fields each compute `pairSim`, then weighted (default 0.4/0.6).

### 9.1 The learned, calibrated scorer (replacing all hand-tuned magic numbers)

**Feature vector**, one per `(input, candidate)` (all reuse quantities already computed above, no new heavy work):

| Feature | Meaning |
|---|---|
| `softBigramRecall_primary` | OCR-aware bigram recall on the primary field |
| `softLcsRatio_primary` | twin-aware LCS ÷ length on the primary field |
| `softBigramRecall_secondary` / `softLcsRatio_secondary` | same, for the secondary field |
| `numberOverlap` | Jaccard of extracted numbers (exact, see §8.3) |
| `falseTwinFired` | whether the digit guard fired (discrete 0/1) |
| `lengthRatio` | `log(cleaned candidate ÷ cleaned input)` |
| `hasSecondary` | whether the candidate has a secondary field |
| `inputLen` | input length (distinguishes full-page scan vs single-record screenshot) |
| `heuristicScore` | **the current OCR-aware blended formula score (as a feature)** |

**Model: logistic regression** → `p(candidate is the correct record | features)`.
- **Ranking** = sort by `p`.
- **Confidence** = bin the top-1 `p`; cutoffs are learned per "target precision per tier" on a held-out set (e.g. high = the `p` where precision ≥ 0.95), written into the coefficients file, replacing hard-coded cutoffs.
- **Calibration**: logistic regression is fairly well-calibrated already; add one temperature scaling (Platt) on a held-out set, validated with ECE / a reliability diagram.

**Key decision: feed `heuristicScore` in too** → the learner is a **strict superset** of the hand-tuned formula. At worst it equals the formula (lower bound locked, never worse), and it can squeeze out extra accuracy on top. Lowest-risk default.

**Why logistic regression, not GBT/NN**: ~10 coefficients, a few lines of JSON; pure-Swift inference with zero overhead on the hot path; interpretable coefficients; stable with little data; **falls back to `HeuristicScorer` when no model is present**, so the default never breaks.

```swift
public protocol Scorer {
    func score(input: String, candidate: MatchableRecord) -> Double   // OCR text vs candidate → comparable score
    func confidence(forTopScore p: Double) -> Confidence
}
// HeuristicScorer: the current OCR-aware formula + legacy cutoffs (fallback / A-B baseline)
// LogisticScorer:  load coefficients → feature dot product + sigmoid + learned cutoffs
```

`GlyphScanMatcher` holds a `Scorer`, defaulting to `.bundledLearned`, switchable to `.heuristic` / `.custom(coeffs)`.

## 10. Two-stage matcher + CandidateSource decoupling

```swift
public protocol CandidateSource {
    /// Given the core's sliding-window substrings, return a bounded pool of
    /// records whose primary field may contain any of them.
    func candidates(matchingAnyOf windows: [String], limit: Int) -> [MatchableRecord]
}
```

- The window strategy (5-char / stride 1 / 3-char fallback / leading-4 fallback / pool cap 300 / length ratio [0.3,3.0] filter) stays in the core `GlyphScanMatcher`; it only hands the source "the windows to query"; "fetch rows by window" is the only replaceable point.
- The package ships `ArrayCandidateSource` (in-memory substring scan — good for small corpora, tests, and getting started).
- A large-corpus consumer provides a SQLite/GRDB-backed `CandidateSource` wrapping a sliding-window `LIKE` query.

## 11. Synthetic data + pure-Swift training

- **OCRNoiseModel**: character-level (table-driven look-alike substitution, dropout, junk insertion, full/half-width swaps) + layout-level (secondary-field shuffle, trailing truncation, header/footer junk, multi-form numbering prefixes) + **neighbor bleed** (concatenate adjacent records' text to simulate the "whole page" case).
- **Hard-negative mining**: use the confusion table to find record pairs that "differ only by a look-alike / a number," and generate the hardest negatives, forcing the model to learn fine distinctions.
- **SyntheticDataset**: auto-labeled (the source id is known), producing positive + negative samples, zero manual work.
- **LogisticTrainer**: pure-Swift batch/mini-batch gradient descent (~10 features × a few thousand samples, a few dozen lines), with L2 regularization and temperature calibration.
- **CLI**: `build-confusion` (build the table), `gen` (generate the synthetic set), `train` (fit → write coefficients), `bench` (report metrics).
- **Metrics**: top-1 accuracy, top-3 recall, AUC, ECE, per-tier precision.

## 12. Optional on-device feedback loop (phase 2)

- The library exposes a hook: when the user **accepts/rejects/corrects** a result, it emits `(featureVector, label)`; storage is the consumer's (fully local).
- Phase 1 only does collection + offline retraining; phase 2 considers on-device incremental fine-tuning with the same Swift LR (synthetic prior + real feedback blended). Privacy: fully local, opt-in, no network.

## 13. Public API (consumer's view)

```swift
let matcher = GlyphScanMatcher(
    source: myCandidateSource,        // or the built-in ArrayCandidateSource(records)
    scorer: .bundledLearned           // or .heuristic / .custom(coeffs)
)

// one-shot (text box / single OCR frame):
let hits = matcher.bestMatches(for: ocrText, limit: 3)
// hits: [MatchResult]  —— record + probability + confidence

// the pure utilities are public too: normalize / segment / pairSim / ConfusionTable.query …
```

## 14. Testing and quality gates

- Confusion-table assertions (§8.2).
- **CI benchmark gate**: the synthetic benchmark must hit top-1 ≥ X% / top-3 ≥ Y% / ECE ≤ Z; a regression fails the build — for a matching library this is the lifeline against silently getting worse. (X/Y/Z are baselined after the first benchmark runs.)
- **No-worse-than-formula** test: `LogisticScorer` must be ≥ `HeuristicScorer` on the benchmark, guaranteeing we never ship a worse default.
- An OCR-aware vs exact similarity ablation: prove twin softening genuinely helps on a set with look-alike noise.

## 15. Adopting GlyphScan (integration guide)

- Implement `MatchableRecord` on your record type (primary field → primary, secondary fields → secondary).
- Implement `CandidateSource`: small corpus → built-in `ArrayCandidateSource`; large corpus → SQLite/GRDB wrapping a sliding-window `LIKE`.
- Pick a `Scorer`: default `.bundledLearned`; want a deterministic baseline → `.heuristic`; retrain on your own corpus → `.custom(coeffs)`.
- Streaming / camera scenario: consume `MatchResult.record.id` for cross-frame identity (the streaming tracker is the future optional module `GlyphScanStream`).

## 16. Phased implementation

1. **P0 baseline**: `GlyphScanCore` generic Record + `CandidateSource` decoupling + formula-based similarity/tests (`HeuristicScorer`). Baseline at parity with `HeuristicScorer`.
2. **P1 glyph confusion + OCR-aware similarity**: `GlyphRenderer` / `ConfusionBuilder` / soft similarity + confusion assertions + ablation.
3. **P2 learned calibrated scorer**: features + `LogisticTrainer` + synthetic data + benchmark gate + `default-coefficients.json`.
4. **P3 open-source polish**: English README, optional `GlyphScanVision` target, `sample-corpus`, CI, LICENSE.
5. **(future)** on-device feedback online learning, `GlyphScanStream` (streaming tracker), web playground.

## 17. Risks and trade-offs

| Risk | Mitigation |
|---|---|
| Confusion-table O(n²) generation explodes on a large charset | limit the charset to corpus + seed; bucket-prune; one-time offline |
| Look-alike softening over-pulls (drags genuinely different records together) | digits exact, never softened; conservative τ / k; formula score as a feature locks the lower bound; ablation validation |
| Synthetic noise differs in distribution from real-device OCR | the noise model is driven directly by real glyph confusion; phase 2 corrects with on-device real feedback |
| The learner overfits the small sample corpus | L2 regularization; formula-superset fallback; consumers can retrain on their own corpus |
| CoreText is Apple-only | training tools `#if canImport(CoreText)`; the prebuilt table ships with the package, so non-Apple platforms can still load and use it |

## 18. Repository metadata

- **Name**: GlyphScan (highlights the "look at glyphs" core idea; generic, not bound to a domain).
- **License**: MIT.
- **Doc language**: README and design doc are provided in both Chinese and English.

## 19. Open issues / to baseline in the first version
- §14 benchmark thresholds X/Y/Z to be fixed after the first benchmark runs.
- The confusion table's N (bitmap resolution), k, and τ defaults to be settled by small-scale experiments (initial values 32 / 8 / 0.35).
