// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 下地を読む混ぜ方のうち 6 種が、**仕様の式どおりの値**を作業空間に残すことの検査
/// ([#1380])。GPU を要する。
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
/// そこで色は ``LinearRGBA/linear(red:green:blue:)`` (作業空間の値そのもの・原色を移さない)
/// で渡し、成分を 2 進の短い小数に取る。すると式の厳密な値が Float16 で表せる — 丸めが
/// 起きないので、**許す幅を置かずに完全一致で比べられる**。丸めを許すと、GPU の丸めが
/// 最寄りとは限らないぶん (#911) 1 段ぶんの取り違えが隠れる。この前提 (期待値が Float16
/// で表せる) は照合の前に検査自身が確かめる — 前提の崩れた組を足したら、照合より先に
/// そちらが落ちる。
///
/// 不透明どうしなので乗算済みと乗算前が一致し、アルファで効かせる段
/// (`mix(下地, 混ぜた色, 上のアルファ)`) も混ぜた色をそのまま返す。見ているのは式だけである。
///
/// ## 式の枝を両方に振る
///
/// 成分ごとに、取り違えれば値が変わるように組を選んである — `lightest` / `darkest` は
/// 赤で下地が勝ち緑で上が勝つ、`subtract` は向きを逆にすると符号が変わる、など。
/// `multiply` は白の上だけだと「上の色をそのまま置く」式と見分けが付かないので、灰色
/// どうし (線形 0.5 × 0.5 → 0.25) も見る。
///
/// [#1380]: https://github.com/mokume-metal/mokume/issues/1380
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
        case multiply, lightest, darkest, subtract, screen, exclusion

        var mode: BlendMode {
            switch self {
            case .multiply: .multiply
            case .lightest: .lightest
            case .darkest: .darkest
            case .subtract: .subtract
            case .screen: .screen
            case .exclusion: .exclusion
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
}
