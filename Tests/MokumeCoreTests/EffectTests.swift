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
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
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

    // MARK: - 並びは値

    @Test("並びの順を入れ替えると、絵が変わる")
    func theOrderOfTheListMatters() throws {
        let canvas = try makeCanvas()
        let first = try picture([.monochrome(), .adjust(saturation: 1)], on: canvas)
        let second = try picture([.adjust(saturation: 1), .monochrome()], on: canvas)
        // 単色化してから彩度を上げても戻らない。順が効いていなければ同じ絵になる
        #expect(fingerprint(first) != fingerprint(second))
    }

    /// **書き戻しの段は無い。** 最後の段が入りの絵へ直接書くので、通した段の数は並びが
    /// 宣言する段の数と等しい (#755)。
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

    /// 同じ面を読みながら描くことはできない (Metal では未定義)。最後の段が入りの絵
    /// そのものを読む並びだけ、控えへ書いてから写し戻す。
    @Test("最後の段が入りの絵そのものを読むときだけ、写し戻しの 1 段が付く")
    func copiesBackOnlyWhenTheLastPassReadsTheInput() throws {
        let canvas = try makeCanvas()
        // 1 段だけの並び: 1 + 写し戻し
        _ = try picture([.invert()], on: canvas)
        #expect(canvas.effectPassesEncoded == 2)

        canvas.effectPassesEncoded = 0
        // にじみ単独: 合成が入りの絵を読むので 4 + 写し戻し
        _ = try picture([.bloom(amount: 0.5)], on: canvas)
        #expect(canvas.effectPassesEncoded == 5)
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
        #expect(canvas.warnedEffectFailed)
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
        #expect(canvas.warnedEffectFailed)
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

        for frame in 0..<200 {
            // **値を動かし続ける。** 小数を控えのキーにしていれば、ここで増える。
            // 半径は縮め幅の境目 (8・16・32) をまたいで動かす
            ripple.set("shift", .number(Float(frame) / 2000))
            _ = try picture(
                [
                    .blur(radius: Float(frame % 50)), .bloom(amount: Float(frame % 5) / 5),
                    .custom(ripple),
                ], on: canvas)
        }

        #expect(pipeline.tablesBuilt == tables)
        #expect(pipeline.buffersBuilt == buffers)
        #expect(pipeline.scratchBuilt == scratch)
        #expect(pipeline.reducedBuilt == reduced)
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
}
