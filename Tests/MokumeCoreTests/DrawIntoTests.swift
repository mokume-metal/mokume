// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `draw(into:)` は、閉包の間だけスケッチの口を描き場所へ向ける ([#2454])。
///
/// 約束は 4 つ。**描き場所の画素が `pg.draw { }` に `pg.` を付けて書いたときと同じ** / **閉包の中の描画は本体に
/// 出ない** / **フレームは `pg.draw { }` と同じ規則で開く** / **抜けると向き先は 1 つ前へ戻る** (入れ子)。
/// 期待は同じ手順を `pg.` 付きで書いた別の実行から作り、検査の対象と同じ口から作らない。
///
/// [#2454]: https://github.com/mokume-metal/mokume/issues/2454
@Suite(
    "draw(into:)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct DrawIntoTests {
    // 目印の色は作業空間の原色 (`.linear`) で書く。純色のまま 255 / 0 に出るので期待値をそのまま書ける
    // (`fill(255, 0, 0)` は表示色なので、画素の絶対値を比べる所では使わない — GraphicsTests と同じ)
    private static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private static let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    private static let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
    private static let yellow = LinearRGBA.linear(red: 1, green: 1, blue: 0)

    /// 台本を最初の `draw()` で 1 度だけ走らせるスケッチ。本体は 64×64。
    final class Probe: Sketch {
        var settings: SketchSettings = {
            var settings = SketchSettings(width: 64, height: 64)
            // 刻みを毎回ちょうど 1 / fps にする (粒の数が実時間で揺れない)
            settings.clock = .frames
            return settings
        }()
        /// 描き場所 (32×16)。`setup()` で作る
        var pad: Canvas?
        /// 描き場所 (本体と同じ 64×64)。`setup()` で作る
        var layer: Canvas?
        /// 直に作った面。`setup()` で作る
        var direct: Canvas?
        /// `pad` の粒 (`setup()` で作る。粒は枚をまたいで生きるので、台本の外に持つ)
        var dust: Particles?
        var script: ((Probe) -> Void)?
        /// `setup()` の終わりに走らせる台本 (描き場所を作った後)
        var setupScript: ((Probe) -> Void)?
        /// 走らせているランタイム。閉包の中の `canvas` は向き先なので、本体の面はここから引く
        weak var runtime: SketchRuntime?

        init() {}

        func setup() {
            pad = try? createGraphics(32, 16)
            layer = try? createGraphics(64, 64)
            let gpu = canvas.gpu
            dust = try? pad?.makeParticles(count: 64)
            direct = try? Canvas(target: RenderTarget(gpu: gpu, width: 32, height: 32), gpu: gpu)
            setupScript?(self)
        }

        func draw() {
            background(20)
            script?(self)
        }

        /// 本体向けに書いた描く関数。`trail.` を付けない
        func brush() {
            noStroke()
            fill(255, 102, 51, 40)
            circle(20, 20, 24)
        }
    }

    /// 台本を走らせる。`frames` 枚の `draw()` が済んだところで返る。
    @discardableResult
    private func run(
        frames: Int = 1, setup: ((Probe) -> Void)? = nil, _ script: @escaping (Probe) -> Void
    ) throws -> (probe: Probe, runtime: SketchRuntime) {
        let probe = Probe()
        probe.script = script
        probe.setupScript = setup
        let runtime = try SketchRuntime(sketch: probe, gpu: try RenderDevice())
        probe.runtime = runtime
        runtime.start()
        for _ in 0..<frames { try runtime.advance() }
        #expect(probe.pad != nil && probe.layer != nil && probe.direct != nil, "描き場所を作れていない")
        return (probe, runtime)
    }

    private func image(of canvas: Canvas?) throws -> DisplayImage {
        try #require(canvas).output.encodeForDisplay()
    }

    // MARK: - 例 (完了条件 1)

    @Test("draw(into:) の後の画素は、pg に `pg.` を付けて書いたときと同じで、本体には出ない")
    func intoMatchesTheExplicitFormAndStaysOffTheMain() throws {
        let into = try run { probe in
            probe.draw(into: probe.layer!) { probe.brush() }
        }
        let explicit = try run { probe in
            let layer = probe.layer!
            try? layer.draw {
                layer.noStroke()
                layer.fill(255, 102, 51, 40)
                layer.circle(20, 20, 24)
            }
        }
        let drawn = try image(of: into.probe.layer)
        #expect(drawn == (try image(of: explicit.probe.layer)), "`pg.` 付きで書いた絵と画素が違う")
        // 同じ空の絵どうしでも一致するので、円の中心が塗られたことも見る
        #expect(drawn[20, 20] != (0, 0, 0, 0), "描き場所の円が描かれていない")
        #expect(drawn[60, 60] == (0, 0, 0, 0), "円の外は透明のまま")

        // 本体は `background(20)` のまま。`image(layer, …)` を呼ぶまで出ない
        let main = try image(of: into.runtime.canvas)
        #expect(main[20, 20] == main[60, 60], "閉包の中の描画が本体の面に出た")
    }

    // MARK: - フレームの開き方 (完了条件 2)

    /// 3 つの場合 — 閉じている・`beginDraw()` で開いている・形の組み立ての中。
    enum Situation: CaseIterable, CustomTestStringConvertible {
        case closed
        case openedByBeginDraw
        case insideShape

        var testDescription: String {
            switch self {
            case .closed: "閉じているフレーム"
            case .openedByBeginDraw: "beginDraw() で開いているフレームの中"
            case .insideShape: "形の組み立ての中"
            }
        }
    }

    /// 場合ごとの結果。画素と、フレームの規則が言う注意と、描き切った数。
    private struct Outcome: Equatable {
        var image: DisplayImage
        var callInsideFrame: String?
        var frameStartInsideShape: String?
        var framesDrawn: Int
    }

    /// 同じ手順を、`draw(into:)` (`viaInto`) か `pg.draw { }` で走らせる。
    private func outcome(_ situation: Situation, viaInto: Bool) throws -> Outcome {
        let result = try run { probe in
            let layer = probe.layer!
            let paint: () -> Void = {
                if viaInto {
                    probe.draw(into: layer) {
                        probe.noStroke()
                        probe.fill(255, 0, 0)
                        probe.rect(8, 8, 16, 16)
                    }
                } else {
                    try? layer.draw {
                        layer.noStroke()
                        layer.fill(255, 0, 0)
                        layer.rect(8, 8, 16, 16)
                    }
                }
            }
            switch situation {
            case .closed:
                paint()
            case .openedByBeginDraw:
                layer.beginDraw()
                paint()
                layer.endDraw()
            case .insideShape:
                let shape = layer.createShape { paint() }
                try? layer.draw {
                    layer.noStroke()
                    layer.fill(0, 255, 0)
                    layer.shape(shape, 0, 0)
                }
            }
        }
        let layer = try #require(result.probe.layer)
        return Outcome(
            image: try image(of: layer),
            callInsideFrame: layer.warnings.message(for: .frameCallInsideDraw),
            frameStartInsideShape: layer.warnings.message(for: .frameStartInsideShape),
            framesDrawn: layer.framesDrawn)
    }

    @Test(
        "フレームは pg.draw { } と同じ規則で開く。画素も注意も描き切った数も同じ",
        arguments: Situation.allCases)
    func theFrameFollowsTheRulesOfCanvasDraw(_ situation: Situation) throws {
        let into = try outcome(situation, viaInto: true)
        let explicit = try outcome(situation, viaInto: false)
        #expect(into == explicit, "\(situation) で draw { } と違う")
        // 場合ごとに、規則が働いた印が出ている (同じ「何も起きない」どうしで一致していない)
        switch situation {
        case .closed:
            #expect(into.callInsideFrame == nil && into.frameStartInsideShape == nil)
            #expect(into.framesDrawn == 1)
        case .openedByBeginDraw:
            #expect(into.callInsideFrame != nil, "開いているフレームの続きとして走らせる注意が出ない")
        case .insideShape:
            #expect(into.frameStartInsideShape != nil, "組み立ての中でフレームを始めない注意が出ない")
        }
    }

    // MARK: - 切り替わる口 (完了条件 3)

    @Test("width / height は描き場所の大きさで、描き場所の全面を塗る。入力は本体のまま")
    func widthAndHeightFollowThePad() throws {
        var inside: (Float, Float, Float, Float)?
        var outside: (Float, Float, Float, Float)?
        let result = try run { probe in
            outside = (probe.width, probe.height, probe.mouseX, probe.mouseY)
            probe.draw(into: probe.pad!) {
                probe.background(255)
                probe.noStroke()
                probe.fill(Self.red)
                probe.rect(0, 0, probe.width, probe.height)
                inside = (probe.width, probe.height, probe.mouseX, probe.mouseY)
            }
        }
        #expect(outside?.0 == 64 && outside?.1 == 64)
        #expect(inside?.0 == 32 && inside?.1 == 16, "閉包の中の width / height が描き場所の大きさでない")
        #expect(inside?.2 == outside?.2 && inside?.3 == outside?.3, "入力が本体のものから変わった")
        let pad = try image(of: result.probe.pad)
        #expect(pad[0, 0] == (255, 0, 0, 255))
        #expect(pad[31, 15] == (255, 0, 0, 255), "描き場所の全面が塗られていない (本体の大きさで塗っていない)")
    }

    @Test("閉包の中の effects() は描き場所の効果になり、本体の効果は書き換わらない")
    func effectsGoToThePad() throws {
        var padEffects = -1
        var mainEffects = -1
        let result = try run { probe in
            probe.draw(into: probe.pad!) {
                probe.effects([.blur(radius: 4)])
                padEffects = probe.pad!.pendingEffects.count
                mainEffects = probe.runtime!.canvas.pendingEffects.count
            }
        }
        #expect(padEffects == 1, "描き場所に効果が載っていない")
        #expect(mainEffects == 0, "本体の効果が書き換わった")
        #expect(result.runtime.canvas.pendingEffects.isEmpty)
    }

    @Test("閉包の中の filter() は描き場所の絵にその場で掛かり、本体の絵には掛からない (#2455)")
    func filterGoesToThePad() throws {
        let result = try run { probe in
            probe.draw(into: probe.layer!) {
                probe.background(255)
                probe.filter([.invert()])
            }
        }
        let layer = try image(of: result.probe.layer)
        #expect(layer[10, 10] == (0, 0, 0, 255), "描き場所の白が反転していない")
        let main = try image(of: result.runtime.canvas)
        #expect(main[10, 10].red < 100, "本体の下地が反転した")
    }

    @Test("閉包の中の orbitControl() は描き場所の視点を書き、本体の視点は変えない")
    func orbitControlWritesThePadCamera() throws {
        var padCenter: Float = -1
        let result = try run { probe in
            // 既定の視点は面の中央を見ているので、見る先を別の値へ置いて、書いた先を見分ける
            probe.orbit.center = Vector3(5, 7, 0)
            probe.draw(into: probe.pad!) {
                probe.orbitControl()
                padCenter = probe.pad!.currentCamera.center.x
            }
        }
        #expect(padCenter == 5, "視点が描き場所へ書かれていない")
        #expect(result.runtime.canvas.currentCamera.center.x != 5, "本体の視点が書き換わった")
    }

    @Test("閉包の中の emit は、描き場所のフレームへ粒を出す")
    func emitGoesIntoThePad() throws {
        let result = try run(frames: 3) { probe in
            probe.draw(into: probe.pad!) {
                probe.noStroke()
                probe.fill(Self.red)  // 粒の色は向き先の塗りから来る
                probe.emit(
                    probe.dust!, from: .point(16, 8), rate: 3000, speed: 0...0, life: 5...5,
                    size: 8...8)
                probe.particles(probe.dust!)
            }
        }
        #expect(result.probe.dust != nil, "粒を作れていない")
        let pad = try image(of: result.probe.pad)
        let pixel = pad[16, 8]
        #expect(pixel.3 > 0, "描き場所に粒が描かれていない")
        #expect(pixel.0 > 200 && pixel.1 < 50 && pixel.2 < 50, "粒の色が向き先の塗りでない: \(pixel)")
        let main = try image(of: result.runtime.canvas)
        #expect(main[32, 32] == main[2, 2], "粒が本体に出た")
    }

    // MARK: - 入れ子と混在 (完了条件 4)

    @Test("入れ子では内側の向き先が立ち、抜けると 1 つ前へ戻る。`pg.` 付きの呼び出しは指した先へ行く")
    func nestingRestoresTheOuterTargetAndExplicitCallsStay() throws {
        var heads: [Bool] = []
        let result = try run { probe in
            let outer = probe.layer!
            let inner = probe.pad!
            let other = probe.direct!
            probe.draw(into: outer) {
                probe.noStroke()
                probe.fill(Self.red)
                probe.rect(0, 0, 10, 10)  // outer へ
                probe.draw(into: inner) {
                    heads.append(probe.canvas === inner)
                    probe.fill(Self.green)
                    probe.rect(0, 0, 10, 10)  // inner へ
                }
                heads.append(probe.canvas === outer)  // 抜けたら outer へ戻る
                probe.fill(Self.blue)
                probe.rect(20, 20, 10, 10)  // outer へ
                other.beginDraw()
                other.noStroke()
                other.fill(Self.yellow)
                other.rect(0, 0, 10, 10)  // 指して書いたので other へ
                other.endDraw()
            }
            heads.append(probe.canvas !== outer && probe.canvas !== inner)  // 閉包の外は本体
        }
        #expect(heads == [true, true, true])
        let outer = try image(of: result.probe.layer)
        #expect(outer[4, 4] == (255, 0, 0, 255), "外側の rect が外側の描き場所へ行っていない")
        #expect(outer[24, 24] == (0, 0, 255, 255), "内側を抜けた後の rect が外側へ戻っていない")
        let inner = try image(of: result.probe.pad)
        #expect(inner[4, 4] == (0, 255, 0, 255), "内側の rect が内側の描き場所へ行っていない")
        let other = try image(of: result.probe.direct)
        #expect(other[4, 4] == (255, 255, 0, 255), "指して書いた呼び出しが指した面へ行っていない")
        let main = try image(of: result.runtime.canvas)
        #expect(main[4, 4] == main[60, 60], "閉包の中の描画が本体の面に出た")
    }

    // MARK: - 置き場の書き込み (完了条件 5)

    @Test("noiseSeed は本体の置き場へ書く。作った描き場所は元から共有し、直に作った面へ向けても閉包の間だけ借りる")
    func noiseSeedGoesToTheSketchStore() throws {
        var before: ValueNoise?
        var afterGraphics: ValueNoise?
        var insideDirect: ValueNoise?
        var afterDirectMain: ValueNoise?
        var afterDirect: ValueNoise?
        var directOwn: ValueNoise?
        try run { probe in
            before = probe.canvas.noiseSettings
            directOwn = probe.direct!.noiseSettings
            probe.draw(into: probe.layer!) { probe.noiseSeed(42) }
            afterGraphics = probe.canvas.noiseSettings
            if let before { probe.canvas.noiseSettings = before }
            probe.draw(into: probe.direct!) {
                probe.noiseSeed(42)
                probe.noiseDetail(2, 0.3)
                insideDirect = probe.direct!.noiseSettings
            }
            afterDirectMain = probe.canvas.noiseSettings
            afterDirect = probe.direct!.noiseSettings
        }
        #expect(afterGraphics != before, "createGraphics で作った描き場所は本体と置き場を共有するので、本体の種が変わる")
        // 直に作った面へ向けても、種はスケッチに 1 つ (#1503)。書き込みは本体の置き場へ届き、面は閉包の間だけ借りる
        #expect(afterDirectMain?.seed == 42 && afterDirectMain?.octaves == 2, "直に作った面への書き込みが本体の置き場へ届かない")
        #expect(insideDirect == afterDirectMain, "閉包の間、直に作った面がスケッチの置き場を読んでいない")
        #expect(afterDirect == directOwn, "閉包を抜けても、直に作った面が借りた置き場のまま")
    }

    @Test("直に作った面へ向けた閉包の中の noise() は、本体と同じ種で引く")
    func noiseReadsTheSketchSeedForADirectSurface() throws {
        var insideValue: Float = -1
        var bodyValue: Float = -1
        var ownValue: Float = -1
        try run { probe in
            probe.noiseSeed(7)
            bodyValue = probe.noise(1.3, 2.1)
            ownValue = probe.direct!.noise(1.3, 2.1)  // 直に作った面が自分の種で引いた値
            probe.draw(into: probe.direct!) { insideValue = probe.noise(1.3, 2.1) }
        }
        #expect(bodyValue != ownValue, "検査が成り立たない: 本体と直に作った面の種が同じ")
        #expect(insideValue == bodyValue, "閉包の中の noise() が本体と別の種で引いた")
    }

    @Test("直に作った面へ向けた閉包の中の粒の刻みと時刻は、スケッチのものを読む")
    func stepAndTimeFollowTheSketchForADirectSurface() throws {
        var timeInside: Float = -1
        var mainTime: Float = -1
        var stepEqual = false
        var stepEqualAfter = true
        let result = try run(frames: 3) { probe in
            let direct = probe.direct!
            let main = probe.runtime!.canvas
            probe.draw(into: direct) {
                stepEqual = direct.frameStep == main.frameStep
                timeInside = direct.time
            }
            stepEqualAfter = direct.frameStep == main.frameStep
            mainTime = main.time
        }
        #expect(result.probe.direct != nil)
        #expect(stepEqual, "閉包の間、直に作った面の刻みがスケッチの刻みでない")
        #expect(!stepEqualAfter, "閉包を抜けても、直に作った面が借りた刻みのまま")
        #expect(mainTime > 0 && timeInside == mainTime, "閉包の間、直に作った面の時刻がスケッチの時刻でない")
    }

    // MARK: - 道具の状態 (orbitControl)

    @Test("orbitControl() を描き場所の閉包から先に呼んでも、道具の始まりと戻り先は本体の面の中央")
    func orbitStartsFromTheMainSurface() throws {
        var readInside: Vector3?
        let result = try run { probe in
            probe.draw(into: probe.pad!) {
                readInside = probe.orbit.center
                probe.orbitControl()
            }
        }
        let start = Orbit.fitting(width: 64, height: 64)  // 本体は 64×64、描き場所は 32×16
        #expect(readInside == start.center, "閉包の中で読んだ道具の始まりが本体の面の中央でない")
        #expect(result.runtime.orbit?.center == start.center, "道具の状態が描き場所の中央で作られた")
        #expect(result.runtime.orbitHome?.center == start.center, "戻り先が描き場所の中央になった")
    }

    @Test("setup() から描き場所の閉包で呼んだ orbitControl() は、本体と同じく断り、道具の状態を進めない")
    func orbitControlInSetupRefusesLikeTheMain() throws {
        let plain = try run(frames: 0, setup: { $0.orbitControl() }) { _ in }
        let into = try run(frames: 0, setup: { probe in
            probe.draw(into: probe.pad!) { probe.orbitControl() }
        }) { _ in }
        for (name, result) in [("素の呼び出し", plain), ("draw(into:) の中", into)] {
            #expect(result.runtime.orbit == nil && result.runtime.orbitHome == nil, "\(name) が道具の状態を進めた")
            #expect(
                result.runtime.canvas.warnings.hasWarned(Canvas.OutsideFrame.camera.warning),
                "\(name) が本体のフレームの外だと言わなかった")
        }
    }

    // MARK: - 粒の繰り越し (呼んだ順)

    @Test("同じ粒へ本体と閉包の中から出しても、繰り越しは呼んだ順に分かれる")
    func cadenceSplitsByCallOrderAcrossSurfaces() throws {
        var fromMain = 0
        var fromInto = 0
        try run(frames: 6) { probe in
            let dust = probe.dust!
            // 描き場所のフレームを 1 回余分に進めて、面ごとの描き切りの数が本体より先へ行くようにする
            probe.draw(into: probe.pad!) {}
            var mark = dust.cursor
            probe.emit(dust, from: .point(16, 8), rate: 30, speed: 0...0, life: 5...5, size: 1...1)
            fromMain += dust.cursor - mark
            probe.draw(into: probe.pad!) {
                mark = dust.cursor
                probe.emit(dust, from: .point(16, 8), rate: 30, speed: 0...0, life: 5...5, size: 1...1)
                fromInto += dust.cursor - mark
            }
        }
        // 毎フレーム 0.5 個ずつ繰り越すので、6 フレームでどちらも 3 個。1 つの繰り越しを取り合うと片方が飢える
        #expect(fromMain == 3 && fromInto == 3, "噴き口ごとの繰り越しが分かれていない (本体 \(fromMain)・閉包 \(fromInto))")
    }

    // MARK: - 本体の面を渡したとき

    @Test("本体の面を渡しても、フレームを開き直さない。setup() からも本体のフレームは余分に回らない")
    func passingTheMainSurfaceDoesNotOpenAFrame() throws {
        var ranInSetup = false
        var framesAfterSetup = -1
        var insideIsMain = false
        var warnedInFrame = true
        var drewInto: Canvas?
        let result = try run(
            frames: 1,
            setup: { probe in
                probe.draw(into: probe.runtime!.canvas) { ranInSetup = true }
                framesAfterSetup = probe.runtime!.canvas.framesDrawn
            }
        ) { probe in
            let main = probe.runtime!.canvas
            probe.draw(into: main) {
                insideIsMain = probe.canvas === main
            }
            warnedInFrame = main.warnings.hasWarned(.frameCallInsideDraw)
            // 入れ子の中から本体へ戻る
            probe.draw(into: probe.pad!) {
                probe.draw(into: main) { drewInto = probe.canvas }
            }
        }
        #expect(ranInSetup, "setup() の中で閉包が走らない")
        #expect(framesAfterSetup == 0, "setup() の中で本体のフレームが余分に回った")
        #expect(insideIsMain)
        #expect(!warnedInFrame, "本体のフレームの中で、フレームの呼び出しの注意が出た")
        #expect(drewInto === result.runtime.canvas, "入れ子の中から本体へ戻れない")
        #expect(result.runtime.canvas.framesDrawn == 1, "本体のフレームが 1 回でない")
    }

    // MARK: - 失敗系

    @Test("走っていない所から呼んでも落ちず、閉包は走らない")
    func outsideARunItDoesNothing() throws {
        let result = try run { _ in }
        // `run` は 1 フレームを描いて返るので、ランタイムはもう差されていない
        var ran = false
        result.probe.draw(into: try #require(result.probe.layer)) { ran = true }
        #expect(!ran, "走っていないのに閉包が走った")
    }

    // MARK: - Canvas の force (完了条件 6)

    @Test("Canvas の force は可変長でも配列でも同じ力を積む")
    func variadicForceMatchesTheArrayForm() throws {
        var variadic = -1
        var array = -1
        try run { probe in
            guard let layer = probe.layer, let dust = try? layer.makeParticles(count: 8) else { return }
            layer.beginDraw()
            layer.force(dust, .gravity(0, 10), .drag(0.5))
            variadic = dust.pendingForceCount
            layer.force(dust, [.gravity(0, 10), .drag(0.5)])
            array = dust.pendingForceCount - variadic
            layer.endDraw()
        }
        #expect(variadic == 2, "可変長の force が 2 つの力を積んでいない")
        #expect(array == 2, "配列の force が 2 つの力を積んでいない")
    }
}
