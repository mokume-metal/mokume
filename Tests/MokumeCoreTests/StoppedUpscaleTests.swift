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

    /// 出す先を CPU で読む口 (`readPixels()`) も、
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

    // MARK: - 時間方向の位置: フレームの外で描いた図形 (#1913)

    /// 揺らしを掛けて描く列の種類。`rg -n "jittered\(" Sources` が見つけていた口 (列を閉じる 4 か所)
    /// に当たる図形を 1 つずつ選ぶ。面の置き換え (`background()` の周囲) は面全体を覆うので、縁を測れない。
    enum JitteredPath: CaseIterable, CustomTestStringConvertible {
        /// 基本図形の列 (`rect`)。
        case form
        /// 平面の列 (`triangle`)。
        case flat
        /// 立体の列 (保持した形の `plane`)。
        case solid

        var testDescription: String {
            switch self {
            case .form: "基本図形"
            case .flat: "平面"
            case .solid: "立体"
            }
        }
    }

    /// 黒い 60×30 の `plane` を保持した形。保持した形は組み立てた時点の塗りを持つので、塗りも中で決める。
    private static func darkPlane(on canvas: Canvas) -> Shape {
        canvas.createShape {
            canvas.noStroke()
            canvas.fill(LinearRGBA.linear(red: 0, green: 0, blue: 0))
            canvas.plane(60, 30)
        }
    }

    /// 左上の角が (`x`, `y`) で、そこから右へ 60・下へ 30 の縁を持つ黒い図形を置く。`plane` は保持した
    /// 形を真ん中へ置く — 変換はフレームの外では効かないが、形を置く位置は効く。
    private static func placeDark(
        _ path: JitteredPath, on canvas: Canvas, plane: Shape, x: Float, y: Float
    ) {
        canvas.noStroke()
        canvas.fill(LinearRGBA.linear(red: 0, green: 0, blue: 0))
        switch path {
        case .form: canvas.rect(x, y, 60, 30)
        case .flat: canvas.triangle(x, y, x + 60, y, x, y + 30)
        case .solid: canvas.shape(plane, x + 30, y + 15)
        }
    }

    /// 縁の位置 (出す画素・小数)。`row` の行の `xs` と、`column` の列の `ys` で、暗い所の量を縁から
    /// の距離に直す (``edges(of:)`` と同じ測り方)。
    private static func edges(
        of image: DisplayImage, row: Int, xs: Range<Int>, column: Int, ys: Range<Int>
    ) -> (left: Double, top: Double) {
        func dark(_ x: Int, _ y: Int) -> Double { 1 - Double(image[x, y].red) / 255 }
        let left = xs.reduce(0.0) { $0 + dark($1, row) }
        let top = ys.reduce(0.0) { $0 + dark(column, $1) }
        return (Double(xs.upperBound) - left, Double(ys.upperBound) - top)
    }

    /// 完了条件 1 — 時間方向で、止まっている間に置いて描き切らせた矩形は、同じ矩形をフレームの中で
    /// 描いた面と同じ位置に出る。
    ///
    /// 止まっている間の描き切りの絵は、追い付きが最後のフレームの揺らしを戻して広げる (#1914)。直す前は
    /// 次のフレームの揺らしで描いていたので、2 つの揺らしの差だけずれた (実測で最大 横 1.6・縦 1.2
    /// 出す画素。式から見込んだのは 横 0.8125・縦 0.556 描く画素)。
    ///
    /// 基本図形は縁を画素の内側で塗り分けるので、揺らしの差がそのまま縁の位置に出る。平面・立体は
    /// 縁を画素の中心で切るので、何枚も重ねた絵と 1 枚の絵は揺らしの選び方によらず食い違う — そちらは
    /// 同じ絵の中で揃うかを見る (``temporalShapesDrawnWhileStoppedLineUpWithTheLastFrame(path:frames:)``)。
    @Test(
        "時間方向: 止まっている間に置いて描き切らせた矩形は、フレームの中で描いたのと同じ位置に出る",
        // 揺らしの 1 周 (``UpscaleStage/jitterPeriod``)
        arguments: 1...8)
    func temporalRectDrawnWhileStoppedLinesUp(frames: Int) throws {
        func edges(placedWhileStopped: Bool) throws -> (left: Double, top: Double) {
            let canvas = try Self.makeCanvas(density: 0.5, upscale: .temporal)
            let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
            for _ in 0..<frames {
                try canvas.draw {
                    canvas.background(255)
                    guard !placedWhileStopped else { return }
                    canvas.noStroke()
                    canvas.fill(black)
                    canvas.rect(40, 50, 60, 40)
                }
            }
            if placedWhileStopped {
                Self.whileStopped(canvas) {
                    canvas.noStroke()
                    canvas.fill(black)
                    canvas.rect(40, 50, 60, 40)
                    _ = canvas.get(0, 0)
                }
            }
            return Self.edges(of: try Self.shown(canvas))
        }
        let inFrame = try edges(placedWhileStopped: false)
        #expect(
            abs(inFrame.left - 40) < 2 && abs(inFrame.top - 50) < 2, "前提: 縁が矩形の位置にある \(inFrame)")
        let stopped = try edges(placedWhileStopped: true)

        #expect(abs(stopped.left - inFrame.left) < 0.3, "左の縁がずれた: \(inFrame.left) → \(stopped.left)")
        #expect(abs(stopped.top - inFrame.top) < 0.3, "上の縁がずれた: \(inFrame.top) → \(stopped.top)")
    }

    /// 完了条件 2 — 揺らしを掛ける口のすべて (基本図形・平面・立体) で、止まっている間に置いて描き切らせた
    /// 図形は、最後のフレームに描いた同じ図形と、追い付いた出す先の上で揃う。
    ///
    /// 最後のフレームで上に図形を描き、止まっている間にちょうど 60 下 (描く画素 30 個) へ同じ図形を置いて
    /// 描き切らせる。同じ揺らしで描いて同じ揺らしで戻すなら、2 つの縁は同じ位置に出る。縁は描く画素の
    /// 中心 (出す画素の奇数) に置く — 平面・立体は縁を画素の中心で切るので、そこに置かないと揺らしの差が
    /// 絵に出ない。
    @Test(
        "時間方向: 止まっている間に置いて描き切らせた図形は、最後のフレームに描いた絵と揃う",
        arguments: JitteredPath.allCases, 1...8)
    func temporalShapesDrawnWhileStoppedLineUpWithTheLastFrame(path: JitteredPath, frames: Int) throws {
        let canvas = try Self.makeCanvas(density: 0.5, upscale: .temporal)
        let plane = Self.darkPlane(on: canvas)
        for _ in 0..<frames {
            try canvas.draw {
                canvas.background(255)
                Self.placeDark(path, on: canvas, plane: plane, x: 41, y: 21)
            }
        }
        Self.whileStopped(canvas) {
            Self.placeDark(path, on: canvas, plane: plane, x: 41, y: 81)
            _ = canvas.get(0, 0)
        }
        let image = try Self.shown(canvas)
        let drawn = Self.edges(of: image, row: 26, xs: 31..<51, column: 50, ys: 11..<31)
        let placed = Self.edges(of: image, row: 86, xs: 31..<51, column: 50, ys: 71..<91)
        #expect(
            abs(drawn.left - 41) < 2 && abs(drawn.top - 21) < 2, "前提: 縁が図形の位置にある \(drawn)")

        #expect(abs(placed.left - drawn.left) < 0.3, "左の縁がずれた: \(drawn.left) → \(placed.left)")
        #expect(
            abs(placed.top - 60 - drawn.top) < 0.3, "上の縁がずれた: \(drawn.top) → \(placed.top - 60)")
    }

    /// 完了条件 3 — 止まっている間に置いても描き切らせなければ、図形は次のフレームの描き切りで描かれ、
    /// そのフレームの終わりの拡大が戻す揺らしで揃う。止まっている間に列を閉じても (混ぜ方の切り替え)
    /// 同じである。
    ///
    /// **揺らしを選ぶのは、列を閉じる時点ではなく描き切る時点である。** 閉じる時点の状態 (持ち越しの
    /// 区間か) で最後のフレームの揺らしを選ぶと、ここが新しくずれる。フレームの中で置いた面と同じ操作に
    /// なるので、出す先の絵はバイト単位で一致する。縁は完了条件 2 と同じく描く画素の中心に置く。
    @Test(
        "時間方向: 止まっている間に置いて次のフレームで描いた図形は、フレームの中で置いたのと同じ絵になる",
        arguments: JitteredPath.allCases, [false, true])
    func temporalShapesCarriedOverLineUp(path: JitteredPath, closesWhileStopped: Bool) throws {
        func shown(frames: Int, placedWhileStopped: Bool) throws -> DisplayImage {
            let canvas = try Self.makeCanvas(density: 0.5, upscale: .temporal)
            let plane = Self.darkPlane(on: canvas)
            for _ in 0..<frames { try canvas.draw { canvas.background(255) } }
            if placedWhileStopped {
                Self.whileStopped(canvas) {
                    Self.placeDark(path, on: canvas, plane: plane, x: 41, y: 51)
                    if closesWhileStopped {
                        canvas.blendMode(.multiply)
                        canvas.blendMode(.blend)
                    }
                }
                try canvas.draw {}
            } else {
                try canvas.draw { Self.placeDark(path, on: canvas, plane: plane, x: 41, y: 51) }
            }
            return try Self.shown(canvas)
        }
        // ずれの大きい枚 (横は 2・7、縦は 2・8)
        for frames in [2, 7, 8] {
            let inFrame = try shown(frames: frames, placedWhileStopped: false)
            #expect(inFrame[70, 60].red < 255, "前提: 図形が出ている (\(frames) 枚)")
            let carried = try shown(frames: frames, placedWhileStopped: true)
            #expect(carried == inFrame, "フレームの中で置いた絵と違う (\(frames) 枚)")
        }
    }

    /// ``edges(of:)`` を、図形の中 (70, 70) の暗さで割ったもの。**図形が履歴と混ざって薄いとき**に使う —
    /// 暗い所の量は暗さに比例するので、割らないと縁のずれも同じ割合で縮んで見える。
    private static func scaledEdges(of image: DisplayImage) -> (left: Double, top: Double) {
        let inside = 1 - Double(image[70, 70].red) / 255
        let edges = edges(of: image)
        return (50 - (50 - edges.left) / inside, 60 - (60 - edges.top) / inside)
    }

    /// 止まっている間に描き切らせた図形は、**描く先の上で、最後のフレームに描いた図形と同じ絵になる**
    /// (反証の指摘 1〜3)。
    ///
    /// 描く先に残った絵は、次に描くフレームの終わりの拡大が描く先の全体を同じ量 (次のフレームの揺らし)
    /// だけ戻して広げる。だから描く先で同じ絵なら、追い付きでも、塗り直さない次のフレームでも、効果の
    /// 前の控え (同じ列・同じ値で描く) でも、奥行き (同じ描き切りが書く) でも、最後のフレームの絵と
    /// 同じに扱われる。直す前は次のフレームの揺らしで描いたので、ここが食い違った。
    @Test(
        "時間方向: 止まっている間に描き切らせた図形は、描く先の上で最後のフレームに描いた図形と同じ絵になる",
        arguments: JitteredPath.allCases, [2, 7, 8])
    func temporalShapesDrawnWhileStoppedMatchTheLastFrameOnTheTarget(
        path: JitteredPath, frames: Int
    ) throws {
        func drawn(placedWhileStopped: Bool) throws -> PixelBuffer {
            let canvas = try Self.makeCanvas(density: 0.5, upscale: .temporal)
            let plane = Self.darkPlane(on: canvas)
            for index in 0..<frames {
                try canvas.draw {
                    canvas.background(255)
                    if !placedWhileStopped && index == frames - 1 {
                        Self.placeDark(path, on: canvas, plane: plane, x: 41, y: 51)
                    }
                }
            }
            if placedWhileStopped {
                Self.whileStopped(canvas) {
                    Self.placeDark(path, on: canvas, plane: plane, x: 41, y: 51)
                    _ = canvas.get(0, 0)
                }
            }
            return try canvas.target.readPixels()
        }
        let lastFrame = try drawn(placedWhileStopped: false)
        #expect(lastFrame[35, 30].red < 0.01, "前提: 図形が描く先にある")
        #expect(try drawn(placedWhileStopped: true) == lastFrame, "最後のフレームに描いた絵と違う")
    }

    /// 止まっている間に描き切らせた図形は、**塗り直さない次のフレームでは、描く先に残った絵と一緒に
    /// 揺らしの差だけずれる** (反証の指摘 1)。時間方向の代償で、直さない。
    ///
    /// 時間方向の拡大は履歴を位置で合わせ直さない (`Builtin.metal` の `kEffectAccumulate` は、その回の
    /// 揺らしを戻して広げた絵と前の結果を混ぜるだけ)。だから塗り直さないスケッチでは、前のフレームに
    /// 描いて描く先に残った絵は、次のフレームで「描いたときの揺らし − 次の揺らし」だけずれて混ざる。
    /// 止まっている間に描き切らせた図形もその 1 つになる (直す前は、止まっている間の絵の上で同じ大きさ
    /// だけ逆にずれていた)。ここでは、その量が 2 つの揺らしの差 (出す画素へ 2 倍) どおりであることを
    /// 固定する。基本図形だけを見る — 縁を画素の内側で塗り分けるので、ずれがそのまま縁に出る。
    @Test(
        "時間方向: 止まっている間に描き切らせた図形は、塗り直さない次のフレームで、残った絵と同じだけずれる",
        arguments: [2, 7, 8])
    func temporalShapesDrawnWhileStoppedShiftWithTheOldPictureNextFrame(frames: Int) throws {
        func edges(placedWhileStopped: Bool) throws -> (
            edges: (left: Double, top: Double), shift: SIMD2<Float>
        ) {
            let canvas = try Self.makeCanvas(density: 0.5, upscale: .temporal)
            let plane = Self.darkPlane(on: canvas)
            for _ in 0..<frames { try canvas.draw { canvas.background(255) } }
            let stage = try #require(canvas.upscaleStage)
            // 描く先に残った絵が次のフレームでずれる量 (出す画素)
            let shift = (stage.lastJitter - stage.jitter) * 2
            if placedWhileStopped {
                Self.whileStopped(canvas) {
                    Self.placeDark(.form, on: canvas, plane: plane, x: 40, y: 50)
                    _ = canvas.get(0, 0)
                }
                try canvas.draw {}
            } else {
                // 比べる相手: 次のフレームの中で同じ図形を描く (ずれない)
                try canvas.draw { Self.placeDark(.form, on: canvas, plane: plane, x: 40, y: 50) }
            }
            return (Self.scaledEdges(of: try Self.shown(canvas)), shift)
        }
        let (inFrame, shift) = try edges(placedWhileStopped: false)
        let (stopped, _) = try edges(placedWhileStopped: true)
        let moved = (left: stopped.left - inFrame.left, top: stopped.top - inFrame.top)

        #expect(
            abs(moved.left - Double(shift.x)) < 0.35,
            "横のずれが揺らしの差と違う: \(moved.left) (揺らしの差 \(shift.x))")
        #expect(
            abs(moved.top - Double(shift.y)) < 0.35,
            "縦のずれが揺らしの差と違う: \(moved.top) (揺らしの差 \(shift.y))")
    }

    /// 完了条件 4 — フレームの外の描き切りの揺らしが変わるのは、時間方向で 1 枚以上広げた後だけである。
    /// 空間方向は揺らさず、1 枚も広げる前の時間方向は最後のフレームの揺らしが次のものと同じなので、
    /// 落とす行列はバイト単位でこれまでと同じになる。
    @Test("空間方向と 1 枚も広げる前の時間方向では、フレームの外の描き切りもフレームの中と同じ揺らしで描く")
    func jitterOutsideAFrameDiffersOnlyAfterAnUpscale() throws {
        let spatial = try Self.makeCanvas(density: 0.5, upscale: .spatial)
        try Self.firstFrame(spatial, effects: false)
        #expect(spatial.jitter(drawingInFrame: false) == .zero)
        #expect(spatial.jitter(drawingInFrame: true) == .zero)

        let temporal = try Self.makeCanvas(density: 0.5, upscale: .temporal)
        let stage = try #require(temporal.upscaleStage)
        #expect(stage.framesScaled == 0)
        #expect(temporal.jitter(drawingInFrame: false) == temporal.jitter(drawingInFrame: true))

        // 1 枚広げた後は、フレームの外の描き切りだけが最後のフレームの揺らしで描く
        try Self.firstFrame(temporal, effects: false)
        #expect(temporal.jitter(drawingInFrame: true) == stage.jitter)
        #expect(temporal.jitter(drawingInFrame: false) == stage.lastJitter)
        #expect(stage.lastJitter != stage.jitter)
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
