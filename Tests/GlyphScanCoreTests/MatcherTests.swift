import XCTest
@testable import GlyphScanCore

final class MatcherTests: XCTestCase {

    private let corpus: [SimpleRecord] = [
        SimpleRecord(id: 1, stem: "中华人民共和国成立于一九四九年",
                     options: ["1947", "1948", "1949", "1950"]),
        SimpleRecord(id: 2, stem: "光合作用的主要场所是叶绿体",
                     options: ["线粒体", "叶绿体", "细胞核"]),
        SimpleRecord(id: 3, stem: "水的化学式是H2O", options: []),
        SimpleRecord(id: 4, stem: "勾股定理直角三角形两直角边的平方和等于斜边的平方",
                     options: []),
    ]

    private func makeMatcher() -> GlyphScanMatcher {
        GlyphScanMatcher(source: ArrayCandidateSource(corpus))
    }

    func testExactHitRanksFirstWithHighConfidence() {
        let hits = makeMatcher().bestMatches(for: "光合作用的主要场所是叶绿体")
        XCTAssertEqual(hits.first?.record.id, 2)
        XCTAssertGreaterThan(hits.first?.score ?? 0, 0.6)
        XCTAssertEqual(hits.first?.confidence, .high)
    }

    func testSingleCharOCRErrorStillMatches() {
        // 叶 → 吐 (one mangled char). Recall anchoring tolerates it even without
        // the glyph-aware scorer.
        let hits = makeMatcher().bestMatches(for: "光合作用的主要场所是吐绿体")
        XCTAssertEqual(hits.first?.record.id, 2)
    }

    func testNeedleInFullPageHaystack() {
        let page = "第二章 生物学基础 光合作用的主要场所是叶绿体 线粒体是呼吸作用的场所 详见第15页"
        let hits = makeMatcher().bestMatches(for: page)
        XCTAssertEqual(hits.first?.record.id, 2)
    }

    func testGarbageDoesNotProduceHighConfidence() {
        let hits = makeMatcher().bestMatches(for: "今天天气很好我们一起去爬山看日出")
        if let top = hits.first {
            XCTAssertLessThan(top.score, 0.65)
        }
        // empty result is also acceptable
    }

    func testTooShortInputReturnsEmpty() {
        XCTAssertTrue(makeMatcher().bestMatches(for: "光合").isEmpty)
    }

    func testLimitIsRespected() {
        let hits = makeMatcher().bestMatches(for: "光合作用的主要场所是叶绿体", limit: 1)
        XCTAssertLessThanOrEqual(hits.count, 1)
    }
}
