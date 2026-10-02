// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 効果の引数を受け口で検める ([#1544])。GPU を要する。
///
/// 効果は毎フレーム呼ばれる口なので、受け取れない値でも落とさず、安全な側へ倒す
/// ([ADR-0020] 決定 5)。直す前は `invert(amount: .nan)` 1 つでフレームの 25600 画素が
/// すべて NaN になり、`blur(radius: 1e30)` のように**有限の値でも**同じことが起きていた。
///
/// 絵は `readPixels()` の線形の値で見る。「壊れた画素」は、成分のどれかが NaN か無限の
/// 画素である。
///
/// [#1544]: https://github.com/mokume-metal/mokume/issues/1544
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
@Suite(
    "効果の引数を受け口で検める",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct EffectArgumentTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
    }

    /// 起票時の再現の絵。下地の灰に、明るい色の矩形を 1 つ置く。
    private static func scene(on canvas: Canvas) {
        canvas.background(128)
        canvas.fill(255, 200, 40)
        canvas.rect(40, 40, 80, 80)
    }

    /// 効果を掛けて描いた 1 枚。
    private func picture(_ effects: [Effect], on canvas: Canvas) throws -> PixelBuffer {
        try canvas.draw {
            Self.scene(on: canvas)
            canvas.effects(effects)
        }
        return try canvas.output.readPixels()
    }

    /// ビット列の違う成分の数。0 なら**バイトで同じ**である (`Float16` の `==` は 0 と -0 を
    /// 区別せず、NaN どうしを違うと言う)。
    ///
    /// 並びを `#expect(a == b)` で比べない。外れたとき検査の枠組みが 10 万成分の差分を
    /// 組み立てようとして、何十分も戻らない。
    private static func differing(_ left: PixelBuffer, _ right: PixelBuffer) -> Int {
        guard left.components.count == right.components.count else { return .max }
        return zip(left.components, right.components).count { $0.bitPattern != $1.bitPattern }
    }

    /// 成分のどれかが NaN か無限の画素の数。
    private static func broken(_ buffer: PixelBuffer) -> Int {
        stride(from: 0, to: buffer.components.count, by: 4).count { base in
            buffer.components[base..<(base + 4)].contains { !$0.isFinite }
        }
    }

    /// 成分のどれかが負の画素の数 (作業空間の値は光の量なので、負は壊れた光である)。
    private static func negative(_ buffer: PixelBuffer) -> Int {
        stride(from: 0, to: buffer.components.count, by: 4).count { base in
            buffer.components[base..<(base + 4)].contains { $0 < 0 }
        }
    }

    // MARK: - 画素の表明 (#1812)

    // **画素の表明はこの 3 つだけを通す。** どれも、落ちたらその土台で記録された GPU の
    // 打ち切りを文面で名乗る (`RenderDevice.faultNote()`)。直に `#expect` を書くと名乗らない —
    // 専用機の merge queue で 1 度だけ落ちた赤 (#1812) は、同じ時に GPU が仕事を打ち切って
    // いたのに「27328 成分違う」としか名乗らず、console の知らせから辿り直すことになった。
    // 名乗るのは文面だけで、表明を落とす条件にはしない

    /// 2 枚がバイトで同じ。
    private static func expectSame(
        _ got: PixelBuffer, _ expected: PixelBuffer, on canvas: Canvas, _ comment: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            differing(got, expected) == 0, "\(comment)\(canvas.gpu.faultNote())",
            sourceLocation: sourceLocation)
    }

    /// NaN・無限の画素が無い。
    private static func expectWhole(
        _ buffer: PixelBuffer, on canvas: Canvas, _ comment: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(broken(buffer) == 0, "\(comment)\(canvas.gpu.faultNote())", sourceLocation: sourceLocation)
    }

    /// 負の成分を持つ画素が無い。
    private static func expectNoNegative(
        _ buffer: PixelBuffer, on canvas: Canvas, _ comment: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(negative(buffer) == 0, "\(comment)\(canvas.gpu.faultNote())", sourceLocation: sourceLocation)
    }

    /// **3 つの口のどれもが、落ちたときに打ち切りを名乗る。** 打ち切りは GPU を止めずに
    /// 記録だけ作る (#1065 の完了条件 4)。絵も GPU で描かずに組む — 落とすための絵なので、
    /// 描いて食い違わせる必要が無い。
    ///
    /// 落ちた表明は既知の失敗として受け、**文面に理由と回数が載っているものだけ**を既知と
    /// 認める。載っていなければ表明はそのまま赤として残る。口ごとに分けて受けるので、どれかの
    /// 口が落ちなくなっても (既知の失敗が 1 つも記録されない) 赤になる。
    @Test("打ち切りが記録された土台で画素の表明が落ちると、文面に回数と理由が載る")
    func aFailedPixelAssertionNamesTheRecordedFault() throws {
        let canvas = try makeCanvas()
        let reason = "Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)"
        canvas.gpu.recordCommandFaultForTesting(reason)

        let grey = PixelBuffer(width: 1, height: 1, components: [0.5, 0.5, 0.5, 1])
        let white = PixelBuffer(width: 1, height: 1, components: [1, 1, 1, 1])
        let ruined = PixelBuffer(width: 1, height: 1, components: [.nan, -1, 0, 1])
        let namesTheFault: @Sendable (Issue) -> Bool = { issue in
            let text = issue.comments.map(\.rawValue).joined()
            return text.contains(reason) && text.contains("1 回打ち切っている")
        }

        withKnownIssue("食い違いの口") {
            Self.expectSame(grey, white, on: canvas)
        } matching: { namesTheFault($0) }
        withKnownIssue("壊れた画素の口") {
            Self.expectWhole(ruined, on: canvas)
        } matching: { namesTheFault($0) }
        withKnownIssue("負の成分の口") {
            Self.expectNoNegative(ruined, on: canvas)
        } matching: { namesTheFault($0) }
    }

    // MARK: - 数でない値・無限 (完了条件 1・2)

    /// 組み込みの効果の引数 1 つ。**11 個全部を並べる** — 範囲を決めていない引数
    /// (`threshold` と `adjust` の 3 つ) も、非有限なら同じく外す。
    enum Argument: CaseIterable, CustomTestStringConvertible {
        case blurRadius
        case bloomAmount
        case bloomThreshold
        case bloomRadius
        case invertAmount
        case monochromeAmount
        case vignetteAmount
        case fringeAmount
        case adjustBrightness
        case adjustContrast
        case adjustSaturation

        var testDescription: String { "\(self)" }

        /// この引数に `value` を入れ、他は効く値にした効果。
        func effect(_ value: Float) -> Effect {
            switch self {
            case .blurRadius: .blur(radius: value)
            case .bloomAmount: .bloom(amount: value, threshold: 0.2)
            case .bloomThreshold: .bloom(amount: 0.5, threshold: value)
            case .bloomRadius: .bloom(amount: 0.5, threshold: 0.2, radius: value)
            case .invertAmount: .invert(amount: value)
            case .monochromeAmount: .monochrome(amount: value)
            case .vignetteAmount: .vignette(amount: value)
            case .fringeAmount: .fringe(amount: value)
            case .adjustBrightness: .adjust(brightness: value)
            case .adjustContrast: .adjust(contrast: value)
            case .adjustSaturation: .adjust(saturation: value)
            }
        }
    }

    /// 数でない値と、正負の無限。
    private static let nonFinite: [Float] = [.nan, .infinity, -.infinity]

    @Test(
        "数でない値・無限を受けた効果は、並びから外した絵と同じになる",
        arguments: Argument.allCases)
    func dropsAnEffectWithANonFiniteArgument(argument: Argument) throws {
        let canvas = try makeCanvas()
        let without = try picture([], on: canvas)
        for value in Self.nonFinite {
            let got = try picture([argument.effect(value)], on: canvas)
            Self.expectWhole(got, on: canvas, "\(value)")
            Self.expectSame(got, without, on: canvas, "\(value)")
        }
    }

    @Test("外すのはその効果だけで、並びの他の効果はそのまま掛かる")
    func keepsTheOtherEffectsInTheList() throws {
        let canvas = try makeCanvas()
        let expected = try picture([.monochrome()], on: canvas)
        let got = try picture([.invert(amount: .nan), .monochrome()], on: canvas)
        Self.expectWhole(got, on: canvas)
        Self.expectSame(got, expected, on: canvas)
    }

    // MARK: - 警告 (完了条件 3)

    @Test("数でない値・無限を受けたら、初回だけ言う")
    func warnsOnceAboutANonFiniteArgument() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            Self.scene(on: canvas)
            canvas.effects([.invert(amount: .nan)])
            canvas.effects([.blur(radius: .infinity)])
            canvas.effects([.invert(amount: .nan)])
        }
        try canvas.draw {
            Self.scene(on: canvas)
            canvas.effects([.adjust(contrast: -.infinity)])
        }
        #expect(canvas.warnings.hasWarned(.badEffect))
        // 文面が 1 度目のまま — 2 度目からは組み立てられていない。どの効果を外したかも読める
        let message = canvas.warnings.message(for: .badEffect)
        #expect(message?.hasPrefix("effects(): the invert effect") == true, "\(message ?? "")")
    }

    @Test("範囲の中の値と、締めるだけの値では言わない")
    func staysSilentForValuesItCanTake() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            Self.scene(on: canvas)
            canvas.effects([
                .blur(radius: 4), .bloom(amount: 0.5), .invert(amount: 2), .vignette(amount: -1),
                .blur(radius: 1e30), .adjust(brightness: 5),
            ])
        }
        #expect(!canvas.warnings.hasWarned(.badEffect))
        #expect(!canvas.warnings.hasWarned(.effectFailed))
    }

    // MARK: - 範囲の外の amount (完了条件 4)

    /// `amount` の説明は「0…1 で、1 がいちばん強い」。越えた値は 1 と同じ絵になる。
    @Test(
        "amount は 0…1 に締まる — 1 を越えた絵は 1 の絵と同じ",
        arguments: [
            (Argument.invertAmount, Float(2)),
            (Argument.vignetteAmount, Float(2)),
            (Argument.monochromeAmount, Float(2)),
            (Argument.fringeAmount, Float(3)),
            (Argument.bloomAmount, Float(3)),
        ])
    func clampsTheAmountToOne(argument: Argument, amount: Float) throws {
        let canvas = try makeCanvas()
        let full = try picture([argument.effect(1)], on: canvas)
        let over = try picture([argument.effect(amount)], on: canvas)
        Self.expectNoNegative(over, on: canvas)
        Self.expectSame(over, full, on: canvas)
    }

    @Test(
        "負の amount は、いまと同じく効果を掛けない絵になる",
        arguments: [
            Argument.invertAmount, .monochromeAmount, .vignetteAmount, .fringeAmount,
            .bloomAmount,
        ])
    func negativeAmountLeavesThePictureAlone(argument: Argument) throws {
        let canvas = try makeCanvas()
        let without = try picture([], on: canvas)
        let got = try picture([argument.effect(-1)], on: canvas)
        Self.expectSame(got, without, on: canvas)
    }

    // MARK: - 有限でも大きすぎる半径 (完了条件 5)

    @Test(
        "有限の大きな半径でも、絵が壊れない",
        arguments: [
            Effect.blur(radius: 1e30),
            .blur(radius: .greatestFiniteMagnitude),
            .bloom(amount: 0.5, radius: 1e30),
        ])
    func survivesAHugeFiniteRadius(effect: Effect) throws {
        let canvas = try makeCanvas()
        let got = try picture([effect], on: canvas)
        Self.expectWhole(got, on: canvas)
    }

    /// 締めるのは上限を越えた半径だけで、それより下の半径はそのまま段へ渡る。半径 64 以下
    /// (縮めて回す経路の上限の段まで) の絵は、これで変わらない。
    @Test("上限より下の半径は、締めずにそのまま渡す", arguments: [Float(0.5), 8, 9, 64, 1e5])
    func passesRadiiBelowTheLimitThrough(radius: Float) {
        if case .blur(let kept)? = Effect.blur(radius: radius).accepted {
            #expect(kept.bitPattern == radius.bitPattern)
        } else {
            Issue.record("blur が外された")
        }
        if case .bloom(_, _, let kept)? = Effect.bloom(amount: 0.5, radius: radius).accepted {
            #expect(kept.bitPattern == radius.bitPattern)
        } else {
            Issue.record("bloom が外された")
        }
    }

    // MARK: - 描き場所の面 (完了条件 6)

    @Test(
        "描き場所の面で受けても、貼った先の主の面は壊れない",
        arguments: [Effect.invert(amount: .nan), .blur(radius: .infinity), .blur(radius: 1e30)])
    func aGraphicsLayerDoesNotSpreadItToTheMainCanvas(effect: Effect) throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(80, 80)
        layer.beginDraw()
        layer.background(128)
        layer.fill(255, 200, 40)
        layer.rect(20, 20, 40, 40)
        layer.effects([effect])
        layer.endDraw()
        try canvas.draw {
            canvas.background(128)
            canvas.image(layer, 40, 40)
        }
        Self.expectWhole(try canvas.output.readPixels(), on: canvas)
    }
}
