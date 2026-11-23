// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 型板の区間の頂点を、被覆 1 の片が先・被覆 < 1 の片が後に並べ替える (``Canvas/putFullCoverageFirst(in:vertices:coverageSpans:)``・
/// #4034)。GPU を使わず、頂点の並びと被覆の区間を直に組んで見る。頂点は元の番号を `position.x` に持つ。
@MainActor
@Suite("型板の区間の被覆 1 の片を先に")
struct FullCoverageFirstTests {
    typealias Span = Canvas.CoverageSpan

    /// 結果の頂点の元の番号と、被覆の区間。
    private func reordered(
        count: Int, section: Range<Int>, spans: [Span]
    ) -> (order: [Int], spans: [Span]) {
        var vertices = (0..<count).map {
            ShapeVertex(position: SIMD2(Float($0), 0), uv: .zero, color: .linear(red: 1, green: 1, blue: 1))
        }
        var coverage = spans
        Canvas.putFullCoverageFirst(in: section, vertices: &vertices, coverageSpans: &coverage)
        return (vertices.map { Int($0.position.x) }, coverage)
    }

    @Test("被覆 1 の片を先へ移し、被覆の区間を移した先へ付け直す")
    func movesFullPiecesFirst() {
        let result = reordered(count: 9, section: 0..<9, spans: [Span(range: 3..<6, value: 0.5)])
        #expect(result.order == [0, 1, 2, 6, 7, 8, 3, 4, 5])
        #expect(result.spans == [Span(range: 6..<9, value: 0.5)])
    }

    /// 被覆が 3 種類 (隣り合う違う値を含む) でも、細い片どうしは元の順のまま。
    @Test("被覆が 3 種類でも、細い片どうしは元の順で、区間は値ごとに分かれたまま")
    func keepsThinPiecesInOrder() {
        let result = reordered(
            count: 12, section: 0..<12,
            spans: [Span(range: 0..<3, value: 0.5), Span(range: 3..<6, value: 0.8), Span(range: 9..<12, value: 0.3)])
        #expect(result.order == [6, 7, 8, 0, 1, 2, 3, 4, 5, 9, 10, 11])
        #expect(
            result.spans == [
                Span(range: 3..<6, value: 0.5), Span(range: 6..<9, value: 0.8), Span(range: 9..<12, value: 0.3),
            ])
    }

    /// 前の図形の細い片と同じ被覆で続いた区間 (2..<6) は、区間の頭 (4) で割り、前の図形の分 (2..<4) を残す。
    @Test("前の図形とまとまった被覆の区間は、区間の頭で割って前の図形の分を残す")
    func splitsASpanSharedWithThePreviousFigure() {
        let result = reordered(
            count: 12, section: 4..<12,
            spans: [Span(range: 2..<6, value: 0.5), Span(range: 9..<12, value: 0.8)])
        #expect(result.order == [0, 1, 2, 3, 6, 7, 8, 4, 5, 9, 10, 11])
        #expect(
            result.spans == [
                Span(range: 2..<4, value: 0.5), Span(range: 7..<9, value: 0.5), Span(range: 9..<12, value: 0.8),
            ])
    }

    /// 後ろの図形と続いた区間 (6..<10) は、区間の終わり (8) で割る。区間の終わりへ移した同じ被覆の頂点と続くので、
    /// 外の分 (8..<10) とまた 1 つにまとまる。区間の外の頂点は動かない。
    @Test("後ろの図形とまとまった被覆の区間は、区間の外の頂点を動かさない")
    func keepsASpanSharedWithTheNextFigure() {
        let result = reordered(
            count: 12, section: 0..<8,
            spans: [Span(range: 0..<2, value: 0.5), Span(range: 6..<10, value: 0.8)])
        #expect(result.order == [2, 3, 4, 5, 0, 1, 6, 7, 8, 9, 10, 11])
        #expect(result.spans == [Span(range: 4..<6, value: 0.5), Span(range: 6..<10, value: 0.8)])
    }

    /// 被覆 1 の片が細い片の後ろに無いとき (細い片だけ・被覆 1 の片が全部先・区間に被覆が無い・区間が空) は、
    /// 頂点も被覆の区間も動かさない。
    @Test(
        "被覆 1 の片が細い片の後ろに無ければ、何も動かさない",
        arguments: [
            (0..<9, [Span(range: 6..<9, value: 0.5)]),
            (0..<9, [Span(range: 0..<9, value: 0.5)]),
            (0..<6, [Span(range: 7..<9, value: 0.5)]),
            (3..<3, [Span(range: 0..<9, value: 0.5)]),
            (3..<9, [Span(range: 0..<3, value: 0.5)]),
        ])
    func leavesOrderedSectionsAlone(section: Range<Int>, spans: [Span]) {
        let result = reordered(count: 9, section: section, spans: spans)
        #expect(result.order == Array(0..<9))
        #expect(result.spans == spans)
    }
}
