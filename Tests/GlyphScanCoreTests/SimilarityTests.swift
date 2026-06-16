import XCTest
@testable import GlyphScanCore

final class SimilarityTests: XCTestCase {

    func testCleanForMatchingDropsLabelsAndPunctuation() {
        XCTAssertEqual(ScanText.cleanForMatching("A. 北京, B、上海!"), "北京上海")
    }

    func testExtractNumbersSortedUnique() {
        XCTAssertEqual(ScanText.extractNumbers("题1: 3/4 与 12.5 再来个1"),
                       ["1", "12.5", "3/4"])
    }

    func testSplitStemAndOptions() {
        let (stem, opts) = ScanText.splitStemAndOptions("中国的首都是 A. 北京 B. 上海")
        XCTAssertEqual(stem, "中国的首都是")
        XCTAssertTrue(opts.contains("北京"))
        XCTAssertTrue(opts.contains("上海"))
    }

    func testSplitNumberAndBody() {
        let (num, body) = ScanText.splitNumberAndBody("12、下列说法正确的是")
        XCTAssertEqual(num, "12.")
        XCTAssertEqual(body, "下列说法正确的是")
    }

    func testPairSimExactIsNearOne() {
        XCTAssertGreaterThan(Similarity.pairSim("中华人民共和国", "中华人民共和国"), 0.95)
    }

    func testPairSimUnrelatedIsLow() {
        XCTAssertLessThan(Similarity.pairSim("中华人民共和国", "今天天气真好啊"), 0.2)
    }

    func testRecallAnchoredCandidateInsideHaystack() {
        // Candidate appears verbatim inside a much longer noisy input — recall
        // anchoring should keep the score high, not dilute it toward zero.
        let haystack = "第二章 生物 光合作用的主要场所是叶绿体 还有很多别的无关文字 第15页"
        XCTAssertGreaterThan(Similarity.pairSim(haystack, "光合作用的主要场所是叶绿体"), 0.85)
    }

    func testHeuristicScoreExactBeatsGarbage() {
        let rec = SimpleRecord(id: 1,
                               stem: "光合作用的主要场所是叶绿体",
                               options: ["线粒体", "叶绿体", "细胞核"])
        let good = Similarity.heuristicScore(input: "光合作用的主要场所是叶绿体 A.线粒体 B.叶绿体",
                                             candidate: rec)
        let bad = Similarity.heuristicScore(input: "今天天气很好我们去公园散步吧",
                                            candidate: rec)
        XCTAssertGreaterThan(good, bad)
        XCTAssertGreaterThan(good, 0.5)
    }

    func testConfidenceTiers() {
        XCTAssertEqual(Confidence.tier(for: 0.70), .high)
        XCTAssertEqual(Confidence.tier(for: 0.40), .medium)
        XCTAssertEqual(Confidence.tier(for: 0.20), .low)
        XCTAssertEqual(Confidence.tier(for: 0.05), .veryLow)
    }
}
