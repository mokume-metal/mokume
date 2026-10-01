// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing
import simd

@testable import MokumeCore

/// フレーム番号から導く時計で、粒の寿命を枚数として数える ([#1710])。GPU を要する。
///
/// 約束は、**寿命 L の粒が描かれる枚数は ⌊L·fps⌋** (L は単精度の値そのもの) である。
/// 刻みはちょうど 1/fps 秒なので、枚数は L と fps の比だけで決まり、単精度の刻み
/// `Float(1/fps)` の丸めにも、寿命から刻みを引き続ける積み重ねにも依らない ([ADR-0025]
/// 決定 6 — 揃えたいものを積分で作らない)。`emit` の数 ⌊rate·n ÷ fps⌋ ([#1640]) と同じ
/// 切り捨ての形で、L·fps が整数なら定常の粒の数がちょうど rate × L になる。
///
/// 単精度の秒を引き続ける作りでは、寿命 1 の粒が fps 24 で 23 枚・60 で 60 枚と割れ、
/// fps 1 の寿命 1 の粒は 1 枚も描かれなかった。上書きの注意も同じ丸めで、60 fps の
/// `makeParticles(count: 60)`・`rate: 60`・`life: 1...1` が 72 枚目に注意を出していた。
///
/// **1 枚の差は静止画では読めない** ので、数えるのは枚数そのものである。描かれたかは
/// 絵の画素 (粒ごとに升を分けて置く) と、GPU が書いた描く個数の両方で見る。
///
/// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
/// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
@Suite(
    "粒の寿命 (フレーム番号の時計)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ParticleLifetimeTests {
    /// 確かめる寿命 ([#1710] の完了条件 1)。0.37 はどの fps でも単精度の引き算と食い違わない
    /// 陰性対照で、0.05・0.2・0.7 は 10 進で書いた寿命 (単精度の丸めの向きに従う)。
    ///
    /// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
    static let lives: [Float] = [0.05, 0.2, 0.37, 0.5, 0.7, 1, 2, 3]

    /// ⌊`life`·`fps`⌋ を**整数で**求める。`life` は `Float` で、その値は m·2^−k (m・k は
    /// 整数) と厳密に書けるので、掛け算を丸めずに済む — 実装の倍精度の式を写さない。
    static func frames(life: Float, fps: Int) -> Int {
        guard life > 0 else { return 0 }
        // 仮数を整数にする桁 (1 未満の life も含めて、2^k 倍で整数になる最小の k 以上)
        let shift = max(0, Int(Float.significandBitCount) - Int(life.exponent))
        let numerator = Int(Double(life) * Double(1 << shift))
        return numerator * fps / (1 << shift)
    }

    /// 粒 1 つぶんの升の幅 (画素)。粒 i は i 番目の升の真ん中に、動かずに置く。
    static let spacing = 8

    /// 時計から刻みを受け取って回す、横 1 列の粒。
    ///
    /// **刻みは時計 (``FrameTiming``) から受け取る** — `SketchRuntime` が面へ渡すのと同じ
    /// 2 行 (`canvas.time`・`canvas.frameStep`) を通す。手で `.frame(perSecond:)` を書くと、
    /// 時計と面の間の受け渡しを飛ばしてしまう。
    final class Row {
        let canvas: Canvas
        let dust: Particles
        let fps: Int
        let slots: Int
        private let timing: FrameTiming
        private var randomness = Randomness(seed: 1710)

        init(
            on canvas: Canvas, fps: Int, slots: Int, capacity: Int? = nil,
            route: Canvas.ParticleRoute = .instanced
        ) throws {
            self.canvas = canvas
            self.fps = fps
            self.slots = slots
            canvas.particleRoute = route
            dust = try canvas.makeParticles(count: capacity ?? slots)
            timing = FrameTiming(clock: .frameIndex(frameRate: fps), now: { 0 })
        }

        /// 1 枚進める。`lives` の粒を升の順に 1 つずつ出してから、進めて描く。
        ///
        /// `requestedTime` を渡すと、時刻を指定して 1 枚描き直す観測の 1 枚になる (#1760)。
        /// `rate` を渡すと、升ではなく真ん中の 1 点から毎秒 `rate` 個を寿命 1 で出す
        /// (上書きの注意を見る形)。
        func advance(
            emitting lives: [Float] = [], at requestedTime: Float? = nil, speed: Float = 0,
            rate: Float? = nil
        ) throws {
            timing.advance(at: requestedTime)
            canvas.time = timing.time
            canvas.frameStep = timing.step
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                for (slot, life) in lives.enumerated() {
                    let center = Float(spacing * slot + spacing / 2)
                    // 1 枚目に毎秒 fps 個を頼むと、ちょうど 1 個出る (#1640)
                    canvas.emit(
                        dust, from: .point(center, Float(spacing / 2)), rate: Float(fps),
                        speed: speed...speed, angle: 0...0, life: life...life, size: 4...4,
                        color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
                }
                if let rate {
                    canvas.emit(
                        dust, from: .point(Float(spacing / 2), Float(spacing / 2)), rate: rate,
                        speed: 0...0, angle: 0...0, life: 1...1, size: 1...1,
                        color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
                }
                canvas.particles(dust)
            }
        }

        /// 升ごとに、いまの絵で粒が描かれているか。
        func lit() throws -> [Bool] {
            let bytes = try canvas.target.encodeForDisplay().bytes
            let width = spacing * slots
            return (0..<slots).map { slot in
                let start = ((spacing / 2) * width + spacing * slot + spacing / 2) * 4
                return (bytes[start..<(start + 3)].max() ?? 0) > 128
            }
        }

        /// GPU が書いた描く個数 (先頭の組の描く引数の 2 語目)。
        var instanceCount: Int { Int(canvas.read(dust.arguments)[1].bitPattern) }

        /// 升 `slot` の粒の状態 (``Particle``)。
        func particle(_ slot: Int) -> Particle {
            let values = canvas.read(dust.state)
            let floats = Particles.particleFloats
            return values[(slot * floats)..<((slot + 1) * floats)].withUnsafeBytes {
                $0.loadUnaligned(as: Particle.self)
            }
        }
    }

    private func makeCanvas(gpu: RenderDevice, slots: Int) throws -> Canvas {
        try CanvasFixture.make(gpu: gpu, width: Self.spacing * slots, height: Self.spacing)
    }

    /// 1 枚目に `lives` を出して、描かれた枚数を升ごとに数える。**毎枚読む** (小さい組だけに使う)。
    private func drawnFrames(
        on canvas: Canvas, fps: Int, lives: [Float], route: Canvas.ParticleRoute
    ) throws -> [Int] {
        let row = try Row(on: canvas, fps: fps, slots: lives.count, route: route)
        let last = lives.map { Self.frames(life: $0, fps: fps) }.max() ?? 0
        var drawn = Array(repeating: 0, count: lives.count)
        for frame in 1...(last + 2) {
            try row.advance(emitting: frame == 1 ? lives : [])
            for (slot, on) in try row.lit().enumerated() where on { drawn[slot] += 1 }
        }
        return drawn
    }

    // MARK: - 物差し

    /// 整数で求めた枚数そのものの確かめ。**物差しが外れていれば、下の検査は何も言わない。**
    @Test("整数で求めた ⌊L·fps⌋ は、有理数で書ける例と単精度の丸めの向きに一致する")
    func theExpectedCountIsExact() {
        #expect(Self.frames(life: 1, fps: 24) == 24)
        #expect(Self.frames(life: 3, fps: 120) == 360)
        #expect(Self.frames(life: 0.37, fps: 60) == 22)
        #expect(Self.frames(life: 0, fps: 60) == 0)
        // `Float(0.05)` = 0.0500000007… は 0.05 よりわずかに大きいので、60 fps で 3 枚
        #expect(Self.frames(life: 0.05, fps: 60) == 3)
        #expect(Self.frames(life: 0.2, fps: 5) == 1)
        // `Float(0.7)` = 0.699999988… は 0.7 よりわずかに小さいので、10 fps で 6 枚
        #expect(Self.frames(life: 0.7, fps: 10) == 6)
    }

    // MARK: - 枚数

    /// [#1710] の完了条件 1。fps 1…120 × 寿命 8 本のすべてで、GPU の断片を通して数える。
    ///
    /// 読むのは 1 枚目と、粒ごとの境目の 2 枚 (n 枚目と n + 1 枚目) だけである。寿命は減る
    /// だけなので、描かれる枚は 1 枚目から続く — n 枚目に描かれて n + 1 枚目に描かれなければ、
    /// ちょうど n 枚である。直す前は 1 つの fps でも 8 本のどれかが割れていた。
    ///
    /// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
    @Test("フレーム番号の時計のどの fps でも、寿命 L の粒は ⌊L·fps⌋ 枚描かれる")
    func drawsTheFloorOfLifeTimesFrameRate() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu: gpu, slots: Self.lives.count)
        var broken: [String] = []
        for fps in 1...120 {
            let row = try Row(on: canvas, fps: fps, slots: Self.lives.count)
            let expected = Self.lives.map { Self.frames(life: $0, fps: fps) }
            let checkpoints = Set(expected.flatMap { [$0, $0 + 1] }.filter { $0 >= 1 } + [1])
            for frame in 1...(checkpoints.max() ?? 1) {
                try row.advance(emitting: frame == 1 ? Self.lives : [])
                guard checkpoints.contains(frame) else { continue }
                let lit = try row.lit()
                for (slot, count) in expected.enumerated() where lit[slot] != (frame <= count) {
                    broken.append(
                        "fps \(fps)・寿命 \(Self.lives[slot])・\(frame) 枚目に"
                            + "\(lit[slot] ? "描かれた" : "描かれない") (⌊L·fps⌋ = \(count))")
                }
                let living = expected.count { frame <= $0 }
                if row.instanceCount != living {
                    broken.append(
                        "fps \(fps)・\(frame) 枚目: 描く個数 \(row.instanceCount) (生きているはずの数 \(living))")
                }
            }
        }
        #expect(broken.isEmpty, "⌊L·fps⌋ と違う枚が \(broken.count) 件: \(broken.prefix(12))")
    }

    /// [#1710] の完了条件 2。**GPU が置き場所を埋める経路と、CPU が読み戻して埋める経路で、
    /// 描かれる枚数が一致する。** 寿命の表し方を変えるなら、参照の経路の生存の判定
    /// (`Particles.living(from:)`) も同じ数え方に揃っていなければならない。
    ///
    /// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
    @Test("速い経路と参照の経路で、寿命 L の粒が描かれる枚数が一致する", arguments: [1, 24, 25, 30, 60])
    func bothRoutesDrawTheSameNumberOfFrames(fps: Int) throws {
        let lives: [Float] = [0.5, 1]
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu: gpu, slots: lives.count)
        let fast = try drawnFrames(on: canvas, fps: fps, lives: lives, route: .instanced)
        let reference = try drawnFrames(on: canvas, fps: fps, lives: lives, route: .reference)
        let expected = lives.map { Self.frames(life: $0, fps: fps) }
        #expect(fast == reference, "fps \(fps): 速い経路 \(fast) 枚・参照の経路 \(reference) 枚")
        #expect(reference == expected, "fps \(fps): 参照の経路 \(reference) 枚 (⌊L·fps⌋ = \(expected))")
    }

    /// 境目の値を、整数の物差しを通さずに書く。
    @Test("寿命 0 は 1 枚も描かれず、fps 1 の寿命 1 は 1 枚、60 fps の寿命 0.05 は 3 枚描かれる")
    func boundaryLivesDrawTheCountsWrittenOut() throws {
        let gpu = try RenderDevice()
        func drawn(life: Float, fps: Int) throws -> Int {
            try drawnFrames(
                on: makeCanvas(gpu: gpu, slots: 1), fps: fps, lives: [life], route: .instanced)[0]
        }
        #expect(try drawn(life: 0, fps: 60) == 0)
        #expect(try drawn(life: 1, fps: 1) == 1)
        #expect(try drawn(life: 0.05, fps: 60) == 3)
    }

    /// 枚数で持つ寿命の頭打ち (2^24 − 1 枚)。**大きすぎる寿命でも止まらず、描かれ、生きている
    /// 粒として上書きの注意に数えられる。** 頭打ちの値を単精度の寿命に直すとき、2^24 を
    /// 越えると 1 ずつ減らせなくなる。
    @Test("頭打ちを越える寿命の粒も描かれ、まだ生きている粒として数えられる")
    func livesBeyondTheCapStillDrawAndCountAsAlive() throws {
        let gpu = try RenderDevice()
        let row = try Row(on: makeCanvas(gpu: gpu, slots: 1), fps: 120, slots: 1)
        try row.advance(emitting: [1e30])
        #expect(try row.lit() == [true])
        try row.advance()
        #expect(try row.lit() == [true])
        #expect(!row.dust.warnings.hasWarned(.overwrite))
        // 枠 1 つに、もう 1 つ出す。前の粒はまだ生きている
        try row.advance(emitting: [1])
        #expect(row.dust.warnings.hasWarned(.overwrite))
    }

    // MARK: - 時計から面まで

    /// 24 fps で 1 枚目に寿命 1 の粒を 1 つ出す。粒は 1 点に止まっている。
    final class OneSpark: Sketch {
        static let fps = 24
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: Self.fps) }
        var spark: Particles?
        var emitted = false
        init() {}

        func setup() { spark = try? makeParticles(count: 1) }

        func draw() {
            background(0)
            guard let spark else { return }
            if !emitted {
                emitted = true
                emit(
                    spark, from: .point(8, 8), rate: Float(Self.fps), speed: 0...0, angle: 0...0,
                    life: 1...1, size: 8...8,
                    color: LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: 1))
            }
            particles(spark)
        }
    }

    /// [#1710] の完了条件 3。**時計から粒を進めるところまでを `SketchRuntime` ごと通す** —
    /// 数える側だけを見る検査は、時計と面の間の受け渡しで刻みが秒に直るのを見落とす。
    /// 直す前は 23 枚目までしか描かれなかった。
    ///
    /// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
    @Test("24 fps で 1 枚目に出した寿命 1 の粒は、24 枚目まで描かれ、25 枚目で消える")
    func theRuntimeDrawsALifeOfOneForTwentyFourFrames() throws {
        let runtime = try SketchRuntime(sketch: OneSpark(), gpu: RenderDevice())
        defer { runtime.closePlugins() }
        func lit() throws -> Bool { try runtime.target.readPixels()[8, 8].red > 0.3 }
        for _ in 0..<OneSpark.fps { try runtime.advance() }
        #expect(try lit(), "\(OneSpark.fps) 枚目に描かれていない")
        try runtime.advance()
        #expect(try !lit(), "\(OneSpark.fps + 1) 枚目にまだ描かれている")
    }

    /// [#1710] の完了条件 4。**時刻を指定して 1 枚描き直す観測 (その 1 枚の刻みは 0 秒) では、
    /// 粒は動かず寿命も減らない。** フレーム番号の時計の途中にその 1 枚を挟むと、描かれる
    /// 枚数がちょうど 1 枚増える。挟む所は、出した次の枚・途中・描かれる最後の枚の直後。
    ///
    /// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
    @Test("観測の 1 枚を挟むと、粒は動かず、描かれる枚数がちょうど 1 枚増える", arguments: [1, 12, 24])
    func anObservedFrameNeitherMovesNorAgesTheParticle(after observed: Int) throws {
        let fps = 24
        let gpu = try RenderDevice()
        let row = try Row(on: makeCanvas(gpu: gpu, slots: 1), fps: fps, slots: 1)
        var drawn = 0
        var frame = 0
        while frame < Self.frames(life: 1, fps: fps) + 2 {
            frame += 1
            try row.advance(emitting: frame == 1 ? [1] : [], speed: 3)
            drawn += row.instanceCount
            guard frame == observed else { continue }
            let before = row.particle(0)
            try row.advance(at: 0.5)
            drawn += row.instanceCount
            let after = row.particle(0)
            #expect(row.instanceCount == 1, "観測の 1 枚で描かれていない")
            #expect(after.x == before.x && after.y == before.y, "観測の 1 枚で粒が動いた")
            #expect(after.life == before.life, "観測の 1 枚で寿命が減った")
        }
        #expect(drawn == Self.frames(life: 1, fps: fps) + 1, "\(observed) 枚目の後に観測を挟んで \(drawn) 枚")
    }

    // MARK: - 上書きの注意

    /// [#1710] の完了条件 5。**「まだ生きている」も同じ数え方で決まる。** fps f で毎秒 f 個・
    /// 寿命 1 なら、生きている粒は常に f 個で、枠 f 個の環は生きている粒を上書きしない。
    /// 枠 f − 1 個なら、まだ描かれる粒を上書きする。直す前は、単精度の時刻に単精度の寿命を
    /// 足した境目で決めていたので、60 fps の枠 60 個が 72 枚目に注意を出していた。
    ///
    /// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
    @Test("毎秒 f 個・寿命 1 なら、枠 f 個では上書きの注意が出ず、f − 1 個では出る")
    func overwritesAreCountedTheSameWay() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu: gpu, slots: 1)
        var silent: [Int] = []
        var unwarned: [Int] = []
        for fps in 2...120 {
            let enough = try Row(on: canvas, fps: fps, slots: 1, capacity: fps)
            let short = try Row(on: canvas, fps: fps, slots: 1, capacity: fps - 1)
            for _ in 0..<(3 * fps) {
                try enough.advance(rate: Float(fps))
                if !short.dust.warnings.hasWarned(.overwrite) { try short.advance(rate: Float(fps)) }
            }
            if enough.dust.warnings.hasWarned(.overwrite) { silent.append(fps) }
            if !short.dust.warnings.hasWarned(.overwrite) { unwarned.append(fps) }
        }
        #expect(silent.isEmpty, "枠 fps 個で上書きの注意が出た fps: \(silent)")
        #expect(unwarned.isEmpty, "枠 fps − 1 個で上書きの注意が出なかった fps: \(unwarned)")
    }
}
