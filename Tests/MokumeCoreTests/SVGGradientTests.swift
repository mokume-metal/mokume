// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// SVG に書いた勾配 (`linearGradient`・`radialGradient`) の読み解き (#3031)。GPU は要らない。絵は
/// ``SVGGradientShapeTests`` が見る。
///
/// 期待値は書いた文字から手で導く。勾配の座標は `space` で要素の座標へ写すので、点を写した先で比べる。
@Suite("SVG の勾配の読み解き")
struct SVGGradientTests {
    private static let red = SVGFile.Color(red: 1, green: 0, blue: 0, alpha: 1)
    private static let blue = SVGFile.Color(red: 0, green: 0, blue: 1, alpha: 1)
    private static let stops =
        "<stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/>"

    private func document(_ body: String) throws -> SVGFile.Drawing {
        try SVGFile.parse("<svg xmlns='http://www.w3.org/2000/svg'>\(body)</svg>", path: "gradient.svg")
    }

    /// 1 つ目の描くものの勾配。
    private func gradient(_ body: String) throws -> SVGFile.GradientFill {
        let drawing = try document(body)
        let item = try #require(drawing.items.first)
        return try #require(item.gradient, "\(drawing)")
    }

    private func isClose(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { simd_length(a - b) < 1e-4 }

    /// 線形の勾配の 2 点を、要素の座標へ写したもの。
    private func ends(_ fill: SVGFile.GradientFill) -> (SIMD2<Float>, SIMD2<Float>)? {
        guard case .linear(let from, let to) = fill.geometry else { return nil }
        return (fill.space.apply(from), fill.space.apply(to))
    }

    // MARK: - 完了条件 4・5

    @Test("線形 (条件 4): 区切り 2 つの勾配で塗った矩形は、外接矩形の左端から右端への勾配を持ち、何も名乗らない")
    func linearGradientIsRead() throws {
        let drawing = try document(
            "<linearGradient id='g'>\(Self.stops)</linearGradient><rect width='80' height='50' fill='url(#g)'/>")
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        let item = try #require(drawing.items.first)
        #expect(item.fill == .white)
        let fill = try #require(item.gradient)
        #expect(fill.stops == [.init(color: Self.red, offset: 0), .init(color: Self.blue, offset: 1)])
        let (from, to) = try #require(ends(fill))
        #expect(isClose(from, [0, 0]) && isClose(to, [80, 0]), "\(from) → \(to)")
    }

    @Test("放射 (条件 5): cx・cy・r が 0.5 の勾配は、外接矩形の中心が位置 0、外接矩形の縁が位置 1")
    func radialGradientIsRead() throws {
        let fill = try gradient(
            "<radialGradient id='r' cx='0.5' cy='0.5' r='0.5'>\(Self.stops)</radialGradient>"
                + "<circle cx='60' cy='40' r='30' fill='url(#r)'/>")
        guard case .radial(let center, let radius) = fill.geometry else {
            Issue.record("放射でない: \(fill.geometry)")
            return
        }
        #expect(isClose(fill.space.apply(center), [60, 40]))
        #expect(isClose(fill.space.apply(center + [radius, 0]), [90, 40]))
        #expect(isClose(fill.space.apply(center + [0, radius]), [60, 70]))
    }

    // MARK: - 条件 6: gradientUnits

    @Test("objectBoundingBox (既定): x2 を省くと 100% で外接矩形の右端。数と百分率は外接矩形の割合")
    func boundingBoxUnitsAreFractions() throws {
        let omitted = try #require(
            ends(gradient("<linearGradient id='g' x1='0.25'>\(Self.stops)</linearGradient>"
                + "<rect x='10' y='20' width='80' height='40' fill='url(#g)'/>")))
        #expect(isClose(omitted.0, [30, 20]) && isClose(omitted.1, [90, 20]), "\(omitted)")
        let percent = try #require(
            ends(gradient("<linearGradient id='g' x1='0%' y1='50%' x2='50%' y2='100%' gradientUnits='objectBoundingBox'>"
                + "\(Self.stops)</linearGradient><rect x='10' y='20' width='80' height='40' fill='url(#g)'/>")))
        #expect(isClose(percent.0, [10, 40]) && isClose(percent.1, [50, 60]), "\(percent)")
    }

    @Test("userSpaceOnUse: 座標を要素の座標のまま読む (百分率は表示枠の割合)")
    func userSpaceUnitsAreCoordinates() throws {
        let fill = try gradient(
            "<linearGradient id='g' gradientUnits='userSpaceOnUse' x1='15' y1='5' x2='50%' y2='0'>"
                + "\(Self.stops)</linearGradient><rect x='10' y='20' width='80' height='40' fill='url(#g)'/>")
        let (from, to) = try #require(ends(fill))
        // 根の svg は大きさを書いていないので、表示枠は 100 × 100
        #expect(isClose(from, [15, 5]) && isClose(to, [50, 0]), "\(from) → \(to)")
    }

    @Test("objectBoundingBox の外接矩形は曲線の膨らみの端までちょうど (制御点ではない)")
    func boundingBoxFollowsCurveExtrema() throws {
        // 制御点は y = -40 まで届くが、曲線の頂点は y = -30
        let fill = try gradient(
            "<linearGradient id='g' x2='0' y2='1'>\(Self.stops)</linearGradient>"
                + "<path d='M0 0 C0 -40 40 -40 40 0 Z' fill='url(#g)'/>")
        let (from, to) = try #require(ends(fill))
        #expect(isClose(from, [0, -30]) && isClose(to, [0, 0]), "\(from) → \(to)")
    }

    // MARK: - 条件 7: gradientTransform

    @Test("gradientTransform を勾配の向きに掛ける: rotate(90) で左右の勾配が上下になる")
    func gradientTransformRotates() throws {
        let fill = try gradient(
            "<linearGradient id='g' gradientTransform='rotate(90)'>\(Self.stops)</linearGradient>"
                + "<rect width='80' height='50' fill='url(#g)'/>")
        let (from, to) = try #require(ends(fill))
        #expect(isClose(from, [0, 0]) && isClose(to, [0, 50]), "\(from) → \(to)")
    }

    // MARK: - 条件 8: href

    @Test(
        "href (xlink:href も) で区切りを引き継ぐ。勾配が使う要素より後ろに書かれていても読む",
        arguments: ["href", "xlink:href"])
    func stopsAreInheritedThroughHref(_ key: String) throws {
        let drawing = try SVGFile.parse(
            "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'>"
                + "<rect width='80' height='50' fill='url(#b)'/>"
                + "<defs><linearGradient id='b' \(key)='#a' x1='0' x2='1'/>"
                + "<linearGradient id='a'>\(Self.stops)</linearGradient></defs></svg>",
            path: "href.svg")
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        let fill = try #require(drawing.items.first?.gradient)
        #expect(fill.stops.map(\.color) == [Self.red, Self.blue])
    }

    @Test(
        "href の指す先が無い・循環するなら塗らず、勾配ごとに 1 度だけ名乗る",
        arguments: [
            ("<linearGradient id='b' href='#none'/>", ##"<linearGradient href="#none">"##),
            ("<linearGradient id='b' href='#c'/><linearGradient id='c' href='#b'/>", ##"<linearGradient href="#b">"##),
            ("<linearGradient id='b' href='#b'/>", ##"<linearGradient href="#b">"##),
        ])
    func brokenHrefPaintsNothing(_ sample: (String, String)) throws {
        let drawing = try document(
            sample.0 + "<rect width='80' height='50' fill='url(#b) red'/><rect y='60' width='8' height='5' fill='url(#b)'/>")
        #expect(drawing.items.isEmpty, "\(sample.0): \(drawing.items)")
        #expect(drawing.skipped.map(\.what) == [sample.1], "\(sample.0): \(drawing.skipped)")
        #expect(drawing.skipped.first?.count == 1)
    }

    @Test("href で指した勾配の属性は引き継がず、引き継がなかった属性を名乗る (区切りは引き継ぐ)")
    func hrefAttributesAreNamed() throws {
        let drawing = try document(
            "<linearGradient id='a' gradientTransform='rotate(90)' x2='0.5'>\(Self.stops)</linearGradient>"
                + "<linearGradient id='b' href='#a'/><rect width='80' height='50' fill='url(#b)'/>")
        #expect(
            drawing.skipped.map(\.what) == [
                "<linearGradient gradientTransform> inherited through href", "<linearGradient x2> inherited through href",
            ])
        let fill = try #require(drawing.items.first?.gradient)
        let (from, to) = try #require(ends(fill))
        #expect(isClose(from, [0, 0]) && isClose(to, [80, 0]), "\(from) → \(to)")
    }

    // MARK: - 条件 9: 名乗って捨てる

    @Test(
        "spreadMethod の reflect・repeat と、中心と違う焦点は読まずに名乗る (勾配は pad・中心の焦点で描く)",
        arguments: [
            ("<linearGradient id='g' spreadMethod='reflect'>", #"<linearGradient spreadMethod="reflect">"#),
            ("<linearGradient id='g' spreadMethod='repeat'>", #"<linearGradient spreadMethod="repeat">"#),
            ("<radialGradient id='g' fx='0.2'>", #"<radialGradient fx="0.2">"#),
            ("<radialGradient id='g' fy='30%'>", #"<radialGradient fy="30%">"#),
            ("<radialGradient id='g' fr='0.1'>", #"<radialGradient fr="0.1">"#),
        ])
    func unreadFeaturesAreNamed(_ sample: (String, String)) throws {
        let close = sample.0.hasPrefix("<radial") ? "</radialGradient>" : "</linearGradient>"
        let drawing = try document(
            sample.0 + Self.stops + close
                + "<rect width='80' height='50' fill='url(#g)'/><rect y='60' width='80' height='50' fill='url(#g)'/>")
        #expect(drawing.skipped == [SVGFile.Skip(what: sample.1, count: 1, line: 1)], "\(drawing.skipped)")
        #expect(drawing.items.allSatisfy { $0.gradient != nil })
    }

    @Test(
        "pad と、中心と同じ焦点 (Inkscape の書き方)・0 の fr は名乗らない",
        arguments: [
            "<linearGradient id='g' spreadMethod='pad'>",
            "<radialGradient id='g' cx='0.3' cy='0.6' fx='0.3' fy='0.6' fr='0'>",
        ])
    func harmlessFeaturesAreNotNamed(_ open: String) throws {
        let close = open.hasPrefix("<radial") ? "</radialGradient>" : "</linearGradient>"
        let drawing = try document(open + Self.stops + close + "<rect width='80' height='50' fill='url(#g)'/>")
        #expect(drawing.skipped.isEmpty, "\(drawing.skipped)")
        #expect(drawing.items.first?.gradient != nil)
    }

    @Test("区切りが 10 個を越えた分は使わず、名乗る")
    func stopsBeyondTenAreNamed() throws {
        let stops = (0...10).map { "<stop offset='\(Float($0) / 10)' stop-color='red'/>" }.joined()
        let drawing = try document(
            "<linearGradient id='g'>\(stops)</linearGradient><rect width='80' height='50' fill='url(#g)'/>")
        #expect(drawing.skipped.map(\.what) == ["<linearGradient> stops after the first 10"])
        #expect(drawing.items.first?.gradient?.stops.count == 10)
        let ten = (0...9).map { "<stop offset='\(Float($0) / 9)' stop-color='red'/>" }.joined()
        let exact = try document(
            "<linearGradient id='g'>\(ten)</linearGradient><rect width='80' height='50' fill='url(#g)'/>")
        #expect(exact.skipped.isEmpty, "境界の 10 個は名乗らない: \(exact.skipped)")
    }

    // MARK: - 区切りの読み方

    @Test("区切りの色と不透明度は属性・<style>・style 属性 (Inkscape の書き方) で読み、位置は前の区切りより小さければ寄せる")
    func stopsAreReadLikeCSS() throws {
        let fill = try gradient(
            "<style>.half { stop-opacity: 0.5 }</style><linearGradient id='g'>"
                + "<stop offset='40%' style='stop-color:#ff0000;stop-opacity:1'/>"
                + "<stop offset='0.2' class='half' stop-color='blue'/>"
                + "<stop offset='1' stop-color='red' style='stop-color: blue'/></linearGradient>"
                + "<rect width='80' height='50' fill='url(#g)'/>")
        #expect(
            fill.stops == [
                .init(color: Self.red, offset: 0.4),
                .init(color: SVGFile.Color(red: 0, green: 0, blue: 1, alpha: 0.5), offset: 0.4),
                .init(color: Self.blue, offset: 1),
            ])
    }

    @Test("区切りの読めない値は名乗り、初めの値 (位置 0・黒・不透明) で読む")
    func unreadableStopValuesAreNamed() throws {
        let drawing = try document(
            "<linearGradient id='g'><stop offset='abc' stop-color='bogus'/><stop offset='1' stop-color='blue'/>"
                + "</linearGradient><rect width='80' height='50' fill='url(#g)'/>")
        #expect(drawing.skipped.map(\.what) == [#"<stop offset="abc">"#, #"stop-color "bogus""#])
        #expect(drawing.items.first?.gradient?.stops.first == .init(color: .black, offset: 0))
    }

    // MARK: - SVG の約束どおりの 1 色・塗らない

    @Test("区切りが 1 つ・2 点が同じ・半径 0 は 1 色で塗り、区切りが無い勾配は塗らない (どれも名乗らない)")
    func degenerateGradientsFollowSVG() throws {
        let one = try document(
            "<linearGradient id='g'><stop stop-color='red'/></linearGradient><rect width='8' height='5' fill='url(#g)'/>")
        #expect(one.items.first?.fill == Self.red && one.items.first?.gradient == nil)
        let point = try document(
            "<linearGradient id='g' x2='0'>\(Self.stops)</linearGradient><rect width='8' height='5' fill='url(#g)'/>")
        #expect(point.items.first?.fill == Self.blue && point.items.first?.gradient == nil)
        let zero = try document(
            "<radialGradient id='g' r='0'>\(Self.stops)</radialGradient><rect width='8' height='5' fill='url(#g)'/>")
        #expect(zero.items.first?.fill == Self.blue)
        let empty = try document("<linearGradient id='g'/><rect width='8' height='5' fill='url(#g) red'/>")
        #expect(empty.items.isEmpty, "区切りの無い勾配は none と同じで、代わりの色も使わない")
        for drawing in [one, point, zero, empty] { #expect(drawing.skipped.isEmpty, "\(drawing.skipped)") }
    }

    @Test("指す先が勾配でない (パターン)・無い・ほかのファイルなら、代わりの色で塗って fill=\"url(…)\" を名乗る")
    func unresolvedReferenceKeepsTheFallback() throws {
        for reference in ["#p", "#missing", "other.svg#g"] {
            let drawing = try document(
                "<pattern id='p'/><linearGradient id='g'>\(Self.stops)</linearGradient>"
                    + "<rect width='8' height='5' fill='url(\(reference)) red'/>")
            #expect(drawing.skipped.map(\.what) == [#"fill="url(…)""#], "\(reference)")
            #expect(drawing.items.first?.fill == Self.red && drawing.items.first?.gradient == nil, "\(reference)")
        }
    }

    @Test("線の勾配は読まない: stroke=\"url(…)\" を名乗り、塗りの勾配は効く")
    func strokeGradientIsStillNamed() throws {
        let drawing = try document(
            "<linearGradient id='g'>\(Self.stops)</linearGradient>"
                + "<rect width='80' height='50' fill='url(#g)' stroke='url(#g) red'/>")
        #expect(drawing.skipped.map(\.what) == [#"stroke="url(…)""#])
        #expect(drawing.items.first?.gradient != nil && drawing.items.first?.stroke == Self.red)
    }

    @Test("fill-opacity と opacity は塗りの白の不透明度に入り、勾配の区切りには入らない")
    func opacityStaysOnTheFill() throws {
        let drawing = try document(
            "<linearGradient id='g'>\(Self.stops)</linearGradient>"
                + "<rect width='80' height='50' fill='url(#g)' fill-opacity='0.5' opacity='0.5'/>")
        let item = try #require(drawing.items.first)
        #expect(item.fill?.alpha == 0.25)
        #expect(item.gradient?.stops.allSatisfy { $0.color.alpha == 1 } == true)
    }

    @Test("objectBoundingBox で外接矩形の高さが 0 なら塗らない (SVG の約束)。線は引く")
    func flatBoundingBoxPaintsNothing() throws {
        let drawing = try document(
            "<linearGradient id='g'>\(Self.stops)</linearGradient>"
                + "<polyline points='0 10 80 10' fill='url(#g)' stroke='black'/>")
        #expect(drawing.items.count == 1)
        #expect(drawing.items.first?.fill == nil && drawing.items.first?.stroke == .black)
        #expect(drawing.skipped.isEmpty)
    }
}
