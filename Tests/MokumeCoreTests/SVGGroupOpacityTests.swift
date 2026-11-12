// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 群と、塗りと線を両方持つ要素の `opacity` を、どの範囲で合成の単位 (``SVGFile/Drawing/units``) にするか (#3564)。
/// 読み解きだけを見るので GPU は要らない。描いた絵は `SVGCompositeGroupTests` が見る。
///
/// 重なりのある半透明の群と、塗りと線を両方持つ半透明の要素だけを単位にし、単位の中の色には単位の不透明度を
/// 掛けない。重ならない群は単位にせず、これまでどおり子の色に掛ける (#2884 の名乗りは消えた)。
@Suite("SVG の opacity の合成の単位")
nonisolated struct SVGGroupOpacityTests {
    private func document(_ body: String) throws -> SVGFile.Drawing {
        try SVGFile.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">\n\(body)\n</svg>",
            path: "logo.svg")
    }

    /// 単位の範囲と不透明度。
    private func units(_ drawing: SVGFile.Drawing) -> [String] {
        drawing.units.map { "\($0.items.lowerBound)..<\($0.items.upperBound) \($0.opacity)" }
    }

    private func fillAlphas(_ drawing: SVGFile.Drawing) -> [Float] { drawing.items.map { $0.fill?.alpha ?? -1 } }

    // MARK: - 群

    @Test("opacity < 1 の群で、子の矩形が重なると群を単位にし、子の色には掛けない")
    func overlappingChildrenOfATranslucentGroup() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        #expect(units(drawing) == ["0..<2 0.5"])
        #expect(fillAlphas(drawing) == [1, 1])
        #expect(drawing.approximated.isEmpty, "近似ではなくなったので名乗らない")
        let bounds = try #require(drawing.units.first?.bounds)
        #expect(bounds.low == SIMD2(15, 25))
        #expect(bounds.high == SIMD2(85, 75))
    }

    @Test("離れた子の群・opacity が 1 の群・fill-opacity と stroke-opacity だけの群は単位にせず、色に掛ける")
    func noUnitWhenTheyDoNotOverlapOrNeedNoGroupOpacity() throws {
        let apart = try document(
            """
            <g opacity="0.5">
            <circle cx="20" cy="20" r="10" fill="#f00"/>
            <circle cx="80" cy="80" r="10" fill="#00f"/>
            </g>
            """)
        #expect(apart.units.isEmpty)
        #expect(fillAlphas(apart) == [0.5, 0.5])

        let opaque = try document(
            """
            <g opacity="1">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        #expect(opaque.units.isEmpty)
        #expect(fillAlphas(opaque) == [1, 1])

        let channels = try document(
            """
            <g fill-opacity="0.5" stroke-opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        #expect(channels.units.isEmpty, "SVG でも別々に掛かるので、同じ絵になる")
        #expect(fillAlphas(channels) == [0.5, 0.5])
    }

    @Test("単位にしない群の色は、単位を入れる前と 1 ビットも同じ (祖先から順に掛ける)")
    func colorsOutsideUnitsAreUnchanged() throws {
        // 入れ子の重ならない群。前は祖先の opacity を外側から掛け合わせ、最後に fill-opacity と掛けていた
        let drawing = try document(
            """
            <g opacity="0.7">
            <g opacity="0.3">
            <rect x="0" y="0" width="10" height="10" fill="#f00" fill-opacity="0.9" opacity="0.6"/>
            </g>
            <rect x="50" y="50" width="10" height="10" fill="#f00" stroke="#00f" stroke-opacity="0.8"/>
            </g>
            """)
        // 外側の群は、塗りと線を両方持つ矩形を含むので単位になる。内側の群は重ならないので色に掛ける
        #expect(units(drawing) == ["0..<2 0.7"])
        let fill = try #require(drawing.items.first?.fill)
        let ownAndInner: Float = (1 * 0.3) * 0.6
        #expect(fill.alpha.bitPattern == (Float(1) * (0.9 * ownAndInner)).bitPattern)

        let plain = try document(
            """
            <g opacity="0.7">
            <g opacity="0.3">
            <rect x="0" y="0" width="10" height="10" fill="#f00" fill-opacity="0.9" opacity="0.6"/>
            </g>
            </g>
            """)
        #expect(plain.units.isEmpty)
        let bakedAll: Float = ((1 * 0.7) * 0.3) * 0.6
        #expect(try #require(plain.items.first?.fill).alpha.bitPattern == (Float(1) * (0.9 * bakedAll)).bitPattern)
    }

    @Test("opacity を持つのは外側の群だけで、重なりが外側の子の間にあるときだけ単位にする")
    func nestedGroupsAreJudgedByTheGroupThatHoldsTheOpacity() throws {
        // 内側の群だけが半透明で、重なりは内側の外 (不透明な円との間) にある → 単位にしない
        let insideOnly = try document(
            """
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <g opacity="0.5">
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            """)
        #expect(insideOnly.units.isEmpty)
        #expect(fillAlphas(insideOnly) == [1, 0.5])

        // 外側の群が半透明で、その中の入れ子の群の子どうしが重なる → 外側を単位にする
        let nested = try document(
            """
            <g opacity="0.5">
            <g>
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            </g>
            """)
        #expect(units(nested) == ["0..<2 0.5"])

        // 外側の群の子が、別々の入れ子の群に分かれていても重なれば単位にする
        let split = try document(
            """
            <g opacity="0.5">
            <g><circle cx="40" cy="50" r="25" fill="#f00"/></g>
            <g><circle cx="60" cy="50" r="25" fill="#00f"/></g>
            </g>
            """)
        #expect(units(split) == ["0..<2 0.5"])
    }

    @Test("群ごとに単位を持つ (それぞれの opacity で)")
    func oneUnitPerGroup() throws {
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
        #expect(units(drawing) == ["0..<3 0.5", "3..<5 0.4"])
    }

    @Test("変換を畳んだ座標で比べる (見かけの上で離れていれば単位にしない)")
    func comparesInTheShapeCoordinates() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <rect x="10" y="10" width="20" height="20" fill="#f00"/>
            <rect x="10" y="10" width="20" height="20" fill="#00f" transform="translate(60 60)"/>
            </g>
            """)
        #expect(drawing.units.isEmpty)
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
        #expect(units(touching) == ["0..<2 0.5"])
    }

    @Test("尖った角と四角い端の伸びを含めて広げ、単位の外接もそこまで含める")
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
        #expect(units(drawing) == ["0..<2 0.5"])
        let bounds = try #require(drawing.units.first?.bounds)
        let reach = 10 * Float(2).squareRoot()
        #expect(abs(bounds.low.x - (10 - reach)) < 1e-4)
        #expect(abs(bounds.high.x - 52) < 1e-4)
    }

    // MARK: - 塗りと線の両方を持つ要素

    @Test("塗りと線を両方持ち、opacity < 1 の要素は、要素だけで単位にする")
    func fillAndStrokeUnderOpacity() throws {
        let drawing = try document(
            """
            <rect x="20" y="20" width="60" height="60" fill="#f00" stroke="#000" stroke-width="8" opacity="0.5"/>
            """)
        #expect(units(drawing) == ["0..<1 0.5"])
        #expect(drawing.items.first?.fill?.alpha == 1)
        #expect(drawing.items.first?.stroke?.alpha == 1)
        let bounds = try #require(drawing.units.first?.bounds)
        let reach = 4 * Float(2).squareRoot()
        #expect(abs(bounds.low.x - (20 - reach)) < 1e-4)
    }

    @Test("祖先の opacity なら群を単位にする。塗りだけ・線だけ・opacity 1・fill-opacity だけは単位にしない")
    func fillAndStrokeOnlyWhenBothPaintsAreUnderOpacity() throws {
        let inherited = try document(
            """
            <g opacity="0.5">
            <rect x="20" y="20" width="60" height="60" fill="#f00" stroke="#000" stroke-width="8"/>
            </g>
            """)
        #expect(units(inherited) == ["0..<1 0.5"])

        for body in [
            ##"<rect x="20" y="20" width="60" height="60" fill="#f00" stroke="none" opacity="0.5"/>"##,
            ##"<rect x="20" y="20" width="60" height="60" fill="none" stroke="#000" stroke-width="8" opacity="0.5"/>"##,
            ##"<rect x="20" y="20" width="60" height="60" fill="#f00" stroke="#000" stroke-width="8"/>"##,
            ##"<rect x="20" y="20" width="60" height="60" fill="#f00" stroke="#000" stroke-width="8" fill-opacity="0.5" stroke-opacity="0.5"/>"##,
        ] {
            let drawing = try document(body)
            #expect(drawing.units.isEmpty, "\(body)")
        }
    }

    @Test("要素だけの単位は、単位にしない祖先の opacity を単位の不透明度に持つ")
    func elementUnitCarriesTheBakedAncestors() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <rect x="0" y="0" width="10" height="10" fill="#f00" stroke="#000" opacity="0.5"/>
            <rect x="50" y="50" width="10" height="10" fill="#0f0"/>
            </g>
            """)
        // 群の子は離れていて、塗りと線を両方持つ矩形は要素だけで単位になる → 群は単位にしない
        #expect(units(drawing) == ["0..<1 0.25"])
        #expect(fillAlphas(drawing) == [1, 0.5])
    }

    // MARK: - 入れ子の単位

    @Test("入れ子の半透明の群が両方重なるなら、内側を単位にし、外側は単位 1 つとして見る")
    func nestedTranslucentGroups() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <g opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            </g>
            """)
        // 外側の中は内側の単位 1 つだけで重ならないので、外側の 0.5 は内側の単位に掛かる
        #expect(units(drawing) == ["0..<2 0.25"])
        #expect(fillAlphas(drawing) == [1, 1])

        let both = try document(
            """
            <g opacity="0.5">
            <rect x="0" y="0" width="60" height="60" fill="#0f0"/>
            <g opacity="0.8">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            </g>
            """)
        // 外側は、矩形と内側の単位が重なるので単位。内側も単位で、外側の中に入れ子になる (外側が先)
        #expect(units(both) == ["0..<3 0.5", "1..<3 0.8"])
        #expect(fillAlphas(both) == [1, 1, 1])
    }

    @Test("単位の群の中の、重ならない半透明の群は色に掛ける")
    func bakedGroupInsideAUnit() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <rect x="0" y="0" width="60" height="60" fill="#0f0"/>
            <g opacity="0.8">
            <rect x="40" y="40" width="10" height="10" fill="#f00"/>
            </g>
            </g>
            """)
        #expect(units(drawing) == ["0..<2 0.5"])
        #expect(fillAlphas(drawing) == [1, 0.8])
    }

    // MARK: - 半透明の容器の種類

    @Test("根の svg・a・switch・入れ子の svg が半透明でも、重なる子を単位にする")
    func everyContainerKindRegistersItsOpacity() throws {
        let circles =
            ##"<circle cx="40" cy="50" r="25" fill="#f00"/><circle cx="60" cy="50" r="25" fill="#00f"/>"##
        let root = try SVGFile.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\" opacity=\"0.5\">\n\(circles)\n</svg>",
            path: "root.svg")
        #expect(units(root) == ["0..<2 0.5"], "根の svg")
        let nestedSvg = try document("<svg opacity=\"0.5\">\(circles)</svg>")
        #expect(units(nestedSvg) == ["0..<2 0.5"], "入れ子の svg")
        let anchor = try document("<a opacity=\"0.5\">\(circles)</a>")
        #expect(units(anchor) == ["0..<2 0.5"], "a")
        let chosen = try document("<switch opacity=\"0.5\"><g>\(circles)</g></switch>")
        #expect(units(chosen) == ["0..<2 0.5"], "switch")
    }

    // MARK: - 部分パスの線

    @Test("半透明の線の部分パスどうしが重なっても、単位にも名乗りにもしない (線を 1 つの図形として引く)")
    func translucentStrokeWithOverlappingSubpaths() throws {
        let cross = ##"d="M10 50 L90 50 M50 10 L50 90""##
        for attributes in [
            ##"stroke="#f00" stroke-width="6" opacity="0.5""##,
            ##"stroke="#f00" stroke-width="6" stroke-opacity="0.5""##,
            ##"stroke="rgba(255,0,0,0.5)" stroke-width="6""##,
        ] {
            let drawing = try document("<path \(cross) fill=\"none\" \(attributes)/>")
            #expect(drawing.units.isEmpty, "\(attributes)")
            #expect(drawing.approximated.isEmpty, "\(attributes)")
            #expect(drawing.items.first?.stroke?.alpha == 0.5, "\(attributes)")
        }
    }

    @Test("opacity の名乗りの文面は無くなった (表示枠の名乗りだけが残る)")
    @MainActor
    func noOpacityNotice() throws {
        let drawing = try document(
            """
            <g opacity="0.5">
            <circle cx="40" cy="50" r="25" fill="#f00"/>
            <circle cx="60" cy="50" r="25" fill="#00f"/>
            </g>
            <rect x="0" y="0" width="30" height="30" fill="#0f0" stroke="#000" opacity="0.5"/>
            """)
        #expect(Canvas.svgApproximatedNotice(drawing, path: "logo.svg") == nil)
        #expect(drawing.skipped.isEmpty)
    }

    // MARK: - 重ならない多数の子

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
        #expect(drawing.units.isEmpty)
        // 総当たりなら 2 億回の比較で数十秒。余裕を見て 20 秒を超えたら 2 乗に戻っている
        #expect(elapsed < .seconds(20), "\(elapsed)")
    }
}
