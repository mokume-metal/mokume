// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 下地を読む混ぜ方が、**仕様の式どおりの値**を作業空間に残すことの検査 ([#1380]・[#1447])。
/// GPU を要する。
///
/// 以前は大小の比較 (「掛ければ暗くなる」「明るいほうが明るい」) しか見ていなかったので、
/// 式が別の式へ崩れても向きさえ合っていれば緑のままだった。ここでは既知の 2 色を重ね、
/// `get()` で読んだ値を**式から導いた値と完全一致**で比べる ([ADR-0019] 決定 4)。
///
/// ## 期待値の導き方と、量子化の段
///
/// `get()` が返すのは描画先の作業空間の値そのもの (`RenderTarget.pixelFormat` =
/// `.rgba16Float`) で、sRGB のエンコードも 8 bit の書き出しも通らない。間にある量子化は
/// **Float16 へ丸める 1 段だけ**である。
///
/// そこで色は作業空間の値そのもの (原色を移さない口) で渡し — 不透明な色は
/// ``LinearRGBA/linear(red:green:blue:)``、透ける色は
/// ``LinearRGBA/init(straightRed:green:blue:alpha:)`` — 成分も不透明度も 2 進の短い小数に
/// 取る。すると式の厳密な値が Float16 で表せる — 丸めが起きないので、**許す幅を置かずに完全一致で比べられる**。丸めを許すと、GPU の丸めが
/// 最寄りとは限らないぶん (#911) 1 段ぶんの取り違えが隠れる。この前提 (期待値が Float16
/// で表せる) は照合の前に検査自身が確かめる — 前提の崩れた組を足したら、照合より先に
/// そちらが落ちる。
///
/// ## 下地のアルファと上のアルファ
///
/// 混ぜ方の式は W3C の合成の一般式に載る (``general(_:top:topAlpha:ground:groundAlpha:)``)。
/// 混ぜる相手がどれだけ居るかを**下地のアルファ**が、置いた色をどれだけ効かせるかを
/// **上のアルファ**が決める。検査は 3 つの下地に分けてある:
///
/// - **不透明どうし** (``compositeMatchesTheSpecifiedFormula(_:_:)``)。乗算済みと乗算前が
///   一致し、一般式は混ぜ方の式 `B` そのものを返す。見ているのは `B` の綴りだけである
/// - **完全に透明な下地** (`background(.transparent)` と、透明で始まる描き場所)。混ぜる相手が
///   無いので、どの混ぜ方でも置いた色がそのまま載る。**置く色は半透明で見る** — 不透明だと、
///   下地のアルファを見ない式でも 5 種が一致してしまう
/// - **透ける下地** (不透明度 0.5・0.25・0.75)。下地のアルファの重みが 0 でも 1 でもない所で、
///   一般式そのものと突き合わせる
///
/// ## 式の枝を両方に振る
///
/// 成分ごとに、取り違えれば値が変わるように組を選んである — `lightest` / `darkest` は
/// 赤で下地が勝ち緑で上が勝つ、`subtract` は向きを逆にすると符号が変わる、など。
/// `multiply` は白の上だけだと「上の色をそのまま置く」式と見分けが付かないので、灰色
/// どうし (線形 0.5 × 0.5 → 0.25) も見る。
///
/// [#1380]: https://github.com/mokume-metal/mokume/issues/1380
/// [#1447]: https://github.com/mokume-metal/mokume/issues/1447
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "混ぜ方の式",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct BlendFormulaTests {
    /// 確かめる式。**実装 (`Shaders/Common.metal` の `mokume_composite`) を写さず、仕様の
    /// 綴りのまま書く** — 写すと、実装が誤っていても検査が一致してしまう。`screen` は
    /// 仕様の `1 − (1 − a)(1 − b)` で書き、実装の `s + d − s·d` とは綴りを変えてある。
    nonisolated enum Formula: CaseIterable, Sendable {
        case multiply, lightest, darkest, subtract, screen, exclusion, add, difference

        var mode: BlendMode {
            switch self {
            case .multiply: .multiply
            case .lightest: .lightest
            case .darkest: .darkest
            case .subtract: .subtract
            case .screen: .screen
            case .exclusion: .exclusion
            case .add: .add
            case .difference: .difference
            }
        }

        /// 仕様の綴り (失敗したときに読む人のため)。
        var spelling: String {
            switch self {
            case .multiply: "a·b"
            case .lightest: "max(a, b)"
            case .darkest: "min(a, b)"
            case .subtract: "下 − 上"
            case .screen: "1 − (1 − a)(1 − b)"
            case .exclusion: "a + b − 2ab"
            case .add: "a + b"
            case .difference: "|下 − 上|"
            }
        }

        /// 下地 `ground` の上に `top` を重ねた成分 (どちらも乗算を戻した値)。
        func apply(ground: Double, top: Double) -> Double {
            switch self {
            case .multiply: ground * top
            case .lightest: max(ground, top)
            case .darkest: min(ground, top)
            case .subtract: ground - top
            case .screen: 1 - (1 - ground) * (1 - top)
            case .exclusion: ground + top - 2 * ground * top
            case .add: ground + top
            case .difference: abs(ground - top)
            }
        }
    }

    /// 重ねる 2 色 (どちらも線形・不透明) と、それを混ぜる式。
    nonisolated struct Pairing: CustomTestStringConvertible, Sendable {
        let formula: Formula
        /// 下地の赤・緑・青。
        let ground: [Double]
        /// 上に塗る色の赤・緑・青。
        let top: [Double]
        /// 何を見る組か。
        let note: String

        var testDescription: String { "\(formula.mode) (\(formula.spelling)): \(note)" }

        /// 成分ごとの期待値。
        var expected: [Double] { zip(ground, top).map { formula.apply(ground: $0, top: $1) } }

        static let all = [
            Pairing(
                formula: .multiply, ground: [1, 1, 1], top: [0.5, 0.25, 0.75],
                note: "白の上では上の色が残る"),
            Pairing(
                formula: .multiply, ground: [0.5, 0.5, 0.5], top: [0.5, 0.5, 0.5],
                note: "灰色どうしは 0.5 × 0.5 = 0.25"),
            // 赤は下地が明るく、緑は上が明るく、青は等しい
            Pairing(
                formula: .lightest, ground: [0.75, 0.25, 0.5], top: [0.25, 0.75, 0.5],
                note: "成分ごとに明るいほうを採る"),
            Pairing(
                formula: .darkest, ground: [0.75, 0.25, 0.5], top: [0.25, 0.75, 0.5],
                note: "成分ごとに暗いほうを採る"),
            // 青は上のほうが明るいので負になる。**0 を下回った値もそのまま残る**
            // (`BlendMode.subtract` の doc・畳むのは出力段だけ — #1057)
            Pairing(
                formula: .subtract, ground: [0.75, 0.5, 0.25], top: [0.25, 0.125, 0.75],
                note: "下地から引き、0 を下回っても畳まない"),
            Pairing(
                formula: .screen, ground: [0.5, 0.25, 0.75], top: [0.5, 0.5, 0.25],
                note: "反転して掛け、また反転する"),
            Pairing(
                formula: .exclusion, ground: [0.75, 0.25, 1], top: [0.5, 0.75, 0.25],
                note: "和から積の 2 倍を引く"),
        ]
    }

    /// `mokume_composite` へ届く入口。**2 つある** — 基本図形の断片 (`mokume_formFragment`)
    /// と、三角形の断片 (`mokume_fragmentMain`)。どちらも同じ関数を呼ぶが、渡す色の作り方が
    /// 違う (被覆率を掛けた塗り / 頂点の色) ので両方で見る。
    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case form = "基本図形 (rect)"
        case triangles = "三角形 (quad)"
        var testDescription: String { rawValue }
    }

    private static func color(_ components: [Double]) -> LinearRGBA {
        .linear(red: Float(components[0]), green: Float(components[1]), blue: Float(components[2]))
    }

    /// 下地の上に上の色を 1 枚重ね、真ん中の画素を読む。
    private func drawn(_ pairing: Pairing, through route: Route) throws -> LinearRGBA {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        try canvas.draw {
            canvas.background(Self.color(pairing.ground))
            canvas.noStroke()
            canvas.blendMode(pairing.formula.mode)
            canvas.fill(Self.color(pairing.top))
            switch route {
            case .form: canvas.rect(0, 0, 16, 16)
            case .triangles: canvas.quad(0, 0, 16, 0, 16, 16, 0, 16)
            }
        }
        return canvas.get(8, 8)
    }

    @Test("重ねた画素が、仕様の式から導いた値と一致する", arguments: Pairing.all, Route.allCases)
    func compositeMatchesTheSpecifiedFormula(_ pairing: Pairing, _ route: Route) throws {
        let expected = pairing.expected
        // **前提: 式の厳密な値が Float16 で表せる。** 表せない組では描画先へ書くときに
        // 丸めが入り、完全一致で比べる根拠が無くなる
        for value in expected {
            try #require(
                Double(Float16(value)) == value,
                "期待値 \(value) が Float16 で表せない — 組の選び方の前提が崩れている")
        }

        let pixel = try drawn(pairing, through: route)
        let channels = [("赤", pixel.red), ("緑", pixel.green), ("青", pixel.blue)]
        for ((name, drawn), value) in zip(channels, expected) {
            #expect(
                Double(drawn) == value,
                "\(route.rawValue) で\(name)が \(drawn) — 式からは \(value)")
        }
        #expect(pixel.alpha == 1, "不透明どうしを重ねたのに不透明度が \(pixel.alpha)")
    }

    // MARK: - 透ける下地の上 (#1447)

    /// 置く色の不透明度。
    ///
    /// **本題は半透明のほうである。** 不透明な色だと、完全に透明な下地の上では
    /// `add` / `lightest` / `difference` / `exclusion` / `screen` の 5 種が、下地の
    /// アルファを見ない式でも一致してしまう (下地の色を 0 と読んで混ぜ、上のアルファ 1 で
    /// 全部を効かせると、混ぜる前の色がそのまま出る)。
    nonisolated enum Opacity: Double, CaseIterable, Sendable {
        case half = 0.5
        case opaque = 1

        var name: String {
            switch self {
            case .half: "半透明 (α 0.5)"
            case .opaque: "不透明"
            }
        }
    }

    /// 透明な下地へ色を置く 1 回 (混ぜ方と、置く色の不透明度)。
    nonisolated struct Placement: CustomTestStringConvertible, Sendable {
        let mode: BlendMode
        let opacity: Opacity

        var testDescription: String { "\(mode) で\(opacity.name)の色を置く" }

        /// 10 の混ぜ方すべて × 2 つの不透明度。**`blend` と `replace` も入れる** —
        /// 「置いた色がそのまま載る」はどの混ぜ方でも同じ答えなので、下地を読まない 2 種が
        /// 物差しになる。
        static let all = BlendMode.allCases.flatMap { mode in
            Opacity.allCases.map { Placement(mode: mode, opacity: $0) }
        }
    }

    /// 透ける下地の上に、半透明の色を置く 1 回 (混ぜ方と、下地の不透明度)。
    nonisolated struct Overlay: CustomTestStringConvertible, Sendable {
        let formula: Formula
        let groundAlpha: Double

        var testDescription: String {
            "\(formula.mode) (\(formula.spelling)) を α \(groundAlpha) の下地へ"
        }

        /// 下地を読む 8 種 × 3 つの不透明度。**0.5 が本題**で、0.25 と 0.75 は上のアルファ
        /// (0.5) と取り違えた式を捕まえるために置く — 両方 0.5 だと、置く色を下地のアルファで
        /// 振り分けても上のアルファで振り分けても同じ値になる。
        static let all = Formula.allCases.flatMap { formula in
            [0.5, 0.25, 0.75].map { Overlay(formula: formula, groundAlpha: $0) }
        }
    }

    /// 置く色 (乗算前)。成分も不透明度も 2 進の短い小数に取るので、乗算済みの値も
    /// 一般式の値も Float16 で表せる。
    private static let placedColor: [Double] = [0.75, 0.5, 0.25]
    /// 透ける下地の色 (乗算前)。
    private static let groundColor: [Double] = [0.5, 0.25, 0.75]

    private static func color(_ straight: [Double], alpha: Double) -> LinearRGBA {
        LinearRGBA(
            straightRed: Float(straight[0]), green: Float(straight[1]),
            blue: Float(straight[2]), alpha: Float(alpha))
    }

    /// W3C の合成の一般式 ([Compositing and Blending Level 1] の 6 節・混ぜ方は 10 節)。
    ///
    /// ```text
    /// co = cs·(1 − αb) + cb·(1 − αs) + αs·αb·B(Cb, Cs)
    /// αo = αs + αb·(1 − αs)
    /// ```
    ///
    /// 小文字は乗算済み、大文字は乗算前の色。`B` は ``Formula/apply(ground:top:)`` で、
    /// **乗算前の色どうしで取る。** 返すのは乗算済みの成分と不透明度 (`get()` が返す形)。
    ///
    /// `add` と `subtract` は W3C に無いが、同じ式を当てる。下地が不透明 (αb = 1) なら
    /// `B` を上のアルファで効かせる形に戻るので、上の ``compositeMatchesTheSpecifiedFormula(_:_:)``
    /// の期待値とも食い違わない。
    ///
    /// [Compositing and Blending Level 1]: https://www.w3.org/TR/compositing-1/#generalformula
    private static func general(
        _ formula: Formula, top: [Double], topAlpha: Double,
        ground: [Double], groundAlpha: Double
    ) -> (color: [Double], alpha: Double) {
        let color = zip(top, ground).map { topColor, groundColor in
            let cs = topColor * topAlpha
            let cb = groundColor * groundAlpha
            return cs * (1 - groundAlpha) + cb * (1 - topAlpha)
                + topAlpha * groundAlpha * formula.apply(ground: groundColor, top: topColor)
        }
        return (color, topAlpha + groundAlpha * (1 - topAlpha))
    }

    /// 期待値が Float16 で表せることを確かめる (上の検査と同じ前提)。
    private func requireExactInFloat16(_ values: [Double]) throws {
        for value in values {
            try #require(
                Double(Float16(value)) == value,
                "期待値 \(value) が Float16 で表せない — 組の選び方の前提が崩れている")
        }
    }

    /// 読んだ画素を、乗算済みの期待値と完全一致で比べる。
    private func expectPixel(
        _ pixel: LinearRGBA, equals color: [Double], alpha: Double, _ context: String
    ) {
        let channels = [("赤", pixel.red), ("緑", pixel.green), ("青", pixel.blue)]
        for ((name, drawn), value) in zip(channels, color) {
            #expect(Double(drawn) == value, "\(context)で\(name)が \(drawn) — 式からは \(value)")
        }
        #expect(
            Double(pixel.alpha) == alpha,
            "\(context)で不透明度が \(pixel.alpha) — 式からは \(alpha)")
    }

    /// 経路に合わせて、面いっぱいに 1 枚置く。
    private static func cover(_ canvas: Canvas, through route: Route) {
        switch route {
        case .form: canvas.rect(0, 0, 16, 16)
        case .triangles: canvas.quad(0, 0, 16, 0, 16, 16, 0, 16)
        }
    }

    @Test(
        "完全に透明な下地の上では、どの混ぜ方でも置いた色がそのまま載る",
        arguments: Placement.all, Route.allCases)
    func placedColorSurvivesOnATransparentGround(_ placement: Placement, _ route: Route) throws {
        let alpha = placement.opacity.rawValue
        let expected = Self.placedColor.map { $0 * alpha }
        try requireExactInFloat16(expected + [alpha])

        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        try canvas.draw {
            canvas.background(.transparent)
            canvas.noStroke()
            canvas.blendMode(placement.mode)
            canvas.fill(Self.color(Self.placedColor, alpha: alpha))
            Self.cover(canvas, through: route)
        }
        expectPixel(
            canvas.get(8, 8), equals: expected, alpha: alpha,
            "\(route.rawValue) に \(placement.mode) で置いた所")
    }

    @Test(
        "透ける下地の上では、下地のアルファで混ぜ方の効きを弱めた一般式と一致する",
        arguments: Overlay.all, Route.allCases)
    func compositeOnATranslucentGroundMatchesTheGeneralFormula(
        _ overlay: Overlay, _ route: Route
    ) throws {
        let topAlpha = Opacity.half.rawValue
        let expected = Self.general(
            overlay.formula, top: Self.placedColor, topAlpha: topAlpha,
            ground: Self.groundColor, groundAlpha: overlay.groundAlpha)
        try requireExactInFloat16(expected.color + [expected.alpha])

        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        try canvas.draw {
            canvas.background(Self.color(Self.groundColor, alpha: overlay.groundAlpha))
            canvas.noStroke()
            canvas.blendMode(overlay.formula.mode)
            canvas.fill(Self.color(Self.placedColor, alpha: topAlpha))
            Self.cover(canvas, through: route)
        }
        let context =
            "\(route.rawValue) で \(overlay.formula.mode) を α \(overlay.groundAlpha) の下地へ置いた所"
        expectPixel(canvas.get(8, 8), equals: expected.color, alpha: expected.alpha, context)
    }

    /// `createGraphics` の面は透明で始まる (`Canvas+Graphics.swift`)。`background` を
    /// 呼ばずに描くのが、この面を重ねる素材に使うときの普通の書き方である。
    @Test(
        "描き場所 (透明で始まる) へ描いても、どの混ぜ方でも置いた色がそのまま載る",
        arguments: Placement.all, Route.allCases)
    func placedColorSurvivesOnAFreshGraphics(_ placement: Placement, _ route: Route) throws {
        let alpha = placement.opacity.rawValue
        let expected = Self.placedColor.map { $0 * alpha }
        try requireExactInFloat16(expected + [alpha])

        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        let layer = try canvas.createGraphics(16, 16)
        layer.beginDraw()
        layer.noStroke()
        layer.blendMode(placement.mode)
        layer.fill(Self.color(Self.placedColor, alpha: alpha))
        Self.cover(layer, through: route)
        layer.endDraw()
        expectPixel(
            layer.get(8, 8), equals: expected, alpha: alpha,
            "描き場所の\(route.rawValue) に \(placement.mode) で置いた所")
    }
}
