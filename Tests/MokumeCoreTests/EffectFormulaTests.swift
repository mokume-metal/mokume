// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 組み込みの効果と利用者の効果が、**式どおりの値**を作業空間に残すことの検査 ([#1384])。
/// GPU を要する。
///
/// `EffectTests` が見ているのは「無効の値では 1 ビットも変わらない」「効かせれば変わる」と、
/// 単色化・ぼかしの不変条件である。それだけだと、式が別の式へ崩れても絵が変わってさえ
/// いれば緑のままになる。ここでは既知の色の面に効果をかけ、読んだ値を**式から導いた値**と
/// 比べる ([ADR-0019] 決定 4)。
///
/// ## 期待値の導き方と、量子化の段
///
/// 期待値は `Shaders/Effects/Builtin.metal` に書かれた式と各効果の doc から導き、CPU で
/// 計算する。**実装の綴りは写さない** — 反転は「乗算を戻して 1 から引き、掛け直す」、
/// 彩度は「輝度からの隔たりを 1 + p 倍する」のように、同じ値を別の綴りで書く。
///
/// 読むのは描画先の作業空間の値そのもの (`RenderTarget.pixelFormat` = `.rgba16Float`) で、
/// 間にある量子化は **Float16 へ丸める 1 段だけ**である。そこで色は 2 進の短い小数で渡す。
///
/// - **式が 2 進で閉じるもの** (反転・明るさ・対比・利用者の効果・周辺減光の中心) は、
///   厳密な値が Float16 で表せることを検査自身が `#require` で確かめてから**完全一致**で比べる
///   ([#1380] と同じ形)
/// - **閉じないもの** (彩度の重み・周辺減光の smoothstep と距離・色ずれの 3 で割る平均) は、
///   完全一致が原理的に取れない。GPU の単精度の計算は丸めを含み、しかも Float16 へ落とす
///   丸めは最寄りとは限らない (#911 — 目盛りの途中の値が下の目盛りへ落ちたことがある)。
///   だから**期待値を挟む 2 つの Float16 の値のどちらか**を許す。挟む範囲は単精度の計算の
///   丸めぶん (`slack`) だけ広げ、その大きさの根拠は各検査に書く。どの `slack` も、
///   式を取り違えたときのずれより 2 桁以上小さい
///
/// [#1380]: https://github.com/mokume-metal/mokume/issues/1380
/// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "効果の式",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct EffectFormulaTests {
    // MARK: - 読み書き

    /// 乗算済みの 4 成分 (赤・緑・青・不透明度)。
    nonisolated struct Premultiplied: Equatable, Sendable, CustomTestStringConvertible {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        var channels: [Double] { [red, green, blue, alpha] }
        var testDescription: String { "(\(red), \(green), \(blue), a \(alpha))" }
    }

    private static let names = ["赤", "緑", "青", "不透明度"]

    private func makeCanvas(width: Int = 16, height: Int = 16) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 一様な面に効果をかけて、全画素を読む。
    private func uniform(
        _ color: Premultiplied, _ effects: [Effect], on canvas: Canvas
    ) throws -> PixelBuffer {
        try canvas.draw {
            canvas.background(
                LinearRGBA(
                    premultipliedRed: Float(color.red), green: Float(color.green),
                    blue: Float(color.blue), alpha: Float(color.alpha)))
            canvas.effects(effects)
        }
        return try canvas.target.readPixels()
    }

    private static func channels(_ pixel: LinearRGBA) -> [Double] {
        [Double(pixel.red), Double(pixel.green), Double(pixel.blue), Double(pixel.alpha)]
    }

    /// **前提: 式の厳密な値が Float16 で表せる。** 表せない組では描画先へ書くときに丸めが
    /// 入り、完全一致で比べる根拠が無くなる。
    private static func requireRepresentable(_ values: [Double]) throws {
        for value in values {
            try #require(
                Double(Float16(value)) == value,
                "期待値 \(value) が Float16 で表せない — 組の選び方の前提が崩れている")
        }
    }

    /// `value` を挟む 2 つの Float16 の値。`slack` だけ外へ広げてから挟む。
    ///
    /// 表せる値ならその値 1 つ (の両隣の手前まで) になる。
    static func halfBracket(_ value: Double, slack: Double) -> ClosedRange<Double> {
        var below = Float16(value - slack)
        if Double(below) > value - slack { below = below.nextDown }
        var above = Float16(value + slack)
        if Double(above) < value + slack { above = above.nextUp }
        return Double(below)...Double(above)
    }

    /// 完全一致で比べる。
    private static func expectExact(
        _ pixel: LinearRGBA, _ expected: Premultiplied, _ note: String
    ) {
        for (index, (drawn, value)) in zip(channels(pixel), expected.channels).enumerated() {
            #expect(drawn == value, "\(note): \(names[index])が \(drawn) — 式からは \(value)")
        }
    }

    /// 期待値を挟む 2 つの Float16 の値のどちらかであることを見る。
    private static func expectBracketed(
        _ pixel: LinearRGBA, _ expected: Premultiplied, slack: Double, _ note: String
    ) {
        for (index, (drawn, value)) in zip(channels(pixel), expected.channels).enumerated() {
            let range = halfBracket(value, slack: slack)
            #expect(
                range.contains(drawn),
                "\(note): \(names[index])が \(drawn) — 式からは \(value) (許す範囲 \(range))")
        }
    }

    // MARK: - 反転

    /// 反転の組。`amount` と、効かせる面の色。
    nonisolated struct Inversion: Sendable, CustomTestStringConvertible {
        let amount: Double
        let color: Premultiplied
        let note: String

        var testDescription: String { "amount \(amount): \(note)" }

        /// **乗算を戻して 1 から引き、掛け直す** (乗算前の反転 1 − c/a を乗算済みへ移したもの)。
        /// それを元の色と `amount` で混ぜる。実装の `mix(c, a − c, p)` とは綴りを変えてある。
        var expected: Premultiplied {
            let a = color.alpha
            func invert(_ c: Double) -> Double {
                let inverted = a * (1 - c / a)
                return (1 - amount) * c + amount * inverted
            }
            return Premultiplied(
                invert(color.red), invert(color.green), invert(color.blue), alpha: a)
        }

        static let all = [
            Inversion(
                amount: 1, color: Premultiplied(0.25, 0.5, 0.875),
                note: "不透明な面は 1 − c"),
            // 乗算済み (0.125, 0.25, 0.5) = 乗算前 (0.25, 0.5, 1) の半透明
            Inversion(
                amount: 1, color: Premultiplied(0.125, 0.25, 0.5, alpha: 0.5),
                note: "半透明の面は a − c で、不透明度は動かない"),
            // (1 − p)c + p(a − c) は p = 1/2 で c に依らず a/2 になる
            Inversion(
                amount: 0.5, color: Premultiplied(0.25, 0.5, 0.875),
                note: "半分だけ効かせると、どの色も a/2 になる"),
        ]
    }

    @Test("反転は、作業空間で a − c に完全一致する", arguments: Inversion.all)
    func invertMatchesTheFormula(_ inversion: Inversion) throws {
        let expected = inversion.expected
        try Self.requireRepresentable(expected.channels)
        let canvas = try makeCanvas()
        let pixels = try uniform(
            inversion.color, [.invert(amount: Float(inversion.amount))], on: canvas)
        Self.expectExact(pixels[8, 8], expected, inversion.testDescription)
        // 一様な面なので、端の画素も同じ
        Self.expectExact(pixels[0, 15], expected, "端 \(inversion.testDescription)")
    }

    // MARK: - 色調整

    /// 作業空間の相対輝度 Y。**重みの正本は `ColorPrimaries.luminanceWeights`** で、単色化
    /// (`EffectTests` が Rec.709 の値で見ている) と彩度はこれと同じ重みを掛けているはずである。
    private static func luminance(_ rgb: [Double]) -> Double {
        let weights = ColorPrimaries.luminanceWeights
        return rgb[0] * weights.x + rgb[1] * weights.y + rgb[2] * weights.z
    }

    /// sRGB の原色に掛ける Rec.709 の重み。**作業空間の値に掛けたら誤り** (#1212)。
    /// 取り違えが検査に掛かることを確かめるのに使う。
    private static func rec709Luminance(_ rgb: [Double]) -> Double {
        rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
    }

    /// 色調整の組。
    nonisolated struct Adjustment: Sendable, CustomTestStringConvertible {
        let brightness: Double
        let contrast: Double
        let saturation: Double
        let color: Premultiplied
        let note: String

        init(
            brightness: Double = 0, contrast: Double = 0, saturation: Double = 0,
            _ color: Premultiplied, _ note: String
        ) {
            self.brightness = brightness
            self.contrast = contrast
            self.saturation = saturation
            self.color = color
            self.note = note
        }

        var testDescription: String {
            "brightness \(brightness)・contrast \(contrast)・saturation \(saturation): \(note)"
        }

        var effect: Effect {
            .adjust(
                brightness: Float(brightness), contrast: Float(contrast),
                saturation: Float(saturation))
        }

        /// 彩度の段に入る直前の乗算前の色 (明るさ → 対比の順に、どちらも 0 で止める)。
        var beforeSaturation: [Double] {
            let a = color.alpha
            return [color.red, color.green, color.blue].map { c in
                let lifted = max(c / a + brightness, 0)
                return max((lifted - 0.5) * (1 + contrast) + 0.5, 0)
            }
        }

        /// 期待値。彩度は **輝度からの隔たりを 1 + p 倍する** (実装の `mix(Y, s, 1 + p)` と
        /// 同じ値の別の綴り)。
        func expected(luminance: ([Double]) -> Double) -> Premultiplied {
            let s = beforeSaturation
            let y = luminance(s)
            let saturated = s.map { max(y + (1 + saturation) * ($0 - y), 0) }
            let a = color.alpha
            return Premultiplied(saturated[0] * a, saturated[1] * a, saturated[2] * a, alpha: a)
        }

        /// 明るさと対比だけ。**彩度の段は p = 0 でも通る** (`mix(Y, s, 1)`) — 下の
        /// `requireTheSaturationStepIsExact` の理由で、そこでも値は動かない。
        static let exact = [
            Adjustment(
                brightness: 0.25, Premultiplied(0.5, 0.375, 0.25), "明るさは乗算前の色に足す"),
            Adjustment(
                brightness: -0.25, Premultiplied(0.5, 0.375, 0.125), "引いて 0 を下回った成分は 0 で止める"),
            Adjustment(
                contrast: 1, Premultiplied(0.625, 0.5, 0.4375), "対比は 0.5 からの隔たりを 1 + p 倍する"),
            Adjustment(
                contrast: -0.5, Premultiplied(0.75, 0.25, 0.5), "負の対比は 0.5 へ寄せる"),
            Adjustment(
                contrast: 3, Premultiplied(0.375, 0.5, 0.5625), "広げて 0 を下回った成分は 0 で止める"),
            Adjustment(
                brightness: 0.125, contrast: 1, Premultiplied(0.5, 0.375, 0.4375),
                "明るさを足してから対比を掛ける"),
        ]

        /// 彩度の組。**重みが 2 進で閉じないので、完全一致は原理的に取れない。**
        static let saturations = [
            Adjustment(saturation: -1, Premultiplied(1, 0, 0), "彩度を抜いた赤は赤の重み"),
            Adjustment(saturation: -1, Premultiplied(0, 1, 0), "彩度を抜いた緑は緑の重み"),
            Adjustment(saturation: -1, Premultiplied(0, 0, 1), "彩度を抜いた青は青の重み"),
            Adjustment(saturation: 1, Premultiplied(0.5, 0.375, 0.25), "輝度からの隔たりを倍にする"),
            Adjustment(saturation: -0.5, Premultiplied(0.75, 0.25, 0.5), "隔たりを半分にする"),
            Adjustment(saturation: 3, Premultiplied(0.25, 0.5, 0.125), "広げて 0 を下回った成分は 0 で止める"),
        ]
    }

    /// **前提: 彩度の段 `mix(Y, s, 1)` = `Y + (s − Y)·1` が s に戻る。**
    ///
    /// Y は重みが 2 進で閉じないので単精度で丸まっている。それでも差 s − Y が丸めなしで
    /// 求まれば、足し戻した値は s そのものになる。差が丸めなしで求まるのは、s が 0 か、
    /// Y/2 ≤ s ≤ 2Y のとき (Sterbenz の補題)。Y の単精度の丸め (相対 1e-7 程度) で境目を
    /// またがないよう、1% の余裕を取る。
    private static func requireTheSaturationStepIsExact(_ adjustment: Adjustment) throws {
        let s = adjustment.beforeSaturation
        let y = luminance(s)
        for value in s where value != 0 {
            try #require(
                value >= y / 2 * 1.01 && value <= y * 2 / 1.01,
                "\(value) が輝度 \(y) の半分から倍の外 — 彩度の段で丸めが入りうる")
        }
    }

    /// 完了条件 2 の前半 ([#1384])。不透明な面では割り算も掛け戻しも 1 で、明るさと対比は
    /// 2 進の短い小数で閉じる。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("明るさと対比は、式から導いた値に完全一致する", arguments: Adjustment.exact)
    func brightnessAndContrastMatchTheFormula(_ adjustment: Adjustment) throws {
        let expected = adjustment.expected(luminance: Self.luminance)
        try Self.requireRepresentable(expected.channels)
        try Self.requireTheSaturationStepIsExact(adjustment)
        let canvas = try makeCanvas()
        let pixels = try uniform(adjustment.color, [adjustment.effect], on: canvas)
        Self.expectExact(pixels[8, 8], expected, adjustment.testDescription)
    }

    /// **掛け戻してから調整する** (`Builtin.metal`)。乗算済みのまま明るさを足すと、半透明の
    /// ところだけ効き方が変わる。
    ///
    /// 割り算は近似の割り算 (fast math) を通るので、2 のべきで割るときでも丸めが入らないとは
    /// 言い切れない。許すのは単精度の 1 目盛りに余裕を見た 1e-6 だけで、乗算済みのまま
    /// 調整したときのずれ (ここでは 0.156) より 5 桁小さい。
    ///
    /// **組の選び方に罠がある。** 明るさ 0.25・対比 1・不透明度 0.5 では、乗算済みのまま
    /// 調整しても同じ値になる (どちらも 2c)。だから取り違えた綴りが許す範囲の外にあることを、
    /// 照合の前に検査自身が確かめる。
    @Test("半透明の面では、乗算を戻してから明るさと対比を掛ける")
    func adjustsTheStraightColourOfTranslucentAreas() throws {
        // 乗算済み (0.25, 0.1875, 0.125) = 乗算前 (0.5, 0.375, 0.25) の半透明
        let adjustment = Adjustment(
            brightness: 0.25, contrast: 0.5, Premultiplied(0.25, 0.1875, 0.125, alpha: 0.5),
            "半透明")
        let expected = adjustment.expected(luminance: Self.luminance)
        try Self.requireTheSaturationStepIsExact(adjustment)
        // **前提: 乗算済みのまま調整した値 (不透明度 1 として扱った値) は、許す範囲の外にある**
        let color = adjustment.color
        let mistaken = Adjustment(
            brightness: adjustment.brightness, contrast: adjustment.contrast,
            Premultiplied(color.red, color.green, color.blue), "乗算済みのまま"
        ).expected(luminance: Self.luminance)
        let distinguishable = zip(expected.channels.prefix(3), mistaken.channels).allSatisfy {
            !Self.halfBracket($0, slack: 1e-6).contains($1)
        }
        try #require(distinguishable, "乗算済みのまま調整しても同じ値になる — 組の選び方が悪い")
        let canvas = try makeCanvas()
        let pixels = try uniform(adjustment.color, [adjustment.effect], on: canvas)
        Self.expectBracketed(pixels[8, 8], expected, slack: 1e-6, adjustment.testDescription)
    }

    /// 完了条件 2 の後半 ([#1384])。**彩度は単色化と同じ重み** — 作業空間 (線形 Display P3) の
    /// 相対輝度の行 (ec27231・#1212) — で輝度を取る。
    ///
    /// 許す幅 `slack` は 1e-5。シェーダの重みは正本を 6 桁に丸めた写しで (各 5e-7 以内)、
    /// 単精度の内積と隔たりの 1 + p 倍 (最大 4 倍) の丸めを足しても 1e-5 に届かない。
    /// **sRGB の重み (Rec.709) を掛けていたら外れる**ことを、照合の前に検査自身が確かめる —
    /// 赤で 0.016、青で 0.007 ずれ、どちらも許す範囲の外である。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("彩度は、単色化と同じ作業空間の輝度の重みで混ぜる", arguments: Adjustment.saturations)
    func saturationUsesTheWorkingSpaceLuminance(_ adjustment: Adjustment) throws {
        let slack = 1e-5
        let expected = adjustment.expected(luminance: Self.luminance)
        let mistaken = adjustment.expected(luminance: Self.rec709Luminance)
        // **前提: 重みを取り違えた値は、許す範囲の外にある** (どれか 1 成分でも)
        let distinguishable = zip(expected.channels, mistaken.channels).contains { right, wrong in
            !Self.halfBracket(right, slack: slack).contains(wrong)
        }
        try #require(distinguishable, "sRGB の重みとの違いが許す幅に埋もれる — 組の選び方が悪い")

        let canvas = try makeCanvas()
        let pixels = try uniform(adjustment.color, [adjustment.effect], on: canvas)
        Self.expectBracketed(pixels[8, 8], expected, slack: slack, adjustment.testDescription)

        // 彩度を抜き切った色は、単色化した色と同じ値になる (どちらも Y)
        if adjustment.saturation == -1 {
            let grey = try uniform(adjustment.color, [.monochrome()], on: canvas)[8, 8]
            Self.expectBracketed(
                grey, expected, slack: slack, "単色化 \(adjustment.testDescription)")
        }
    }

    // MARK: - 周辺減光

    /// 周辺減光の掛け率。**画素の中心**の、画面の中心からの距離 d で決まる。
    ///
    /// d は縦横それぞれ半幅を 1 として測る (画面の角で √2)。角の画素の中心は角そのもの
    /// ではないので、√2 ではなく √((1 − 1/W)² + (1 − 1/H)²) になる。smoothstep は
    /// エルミートの 3 次 t²(3 − 2t) で、t = (d − 0.4) / (1.45 − 0.4) を 0…1 に留めたもの。
    private static func vignetteFactor(x: Int, y: Int, width: Int, height: Int, amount: Double)
        -> (distance: Double, factor: Double)
    {
        let across = (Double(x) + 0.5) / Double(width) * 2 - 1
        let down = (Double(y) + 0.5) / Double(height) * 2 - 1
        let distance = (across * across + down * down).squareRoot()
        let t = min(max((distance - 0.4) / (1.45 - 0.4), 0), 1)
        return (distance, 1 - amount * t * t * (3 - 2 * t))
    }

    /// 完了条件 3 ([#1384])。**全画素を式と照合する** — 縦と横で画素数の違う面を使うので、
    /// 距離を縦横それぞれの半幅で測っていること (縦横比で直していないこと) も見える。
    ///
    /// - d ≤ 0.4 の画素は smoothstep が厳密に 0 なので、**1 ビットも変わらない**
    /// - それより外は完全一致が取れない (距離の平方根と smoothstep の割り算が 2 進で閉じない)。
    ///   許す幅 `slack` は 2e-5。画素の中心の補間・長さ・割り算の単精度の丸めは合わせて
    ///   1e-6 程度で、smoothstep の傾き (最大 1.43) を掛けても届かない。**端の 0.4 や 1.45 を
    ///   取り違えると、辺の中ほどで 0.01 以上ずれる** — 許す幅の 500 倍である
    /// - アルファは動かない
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("周辺減光は、画素の中心の距離 d で 1 − p·smoothstep(0.4, 1.45, d) 倍になる")
    func vignetteFollowsTheSmoothstepOfTheDistance() throws {
        let (width, height) = (64, 48)
        let amount = 0.75
        let color = Premultiplied(0.75, 0.5, 0.25)
        let canvas = try makeCanvas(width: width, height: height)
        let pixels = try uniform(color, [.vignette(amount: Float(amount))], on: canvas)

        var untouched = 0
        var mismatched: [String] = []
        for y in 0..<height {
            for x in 0..<width {
                let (distance, factor) = Self.vignetteFactor(
                    x: x, y: y, width: width, height: height, amount: amount)
                let drawn = Self.channels(pixels[x, y])
                let expected = [color.red * factor, color.green * factor, color.blue * factor, 1]
                // 境目 0.4 の上に乗る画素は無い (距離の丸めで枝を取り違えないよう、少し離す)
                let inner = distance < 0.4 - 1e-4
                if inner { untouched += 1 }
                for (index, value) in expected.enumerated() {
                    let fits =
                        inner || index == 3
                        ? drawn[index] == value
                        : Self.halfBracket(value, slack: 2e-5).contains(drawn[index])
                    if !fits {
                        mismatched.append("(\(x), \(y)) の\(Self.names[index]) \(drawn[index]) ≠ \(value)")
                    }
                }
            }
        }
        // 中心の近くの画素が確かにある (無ければ「変わらない」を見ていない)
        #expect(untouched > 100)
        #expect(mismatched.isEmpty, "\(mismatched.count) 成分が外れた: \(mismatched.prefix(6))")

        // 角の画素は角そのものではない。**期待値が角の √2 で決まる値とは違う**ことを、
        // 式の側で確かめておく (違わないなら、画素の中心で測る理由の説明が嘘になる)
        let corner = Self.vignetteFactor(x: 0, y: 0, width: width, height: height, amount: amount)
        #expect(corner.distance < 2.0.squareRoot() - 0.02)
        #expect(Self.channels(pixels[0, 0])[0] < color.red * 0.5, "角が落ちていない")
    }

    // MARK: - 色ずれ

    /// 完了条件 4 の前半 ([#1384])。**一様な面は変わらない** — 赤と青をずらして読んでも、
    /// 読む先が同じ色だからである。
    ///
    /// アルファは 3 枚の平均 (a + a + a) / 3 で、3 での割り算は 2 進で閉じない。近似の割り算
    /// (fast math) を通るので、単精度の 1 目盛り (1.2e-7) ぶん下がって 1 未満になりうる。
    /// 許す幅は 1e-6 で、赤・青を別の成分から読んだとき (ここでは 0.25 以上) より 5 桁小さい。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("色ずれは、一様な面を変えない")
    func fringeLeavesAUniformSurfaceAlone() throws {
        let color = Premultiplied(0.75, 0.5, 0.25)
        let canvas = try makeCanvas(width: 33, height: 33)
        let pixels = try uniform(color, [.fringe(amount: 1)], on: canvas)
        // ずれがいちばん大きい角と、辺と、中心
        for (x, y) in [(0, 0), (32, 32), (0, 16), (16, 0), (16, 16), (5, 27)] {
            Self.expectBracketed(pixels[x, y], color, slack: 1e-6, "(\(x), \(y))")
        }
    }

    /// 1 画素ごとに色の替わる縦縞。**わずかでもずらして読めば、隣の縞の色が混ざる。**
    private func stripes(on canvas: Canvas, _ effects: [Effect]) throws -> PixelBuffer {
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0.5, blue: 1))
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            for x in stride(from: 0, to: canvas.target.width, by: 2) {
                canvas.rect(Float(x), 0, 1, Float(canvas.target.height))
            }
            canvas.effects(effects)
        }
        return try canvas.target.readPixels()
    }

    /// 完了条件 4 の前半 ([#1384])。**画面の中心は変わらない** — ずれ幅は中心からの隔たりに
    /// 比例し、中心で 0 になる。
    ///
    /// 奇数の画素数の面なら、真ん中の画素の中心が画面の中心に一致する。縞は 1 画素ごとに
    /// 替わるので、中心から 1 画素隣 (ずれ幅は 0.04 画素) でも隣の縞の色が混ざる — そちらが
    /// 変わることも見て、縞が「ずれ」を見分けられる絵であることを確かめる。
    ///
    /// 許す幅は上の一様な面と同じ理由で 1e-6。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("色ずれは、画面の中心の画素を変えない")
    func fringeLeavesTheCentreAlone() throws {
        let canvas = try makeCanvas(width: 33, height: 33)
        let plain = try stripes(on: canvas, [])
        let shifted = try stripes(on: canvas, [.fringe(amount: 1)])

        let centre = Self.channels(plain[16, 16])
        Self.expectBracketed(
            shifted[16, 16], Premultiplied(centre[0], centre[1], centre[2], alpha: centre[3]),
            slack: 1e-6, "中心")

        // 隣の画素は変わる (赤と青に隣の縞が混ざる)
        for x in [15, 17] {
            let before = Self.channels(plain[x, 16])
            let after = Self.channels(shifted[x, 16])
            #expect(abs(after[0] - before[0]) > 0.01, "(\(x), 16) の赤が変わっていない")
            #expect(abs(after[2] - before[2]) > 0.01, "(\(x), 16) の青が変わっていない")
            // 緑はずらさない
            #expect(after[1] == before[1], "(\(x), 16) の緑が変わった")
        }
    }

    // MARK: - にじみ

    /// 暗い色だけの絵。**どの成分も 0.625 以下**なので、どの重みで輝度を取っても
    /// (重みはどれも正で和が 1) しきい値 0.7 を越えない。
    private func dimScene(on canvas: Canvas, brightSpot: Bool, _ effects: [Effect]) throws
        -> PixelBuffer
    {
        try canvas.draw {
            canvas.background(.linear(red: 0.25, green: 0.125, blue: 0.5))
            canvas.noStroke()
            canvas.fill(.linear(red: 0.625, green: 0.5, blue: 0.375))
            canvas.circle(20, 20, 18)
            canvas.fill(.linear(red: 0.5, green: 0.625, blue: 0.125))
            canvas.rect(34, 30, 24, 20)
            if brightSpot {
                canvas.fill(.linear(red: 1, green: 1, blue: 1))
                canvas.rect(44, 8, 4, 4)
            }
            canvas.effects(effects)
        }
        return try canvas.target.readPixels()
    }

    /// 完了条件 4 の後半 ([#1384])。**しきい値未満だけの絵は 1 ビットも変わらない** —
    /// 種を取る段が `max(Y − しきい値, 0)` で明るさを削るので、足す光が厳密に 0 になる
    /// (0 をぼかしても 0、元へ 0 を足しても元のまま)。完全一致で比べられる。
    ///
    /// 明るい点を 1 つ足すと変わることも見る — 変わらないのが「しきい値のせい」であって、
    /// にじみが効いていないせいではないことを確かめる。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("にじみは、しきい値未満だけの絵を変えない")
    func bloomLeavesAPictureBelowTheThresholdAlone() throws {
        let canvas = try makeCanvas(width: 64, height: 64)
        let bloom = Effect.bloom(amount: 1, threshold: 0.7, radius: 12)

        let plain = try dimScene(on: canvas, brightSpot: false, [])
        let bloomed = try dimScene(on: canvas, brightSpot: false, [bloom])
        #expect(Set(plain.components).count > 3, "絵が一様 — 比べる前提が崩れている")
        #expect(bloomed == plain, "しきい値未満の絵が変わった")

        let lit = try dimScene(on: canvas, brightSpot: true, [])
        let litBloomed = try dimScene(on: canvas, brightSpot: true, [bloom])
        #expect(litBloomed != lit, "しきい値を越える点があるのに、にじみが効いていない")
    }

    // MARK: - 利用者の効果

    /// 利用者の効果の組。断片の本体と、面の色から導いた期待値。
    nonisolated struct UserFormula: Sendable, CustomTestStringConvertible {
        let note: String
        let body: String
        let values: [String: Float]
        /// 画素 (x, y) の期待値。
        let expected: @Sendable (_ x: Int, _ y: Int, _ color: Premultiplied) -> Premultiplied

        var testDescription: String { note }

        static let all = [
            UserFormula(
                note: "赤を 0 にし、緑へ青を・青へ緑の gain 倍を置く",
                body: """
                    float4 effect(Pixel in, Values values) {
                        return float4(0.0, in.color.b, in.color.g * values.gain, in.color.a);
                    }
                    """,
                values: ["gain": 0.5],
                expected: { _, _, c in Premultiplied(0, c.blue, c.green * 0.5, alpha: c.alpha) }),
            // 位置は画素の中心で、左上が原点 (`Pixel.position` の doc)。1/16 は 2 進で閉じる
            UserFormula(
                note: "位置は画素の中心・左上が原点",
                body: """
                    float4 effect(Pixel in, Values values) {
                        return float4(in.position.x * 0.0625, in.position.y * 0.0625, 0.0, 1.0);
                    }
                    """,
                values: [:],
                expected: { x, y, _ in
                    Premultiplied((Double(x) + 0.5) / 16, (Double(y) + 0.5) / 16, 0)
                }),
        ]
    }

    /// 完了条件 5 ([#1384])。組み込みと同じ規約 (`float4 effect(Pixel in, Values values)`) で
    /// 書いた既知の式が、画素の値をそのとおりに作る。値の口 (`values`) と位置の口
    /// (`Pixel.position`) も通す。
    ///
    /// [#1384]: https://github.com/mokume-metal/mokume/issues/1384
    @Test("利用者の効果は、書いた式どおりの値を出す", arguments: UserFormula.all)
    func userEffectMatchesItsFormula(_ formula: UserFormula) throws {
        let color = Premultiplied(0.25, 0.5, 0.75, alpha: 0.75)
        let canvas = try makeCanvas()
        let shader = try canvas.makeEffect(
            formula.body, values: formula.values.mapValues { .number($0) })
        let pixels = try uniform(color, [.custom(shader)], on: canvas)
        for (x, y) in [(0, 0), (8, 8), (15, 3), (2, 13)] {
            let expected = formula.expected(x, y, color)
            try Self.requireRepresentable(expected.channels)
            Self.expectExact(pixels[x, y], expected, "(\(x), \(y)) \(formula.note)")
        }
    }
}
