// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Testing

@testable import MokumeCore

/// 効果 (絵から絵への段)。GPU を要する。
@Suite(
    "効果",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct EffectTests {
    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 明暗と色の差がある絵。**効果が効いたかどうかが分かる**ように描く。
    private func scene(on canvas: Canvas) {
        canvas.background(.display(red: 0.02, green: 0.03, blue: 0.06))
        canvas.fill(.display(red: 1, green: 0.85, blue: 0.3))
        canvas.circle(24, 24, 26)
        canvas.fill(.display(red: 0.2, green: 0.5, blue: 1))
        canvas.rect(34, 34, 26, 22)
    }

    /// 効果をかけて描いた 1 枚。
    private func picture(_ effects: [Effect], on canvas: Canvas) throws -> [UInt8] {
        try canvas.draw {
            scene(on: canvas)
            canvas.effects(effects)
        }
        return try canvas.target.encodeForDisplay().bytes
    }

    private func fingerprint(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 数の意味

    /// **無効の値では絵が 1 ビットも変わらない。**
    ///
    /// 「0 なら効かない」を散文の約束にせず、組み込みの効果すべてについて機械で見る。
    /// 式の丸めに任せず断片の側で分岐して返しているのは、ここを厳密に見るためである。
    /// 無効の値を入れた組み込みの効果。**7 つ全部を並べる。**
    private static let idle: [(name: String, effect: Effect)] = [
        ("blur", .blur(radius: 0)),
        ("bloom", .bloom(amount: 0)),
        ("invert", .invert(amount: 0)),
        ("monochrome", .monochrome(amount: 0)),
        ("vignette", .vignette(amount: 0)),
        ("fringe", .fringe(amount: 0)),
        ("adjust", .adjust()),
    ]

    @Test("無効の値では、絵が 1 ビットも変わらない")
    func doesNothingWhenTheAmountIsZero() throws {
        let canvas = try makeCanvas()
        let plain = fingerprint(try picture([], on: canvas))
        for (name, effect) in Self.idle {
            #expect(fingerprint(try picture([effect], on: canvas)) == plain, "\(name)")
        }
    }

    /// **効かせれば必ず変わる。** 上の検査だけだと「何もしない効果」でも通ってしまう。
    /// 効かせた組み込みの効果。
    private static let working: [(name: String, effect: Effect)] = [
        ("blur", .blur(radius: 6)),
        ("bloom", .bloom(amount: 0.8, threshold: 0.2)),
        ("invert", .invert()),
        ("monochrome", .monochrome()),
        ("vignette", .vignette(amount: 0.9)),
        ("fringe", .fringe(amount: 1)),
        ("brightness", .adjust(brightness: 0.2)),
        ("contrast", .adjust(contrast: 0.5)),
        ("saturation", .adjust(saturation: -1)),
    ]

    @Test("効かせると、絵が変わる")
    func changesThePictureWhenItIsAsked() throws {
        let canvas = try makeCanvas()
        let plain = fingerprint(try picture([], on: canvas))
        for (name, effect) in Self.working {
            #expect(fingerprint(try picture([effect], on: canvas)) != plain, "\(name)")
        }
    }

    /// 完了条件「灰色の効果が、sRGB の原色で書いた色の相対輝度を返す」([#1212])。
    ///
    /// 数で書いた色は sRGB の原色の値として作業空間 (線形 Display P3) へ移る (#911)。
    /// 移った後の値に掛ける重みが作業空間の原色のものなら、灰色にした値は元の色の
    /// 相対輝度 Y — sRGB の原色なら Rec.709 の重み — に一致する。**sRGB の重みを P3 の
    /// 値に掛けていると、赤は 0.199 になって外れる。**
    ///
    /// 許容は、期待値の位置での半精度の 1 目盛り (0.2 付近で 1.2e-4・0.7 付近で 4.9e-4) と、
    /// Rec.709 の重みが 4 桁に丸めた公称値であることの 1e-4 を足したもの。
    ///
    /// [#1212]: https://github.com/mokume-metal/mokume/issues/1212
    @Test(
        "単色化した画素は、sRGB の原色で書いた色の相対輝度になる",
        arguments: [
            (SIMD3<Float>(1, 0, 0), Float(0.2126)),
            (SIMD3<Float>(0, 1, 0), Float(0.7152)),
            (SIMD3<Float>(0, 0, 1), Float(0.0722)),
        ])
    func monochromeGivesTheRelativeLuminance(primary: SIMD3<Float>, luminance: Float) throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.display(red: primary.x, green: primary.y, blue: primary.z))
            canvas.effects([.monochrome()])
        }
        let grey = try canvas.target.readPixels()[8, 8]
        let tolerance = Float(Float16(luminance).nextUp) - Float(Float16(luminance)) + 1e-4
        for (name, value) in [("red", grey.red), ("green", grey.green), ("blue", grey.blue)] {
            #expect(abs(value - luminance) <= tolerance, "\(name) = \(value)、期待は \(luminance)")
        }
    }

    // MARK: - 並びは値

    @Test("並びの順を入れ替えると、絵が変わる")
    func theOrderOfTheListMatters() throws {
        let canvas = try makeCanvas()
        let first = try picture([.monochrome(), .adjust(saturation: 1)], on: canvas)
        let second = try picture([.adjust(saturation: 1), .monochrome()], on: canvas)
        // 単色化してから彩度を上げても戻らない。順が効いていなければ同じ絵になる
        #expect(fingerprint(first) != fingerprint(second))
    }

    /// **書き戻しの段は無い。** 最後の段が描く先へ直接書くので、通した段の数は並びが
    /// 宣言する段の数と等しい (#755)。**例外は無い** — 入りの絵は控えから読むので、
    /// 最後の段が入りの絵を読む並びでも写し戻しの段は付かない (#1469)。控えへの写しは
    /// 段ではない (blit) ので、ここには数えられない。
    @Test("段の数は、並びから決まる — 書き戻しの段は付かない")
    func derivesThePassCountFromTheList() throws {
        let canvas = try makeCanvas()
        // 2 段の並び。最後の段 (単色化) が入りの絵へ書く
        _ = try picture([.invert(), .monochrome()], on: canvas)
        #expect(canvas.effectPassesEncoded == 2)

        canvas.effectPassesEncoded = 0
        // 小さなぼかしは横と縦の 2 段
        _ = try picture([.blur(radius: 2)], on: canvas)
        #expect(canvas.effectPassesEncoded == 2)

        canvas.effectPassesEncoded = 0
        // 大きなぼかしは 縮める → 横 → 縦 → 広げる の 4 段
        _ = try picture([.blur(radius: 12)], on: canvas)
        #expect(canvas.effectPassesEncoded == 4)

        canvas.effectPassesEncoded = 0
        // にじみは しきい値 + 縮める → 横 → 縦 → 合成 の 4 段。ぼかしの後ろに置けば
        // 合成の入りは控えなので、合成がそのまま入りの絵へ書く
        _ = try picture([.blur(radius: 2), .bloom(amount: 0.5)], on: canvas)
        #expect(canvas.effectPassesEncoded == 6)

        canvas.effectPassesEncoded = 0
        canvas.effectBarriersEncoded = 0
        // 頼まなければ 1 段も立たない (台帳の既存の行が動かないのはこれによる)
        _ = try picture([], on: canvas)
        #expect(canvas.effectPassesEncoded == 0)
        #expect(canvas.effectBarriersEncoded == 0)
    }

    /// 同じ面を読みながら描くことはできない (Metal では未定義)。**入りの絵は控え**なので、
    /// 最後の段が入りの絵を読む並び (1 段だけの並び・にじみ単独の合成) でも、最後の段は
    /// 描く先へ直接書ける ([#1469])。かつてはこの並びだけ控えへ書いてから写し戻す 1 段が
    /// 付いていた (#767 の例外)。
    ///
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    @Test("最後の段が入りの絵を読む並びでも、写し戻しの段は付かない")
    func addsNoCopyBackPassEvenWhenTheLastPassReadsTheInput() throws {
        let canvas = try makeCanvas()
        // 1 段だけの並び
        _ = try picture([.invert()], on: canvas)
        #expect(canvas.effectPassesEncoded == 1)

        canvas.effectPassesEncoded = 0
        // にじみ単独: しきい値 + 縮める → 横 → 縦 → 合成 の 4 段
        _ = try picture([.bloom(amount: 0.5)], on: canvas)
        #expect(canvas.effectPassesEncoded == 4)
    }

    @Test("段ごとに待つ仕掛けが積まれる")
    func waitsBetweenEveryPass() throws {
        let canvas = try makeCanvas()
        _ = try picture([.blur(radius: 3)], on: canvas)
        // 横・縦の 2 段とも、前の段の書き終わりを待つ
        #expect(canvas.effectBarriersEncoded == 2)
        #expect(canvas.effectBarriersEncoded == canvas.effectPassesEncoded)

        canvas.effectBarriersEncoded = 0
        canvas.effectPassesEncoded = 0
        // 縮めた段を挟んでも 1 段ごと
        _ = try picture([.blur(radius: 40), .bloom(amount: 0.5)], on: canvas)
        #expect(canvas.effectBarriersEncoded == canvas.effectPassesEncoded)
    }

    // MARK: - 縮めた段

    /// 半径 → 縮め幅の対応。**GPU を要さない。**
    @Test("半径が大きいほど、低い段で回す")
    func choosesTheReductionLevelFromTheRadius() {
        #expect(Effect.reductionLevel(for: 0) == 0)
        #expect(Effect.reductionLevel(for: 8) == 0)
        #expect(Effect.reductionLevel(for: 8.5) == 1)
        #expect(Effect.reductionLevel(for: 16) == 1)
        #expect(Effect.reductionLevel(for: 17) == 2)
        #expect(Effect.reductionLevel(for: 32) == 2)
        #expect(Effect.reductionLevel(for: 33) == 3)
        // 1/8 より下へは行かない
        #expect(Effect.reductionLevel(for: 10_000) == 3)
        // 壊れた値は全解像度
        #expect(Effect.reductionLevel(for: .nan) == 0)
        #expect(Effect.reductionLevel(for: .infinity) == 3)
    }

    @Test("大きなぼかしは、縮めた絵を通る")
    func blursLargeRadiiOnReducedImages() throws {
        let canvas = try makeCanvas(width: 64, height: 48)
        _ = try picture([.blur(radius: 12)], on: canvas)
        let pipeline = try canvas.effectPipeline()
        // 半径 12 は 1/2。往復の 2 枚が 1/2 で確保され、1/4 以下は 1 枚も要らない
        #expect(pipeline.reducedBuilt == 2)
        let half = try pipeline.scratch(at: 0, level: 1)
        #expect(half.width == 32)
        #expect(half.height == 24)
        #expect(half.texture.storageMode == .private)
        #expect(half.texture.pixelFormat == RenderTarget.pixelFormat)
    }

    @Test("割り切れない大きさでも、縮めた絵は 1 画素も切り捨てない")
    func roundsReducedSizesUp() throws {
        let canvas = try makeCanvas(width: 97, height: 61)
        _ = try picture([.blur(radius: 40)], on: canvas)
        let pipeline = try canvas.effectPipeline()
        // 1/8: 97 → 13 (12.1 を上へ)、61 → 8 (7.6 を上へ)
        let eighth = try pipeline.scratch(at: 0, level: 3)
        #expect(eighth.width == 13)
        #expect(eighth.height == 8)
    }

    /// 縮めた段を通っても、同じ入力からは同じ絵が出る (ADR-0001 原則 2)。
    @Test("縮めた段を通っても、同じ入力から同じ絵が出る")
    func staysDeterministicThroughReducedPasses() throws {
        // 2 で割り切れない大きさで、縮め・広げの端の扱いまで含めて見る
        let canvas = try makeCanvas(width: 97, height: 61)
        let cases: [(name: String, effects: [Effect])] = [
            ("blur 1/2", [.blur(radius: 12)]),
            ("blur 1/8", [.blur(radius: 40)]),
            ("bloom", [.bloom(amount: 0.7, threshold: 0.3, radius: 20)]),
            ("blur + bloom", [.blur(radius: 12), .bloom(amount: 0.5)]),
        ]
        for (name, effects) in cases {
            let first = fingerprint(try picture(effects, on: canvas))
            let second = fingerprint(try picture(effects, on: canvas))
            #expect(first == second, "\(name)")
        }
    }

    /// 縮め幅が変わる境目で、ぼかしの広がりが逆転しない。**半径を増やせば広がる**ことを、
    /// 明るい四角の縁から離れた画素の明るさで見る。
    @Test("半径を増やすと、段が変わっても広がりは単調に増える")
    func spreadsMonotonicallyAcrossLevels() throws {
        let canvas = try makeCanvas(width: 160, height: 96)
        var previous: Float = -1
        for radius: Float in [4, 8, 12, 16, 24, 32, 48] {
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.fill(.display(red: 1, green: 1, blue: 1))
                canvas.rect(0, 0, 80, 96)
                canvas.effects([.blur(radius: radius)])
            }
            // 縁 (x = 80) から 3 画素外。半径 4 (σ = 2) でも僅かに漏れる距離
            let outside = canvas.target.pixels[83, 48].red
            #expect(outside > previous, "radius \(radius): \(outside) <= \(previous)")
            previous = outside
        }
        // 大きくぼかしても、縁のすぐ外は真っ白にも真っ黒にもならない
        #expect(previous > 0.1 && previous < 0.9)
    }

    // MARK: - アルファ

    /// 入りと出りでアルファの表現が変わらないことを画素で見る。
    ///
    /// **半透明が暗くならない・透明が不透明を名乗らない。** 作業空間は乗算済みなので、
    /// 掛け忘れ・戻し忘れはどちらも「それらしく」壊れる。
    /// 半透明の四角だけを置いた絵。**下地は透明。**
    private func translucent(on canvas: Canvas, _ effects: [Effect]) throws {
        try canvas.draw {
            canvas.background(LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: 0))
            canvas.noStroke()
            canvas.fill(LinearRGBA(straightRed: 1, green: 0.8, blue: 0.2, alpha: 0.5))
            canvas.rect(8, 8, 16, 16)
            canvas.effects(effects)
        }
    }

    /// 乗算を戻した色。**「暗くなっていないか」はこちらで見る** — 乗算済みのままだと、
    /// 透け具合の違いと色の違いが区別できない。
    private func straight(_ color: LinearRGBA) -> (r: Float, g: Float, b: Float) {
        guard color.alpha > 0 else { return (0, 0, 0) }
        return (color.red / color.alpha, color.green / color.alpha, color.blue / color.alpha)
    }

    /// 入りと出りでアルファの表現が変わらないことを画素で見る。
    ///
    /// **透明が不透明を名乗らない。** 乗算済みの絵では、透明な画素は色も 0 でなければ
    /// ならない — 色だけ残ると、次の段や出力段でそれが薄く出る。
    @Test("透明なところは、どの効果を通しても透明のまま")
    func keepsTransparentPixelsTransparent() throws {
        for (name, effect) in Self.working {
            let canvas = try makeCanvas(width: 32, height: 32)
            try translucent(on: canvas, [effect])
            let pixels = canvas.target.pixels
            let corner = pixels[1, 1]
            #expect(corner.alpha < 0.02, "\(name)")
            #expect(corner.red < 0.02, "\(name)")
            #expect(corner.green < 0.02, "\(name)")
            #expect(corner.blue < 0.02, "\(name)")
        }
    }

    @Test("半透明の濃さは、どの効果を通しても変わらない")
    func keepsTheAlphaOfTranslucentAreas() throws {
        for (name, effect) in Self.working {
            let canvas = try makeCanvas(width: 32, height: 32)
            try translucent(on: canvas, [effect])
            // 一様な内側なので、どの効果もアルファを動かさない
            #expect(abs(canvas.target.pixels[16, 16].alpha - 0.5) < 0.03, "\(name)")
        }
    }

    /// **ぼかしはアルファを掛けたまま平均する。**
    ///
    /// 掛けずに平均すると、透明な画素の色 (0) が混ざって**縁が暗くなる**。絵としては
    /// 「それらしく」出てしまうので、縁の 1 画素を数で見る。
    @Test("ぼかしても、透明との境目が暗くならない")
    func blursWithTheAlphaStillMultiplied() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        try translucent(on: canvas, [.blur(radius: 3)])
        let edge = straight(canvas.target.pixels[8, 16])
        // 縁でも色は四角の色のまま (透明と混ざって黒へ寄っていない)
        #expect(abs(edge.r - 1) < 0.05)
        #expect(abs(edge.g - 0.8) < 0.05)
        #expect(abs(edge.b - 0.2) < 0.05)
    }

    // MARK: - 失敗

    @Test("途中で失敗したら、入りの絵がそのまま出る")
    func leavesTheInputAloneWhenAPassFails() throws {
        let canvas = try makeCanvas()
        let plain = fingerprint(try picture([], on: canvas))

        // 2 段目で失敗させる。1 段目は控えへ書いているので、**書き戻す手前で止まれば
        // 入りの絵は無傷**である
        canvas.failEffectPassForTesting = 1
        try canvas.draw {
            scene(on: canvas)
            canvas.effects([.invert(), .monochrome()])
        }
        canvas.failEffectPassForTesting = nil

        // 途中の絵 (反転だけ効いた絵) ではなく、効果をかける前の絵が出ている
        #expect(fingerprint(try canvas.target.encodeForDisplay().bytes) == plain)
        #expect(canvas.warnings.hasWarned(.effectFailed))
    }

    /// 入りの絵へ書くのは最後の 1 段だけで、その段の組み立てに失敗すれば 1 命令も
    /// 積まれない。書き戻しの段を消しても「1 度きり」は変わらない (ADR-0020 決定 5)。
    @Test("最後の段で失敗しても、入りの絵がそのまま出る")
    func leavesTheInputAloneWhenTheLastPassFails() throws {
        let canvas = try makeCanvas()
        let plain = fingerprint(try picture([], on: canvas))

        // 最後の段 (広げながら入りの絵へ書く段) の番号を数えてから、そこで失敗させる
        _ = try picture([.blur(radius: 12)], on: canvas)
        let last = canvas.effectPassesEncoded - 1
        #expect(last == 3)
        canvas.failEffectPassForTesting = last
        try canvas.draw {
            scene(on: canvas)
            canvas.effects([.blur(radius: 12)])
        }
        canvas.failEffectPassForTesting = nil

        #expect(fingerprint(try canvas.target.encodeForDisplay().bytes) == plain)
        #expect(canvas.warnings.hasWarned(.effectFailed))
    }

    // MARK: - 置き場

    /// 控えは色だけの GPU 専用の絵で、奥行きも CPU から読める置き場も伴わない (#753)。
    @Test("控えは色だけの GPU 専用の絵")
    func scratchImagesAreColourOnlyAndPrivate() throws {
        let canvas = try makeCanvas()
        _ = try picture([.blur(radius: 2)], on: canvas)
        let pipeline = try canvas.effectPipeline()
        let scratch = try pipeline.scratch(at: 0)
        #expect(scratch.texture.storageMode == .private)
        #expect(scratch.texture.buffer == nil, "控えが置き場の上に載っている")
        #expect(scratch.texture.pixelFormat == RenderTarget.pixelFormat)
    }

    @Test("長く回しても、置き場の確保が積み上がらない")
    func doesNotGrowWhileItRuns() throws {
        let canvas = try makeCanvas()
        let ripple = try canvas.makeEffect(
            """
            float4 effect(Pixel in, Values values) {
                return mokume_at(in, in.place + float2(values.shift, 0.0));
            }
            """,
            values: ["shift": 0])
        _ = try picture([.blur(radius: 2), .bloom(amount: 0.4), .custom(ripple)], on: canvas)
        let pipeline = try canvas.effectPipeline()
        // 縮め幅が変わる半径を先に全部踏んでおく (1/2・1/4・1/8 の控えと、いちばん
        // 段の多い並びの枠を揃える)
        for radius: Float in [12, 24, 48] {
            _ = try picture(
                [.blur(radius: radius), .bloom(amount: 0.4), .custom(ripple)], on: canvas)
        }
        let tables = pipeline.tablesBuilt
        let buffers = pipeline.buffersBuilt
        let scratch = pipeline.scratchBuilt
        let reduced = pipeline.reducedBuilt
        let carries = pipeline.carriesBuilt
        let restores = canvas.effectCarryRestoresEncoded

        for frame in 0..<200 {
            // **値を動かし続ける。** 小数を控えのキーにしていれば、ここで増える。
            // 半径は縮め幅の境目 (8・16・32) をまたいで動かす
            ripple.set("shift", .number(Float(frame) / 2000))
            let effects: [Effect] = [
                .blur(radius: Float(frame % 50)), .bloom(amount: Float(frame % 5) / 5),
                .custom(ripple),
            ]
            // **半分は塗り直さずに描き足す。** 効果を通す前の絵を控えから戻す経路 (#1469) も
            // 長回しの範囲に入れる
            try canvas.draw {
                if frame.isMultiple(of: 2) {
                    scene(on: canvas)
                } else {
                    canvas.circle(Float(frame % 64), 32, 6)
                }
                canvas.effects(effects)
            }
        }

        #expect(pipeline.tablesBuilt == tables)
        #expect(pipeline.buffersBuilt == buffers)
        #expect(pipeline.scratchBuilt == scratch)
        #expect(pipeline.reducedBuilt == reduced)
        #expect(pipeline.carriesBuilt == carries)
        #expect(carries == 1)
        // 塗り直さなかった 100 フレームは、どれも前のフレームの効果の後に来るので戻す
        #expect(canvas.effectCarryRestoresEncoded - restores == 100)
    }

    // MARK: - フレームの境目 (#1469)

    /// 効果を通す面。**3 つの入口は同じ `beginFrame` / `flush` を通る**ので、同じ検査を
    /// 面ごとに回す ([#1469] 完了条件 4)。
    ///
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    enum CarrySurface: CaseIterable, CustomTestStringConvertible {
        /// 本体の面。細かさ 1 なので、描く先と出す先が同じ 1 枚である。
        case main
        /// 描き場所 (`createGraphics` の面を `beginDraw()` / `endDraw()` で描く)。
        case graphics
        /// 細かさを下げた面。効果は描く先に書かれ、拡大がそこから出す先へ広げる。
        case halfDensity

        var testDescription: String {
            switch self {
            case .main: "本体の面"
            case .graphics: "描き場所"
            case .halfDensity: "細かさ 0.5 の面"
            }
        }

        /// 出す大きさ 160×160 の面を 1 つ作る。
        func make() throws -> CarryFixture {
            let gpu = try RenderDevice()
            switch self {
            case .main:
                let canvas = try CanvasFixture.make(gpu: gpu, width: 160, height: 160)
                return CarryFixture(canvas: canvas) { body in try canvas.draw { body(canvas) } }
            case .graphics:
                let host = try CanvasFixture.make(gpu: gpu, width: 160, height: 160)
                let layer = try host.createGraphics(160, 160)
                return CarryFixture(canvas: layer, host: host) { body in
                    layer.beginDraw()
                    body(layer)
                    layer.endDraw()
                }
            case .halfDensity:
                // `CanvasFixture` を通さない理由は `UpscaleTests.makeCanvas` と同じ
                // (細かさが引数なので、`Canvas(output:gpu:pixelDensity:upscale:)` を直に呼ぶ)
                let output = try RenderTarget(gpu: gpu, width: 160, height: 160)
                let canvas = try Canvas(
                    output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
                return CarryFixture(canvas: canvas) { body in try canvas.draw { body(canvas) } }
            }
        }
    }

    /// 面と、その面で 1 フレームを回す口。
    struct CarryFixture {
        let canvas: Canvas
        /// 描き場所を作った面。描き場所より先に消えないように抱える。
        let host: Canvas?
        let frame: ((Canvas) -> Void) throws -> Void

        init(
            canvas: Canvas, host: Canvas? = nil,
            frame: @escaping ((Canvas) -> Void) throws -> Void
        ) {
            self.canvas = canvas
            self.host = host
            self.frame = frame
        }

        /// 出口 (出す先) の隅 (3, 3)。**出口は効果を通した絵を受け取る。**
        func corner() throws -> LinearRGBA { try canvas.output.readPixels()[3, 3] }
    }

    /// 再現手順の下地 (`background(235)`)。
    private static func paper(_ canvas: Canvas) { canvas.background(235) }

    /// 再現手順の効果。
    private static let darkening: [Effect] = [.vignette(amount: 0.6)]

    /// 完了条件 1・4・5 — **効果は次のフレームの入りにならない。**
    ///
    /// 1 枚目だけ塗って残像を残すスケッチでも、縁が暗くなるのはフレームによらず 1 回ぶん
    /// だけである。直す前は、効果の結果が描く先に残って次のフレームの入りになり、12 枚目の
    /// 隅の赤が 0.344 から 0.00002 まで沈んでいた。出口に届く絵は変わらない — 1 枚目は
    /// 毎フレーム塗り直す版と一致し、どちらも効果を通した絵である。
    @Test(
        "塗り直さずに描き足しても、効果は次のフレームへ焼き込まれない",
        arguments: CarrySurface.allCases)
    func effectsDoNotBakeIntoTheNextFrame(surface: CarrySurface) throws {
        let trailing = try surface.make()
        let repainting = try surface.make()
        var trail: [LinearRGBA] = []
        var repainted: [LinearRGBA] = []
        for index in 0..<12 {
            try trailing.frame { canvas in
                if index == 0 { Self.paper(canvas) }
                canvas.effects(Self.darkening)
            }
            trail.append(try trailing.corner())
            try repainting.frame { canvas in
                Self.paper(canvas)
                canvas.effects(Self.darkening)
            }
            repainted.append(try repainting.corner())
        }

        let plain = try surface.make()
        try plain.frame { Self.paper($0) }
        let unaffected = try plain.corner()

        // 出口には効果が効いている (隅は下地より十分暗い)
        #expect(trail[0].red < unaffected.red * 0.6, "1 枚目の出口に効果が効いていない")
        #expect(trail[0] == repainted[0])
        for (index, value) in trail.enumerated() {
            #expect(value == trail[0], "\(index + 1) 枚目の隅が 1 枚目と違う: \(value.red)")
        }
        #expect(trail[11] == repainted[11])
    }

    /// 完了条件 2 — **書かなかったフレームには何もかからない。** 効果を書いたフレームの次に
    /// 何も書かずに回すと、出口は効果を通す前の絵に戻る。
    @Test(
        "効果を書かないフレームは、効果を通す前の絵を出す", arguments: CarrySurface.allCases)
    func aFrameWithoutEffectsShowsThePictureBeforeThem(surface: CarrySurface) throws {
        let fixture = try surface.make()
        try fixture.frame { canvas in
            Self.paper(canvas)
            canvas.effects(Self.darkening)
        }
        let affected = try fixture.corner()
        try fixture.frame { _ in }
        let next = try fixture.corner()

        let plain = try surface.make()
        try plain.frame { Self.paper($0) }
        let unaffected = try plain.corner()

        #expect(affected != unaffected, "1 枚目に効果が効いていない")
        #expect(next == unaffected, "効果を書かないフレームに効果が残った: \(next.red)")
    }

    /// 画素を読む口。
    enum NextFrameReader: CaseIterable, CustomTestStringConvertible {
        case get
        case pixels

        var testDescription: String {
            switch self {
            case .get: "get"
            case .pixels: "pixels"
            }
        }

        func read(from canvas: Canvas) -> LinearRGBA {
            switch self {
            case .get: canvas.get(3, 3)
            case .pixels: canvas.pixels[3, 3]
            }
        }
    }

    /// 完了条件 3 — 効果を通したフレームの次のフレームで、何も描かないうちに読む画素は
    /// **効果を通す前の値**である。読む口は描き切ってから描く先の写しを読むので、次の
    /// フレームの入りが効果を通した絵なら、それを読んでしまう。
    ///
    /// 比べる相手は、1 枚目の途中 (効果を通す前) に同じ口で読んだ値である — フレームの途中で
    /// 読む画素に効果が効いていないことは、説明が前から約束している。
    @Test(
        "効果を通した次のフレームで描く前に読む画素は、効果を通す前の値",
        arguments: CarrySurface.allCases, NextFrameReader.allCases)
    func pixelsReadInTheNextFrameAreBeforeTheEffect(
        surface: CarrySurface, reader: NextFrameReader
    ) throws {
        let fixture = try surface.make()
        var before = LinearRGBA.transparent
        try fixture.frame { canvas in
            Self.paper(canvas)
            before = reader.read(from: canvas)
            canvas.effects(Self.darkening)
        }
        #expect(try fixture.corner() != before, "1 枚目の出口に効果が効いていない")

        var next = LinearRGBA.transparent
        try fixture.frame { canvas in
            next = reader.read(from: canvas)
        }
        #expect(next == before, "次のフレームで読んだ画素に効果が残った: \(next.red)")
    }

    /// 完了条件 6 — **効果を頼まないフレームは何も払わない。** 控えへ写すのは効果を通す
    /// フレームだけ、控えから戻すのはその次の 1 回だけで、塗り直すフレームでは戻さない。
    ///
    /// 見るのは数である — 戻しすぎても絵は同じなので、絵では分からない。細かさを下げた面は
    /// 効果を頼まなくても拡大のために段のパイプラインが立つので、控えの有無はパイプラインの
    /// 有無ではなく控え専用の作った回数で見る。
    @Test(
        "効果を頼まないフレームは、控えを作らず、写しも戻しも積まない",
        arguments: CarrySurface.allCases)
    func carriesNothingWithoutEffects(surface: CarrySurface) throws {
        let fixture = try surface.make()
        let canvas = fixture.canvas
        var carriesBuilt: Int { canvas.effectPipelineStorage?.carriesBuilt ?? 0 }
        func stroke(_ canvas: Canvas) { canvas.circle(80, 80, 20) }

        // 効果を頼まず、塗り直さずに描き足していく
        for index in 0..<30 {
            try fixture.frame { canvas in
                if index == 0 { Self.paper(canvas) }
                stroke(canvas)
            }
        }
        #expect(carriesBuilt == 0, "効果を頼んでいないのに控えを作った")
        #expect(canvas.effectCarriesEncoded == 0)
        #expect(canvas.effectCarryRestoresEncoded == 0)

        // 効果を通したフレームの次に塗り直すなら、戻さない (戻しても消えるだけ)
        try fixture.frame { $0.effects(Self.darkening) }
        #expect(carriesBuilt == 1)
        #expect(canvas.effectCarriesEncoded == 1)
        try fixture.frame { Self.paper($0) }
        #expect(canvas.effectCarryRestoresEncoded == 0, "塗り直すフレームで控えから戻した")

        // 効果を通したフレームの次に塗り直さないフレームが続いても、戻すのは 1 回だけ
        try fixture.frame { $0.effects(Self.darkening) }
        for _ in 0..<3 { try fixture.frame { stroke($0) } }
        #expect(canvas.effectCarryRestoresEncoded == 1, "効果を通していないフレームの後にも戻した")
        #expect(canvas.effectCarriesEncoded == 2)
        #expect(carriesBuilt == 1, "控えを作り直した")
    }

    // MARK: - 利用者の効果

    @Test("利用者の効果が、平面・立体と同じ規約で書ける")
    func acceptsAUserEffectWrittenLikeTheOthers() throws {
        let canvas = try makeCanvas()
        let plain = try picture([], on: canvas)
        let tint = try canvas.makeEffect(
            """
            float4 effect(Pixel in, Values values) {
                return float4(in.color.rgb * values.gain, in.color.a);
            }
            """,
            values: ["gain": 1])
        // 何も変えない値なら、絵は 1 ビットも変わらない
        #expect(fingerprint(try picture([.custom(tint)], on: canvas)) == fingerprint(plain))

        tint.set("gain", .number(0.25))
        #expect(fingerprint(try picture([.custom(tint)], on: canvas)) != fingerprint(plain))
    }

    @Test("組み立てられない効果は、作るときに断る")
    func refusesAnEffectItCannotBuild() throws {
        let canvas = try makeCanvas()
        #expect(throws: ShaderFailure.self) {
            try canvas.makeEffect("float4 effect(Pixel in, Values values) { return")
        }
    }

    /// 完了条件「効果を壊して保存すると、観測の警告にその理由が出る」([#787])。
    ///
    /// 差し替えの失敗そのものは前から `failure` に載っていた。**載っているだけで
    /// 誰も読まなかった**ので、効果だけが黙って前の絵を出し続けていた — 見るのは
    /// `Canvas/shaderFailures` に届くところである。
    ///
    /// [#787]: https://github.com/mokume-metal/mokume/issues/787
    @Test("差し替えに失敗した効果の理由が、観測へ届く")
    func failedEffectReloadReachesObservation() throws {
        let canvas = try makeCanvas()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-effect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tint.metal")
        try "float4 effect(Pixel in, Values values) { return in.color; }"
            .write(to: url, atomically: true, encoding: .utf8)

        let effect = try canvas.loadEffect(url.path)
        try "これは MSL ではない".write(to: url, atomically: true, encoding: .utf8)
        effect.reload()

        #expect(effect.failure != nil)
        #expect(canvas.shaderFailures.count == 1, "観測へ載っていない")
        #expect(canvas.shaderFailures.first?.hasPrefix("effect tint: ") == true)
    }
}
