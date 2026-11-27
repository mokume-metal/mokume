// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 入れ子の `<svg>` の表示枠の切り抜きを読み解く (#2879)。どの入れ子が切り抜きの範囲 (``SVGFile/Drawing/viewportClips``)
/// を持つかを見る。GPU は要らない。絵は `SVGViewportClipTests` が見る。
///
/// **中身が表示枠をはみ出しうる入れ子だけ**が範囲を持つ。描くもの (``SVGFile/Drawing/items``) は切らずにそのまま持つ
/// (切るのは置くときの型板)。
@Suite("入れ子の svg の表示枠の切り抜きの読み解き")
nonisolated struct SVGNestedViewportTests {
    private func document(_ body: String, attributes: String = "") throws -> SVGFile.Drawing {
        try SVGFile.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"240\" height=\"160\"\(attributes)>\n\(body)\n</svg>",
            path: "panel.svg")
    }

    /// 切り抜きの範囲の数。
    private func clips(_ drawing: SVGFile.Drawing) -> Int { drawing.viewportClips.count }

    /// 表示枠 x=40, y=40, width=80, height=60 の入れ子の `<svg>` に、枠から 20 ずつはみ出す矩形 (#2879 の最小例)。
    private let overflowing =
        "<svg x='40' y='40' width='80' height='60' viewBox='0 0 80 60'><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg>"

    // MARK: - 切り抜きの範囲を持つ

    @Test("最小例を読むと、中の描くものの範囲と、表示枠の 4 隅 (形の座標) を持つ。描くものは切らず、捨てたものも無い")
    func theMinimalExampleIsClipped() throws {
        let drawing = try document(overflowing)
        #expect(drawing.viewportClips == [
            SVGFile.ViewportClipRange(items: 0..<1, corners: [SIMD2(40, 40), SIMD2(120, 40), SIMD2(120, 100), SIMD2(40, 100)])
        ])
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        // 矩形は切らずにそのまま 1 つ描く (切るのは置くときの型板)
        #expect(drawing.items.count == 1)
        #expect(drawing.items[0].outline == .rect(x: -20, y: -20, width: 120, height: 100))
    }

    @Test("はみ出すものが何個あっても、入れ子の svg につき 1 つの範囲。入れ子が 2 つなら 2 つ")
    func oneRangeForEachNestedSVG() throws {
        let one = try document(
            """
            <svg x='40' y='40' width='80' height='60'>
            <rect x='-20' y='0' width='10' height='10' fill='white'/>
            <rect x='200' y='0' width='10' height='10' fill='white'/>
            </svg>
            """)
        #expect(one.viewportClips.map(\.items) == [0..<2])
        let two = try document(
            """
            <rect width='10' height='10'/>
            \(overflowing)
            \(overflowing)
            """)
        #expect(two.viewportClips.map(\.items) == [1..<2, 2..<3], "前の矩形は範囲に入らない")
    }

    @Test("回した祖先や剪断した祖先の下でも切る (表示枠の座標で比べる)。4 隅は祖先の変換で写す", arguments: [
        "rotate(30)", "skewX(25) rotate(-20)", "matrix(1 0.4 -0.3 1 20 10)", "scale(-1 1) translate(-200 0)",
    ])
    func rotatedAndSkewedAncestorsStillClip(transform: String) throws {
        let drawing = try document("<g transform=\"\(transform)\">\(overflowing)</g>")
        #expect(clips(drawing) == 1, "\(transform)")
        // 4 隅は、矩形を描く変換 (祖先と入れ子の svg を畳んだもの) で表示枠の隅を写したもの
        let corners = try #require(drawing.viewportClips.first?.corners)
        let toShape = drawing.items[0].transform
        let expected = [SIMD2<Float>(0, 0), SIMD2(80, 0), SIMD2(80, 60), SIMD2(0, 60)].map(toShape.apply)
        for (corner, want) in zip(corners, expected) {
            #expect(abs(corner.x - want.x) < 1e-3 && abs(corner.y - want.y) < 1e-3, "\(transform): \(corners)")
        }
    }

    @Test("回した祖先の下で枠に収まるものは範囲を持たない (外側の回転が、枠との比べ方を狂わせない)", arguments: [
        "rotate(30)", "skewX(25) rotate(-20)", "scale(-1 1) translate(-200 0)",
    ])
    func rotatedAncestorsKeepFittingShapesQuiet(transform: String) throws {
        let drawing = try document(
            "<g transform=\"\(transform)\"><svg x='40' y='40' width='80' height='60'><rect x='5' y='5' width='70' height='50' fill='white'/></svg></g>")
        #expect(drawing.viewportClips.isEmpty, "\(transform)")
    }

    @Test("枠の中で回した図形が、枠をはみ出すなら切り、収まるなら切らない")
    func aRotatedShapeInsideTheViewport() throws {
        let fitting = try document(
            "<svg width='100' height='100'><g transform='rotate(45 50 50)'><rect x='30' y='30' width='40' height='40' fill='white'/></g></svg>")
        #expect(fitting.viewportClips.isEmpty, "回すと対角が 56.6 になるが、枠 100 には収まる")
        let overflowing = try document(
            "<svg width='100' height='100'><g transform='rotate(45 50 50)'><rect x='10' y='10' width='80' height='80' fill='white'/></g></svg>")
        #expect(clips(overflowing) == 1, "回すと対角が 113 になり、枠 100 をはみ出す")
    }

    @Test("preserveAspectRatio が slice で、viewBox が枠をはみ出すものも切る。meet で viewBox に収まるものは切らない")
    func sliceOverflowsTheViewportButMeetDoesNot() throws {
        // viewBox 100x100 を 50x100 の枠へ: slice は倍率 1 で左右が 25 ずつ切れる。viewBox いっぱいの矩形は切れる
        let slice = try document(
            "<svg width='50' height='100' viewBox='0 0 100 100' preserveAspectRatio='xMidYMid slice'><rect width='100' height='100' fill='white'/></svg>")
        #expect(clips(slice) == 1)
        // meet は viewBox 全体が枠に収まる。同じ矩形は切らない
        let meet = try document(
            "<svg width='50' height='100' viewBox='0 0 100 100' preserveAspectRatio='xMidYMid meet'><rect width='100' height='100' fill='white'/></svg>")
        #expect(meet.viewportClips.isEmpty)
        // 切れない側 (枠の中) に収まる slice の矩形は切らない
        let inside = try document(
            "<svg width='50' height='100' viewBox='0 0 100 100' preserveAspectRatio='xMidYMid slice'><rect x='30' y='0' width='40' height='100' fill='white'/></svg>")
        #expect(inside.viewportClips.isEmpty)
    }

    @Test("入れ子の入れ子では、内側の枠に収まっても、外側の枠をはみ出せば外側の範囲を持つ")
    func theOuterViewportIsWatchedToo() throws {
        let drawing = try document(
            """
            <svg x='0' y='0' width='50' height='50'>
            <svg x='0' y='0' width='200' height='200'><rect width='100' height='100' fill='white'/></svg>
            </svg>
            """)
        #expect(drawing.viewportClips == [
            SVGFile.ViewportClipRange(items: 0..<1, corners: [SIMD2(0, 0), SIMD2(50, 0), SIMD2(50, 50), SIMD2(0, 50)])
        ], "外側の枠だけ")
    }

    @Test("overflow が hidden・scroll・clip なら切る (属性でも CSS でも)", arguments: [
        "overflow='hidden'", "overflow='scroll'", "overflow='clip'", "overflow='HIDDEN'", "style='overflow: hidden'",
        "overflow='visible' style='overflow: hidden'", "overflow='hidden visible'", "overflow='revert'",
        "style='overflow: revert-layer'",
    ])
    func clippingOverflowValuesClip(written: String) throws {
        let drawing = try document(
            "<svg x='40' y='40' width='80' height='60' \(written)><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg>")
        #expect(clips(drawing) == 1, "\(written)")
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
    }

    @Test("<style> の規則で hidden に書いても切る。visible の規則を後に書けば切らない")
    func overflowFromAStyleSheet() throws {
        let hidden = try document(
            "<style>svg { overflow: hidden }</style>\(overflowing)")
        #expect(clips(hidden) == 1)
        let visible = try document(
            "<style>.panel { overflow: visible }</style>\(overflowing.replacingOccurrences(of: "<svg ", with: "<svg class='panel' "))")
        #expect(visible.viewportClips.isEmpty)
    }

    // MARK: - 切り抜きの範囲を持たない

    @Test("中身が枠に収まる入れ子は切らない。ちょうど枠いっぱいでも切らない")
    func contentInsideTheViewportIsQuiet() throws {
        let inside = try document(
            "<svg x='40' y='40' width='80' height='60'><rect x='10' y='10' width='60' height='40' fill='white'/></svg>")
        #expect(inside.viewportClips.isEmpty)
        let exact = try document(
            "<svg x='40' y='40' width='80' height='60'><rect width='80' height='60' fill='white'/></svg>")
        #expect(exact.viewportClips.isEmpty, "辺が枠と一致するだけ")
        let scaled = try document(
            "<svg x='40.5' y='40.25' width='83' height='61' viewBox='0 0 3 7'><rect width='3' height='7' fill='white'/></svg>")
        #expect(scaled.viewportClips.isEmpty, "viewBox の拡大の丸めで、ちょうど収まる形を切らない")
    }

    @Test("overflow が visible か auto なら切らない (属性でも CSS でも)", arguments: [
        "overflow='visible'", "overflow='auto'", "style='overflow: visible'", "style='overflow: auto'",
        "overflow='hidden' style='overflow: visible'", "style='overflow: initial'", "style='overflow: unset'",
        "overflow='auto visible'",
    ])
    func visibleOverflowIsQuiet(written: String) throws {
        let drawing = try document(
            "<svg x='40' y='40' width='80' height='60' \(written)><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg>")
        #expect(drawing.viewportClips.isEmpty, "\(written)")
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
    }

    @Test("overflow: inherit は親の値を取る。親が visible の入れ子なら切らず、親が g なら (visible) 切らない")
    func inheritedOverflow() throws {
        let fromVisibleSVG = try document(
            "<svg x='0' y='0' width='240' height='160' overflow='visible'><svg x='40' y='40' width='80' height='60' style='overflow: inherit'><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg></svg>")
        #expect(fromVisibleSVG.viewportClips.isEmpty)
        let fromGroup = try document(
            "<g><svg x='40' y='40' width='80' height='60' style='overflow: inherit'><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg></g>")
        #expect(fromGroup.viewportClips.isEmpty, "g の overflow は初めの値 visible")
    }

    @Test("根の svg は切らない (形は枠の無い図形として置く)。縁にまたがる図形も同じ")
    func theRootViewportIsNotNamed() throws {
        let drawing = try document("<rect x='-20' y='-20' width='400' height='300' fill='white'/>")
        #expect(drawing.viewportClips.isEmpty)
        let hidden = try document(
            "<rect x='-20' y='-20' width='400' height='300' fill='white'/>", attributes: " overflow=\"hidden\"")
        #expect(hidden.viewportClips.isEmpty)
    }

    @Test("枠の外に描くものでも、見えない図形 (塗りも線も無い・display:none) は描かないので切らない")
    func invisibleShapesAreNotNamed() throws {
        let drawing = try document(
            """
            <svg x='40' y='40' width='80' height='60'>
            <rect x='-20' y='-20' width='120' height='100' fill='none'/>
            <rect x='-20' y='-20' width='120' height='100' fill='white' style='display: none'/>
            <rect x='-20' y='-20' width='120' height='100' fill='white' opacity='0' fill-opacity='0'/>
            </svg>
            """)
        #expect(drawing.viewportClips.isEmpty, "\(drawing.viewportClips)")
    }

    @Test("入れ子の svg の外にあるものは、枠をはみ出していても範囲に入らない")
    func shapesOutsideTheNestedSVGAreQuiet() throws {
        let drawing = try document(
            "<svg x='40' y='40' width='80' height='60'><rect width='10' height='10' fill='white'/></svg><rect x='-20' y='-20' width='400' height='300' fill='white'/>")
        #expect(drawing.viewportClips.isEmpty)
    }

    @Test("重なる半透明の群があっても、切り抜きの範囲は表示枠の分だけ (opacity は合成の単位・#3564)")
    func sitsBesideTheOpacityUnits() throws {
        let drawing = try document(
            """
            <g opacity='0.5'>
            <circle cx='40' cy='50' r='25' fill='#f00'/>
            <circle cx='60' cy='50' r='25' fill='#00f'/>
            </g>
            \(overflowing)
            """)
        #expect(drawing.viewportClips.map(\.items) == [2..<3])
        #expect(drawing.units.count == 1)
    }

    // MARK: - 線の太さと並び

    @Test("塗りが枠に収まっても、線が枠をはみ出しうるなら切る。線が無ければ切らない")
    func strokesCountTowardsOverflow() throws {
        let stroked = try document(
            "<svg x='40' y='40' width='80' height='60'><rect x='1' y='1' width='78' height='58' fill='white' stroke='white' stroke-width='4'/></svg>")
        #expect(clips(stroked) == 1, "線の外側の半分 (2) が枠をはみ出す")
        let filled = try document(
            "<svg x='40' y='40' width='80' height='60'><rect x='1' y='1' width='78' height='58' fill='white'/></svg>")
        #expect(filled.viewportClips.isEmpty)
    }

    @Test("同じ描くものを持つ入れ子の範囲は、外側が先に並ぶ。離れた範囲は始まりの順")
    func rangesAreOrderedOuterFirst() throws {
        let drawing = try document(
            """
            <svg x='0' y='0' width='50' height='50'>
            <svg x='10' y='10' width='20' height='20'><rect x='-100' y='-100' width='400' height='400' fill='white'/></svg>
            </svg>
            \(overflowing)
            """)
        #expect(drawing.viewportClips.map(\.items) == [0..<1, 0..<1, 1..<2])
        #expect(drawing.viewportClips.first?.corners.first == SIMD2(0, 0), "外側の枠が先")
        #expect(drawing.viewportClips.dropFirst().first?.corners.first == SIMD2(10, 10))
    }

    // MARK: - 補助

    @Test("Affine.inverted は元に戻る。つぶれた変換は nil")
    func affineInverse() throws {
        let transform = SVGFile.Affine(a: 2, b: 0.5, c: -0.3, d: 1.5, e: 10, f: -4)
        let inverse = try #require(transform.inverted)
        let point = SIMD2<Float>(7, -3)
        let back = inverse.apply(transform.apply(point))
        #expect(abs(back.x - point.x) < 1e-4 && abs(back.y - point.y) < 1e-4)
        #expect(SVGFile.Affine(a: 1, b: 2, c: 2, d: 4, e: 0, f: 0).inverted == nil)
    }
}
