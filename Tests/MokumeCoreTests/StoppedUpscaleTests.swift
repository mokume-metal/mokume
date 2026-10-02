// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 描く細かさを下げた面で、止まっている間に描く先を変えたとき、出力段がそれを出す ([#1882])。
///
/// **出す先は、描く先を拡大の段が広げて書く絵である。** 拡大が積まれるのはフレームの終わりの
/// 描き切りだけなので、止まっている間のコールバックが描く先を変えても (画素を書く・図形や絵を
/// 置いて描き切らせる)、出す先は次に描くフレームまで変える前の絵のままだった。細かさ 1 は描く先が
/// 出す先そのものなので、同じ操作がその場で出る。直す前の出力段は、細かさを下げた面の出す先の
/// 写しを書き戻すだけで、描く先には触らなかった。
///
/// 止まっている間のコールバックは、面の上では持ち越しの区間 (``Canvas/carriesOver``) である。
/// ここではその印を立てて模す (出す先を読む口が頭で追い付く形)。ランタイムがコールバックを配った
/// 直後に追い付く形と、窓・共有の面が読む出す先は `StoppedUpscaleOutletsTests`、ランタイムを通す
/// `save()` は `EffectStoppedChangeTests` が見る。
///
/// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
@Suite(
    "止まっている間に変えた描く先と、細かさを下げた面の出力段",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct StoppedUpscaleTests {
    private static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)

    /// 出す大きさ 160×160 の面。細かさ 1 なら描く先と出す先は同じ 1 枚である。
    private static func makeCanvas(density: Float, upscale: Upscale = .spatial) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 160, height: 160)
        if density == 1 { return try Canvas(target: output, gpu: gpu) }
        return try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: upscale)
    }

    /// 1 枚目: 下地を塗る。効果を頼めば、下地に周辺減光を通す。
    private static func firstFrame(_ canvas: Canvas, effects: Bool) throws {
        try canvas.draw {
            canvas.background(235)
            if effects { canvas.effects([.vignette(amount: 0.6)]) }
        }
    }

    /// 止まっている間のコールバックを模す (持ち越しの区間の印を立てる)。
    private static func whileStopped(_ canvas: Canvas, _ body: () -> Void) {
        canvas.carriesOver = true
        defer { canvas.carriesOver = false }
        body()
    }

    /// 描く画素の中央に 4×4 の赤を `set` する。**位置は描く画素で数える。**
    private static func writeRedBlock(on canvas: Canvas) {
        let centre = (x: canvas.pixelWidth / 2, y: canvas.pixelHeight / 2)
        for y in centre.y - 2..<centre.y + 2 {
            for x in centre.x - 2..<centre.x + 2 { canvas.set(x, y, red) }
        }
    }

    /// 出力段を通った絵の (80, 80)。**出口が受け取るのと同じ道**である。
    private static func shown(_ canvas: Canvas) throws -> DisplayImage {
        try canvas.output.encodeToImage().read()
    }

    private static func isRed(_ image: DisplayImage) -> Bool {
        let point = image[80, 80]
        return point.red > 200 && point.green < 30 && point.blue < 30
    }

    /// 止まっている間に描く先を変える口。
    enum Change: CaseIterable, CustomTestStringConvertible {
        /// 画素を 4×4 書く。
        case writeBlock
        /// 円を置いて、画素を読む口で描き切らせる。
        case circleThenRead
        // 描き場所を置いて、その描き場所を描き直す口は、ここに無い。描き直す直前に置いた側を
        // 描き切らせていたが、置いた時点の絵を写しに取る形にした (#1656 の案 A2) ので、描く先を
        // 変えない。止まっている間のその形は ``aLayerPlacedAndRedrawnWhileStoppedShowsNextFrame``
        // が見る

        var testDescription: String {
            switch self {
            case .writeBlock: "画素を書く"
            case .circleThenRead: "円を置いて読む"
            }
        }
    }

    /// 細かさ × 効果の有無 × 変え方 の 1 通り。
    struct Scenario: CustomTestStringConvertible {
        let density: Float
        let effects: Bool
        let change: Change

        var testDescription: String {
            "細かさ \(density)・\(effects ? "周辺減光あり" : "効果なし")・\(change.testDescription)"
        }

        nonisolated static var all: [Scenario] {
            [Float(1), 0.5].flatMap { density in
                [false, true].flatMap { effects in
                    Change.allCases.map { Scenario(density: density, effects: effects, change: $0) }
                }
            }
        }
    }

    /// `change` を、止まっている間に加えるまでを済ませた面。
    private static func changedWhileStopped(
        density: Float, effects: Bool, change: Change, upscale: Upscale = .spatial
    ) throws -> Canvas {
        let canvas = try makeCanvas(density: density, upscale: upscale)
        try firstFrame(canvas, effects: effects)
        whileStopped(canvas) {
            switch change {
            case .writeBlock:
                writeRedBlock(on: canvas)
            case .circleThenRead:
                canvas.noStroke()
                canvas.fill(red)
                canvas.circle(80, 80, 40)
                _ = canvas.get(0, 0)
            }
        }
        return canvas
    }

    // MARK: - 置いて描き直した描き場所は、次のフレームに出る (#1656)

    /// 止まっている間に描き場所を置いて描き直しても、置いた側は描き切られない (#1656 の案 A2)。
    /// 置いたものは持ち越され、**次のフレームで、置いた時点の絵 (描き直す前の緑) が出す先に出る** —
    /// 細かさを下げた面では拡大の段を通って出る。止まっている間は、出す先は変わらない。
    @Test(
        "止まっている間に描き場所を置いて描き直すと、出す先にはその場では出ず、次のフレームで置いた時点の絵が出る",
        arguments: [Float(1), 0.5], [false, true])
    func aLayerPlacedAndRedrawnWhileStoppedShowsNextFrame(density: Float, effects: Bool) throws {
        let canvas = try Self.makeCanvas(density: density)
        let layer = try canvas.createGraphics(40, 40)
        layer.beginDraw()
        layer.background(LinearRGBA.linear(red: 0, green: 1, blue: 0))
        layer.endDraw()
        try Self.firstFrame(canvas, effects: effects)
        let before = try Self.shown(canvas)[80, 80]
        let mark = canvas.settleMark
        Self.whileStopped(canvas) {
            canvas.image(layer, 60, 60)
            layer.beginDraw()
            layer.background(Self.red)
            layer.endDraw()
        }
        #expect(canvas.settleMark == mark, "止まっている間に、置いた側が描き切られた")
        let stopped = try Self.shown(canvas)[80, 80]
        #expect(stopped == before, "止まっている間に出す先が変わった: \(stopped)")

        try canvas.draw {}
        let next = try Self.shown(canvas)[80, 80]
        #expect(
            next.green > 200 && next.red < 30 && next.blue < 30,
            "次のフレームに、置いた時点の絵が出ていない: \(next)")
    }

    // MARK: - 出す先に出る

    /// 完了条件 1〜3 — 止まっている間に変えたものが、出力段の絵に出る。細かさ 1 と同じ結果になる。
    ///
    /// 直す前は、細かさ 0.5 の (80, 80) が下地の (235, 235, 235) のままだった。
    @Test(
        "止まっている間に変えたものは、出力段の絵に出る (細かさ 1 と同じ)",
        arguments: Scenario.all)
    func changesReachTheOutputStage(scenario: Scenario) throws {
        let canvas = try Self.changedWhileStopped(
            density: scenario.density, effects: scenario.effects, change: scenario.change)
        let point = try Self.shown(canvas)[80, 80]

        #expect(
            point.red > 200 && point.green < 30 && point.blue < 30,
            "変えたものが出力段に出ていない: \(point)")
    }

    /// 完了条件 3 — 出力段を通した後に描き直しても、書いた画素は残り、効果は焼き込まれない。
    ///
    /// 出力段の追い付きは、写しを描く先へ書き戻す。効果を通す前の絵 (次のフレームの入り) へも
    /// 同じく写さないと、次のフレームの頭が控えを戻して、書いた画素が消える。
    @Test("追い付きは、書いた画素を効果を通す前の絵にも写す", arguments: [Float(1), 0.5])
    func catchingUpKeepsWhatWasWrittenForTheNextFrame(density: Float) throws {
        let canvas = try Self.changedWhileStopped(
            density: density, effects: true, change: .writeBlock)
        _ = try Self.shown(canvas)
        try canvas.draw {}
        let drawn = try canvas.target.readPixels()
        let centre = (x: canvas.pixelWidth / 2, y: canvas.pixelHeight / 2)
        #expect(drawn[centre.x, centre.y].red > 0.99 && drawn[centre.x, centre.y].green < 0.01)

        // 隅は周辺減光が最も効くところで、書いていない。2 枚目は効果を頼まないので下地の値に戻る
        let untouched = try Self.makeCanvas(density: density)
        try Self.firstFrame(untouched, effects: true)
        try untouched.draw {}
        let plain = try untouched.target.readPixels()
        #expect(drawn[3, 3] == plain[3, 3], "隅に効果が焼き込まれた: \(drawn[3, 3].red)")
    }

    // MARK: - 変えたときだけ払う

    /// 完了条件 4 — 変えないなら、出力段は拡大を積み直さない。読むだけでも積まない。
    @Test("止まっている間に変えなければ、出力段を何度通しても拡大を積み直さない", arguments: [false, true])
    func paysNothingWithoutAChange(effects: Bool) throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        try Self.firstFrame(canvas, effects: effects)
        let framePasses = canvas.effectPassesEncoded

        Self.whileStopped(canvas) { _ = canvas.get(40, 40) }
        for _ in 0..<3 { _ = try Self.shown(canvas) }

        #expect(canvas.effectPassesEncoded == framePasses, "変えていないのに拡大を積み直した")
    }

    /// 変えたら、出力段を何度通しても 1 度だけ積む。
    @Test(
        "止まっている間に変えたら、出力段を何度通しても拡大を積むのは 1 度だけ",
        arguments: [false, true], Change.allCases)
    func paysOnceForAChange(effects: Bool, change: Change) throws {
        let canvas = try Self.changedWhileStopped(density: 0.5, effects: effects, change: change)
        let before = canvas.effectPassesEncoded
        for _ in 0..<3 { _ = try Self.shown(canvas) }

        #expect(canvas.effectPassesEncoded - before == 1, "拡大を積んだ回数が 1 でない")
    }

    /// 回しているフレームは、出力段を通しても追い付かない (フレームの終わりの拡大が済んでいる)。
    @Test("回しているフレームは、出力段を通しても拡大を積み足さない", arguments: [false, true])
    func runningFramesPayNothingExtra(effects: Bool) throws {
        func run(reading: Bool) throws -> Int {
            let canvas = try Self.makeCanvas(density: 0.5)
            for index in 0..<4 {
                try canvas.draw {
                    canvas.background(235)
                    if effects { canvas.effects([.vignette(amount: 0.6)]) }
                    // フレームの途中で画素を読み、書く (途中の描き切りが旗を立てても、
                    // 終わりの描き切りが下ろす)
                    canvas.set(index, index, Self.red)
                    _ = canvas.get(80, 80)
                }
                if reading { _ = try Self.shown(canvas) }
            }
            return canvas.effectPassesEncoded
        }
        #expect(try run(reading: true) == run(reading: false), "回しているフレームで拡大を積み足した")
    }

    /// 細かさ 1 は拡大の段そのものを持たない。
    @Test("細かさ 1 は、止まっている間に変えても拡大を積まない")
    func aFullDensitySurfacePaysNoUpscale() throws {
        let canvas = try Self.changedWhileStopped(density: 1, effects: false, change: .writeBlock)
        _ = try Self.shown(canvas)
        #expect(canvas.upscaleStage == nil)
        #expect(canvas.effectPassesEncoded == 0)
    }

    // MARK: - 時間方向

    /// 時間方向でも、止まっている間の追い付きは履歴と混ぜない拡大である。
    ///
    /// 履歴と混ぜると重み 0.2 で変えた分が薄まる。揺らしの位相 (`framesScaled`) も進めない。
    @Test("時間方向: 追い付きは履歴と混ぜず、揺らしの位相を進めない")
    func temporalUpscaleCatchesUpWithoutHistory() throws {
        let canvas = try Self.makeCanvas(density: 0.5, upscale: .temporal)
        for _ in 0..<3 { try Self.firstFrame(canvas, effects: false) }
        let stage = try #require(canvas.upscaleStage)
        let scaled = stage.framesScaled
        #expect(scaled >= 2, "重みが 0.2 になるまで積んでいない")

        Self.whileStopped(canvas) { Self.writeRedBlock(on: canvas) }
        let point = try Self.shown(canvas)[80, 80]

        #expect(
            point.red > 200 && point.green < 30 && point.blue < 30,
            "変えた分が履歴と混ざって薄まった: \(point)")
        #expect(stage.framesScaled == scaled, "追い付きが揺らしの位相を進めた")
    }

    // MARK: - 失敗系

    /// 追い付きを組み立てられなければ、出力段が投げる。**古い絵を黙って返さない。** 投げた回は
    /// 書き戻しも「済んだ」ことにしないので、直ったあとの出力段には書いた画素が出る。
    @Test("追い付きを組み立てられなかった回は、書いた画素を失わず、次の出力段に出る")
    func aFailedCatchUpLosesNothing() throws {
        let canvas = try Self.changedWhileStopped(density: 0.5, effects: false, change: .writeBlock)

        canvas.failEffectPassForTesting = 0
        #expect(throws: RenderFailure.self) { _ = try canvas.output.encodeToImage() }
        #expect(canvas.target.hasPendingPixelWrites, "投げた回で書き込み待ちが下りた")
        #expect(canvas.needsOutputEnlargement, "投げた回で追い付きが済んだことになった")

        canvas.failEffectPassForTesting = nil
        #expect(Self.isRed(try Self.shown(canvas)), "直ったあとの出力段に書いた画素が出ていない")
        #expect(!canvas.target.hasPendingPixelWrites)
        #expect(!canvas.needsOutputEnlargement)
    }

    // MARK: - CPU の読み出し

    /// 出す先を CPU で読む口 (`readPixels()`・`encodeForDisplay()`・`writePNG(to:)` の元) も、
    /// 止まっている間に変わった描く先を広げ直してから読む。出力段と食い違わない。
    @Test("CPU で読む出す先にも、止まっている間に変えたものが出る", arguments: Change.allCases)
    func cpuReadsTheCaughtUpPicture(change: Change) throws {
        let canvas = try Self.changedWhileStopped(density: 0.5, effects: false, change: change)
        let read = try canvas.output.readPixels()[80, 80]

        #expect(read.red > 0.9 && read.green < 0.1 && read.blue < 0.1, "CPU の読み出しに出ていない: \(read)")
    }

    // MARK: - 時間方向の位置

    /// 出す先の絵の、暗い矩形の左の縁と上の縁の位置 (出す画素・小数)。
    ///
    /// 暗い所の量を縁をまたぐ幅で足して、縁からの距離に直す。sRGB の階調のまま足すので絶対の位置には
    /// 偏りがあるが、**同じ縁の 2 つの絵の差**を見るぶんには揃う。
    private static func edges(of image: DisplayImage) -> (left: Double, top: Double) {
        func dark(_ x: Int, _ y: Int) -> Double { 1 - Double(image[x, y].red) / 255 }
        var left = 0.0
        for x in 30..<50 { left += dark(x, 70) }
        var top = 0.0
        for y in 40..<60 { top += dark(70, y) }
        return (50 - left, 60 - top)
    }

    /// 時間方向で、止まっている間に離れた所を変えても、変えていない場所の絵は動かない。
    ///
    /// 時間方向は描く位置をフレームごとに画素の内側で揺らし、広げるときに戻す。追い付きが戻さずに
    /// 広げると、揺らしの分 (最大で描く画素 0.5 個 = 出す画素 1 個) だけ絵全体がずれた。8 枚目の
    /// 揺らしは横 -0.4375・縦 +0.389 (描く画素) で、ずれが最も大きい枚のひとつである。
    @Test("時間方向: 追い付きは最後のフレームの揺らしを戻して、変えていない場所を動かさない")
    func temporalCatchUpKeepsTheUnchangedPicturePut() throws {
        let canvas = try Self.makeCanvas(density: 0.5, upscale: .temporal)
        for _ in 0..<8 {
            try canvas.draw {
                canvas.background(255)
                canvas.noStroke()
                canvas.fill(LinearRGBA.linear(red: 0, green: 0, blue: 0))
                canvas.rect(40, 50, 60, 40)
            }
        }
        let before = Self.edges(of: try Self.shown(canvas))
        #expect(abs(before.left - 40) < 2 && abs(before.top - 50) < 2, "前提: 縁が矩形の位置にある \(before)")

        // 矩形から離れた隅を 1 画素だけ変える
        Self.whileStopped(canvas) { canvas.set(2, 2, Self.red) }
        let after = Self.edges(of: try Self.shown(canvas))

        #expect(abs(after.left - before.left) < 0.3, "左の縁が動いた: \(before.left) → \(after.left)")
        #expect(abs(after.top - before.top) < 0.3, "上の縁が動いた: \(before.top) → \(after.top)")
    }

    // MARK: - 拡大が積めなかったフレーム

    /// フレームの終わりの拡大は、失敗しても投げない。**積めなかったのに「広げた」ことにしない** —
    /// 出す先は古い絵のままなので、次に出力段が読むときに広げ直す。
    @Test("拡大が積めなかったフレームの後は、出力段が広げ直す")
    func afterAFailedUpscaleTheOutputStageCatchesUp() throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        try Self.firstFrame(canvas, effects: false)

        // 拡大の段は枠 0。効果は頼まないので、このフレームで積む段はそれだけ
        canvas.failEffectPassForTesting = 0
        try canvas.draw {
            canvas.background(235)
            canvas.noStroke()
            canvas.fill(Self.red)
            canvas.circle(80, 80, 40)
        }
        canvas.failEffectPassForTesting = nil

        #expect(canvas.needsOutputEnlargement, "拡大が積めなかったのに、追い付いたことになった")
        #expect(Self.isRed(try Self.shown(canvas)), "積めなかったフレームの絵が、出力段に出ていない")
        #expect(!canvas.needsOutputEnlargement)
    }
}
