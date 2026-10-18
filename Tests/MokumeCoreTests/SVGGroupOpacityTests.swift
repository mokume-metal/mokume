// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 群と、塗りと線を両方持つ要素の `opacity` を、子ごとに掛ける近似で描くとき、黙らずに名乗る
/// (#2884。#2878 の主案が入ったら、この名乗りごと消す)。GPU は要らない。
///
/// **描く絵は変えない** — 名乗りは読み解きの結果への追加の欄で、描くものは触らない。
@Suite("群の opacity の近似の名乗り")
struct SVGGroupOpacityTests {
    private func document(_ body: String) throws -> SVGFile.Drawing {
        try SVGFile.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">\n\(body)\n</svg>",
            path: "logo.svg")
    }

    private func names(_ drawing: SVGFile.Drawing) -> [String] { drawing.approximated.map(\.what) }

    private static let groupOverlap = "opacity on a group whose shapes overlap"
    private static let fillAndStroke = "opacity on a shape with both fill and stroke"
    private static let strokeSubpaths = "translucent stroke on a path whose subpaths overlap"

    // MARK: - 群

    @Test("opacity < 1 の群で、子の矩形が重なると名乗る (群の行を添える)")
    func overlappingChildrenOfATranslucentGroup() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        #expect(names(drawing) == [Self.groupOverlap])
        #expect(drawing.approximated.first?.count == 1)
        #expect(drawing.approximated.first?.line == 2, "群 (<g>) の行")
        // 描くものは変わらない: 2 つの円がどちらも alpha 0.5 で入っている
        #expect(drawing.items.count == 2)
        #expect(drawing.items.allSatisfy { abs(($0.fill?.alpha ?? 0) - 0.5) < 1e-6 })
    }

    @Test("離れた子の群・opacity が 1 の群・fill-opacity と stroke-opacity だけの群は名乗らない")
    func nothingToNameWhenTheyDoNotOverlapOrNeedNoGroupOpacity() throws {
        let apart = try document(
            """
            <g opacity="0.5">
            <circle cx="20" cy="20" r="10" fill="#f00"/>
            <circle cx="80" cy="80" r="10" fill="#00f"/>
            </g>
            """)
        #expect(apart.approximated.isEmpty)

        let opaque = try document(
            """
            <g opacity="1">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        #expect(opaque.approximated.isEmpty)

        let channels = try document(
            """
            <g fill-opacity="0.5" stroke-opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        #expect(channels.approximated.isEmpty, "SVG でも別々に掛かるので、同じ絵になる")
    }

    @Test("opacity を持つのは外側の群だけで、重なりが外側の子の間にあるときだけ名乗る")
    func nestedGroupsAreJudgedByTheGroupThatHoldsTheOpacity() throws {
        // 内側の群だけが半透明で、重なりは内側の外 (不透明な円との間) にある → 名乗らない。
        // 半透明の群を丸ごと上に置く SVG と、子ごとに掛ける絵は、この重なりでは同じになる
        let insideOnly = try document(
            """
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <g opacity="0.5">
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        #expect(insideOnly.approximated.isEmpty)

        // 外側の群が半透明で、その中の入れ子の群の子どうしが重なる → 外側を 1 回名乗る
        let nested = try document(
            """
            <g opacity="0.5">
            <g>
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            </g>
            """)
        #expect(names(nested) == [Self.groupOverlap])
        #expect(nested.approximated.first?.line == 2)

        // 外側の群の子が、別々の入れ子の群に分かれていても重なれば名乗る
        let split = try document(
            """
            <g opacity="0.5">
            <g><circle cx="40" cy="50" r="25" fill="#f00"/></g>
            <g><circle cx="60" cy="50" r="25" fill="#00f"/></g>
            </g>
            """)
        #expect(names(split) == [Self.groupOverlap])
    }

    @Test("群ごとに 1 回数える (何度重なっても 1 回)・別の群は別に数える")
    func countsOncePerGroup() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <rect x="10" y="10" width="40" height="40" fill="#f00"/>
            <rect x="20" y="20" width="40" height="40" fill="#0f0"/>
            <rect x="30" y="30" width="40" height="40" fill="#00f"/>
            </g>
            <g opacity="0.4">
            <rect x="10" y="60" width="30" height="30" fill="#f00"/>
            <rect x="20" y="70" width="30" height="30" fill="#0f0"/>
            </g>
            """)
        #expect(names(drawing) == [Self.groupOverlap])
        #expect(drawing.approximated.first?.count == 2)
        #expect(drawing.approximated.first?.line == 2, "最初に出た行")
    }

    @Test("変換を畳んだ座標で比べる (見かけの上で離れていれば名乗らない)")
    func comparesInTheShapeCoordinates() throws {
        // 局所の座標では重なっているが、transform で片方が遠くへ動く
        let drawing = try document(
            """
            <g opacity="0.5">
            <rect x="10" y="10" width="20" height="20" fill="#f00"/>
            <rect x="10" y="10" width="20" height="20" fill="#00f" transform="translate(60 60)"/>
            </g>
            """)
        #expect(drawing.approximated.isEmpty)
    }

    @Test("線の太さの分だけ広げて比べる (外接矩形が離れていても、線が届けば重なる)")
    func strokeWidthWidensTheBox() throws {
        let touching = try document(
            """
            <g opacity="0.5">
            <line x1="10" y1="50" x2="40" y2="50" stroke="#f00" stroke-width="10"/>
            <line x1="40" y1="52" x2="70" y2="52" stroke="#00f" stroke-width="10"/>
            </g>
            """)
        #expect(names(touching) == [Self.groupOverlap])
    }

    // MARK: - 塗りと線の両方を持つ要素

    @Test("塗りと線を両方持ち、opacity < 1 の要素は名乗る (行を添える)")
    func fillAndStrokeUnderOpacity() throws {
        let drawing = try document(
            """
            <rect x="20" y="20" width="60" height="60" fill="#f00" stroke="#000" stroke-width="8" opacity="0.5"/>
            """)
        #expect(names(drawing) == [Self.fillAndStroke])
        #expect(drawing.approximated.first?.line == 2)
    }

    @Test("祖先の opacity も数える。塗りだけ・線だけ・opacity 1・fill-opacity だけは名乗らない")
    func fillAndStrokeOnlyWhenBothPaintsAreUnderOpacity() throws {
        let inherited = try document(
            """
            <g opacity="0.5">
            <rect x="20" y="20" width="60" height="60" fill="#f00" stroke="#000" stroke-width="8"/>
            </g>
            """)
        #expect(names(inherited) == [Self.fillAndStroke])

        for body in [
            ##"<rect x="20" y="20" width="60" height="60" fill="#f00" stroke="none" opacity="0.5"/>"##,
            ##"<rect x="20" y="20" width="60" height="60" fill="none" stroke="#000" stroke-width="8" opacity="0.5"/>"##,
            ##"<rect x="20" y="20" width="60" height="60" fill="#f00" stroke="#000" stroke-width="8"/>"##,
            ##"<rect x="20" y="20" width="60" height="60" fill="#f00" stroke="#000" stroke-width="8" fill-opacity="0.5" stroke-opacity="0.5"/>"##,
        ] {
            let drawing = try document(body)
            #expect(drawing.approximated.isEmpty, "\(body)")
        }
    }

    // MARK: - 絵は変えない・文面

    @Test("捨てたものの欄とは混ざらない (近似は描いている)")
    func approximationsAreNotSkips() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        #expect(drawing.skipped.isEmpty)
        #expect(!drawing.items.isEmpty)
        // 描く絵は、名乗りが無かったときと同じ (opacity を子の色に掛けた alpha)
        let plain = try document(
            """
            <circle cx="40" cy="50" r="25" fill="#f00" opacity="0.5"/>
            <circle cx="60" cy="50" r="25" fill="#00f" opacity="0.5"/>
            """)
        #expect(drawing.items == plain.items)
    }

    @Test("文面に opacity と最初の行が載る。近似が無ければ文面は無い")
    func noticeNamesOpacityAndTheFirstLine() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            <rect x="0" y="0" width="30" height="30" fill="#0f0" stroke="#000" opacity="0.5"/>
            """)
        let notice = try #require(Canvas.svgApproximatedNotice(drawing, path: "logo.svg"))
        #expect(notice.contains("\"logo.svg\""))
        #expect(notice.contains("opacity"))
        #expect(notice.contains("line 2"))
        #expect(notice.contains("line 6"))
        #expect(notice.contains(Self.groupOverlap))
        #expect(notice.contains(Self.fillAndStroke))

        let clean = try document(##"<circle cx="40" cy="50" r="25" fill="#f00"/>"##)
        #expect(Canvas.svgApproximatedNotice(clean, path: "logo.svg") == nil)
    }

    // MARK: - 線だけの要素の部分パス (反証 1)

    @Test("半透明の線で、部分パスの線どうしが重なると名乗る (opacity を直に書いても、stroke-opacity だけでも)")
    func translucentStrokeWithOverlappingSubpaths() throws {
        let cross = ##"d="M10 50 L90 50 M50 10 L50 90""##
        for attributes in [
            ##"stroke="#f00" stroke-width="6" opacity="0.5""##,
            ##"stroke="#f00" stroke-width="6" stroke-opacity="0.5""##,
            ##"stroke="rgba(255,0,0,0.5)" stroke-width="6""##,
        ] {
            let drawing = try document("<path \(cross) fill=\"none\" \(attributes)/>")
            #expect(names(drawing) == [Self.strokeSubpaths], "\(attributes)")
            #expect(drawing.approximated.first?.line == 2)
        }
    }

    @Test("部分パスが重ならない・線が不透明・部分パスが 1 本なら名乗らない")
    func strokeSubpathsNotOverlapping() throws {
        for body in [
            ##"<path d="M10 10 L30 10 M70 90 L90 90" fill="none" stroke="#f00" stroke-width="2" opacity="0.5"/>"##,
            ##"<path d="M10 50 L90 50 M50 10 L50 90" fill="none" stroke="#f00" stroke-width="6"/>"##,
            ##"<path d="M10 50 L90 50 L90 90" fill="none" stroke="#f00" stroke-width="6" opacity="0.5"/>"##,
        ] {
            #expect(try document(body).approximated.isEmpty, "\(body)")
        }
    }

    // MARK: - 線の広がり (反証 4)

    @Test("尖った角と四角い端の伸びを含めて広げる (太さの半分だけでは届かない所も名乗る)")
    func strokeReachIncludesCornersAndCaps() throws {
        // 太さ 20 の線の矩形 (x 10…30)。角は √2 × 10 ≈ 14.1 まで尖りうるので、44 までは届きうる。
        // 太さの半分 (10) だけなら 40 までで、x = 42 の矩形には届かない
        let drawing = try document(
            """
            <g opacity="0.5">
            <rect x="10" y="10" width="20" height="20" fill="none" stroke="#f00" stroke-width="20"/>
            <rect x="42" y="10" width="10" height="10" fill="#00f"/>
            </g>
            """)
        #expect(names(drawing).contains(Self.groupOverlap))
    }

    // MARK: - 半透明の容器の種類 (反証 6)

    @Test("根の svg・a・switch が半透明でも、重なる子を名乗る")
    func everyContainerKindRegistersItsOpacity() throws {
        let circles =
            ##"<circle cx="40" cy="50" r="25" fill="#f00"/><circle cx="60" cy="50" r="25" fill="#00f"/>"##
        let root = try SVGFile.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\" opacity=\"0.5\">\n\(circles)\n</svg>",
            path: "root.svg")
        #expect(names(root) == [Self.groupOverlap], "根の svg")
        #expect(root.approximated.first?.line == 1)

        let nestedSvg = try document("<svg opacity=\"0.5\">\(circles)</svg>")
        #expect(names(nestedSvg) == [Self.groupOverlap], "入れ子の svg")

        let anchor = try document("<a opacity=\"0.5\">\(circles)</a>")
        #expect(names(anchor) == [Self.groupOverlap], "a")

        let chosen = try document("<switch opacity=\"0.5\"><g>\(circles)</g></switch>")
        #expect(names(chosen) == [Self.groupOverlap], "switch")
    }

    @Test("入れ子の半透明の群が両方重なるなら、最初の行は外側の群")
    func nestedTranslucentGroupsKeepTheEarliestLine() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <g opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            </g>
            """)
        #expect(names(drawing) == [Self.groupOverlap])
        #expect(drawing.approximated.first?.count == 2)
        #expect(drawing.approximated.first?.line == 2, "外側の群の行")
    }

    // MARK: - 重ならない多数の子 (反証 3)

    private func box(_ x: Float, _ y: Float, _ width: Float = 1, _ height: Float = 1) -> SVGFile.Box {
        SVGFile.Box(low: SIMD2(x, y), high: SIMD2(x + width, y + height))
    }

    @Test("重ならない多数の矩形は、2 乗にならない回数で比べ終える (横一列・縦一列・格子)")
    func disjointBoxesAreNotComparedAllPairs() {
        let count = 20_000
        let row = (0..<count).map { box(Float($0) * 2, 0) }
        let column = (0..<count).map { box(0, Float($0) * 2) }
        let grid = (0..<count).map { box(Float($0 % 200) * 2, Float($0 / 200) * 2) }
        for (name, boxes) in [("row", row), ("column", column), ("grid", grid)] {
            let result = SVGFile.firstOverlap(in: boxes)
            #expect(result.found == false, "\(name)")
            // 総当たりなら約 2 億回。掃いて届く矩形とだけ比べれば、数百万回で済む
            #expect(result.comparisons < count * 500, "\(name): \(result.comparisons) 回")
        }
        #expect(SVGFile.firstOverlap(in: row).comparisons < count * 4, "横一列はほぼ線形")
        #expect(SVGFile.firstOverlap(in: column).comparisons < count * 4, "縦一列も軸を選んでほぼ線形")
    }

    @Test("重なりが 1 組でもあれば見つけ、見つけたら打ち切る")
    func findsTheOverlapAndStops() {
        var boxes = (0..<10_000).map { box(Float($0) * 2, 0) }
        boxes.append(box(2.5, 0, 1, 1))  // 2 番目の矩形 (x 2…3) と重なる
        let result = SVGFile.firstOverlap(in: boxes)
        #expect(result.found)
        #expect(result.comparisons < 100, "最初に見つかった所で止まる: \(result.comparisons) 回")
        // 辺が接するだけなら重ならない
        #expect(SVGFile.firstOverlap(in: [box(0, 0, 1, 1), box(1, 0, 1, 1)]).found == false)
        #expect(SVGFile.firstOverlap(in: []).found == false)
    }

    @Test("子が多く重ならない半透明の群も、読み込みが 2 乗にならずに終わる")
    func manyDisjointChildrenParseQuickly() throws {
        var body = "<g opacity=\"0.5\">\n"
        for index in 0..<20_000 {
            body += "<rect x=\"\(index % 200 * 4)\" y=\"\(index / 200 * 4)\" width=\"2\" height=\"2\" fill=\"#f00\"/>\n"
        }
        body += "</g>"
        let clock = ContinuousClock()
        var drawing = SVGFile.Drawing(items: [], skipped: [])
        let elapsed = try clock.measure { drawing = try document(body) }
        #expect(drawing.items.count == 20_000)
        #expect(drawing.approximated.isEmpty)
        // 総当たりなら 2 億回の比較で数十秒。余裕を見て 20 秒を超えたら 2 乗に戻っている
        #expect(elapsed < .seconds(20), "\(elapsed)")
    }
}
