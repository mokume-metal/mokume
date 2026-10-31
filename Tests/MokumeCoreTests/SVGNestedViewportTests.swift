// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 入れ子の `<svg>` の表示枠の外に描くものがあるとき、切り抜かずに描くことを名乗る (#3563。#2879 のつなぎ)。
/// GPU は要らない。
///
/// **描く絵は変えない** — 名乗りは読み解きの結果への追加の欄 (``SVGFile/Drawing/approximated``) で、描くものは
/// 触らない。本設計 (#2879 の (b)) が入ったら、この名乗りごと消す。
@Suite("入れ子の svg の表示枠の名乗り")
nonisolated struct SVGNestedViewportTests {
    private static let note = "content outside the viewport of a nested <svg>"

    private func document(_ body: String, attributes: String = "") throws -> SVGFile.Drawing {
        try SVGFile.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"240\" height=\"160\"\(attributes)>\n\(body)\n</svg>",
            path: "panel.svg")
    }

    private func names(_ drawing: SVGFile.Drawing) -> [String] { drawing.approximated.map(\.what) }

    /// 表示枠 x=40, y=40, width=80, height=60 の入れ子の `<svg>` に、枠から 20 ずつはみ出す矩形 (#2879 の最小例)。
    private let overflowing =
        "<svg x='40' y='40' width='80' height='60' viewBox='0 0 80 60'><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg>"

    // MARK: - 名乗る

    @Test("最小例を読むと、入れ子の svg の行を添えて 1 度名乗る。skipped には混ぜず、絵は変えない")
    func theMinimalExampleIsNamed() throws {
        let drawing = try document(overflowing)
        #expect(names(drawing) == [Self.note])
        #expect(drawing.approximated.first?.count == 1)
        #expect(drawing.approximated.first?.line == 2, "入れ子の <svg> の行")
        #expect(drawing.skipped.isEmpty, "捨てたのではなく、近似で描いている: \(drawing.skipped)")
        // 描く絵は変えない: 矩形は切らずにそのまま 1 つ描く
        #expect(drawing.items.count == 1)
        #expect(drawing.items[0].outline == .rect(x: -20, y: -20, width: 120, height: 100))
    }

    @Test("はみ出すものが何個あっても、入れ子の svg につき 1 度。入れ子が 2 つなら 2 回で、最初の行が残る")
    func oneNoteForEachNestedSVG() throws {
        let one = try document(
            """
            <svg x='40' y='40' width='80' height='60'>
            <rect x='-20' y='0' width='10' height='10' fill='white'/>
            <rect x='200' y='0' width='10' height='10' fill='white'/>
            </svg>
            """)
        #expect(one.approximated.first?.count == 1)
        #expect(one.approximated.first?.line == 2)
        let two = try document(
            """
            <rect width='10' height='10'/>
            \(overflowing)
            \(overflowing)
            """)
        #expect(two.approximated.first?.count == 2)
        #expect(two.approximated.first?.line == 3, "最初に名乗った入れ子の行")
    }

    @Test("回した祖先や剪断した祖先の下でも黙らない (表示枠の座標で比べる)", arguments: [
        "rotate(30)", "skewX(25) rotate(-20)", "matrix(1 0.4 -0.3 1 20 10)", "scale(-1 1) translate(-200 0)",
    ])
    func rotatedAndSkewedAncestorsStillName(transform: String) throws {
        let drawing = try document("<g transform=\"\(transform)\">\(overflowing)</g>")
        #expect(names(drawing) == [Self.note], "\(transform)")
    }

    @Test("回した祖先の下で枠に収まるものは名乗らない (外側の回転が、枠との比べ方を狂わせない)", arguments: [
        "rotate(30)", "skewX(25) rotate(-20)", "scale(-1 1) translate(-200 0)",
    ])
    func rotatedAncestorsKeepFittingShapesQuiet(transform: String) throws {
        let drawing = try document(
            "<g transform=\"\(transform)\"><svg x='40' y='40' width='80' height='60'><rect x='5' y='5' width='70' height='50' fill='white'/></svg></g>")
        #expect(drawing.approximated.isEmpty, "\(transform)")
    }

    @Test("枠の中で回した図形が、枠をはみ出すなら名乗り、収まるなら名乗らない")
    func aRotatedShapeInsideTheViewport() throws {
        let fitting = try document(
            "<svg width='100' height='100'><g transform='rotate(45 50 50)'><rect x='30' y='30' width='40' height='40' fill='white'/></g></svg>")
        #expect(fitting.approximated.isEmpty, "回すと対角が 56.6 になるが、枠 100 には収まる")
        let overflowing = try document(
            "<svg width='100' height='100'><g transform='rotate(45 50 50)'><rect x='10' y='10' width='80' height='80' fill='white'/></g></svg>")
        #expect(names(overflowing) == [Self.note], "回すと対角が 113 になり、枠 100 をはみ出す")
    }

    @Test("preserveAspectRatio が slice で、viewBox が枠をはみ出すものも名乗る。meet では viewBox の外の余白に描いても名乗らない")
    func sliceOverflowsTheViewportButMeetDoesNot() throws {
        // viewBox 100x100 を 50x100 の枠へ: slice は倍率 1 で左右が 25 ずつ切れる。viewBox いっぱいの矩形は切れる
        let slice = try document(
            "<svg width='50' height='100' viewBox='0 0 100 100' preserveAspectRatio='xMidYMid slice'><rect width='100' height='100' fill='white'/></svg>")
        #expect(names(slice) == [Self.note])
        // meet は viewBox 全体が枠に収まる。同じ矩形は名乗らない
        let meet = try document(
            "<svg width='50' height='100' viewBox='0 0 100 100' preserveAspectRatio='xMidYMid meet'><rect width='100' height='100' fill='white'/></svg>")
        #expect(meet.approximated.isEmpty)
        // 切れない側 (枠の中) に収まる slice の矩形は名乗らない
        let inside = try document(
            "<svg width='50' height='100' viewBox='0 0 100 100' preserveAspectRatio='xMidYMid slice'><rect x='30' y='0' width='40' height='100' fill='white'/></svg>")
        #expect(inside.approximated.isEmpty)
    }

    @Test("入れ子の入れ子では、内側の枠に収まっても、外側の枠をはみ出せば名乗る (外側の行)")
    func theOuterViewportIsWatchedToo() throws {
        let drawing = try document(
            """
            <svg x='0' y='0' width='50' height='50'>
            <svg x='0' y='0' width='200' height='200'><rect width='100' height='100' fill='white'/></svg>
            </svg>
            """)
        #expect(names(drawing) == [Self.note])
        #expect(drawing.approximated.first?.line == 2, "はみ出された外側の <svg> の行")
    }

    @Test("overflow が hidden・scroll・clip なら切る側で、名乗る (属性でも CSS でも)", arguments: [
        "overflow='hidden'", "overflow='scroll'", "overflow='clip'", "overflow='HIDDEN'", "style='overflow: hidden'",
        "overflow='visible' style='overflow: hidden'", "overflow='hidden visible'", "overflow='revert'",
        "style='overflow: revert-layer'",
    ])
    func clippingOverflowValuesAreNamed(written: String) throws {
        let drawing = try document(
            "<svg x='40' y='40' width='80' height='60' \(written)><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg>")
        #expect(names(drawing) == [Self.note], "\(written)")
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
    }

    @Test("<style> の規則で hidden に書いても名乗る。visible の規則を後に書けば名乗らない")
    func overflowFromAStyleSheet() throws {
        let hidden = try document(
            "<style>svg { overflow: hidden }</style>\(overflowing)")
        #expect(names(hidden) == [Self.note])
        let visible = try document(
            "<style>.panel { overflow: visible }</style>\(overflowing.replacingOccurrences(of: "<svg ", with: "<svg class='panel' "))")
        #expect(visible.approximated.isEmpty)
    }

    // MARK: - 名乗らない

    @Test("中身が枠に収まる入れ子は名乗らない。ちょうど枠いっぱいでも名乗らない")
    func contentInsideTheViewportIsQuiet() throws {
        let inside = try document(
            "<svg x='40' y='40' width='80' height='60'><rect x='10' y='10' width='60' height='40' fill='white'/></svg>")
        #expect(inside.approximated.isEmpty)
        let exact = try document(
            "<svg x='40' y='40' width='80' height='60'><rect width='80' height='60' fill='white'/></svg>")
        #expect(exact.approximated.isEmpty, "辺が枠と一致するだけ")
        let scaled = try document(
            "<svg x='40.5' y='40.25' width='83' height='61' viewBox='0 0 3 7'><rect width='3' height='7' fill='white'/></svg>")
        #expect(scaled.approximated.isEmpty, "viewBox の拡大の丸めで、ちょうど収まる形を名乗らない")
    }

    @Test("overflow が visible か auto なら名乗らない (属性でも CSS でも)", arguments: [
        "overflow='visible'", "overflow='auto'", "style='overflow: visible'", "style='overflow: auto'",
        "overflow='hidden' style='overflow: visible'", "style='overflow: initial'", "style='overflow: unset'",
        "overflow='auto visible'",
    ])
    func visibleOverflowIsQuiet(written: String) throws {
        let drawing = try document(
            "<svg x='40' y='40' width='80' height='60' \(written)><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg>")
        #expect(drawing.approximated.isEmpty, "\(written)")
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
    }

    @Test("overflow: inherit は親の値を取る。親が visible の入れ子なら名乗らず、親が g なら (visible) 名乗らない")
    func inheritedOverflow() throws {
        let fromVisibleSVG = try document(
            "<svg x='0' y='0' width='240' height='160' overflow='visible'><svg x='40' y='40' width='80' height='60' style='overflow: inherit'><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg></svg>")
        #expect(fromVisibleSVG.approximated.isEmpty)
        let fromGroup = try document(
            "<g><svg x='40' y='40' width='80' height='60' style='overflow: inherit'><rect x='-20' y='-20' width='120' height='100' fill='white'/></svg></g>")
        #expect(fromGroup.approximated.isEmpty, "g の overflow は初めの値 visible")
    }

    @Test("根の svg は名乗らない (形は枠の無い図形として置く)。縁にまたがる図形も同じ")
    func theRootViewportIsNotNamed() throws {
        let drawing = try document("<rect x='-20' y='-20' width='400' height='300' fill='white'/>")
        #expect(drawing.approximated.isEmpty)
        let hidden = try document(
            "<rect x='-20' y='-20' width='400' height='300' fill='white'/>", attributes: " overflow=\"hidden\"")
        #expect(hidden.approximated.isEmpty)
    }

    @Test("枠の外に描くものでも、見えない図形 (塗りも線も無い・display:none) は描かないので名乗らない")
    func invisibleShapesAreNotNamed() throws {
        let drawing = try document(
            """
            <svg x='40' y='40' width='80' height='60'>
            <rect x='-20' y='-20' width='120' height='100' fill='none'/>
            <rect x='-20' y='-20' width='120' height='100' fill='white' style='display: none'/>
            <rect x='-20' y='-20' width='120' height='100' fill='white' opacity='0' fill-opacity='0'/>
            </svg>
            """)
        #expect(drawing.approximated.isEmpty, "\(drawing.approximated)")
    }

    @Test("入れ子の svg の外にあるものは、枠をはみ出していても名乗らない")
    func shapesOutsideTheNestedSVGAreQuiet() throws {
        let drawing = try document(
            "<svg x='40' y='40' width='80' height='60'><rect width='10' height='10' fill='white'/></svg><rect x='-20' y='-20' width='400' height='300' fill='white'/>")
        #expect(drawing.approximated.isEmpty)
    }

    @Test("名乗りは opacity の近似と並んで数え、片方だけでもう片方を隠さない")
    func sitsBesideTheOpacityNotes() throws {
        let drawing = try document(
            """
            <g opacity='0.5'>
            <circle cx='40' cy='50' r='25' fill='#f00'/>
            <circle cx='60' cy='50' r='25' fill='#00f'/>
            </g>
            \(overflowing)
            """)
        #expect(names(drawing).sorted() == [Self.note, "opacity on a group whose shapes overlap"].sorted())
    }

    // MARK: - 文面

    @Test("文面に、切り抜かないことと、入れ子の svg の最初の行が載る。opacity の近似だけなら、これまでの文面のまま")
    @MainActor
    func noticeSaysItDidNotClip() throws {
        let drawing = try document("<rect width='10' height='10'/>\n\(overflowing)")
        let notice = try #require(Canvas.svgApproximatedNotice(drawing, path: "panel.svg"))
        #expect(notice.contains("\"panel.svg\""))
        #expect(notice.contains("without clipping"))
        #expect(notice.contains("nested <svg>"))
        #expect(notice.contains("(line 3)"), "\(notice)")
        #expect(!notice.contains("opacity"), "opacity の近似は無いので触れない: \(notice)")

        let opacity = try document(
            """
            <g opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        let only = try #require(Canvas.svgApproximatedNotice(opacity, path: "panel.svg"))
        #expect(only.contains("drew opacity as an approximation"))
        #expect(!only.contains("clipping"))

        let both = try document(
            """
            <g opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            \(overflowing)
            """)
        let mixed = try #require(Canvas.svgApproximatedNotice(both, path: "panel.svg"))
        #expect(mixed.contains("drew opacity as an approximation") && mixed.contains("without clipping"))
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
