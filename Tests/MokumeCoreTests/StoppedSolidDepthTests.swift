// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing

@testable import MokumeCore

/// 止まっている間 (と `setup()`) に描き切らせた立体の奥行きは、次のフレームへ引き継がれる ([#1888])。
///
/// 持ち越しを約束する区間 (ADR-0021 決定 4 の追補 (2026-09-27)) で置いた立体は、次に描くフレームの
/// 立体と前後を比べられる。**描き切らせたかどうかで絵が変わらない** — 比べる相手は、置いただけで
/// 描き切らせずに持ち越した 2 枚目である (次のフレームの `draw()` と同じパスで描かれるので、
/// 奥行きは自然に引き継がれる)。
///
/// 直す前は 2 つの根があった。
/// - 止まっている間の最初の描き切りは、前のフレームの最後のパスが捨てた (`.dontCare`) 奥行きを
///   `.load` で読んでいた。
/// - 次のフレームの最初のパスは奥行きを消してから描くので、区間で描き切った立体の奥行きは
///   次のフレームの頭で失われた。`setup()` の区間も同じである。
///
/// 止まっている間のコールバックと `setup()` は、面の上では持ち越しの区間 (``Canvas/carriesOver``)
/// である。ここではその印を立てて模す。ランタイムを通す形は、下の「ランタイムを通す」が見る。
///
/// [#1888]: https://github.com/mokume-metal/mokume/issues/1888
@Suite(
    "描き切らせた立体の奥行きは次のフレームへ引き継がれる",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct StoppedSolidDepthTests {
    /// 検査する面。`EffectStoppedChangeTests` の面とは独立に持つ (別の Issue が触る)。
    enum Surface: CaseIterable, CustomTestStringConvertible {
        /// 本体の面。細かさ 1。
        case main
        /// 細かさを下げた面。効果は描く先に書かれ、拡大がそこから出す先へ広げる。
        case halfDensity

        var testDescription: String {
            switch self {
            case .main: "本体の面"
            case .halfDensity: "細かさ 0.5 の面"
            }
        }

        /// 出す大きさ 160×160 の面を 1 つ作る。
        func make() throws -> Canvas {
            let gpu = try RenderDevice()
            let output = try RenderTarget(gpu: gpu, width: 160, height: 160)
            switch self {
            case .main: return try Canvas(target: output, gpu: gpu)
            case .halfDensity:
                return try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
            }
        }
    }

    /// 効果を通すフレームか。**奥行きは効果の有無と関係なく、フレームの最後のパスで捨てられる**
    /// (効果を通す先は色だけ)。両方で回して、根が効果に無いことを見る。
    enum Effects: CaseIterable, CustomTestStringConvertible {
        case without
        case with

        var testDescription: String {
            switch self {
            case .without: "効果なし"
            case .with: "効果あり"
            }
        }
    }

    /// 持ち越しを約束する区間。
    enum Interval: CaseIterable, CustomTestStringConvertible {
        /// 1 枚目を描いた後の、止まっている間のコールバック。
        case stopped
        /// 1 枚目より前の `setup()`。
        case setup

        var testDescription: String {
            switch self {
            case .stopped: "止まっている間"
            case .setup: "setup()"
            }
        }
    }

    /// 面・効果・区間の組。Swift Testing の引数は 2 つまでなので、組にして 1 つの引数で回す。
    struct Variant: CustomTestStringConvertible, Sendable {
        let surface: Surface
        let effects: Effects
        let interval: Interval

        var testDescription: String {
            "\(surface.testDescription)・\(effects.testDescription)・\(interval.testDescription)"
        }

        nonisolated static let all: [Variant] = Surface.allCases.flatMap { surface in
            Effects.allCases.flatMap { effects in
                Interval.allCases.map { Variant(surface: surface, effects: effects, interval: $0) }
            }
        }
    }

    /// 区間の中で描き切らせるか。
    enum Settling: CaseIterable, CustomTestStringConvertible {
        /// 描き切らせず、置いたまま次のフレームへ持ち越す (比べる相手)。
        case carried
        /// 2 つ置いてから 1 回描き切らせる。
        case once
        /// 1 つ置いては描き切らせる (描き切りを 2 回挟む)。
        case eachTime

        var testDescription: String {
            switch self {
            case .carried: "描き切らせない"
            case .once: "置いてから 1 回"
            case .eachTime: "1 つ置くたびに"
            }
        }
    }

    /// 区間で描き切らせた後に、絵を置き換える背景。
    enum Backdrop: CaseIterable, CustomTestStringConvertible {
        /// 置き換えない。
        case none
        /// 次のフレームの頭で、塗り 1 色の背景 (`background(235)`)。色と奥行きを消して塗り直す。
        case colour
        /// 次のフレームの頭で、周囲の背景 (`background(.sky)`)。色は塗り直さず、視点が写す範囲
        /// いっぱいの板で置き換える (奥行きは比べずに書く・#1685)。
        case sky
        /// 区間で描き切らせた後、区間の中で周囲の背景 (`background(.sky)`)。
        case skyInTheInterval

        /// 置き換えるもの。
        nonisolated static let replacing: [Backdrop] = [.colour, .sky, .skyInTheInterval]

        var testDescription: String {
            switch self {
            case .none: "背景なし"
            case .colour: "次のフレームの background(色)"
            case .sky: "次のフレームの background(.sky)"
            case .skyInTheInterval: "区間の background(.sky)"
            }
        }
    }

    /// 立体の置き方。手前 (z 20・赤)・奥 (z -20・青) を区間で、真ん中 (z 0・緑) を次のフレームで置く。
    enum Scene: CaseIterable, CustomTestStringConvertible {
        /// Issue の再現の置き方。赤が緑を隠し、青は赤に隠れる。
        case issue
        /// 3 つが互いに部分的に重なる置き方。どの組の前後も絵に出る。
        case spread

        var testDescription: String {
            switch self {
            case .issue: "Issue の再現"
            case .spread: "互いに重なる 3 つ"
            }
        }

        var front: Placement {
            switch self {
            case .issue: Placement(x: 80, y: 80, z: 20, fill: StoppedSolidDepthTests.red)
            case .spread: Placement(x: 60, y: 60, z: 20, fill: StoppedSolidDepthTests.red)
            }
        }

        var back: Placement {
            switch self {
            case .issue: Placement(x: 90, y: 90, z: -20, fill: StoppedSolidDepthTests.blue)
            case .spread: Placement(x: 100, y: 100, z: -20, fill: StoppedSolidDepthTests.blue)
            }
        }

        var middle: Placement {
            Placement(x: 80, y: 80, z: 0, fill: StoppedSolidDepthTests.green)
        }

        /// 正しい絵で、その色が出ているはずの点 (出す座標)。検査の前提を確かめるのに使う。
        var expectations: [(x: Float, y: Float, color: Hue, why: String)] {
            switch self {
            case .issue:
                [(80, 80, .red, "赤 (z 20) が緑 (z 0) と青 (z -20) の手前")]
            case .spread:
                [
                    (30, 30, .red, "赤だけの所"),
                    (115, 115, .blue, "青だけの所"),
                    (105, 60, .green, "緑だけの所"),
                    (60, 60, .red, "赤 (z 20) と緑 (z 0) の重なり"),
                    (100, 100, .green, "緑 (z 0) と青 (z -20) の重なり"),
                    (80, 80, .red, "3 つの重なり"),
                ]
            }
        }
    }

    /// 検査の前提に使う色。
    enum Hue {
        case red, green, blue

        func matches(_ pixel: LinearRGBA) -> Bool {
            switch self {
            case .red: pixel.red > 0.4 && pixel.green < 0.1 && pixel.blue < 0.1
            case .green: pixel.green > 0.4 && pixel.red < 0.1 && pixel.blue < 0.1
            case .blue: pixel.blue > 0.4 && pixel.red < 0.1 && pixel.green < 0.1
            }
        }

        /// 出口を通したバイト列 (0–255) で見る。
        func matches(_ pixel: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)) -> Bool {
            switch self {
            case .red: pixel.red > 180 && pixel.green < 60 && pixel.blue < 60
            case .green: pixel.green > 180 && pixel.red < 60 && pixel.blue < 60
            case .blue: pixel.blue > 180 && pixel.red < 60 && pixel.green < 60
            }
        }
    }

    static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    static let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    static let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
    private static let darkening: [Effect] = [.vignette(amount: 0.6)]

    /// 止まっている間のコールバックを模す (持ち越しの区間の印を立てる)。`setup()` も同じ印である。
    private static func inTheInterval(_ canvas: Canvas, _ body: () -> Void) {
        canvas.carriesOver = true
        defer { canvas.carriesOver = false }
        body()
    }

    /// 奥行きを、いちばん手前 (0) で埋める。**「中身の決まっていない奥行き」の毒。**
    ///
    /// 前のフレームの最後のパスは奥行きを捨てる (`.dontCare`)。捨てた後の中身は決まっていないので、
    /// 読めば何が入っているかは機械による。その読みを決定的にするため、どんな立体も奥行きの比較に
    /// 落ちる値 (0) を入れておく — 読んでいれば、区間で置いた立体は 1 つも描かれない。
    /// 効果を通す前の絵の控えへ描くパスが始める奥行き (``EffectPipeline/carryDepth()``) にも入れる。
    private static func poisonDepth(of canvas: Canvas) throws {
        var textures = [canvas.target.depthTexture]
        if canvas.effectPipelineStorage?.existingCarry != nil {
            textures.append(try canvas.effectPipeline().carryDepth().texture)
        }
        for texture in textures {
            let pass = MTL4RenderPassDescriptor()
            // 色の面は描かないが、パスには色か奥行きのどちらかが要る
            let depth = pass.depthAttachment!
            depth.texture = texture
            depth.loadAction = .clear
            depth.clearDepth = 0
            depth.storeAction = .store
            try canvas.target.gpu.withCommands { commands throws(RenderFailure) in
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
                    throw .encoderUnavailable
                }
                encoder.endEncoding()
                try canvas.target.gpu.commitAndWait(commands)
            }
        }
    }

    /// 2 枚目の描く先と、効果を通す前の絵の控えへ描いた回数。
    struct Result {
        let picture: PixelBuffer
        let carryDraws: Int
    }

    /// 1 枚目から 2 枚目までを走らせ、2 枚目の描く先を返す。
    ///
    /// - 止まっている間: 1 枚目は下地 (と効果)、区間で手前・奥を置き、2 枚目で真ん中を置く。
    /// - `setup()`: 区間で下地と手前・奥を置き、1 枚目で真ん中を置く (と効果)。
    ///
    /// `settling` だけが違う 2 枚は、区間で描き切らせたかどうかだけが違う。
    private static func secondFrame(
        _ surface: Surface, _ effects: Effects, _ interval: Interval, _ scene: Scene,
        settling: Settling, poisoned: Bool = false, backdrop: Backdrop = .none
    ) throws -> Result {
        let canvas = try surface.make()
        let plane = canvas.createShape {
            canvas.noStroke()
            canvas.plane(60, 60)
        }
        func applyEffects() {
            if effects == .with { canvas.effects(darkening) }
        }
        func placeInTheInterval() {
            canvas.shape(plane, at: [scene.front])
            if settling == .eachTime { _ = canvas.get(0, 0) }
            canvas.shape(plane, at: [scene.back])
            if settling != .carried { _ = canvas.get(0, 0) }
            if backdrop == .skyInTheInterval { canvas.background(.sky) }
        }
        /// 次のフレームの頭。
        func openTheNextFrame() {
            switch backdrop {
            case .colour: canvas.background(235)
            case .sky: canvas.background(.sky)
            case .none, .skyInTheInterval: break
            }
            canvas.shape(plane, at: [scene.middle])
        }
        switch interval {
        case .stopped:
            try canvas.draw {
                canvas.background(235)
                applyEffects()
            }
            if poisoned { try poisonDepth(of: canvas) }
            inTheInterval(canvas, placeInTheInterval)
            try canvas.draw { openTheNextFrame() }
        case .setup:
            if poisoned { try poisonDepth(of: canvas) }
            inTheInterval(canvas) {
                canvas.background(235)
                placeInTheInterval()
            }
            try canvas.draw {
                openTheNextFrame()
                applyEffects()
            }
        }
        return Result(picture: try canvas.target.readPixels(), carryDraws: canvas.effectCarryDrawsEncoded)
    }

    /// 描く画素の座標 (出す座標に細かさを掛ける)。
    private static func pixel(_ picture: PixelBuffer, _ x: Float, _ y: Float) -> LinearRGBA {
        let scale = Float(picture.width) / 160
        return picture[Int(x * scale), Int(y * scale)]
    }

    /// 違う画素の数と、最初に違った画素。
    private static func difference(_ lhs: PixelBuffer, _ rhs: PixelBuffer) -> (count: Int, first: (x: Int, y: Int)?) {
        var count = 0
        var first: (x: Int, y: Int)?
        for y in 0..<lhs.height {
            for x in 0..<lhs.width where lhs[x, y] != rhs[x, y] {
                if first == nil { first = (x, y) }
                count += 1
            }
        }
        return (count, first)
    }

    /// 検査の前提: 描き切らせずに持ち越した 2 枚目は、奥行きどおりの絵になっている。
    private static func requireDepthOrder(_ carried: PixelBuffer, _ scene: Scene) throws {
        for point in scene.expectations {
            let value = pixel(carried, point.x, point.y)
            try #require(
                point.color.matches(value),
                "持ち越した 2 枚目が奥行きどおりでない ((\(point.x), \(point.y)): \(point.why)): \(value)")
        }
    }

    /// 検査の前提: 背景で置き換えた 2 枚目は、置き換える前に置いた立体が 1 つも残らず、次のフレームで
    /// 置いた真ん中の立体だけが出ている。
    private static func requireReplaced(_ carried: PixelBuffer, _ scene: Scene) throws {
        let middle = scene.middle
        let value = pixel(carried, middle.x, middle.y)
        try #require(Hue.green.matches(value), "置き換えた 2 枚目の真ん中が緑でない: \(value)")
        var reds = 0
        for y in 0..<carried.height {
            for x in 0..<carried.width where Hue.red.matches(carried[x, y]) { reds += 1 }
        }
        try #require(reds == 0, "置き換える前に置いた赤い立体が \(reds) 画素残っている")
    }

    // MARK: - 描き切らせても、持ち越しても、同じ絵になる

    /// 区間で描き切らせた 2 枚目が、描き切らせずに持ち越した 2 枚目と全画素で一致することを見る。
    /// 1 回だけ描き切らせる形と、1 つ置くたびに描き切らせる形 (描き切りを 2 回挟む) の両方を比べる。
    private static func expectSettledToMatchCarried(
        _ variant: Variant, _ scene: Scene, poisoned: Bool = false, backdrop: Backdrop = .none
    ) throws {
        let (surface, effects, interval) = (variant.surface, variant.effects, variant.interval)
        let carried = try secondFrame(
            surface, effects, interval, scene, settling: .carried, poisoned: poisoned,
            backdrop: backdrop)
        if backdrop == .none {
            try requireDepthOrder(carried.picture, scene)
        } else {
            try requireReplaced(carried.picture, scene)
        }
        #expect(carried.carryDraws == 0, "描き切らせていないのに、効果を通す前の絵へ描いた")

        for settling in [Settling.once, .eachTime] {
            let settled = try secondFrame(
                surface, effects, interval, scene, settling: settling, poisoned: poisoned,
                backdrop: backdrop)
            if effects == .with, interval == .stopped {
                // 効果を通す面の止まっている間は、効果を通す前の絵へも同じ列で描く (#1524)。その
                // 道を通っていなければ、この検査は控えの奥行きを見ていない
                #expect(settled.carryDraws > 0, "\(settling.testDescription): 効果を通す前の絵へ描いていない")
            }
            let differing = difference(settled.picture, carried.picture)
            #expect(
                differing.count == 0,
                "\(settling.testDescription)描き切らせると \(differing.count) / \(carried.picture.width * carried.picture.height) 画素が違う (最初は \(String(describing: differing.first)))"
            )
        }
    }

    /// 完了条件 1・3 — 区間で描き切らせた 2 枚目は、描き切らせずに持ち越した 2 枚目と全画素で一致する。
    ///
    /// 1 回だけ描き切らせる形 (再現) と、手前を置いて描き切らせてから奥を置いて描き切らせる形
    /// (描き切りを 2 回挟む) の両方を、持ち越した形と比べる。後者は、区間の中の描き切りが前の
    /// 描き切りの奥行きを引き継ぐことも見る。効果の有無・面・区間 (止まっている間と `setup()`)
    /// を回して、根が効果に無いことを見る。
    @Test(
        "区間で描き切らせた立体の前後は、次のフレームでも持ち越した立体と同じになる",
        arguments: Variant.all, Scene.allCases)
    func settledSolidsKeepTheirDepth(_ variant: Variant, _ scene: Scene) throws {
        try Self.expectSettledToMatchCarried(variant, scene, poisoned: false)
    }

    /// 完了条件 2 — 区間の描き切りは、中身の決まっていない奥行きを読まない。
    ///
    /// 前のフレームの最後のパスが捨てた奥行きに毒 (どの立体も落ちる値) を入れてから区間で置くと、
    /// 読んでいれば区間の立体は描かれない。読まずに消してから描くので、毒は絵に出ない。効果を
    /// 通す面では、効果を通す前の絵の控えへ描くパスも同じ奥行きから始めるので、そちらの奥行きにも
    /// 毒を入れる。
    @Test(
        "区間の描き切りは、前のフレームが捨てた奥行きを読まない",
        arguments: Variant.all, Scene.allCases)
    func settlingDoesNotReadDiscardedDepth(_ variant: Variant, _ scene: Scene) throws {
        try Self.expectSettledToMatchCarried(variant, scene, poisoned: true)
    }

    // MARK: - 背景で置き換える

    /// 区間で描き切らせた後に背景で置き換えても、描き切らせずに持ち越した形と同じ絵になる。
    ///
    /// - 次のフレームの頭の `background(色)`: 色と奥行きを消して塗り直す。引き継いだ奥行きも消える
    ///   (`pendingBackground` が引き継ぎを切る)。
    /// - `background(.sky)` (次のフレームの頭・区間の中): 周囲の板は色を塗り直さず、いちばん奥で奥行きの
    ///   比較を受ける。引き継いだ奥行きが残っていると、板が区間で描き切らせた赤い立体の画素で落ち、
    ///   赤だけが背景の手前に残る。持ち越した赤い立体は、背景を置くときに捨てられるので出ない。
    ///
    /// 置き方は Issue の再現で、赤 (z 20) を緑 (z 0) の手前に置く。
    @Test(
        "区間で描き切らせた後に背景で置き換えても、持ち越した立体と同じ絵になる",
        arguments: Variant.all, Backdrop.replacing)
    func aBackgroundReplacesSettledSolidsJustAsCarriedOnes(_ variant: Variant, _ backdrop: Backdrop) throws {
        try Self.expectSettledToMatchCarried(variant, .issue, backdrop: backdrop)
    }

    /// フレームの中で描き切らせた後の `background(.sky)` も、描き切らせた立体を置き換える ([#1657])。
    ///
    /// #1888 の時点では、板が最奥で奥行きの比較を受け、フレームの中で描き切らせた立体が背景の手前に
    /// 残っていた (そのときはこの検査が「変えない」と固定していた)。置き換える列は奥行きを比べずに
    /// 書く ([#1685]) ので、引き継いだ奥行きと同じく、このフレームで描き切った奥行きにも板は落ちない。
    /// 2 つの口を並べた検査は `BackgroundReplacementTests` が持ち、ここは区間の検査の隣で境目を見る。
    ///
    /// [#1657]: https://github.com/mokume-metal/mokume/issues/1657
    /// [#1685]: https://github.com/mokume-metal/mokume/issues/1685
    @Test("フレームの中で描き切らせた後の周囲の背景も、描き切らせた立体を置き換える", arguments: Surface.allCases)
    func aBackdropInsideAFrameReplacesItsOwnSettledSolids(surface: Surface) throws {
        let canvas = try surface.make()
        let plane = canvas.createShape {
            canvas.noStroke()
            canvas.plane(60, 60)
        }
        try canvas.draw {
            canvas.shape(plane, at: [Scene.issue.front])
            _ = canvas.get(0, 0)
            canvas.background(.sky)
            canvas.shape(plane, at: [Scene.issue.middle])
        }
        let picture = try canvas.target.readPixels()
        // 赤 (z 20) は背景に置き換えられ、あとから置いた緑 (z 0) が出る
        let centre = Self.pixel(picture, 80, 80)
        #expect(Hue.green.matches(centre), "フレームの中で描き切らせた赤が背景の手前に残っている: \(centre)")
        // 板は緑の外を覆う (置く前の面は透明)
        let corner = Self.pixel(picture, 5, 5)
        #expect(corner.alpha > 0.99, "周囲の背景が緑の外を覆っていない: \(corner)")
    }

    // MARK: - 失敗した描き切り

    /// 最後の描き切りが失敗したフレームの後も、次のフレームの奥行きは、成功したフレームの後と同じに
    /// 始まる。
    ///
    /// 奥行きはフレームごとに作り直す。フレームの終わりは、最後の描き切りが失敗しても引き継ぎを切る
    /// (`abandonFrame()`)。失敗した回だけ奥行きを残すと、その次のフレームで置いた立体が、成功した
    /// ときと違い、区間で描き切らせた立体の奥行きと比べられてしまう。
    @Test("最後の描き切りが失敗したフレームの後も、奥行きは成功したときと同じに始まる", arguments: Surface.allCases)
    func aFailedLastPassEndsTheDepthCarryLikeASuccessfulOne(surface: Surface) throws {
        func picture(failing: Bool) throws -> PixelBuffer {
            let canvas = try surface.make()
            let plane = canvas.createShape {
                canvas.noStroke()
                canvas.plane(60, 60)
            }
            try canvas.draw { canvas.background(235) }
            Self.inTheInterval(canvas) {
                canvas.shape(plane, at: [Scene.issue.front])
                _ = canvas.get(0, 0)
            }
            // 区間の立体を引き継ぐフレーム。何も置かずに終える (失敗する回は最後の描き切りが投げる)
            canvas.beginDraw()
            if failing { canvas.failureForTesting = .deviceUnavailable }
            canvas.endDraw()
            canvas.failureForTesting = nil
            try canvas.draw { canvas.shape(plane, at: [Scene.issue.middle]) }
            return try canvas.target.readPixels()
        }
        let succeeded = try picture(failing: false)
        let failed = try picture(failing: true)
        // 前提: 区間の立体を引き継いだフレームの次のフレームには、奥行きは残らない (緑が赤を覆う)
        let centre = Self.pixel(succeeded, 80, 80)
        try #require(Hue.green.matches(centre), "前提: 成功したフレームの次のフレームで、緑が赤の手前に出ていない: \(centre)")
        let differing = Self.difference(failed, succeeded)
        #expect(differing.count == 0, "失敗したフレームの後は \(differing.count) 画素が違う")
    }

    // MARK: - 描き場所

    /// 描き場所の描き切りは、本体の引き継いだ奥行きを壊さない。
    enum LayerRole: CaseIterable, CustomTestStringConvertible {
        /// 本体が描き切らせた後で、描き場所が自分のフレーム (`beginDraw()`〜`endDraw()`) を走らせる。
        case ownFrameBetween
        /// 本体が描き場所を置き、その描き場所を描き換える。描き換わる直前に本体を描き切らせていたが、
        /// いまは置いた時点の絵を写しに取るので、本体は描き切られない (#1656 の案 A2)。どちらでも
        /// 前後は変わらないことを見る。
        case forcesTheSettle

        var testDescription: String {
            switch self {
            case .ownFrameBetween: "描き場所が自分のフレームを走らせる"
            case .forcesTheSettle: "本体が置いた描き場所を描き換える"
            }
        }
    }

    /// 完了条件 1・7 の描き場所の経路 — 描き場所を置いた本体でも、区間で描き切らせた立体の奥行きは
    /// 次のフレームへ引き継がれる。
    ///
    /// 描き場所の描き切りは、描き場所自身の奥行きの面で走るので、本体の引き継ぎに触れない。
    /// 置いた描き場所を描き換えても、本体は描き切られない (置いた時点の絵を写しに取る・#1656)。
    /// どちらでも、次のフレームの緑 (z 0) は、区間の赤 (z 20) の奥に回る。
    @Test(
        "描き場所を挟んでも、区間で描き切らせた立体の奥行きは次のフレームへ引き継がれる",
        arguments: Variant.all, LayerRole.allCases)
    func aLayersPassesLeaveTheMainDepthCarryAlone(_ variant: Variant, _ role: LayerRole) throws {
        let scene = Scene.spread
        let canvas = try variant.surface.make()
        let plane = canvas.createShape {
            canvas.noStroke()
            canvas.plane(60, 60)
        }
        let layer = try canvas.createGraphics(16, 16)
        func redrawTheLayer() {
            layer.beginDraw()
            layer.background(Self.green)
            layer.endDraw()
        }
        func stage() {
            canvas.shape(plane, at: [scene.front])
            canvas.shape(plane, at: [scene.back])
            switch role {
            case .ownFrameBetween:
                _ = canvas.get(0, 0)
                redrawTheLayer()
            case .forcesTheSettle:
                // 絵の外 (右上の隅) に置く。要所の色には触れない
                canvas.image(layer, 140, 4)
                redrawTheLayer()
            }
        }
        func applyEffects() {
            if variant.effects == .with { canvas.effects(Self.darkening) }
        }
        switch variant.interval {
        case .stopped:
            try canvas.draw {
                canvas.background(235)
                applyEffects()
            }
            Self.inTheInterval(canvas, stage)
            try canvas.draw { canvas.shape(plane, at: [scene.middle]) }
        case .setup:
            Self.inTheInterval(canvas) {
                canvas.background(235)
                stage()
            }
            try canvas.draw {
                canvas.shape(plane, at: [scene.middle])
                applyEffects()
            }
        }
        let picture = try canvas.target.readPixels()
        for point in scene.expectations {
            let value = Self.pixel(picture, point.x, point.y)
            #expect(
                point.color.matches(value),
                "奥行きどおりでない ((\(point.x), \(point.y)): \(point.why)): \(value)")
        }
    }

    // MARK: - 払う費用

    /// 描く先へのパスが奥行きを読み込んだ・書き出した回数。
    private static func depthTraffic(_ canvas: Canvas) -> (loads: Int, stores: Int) {
        (canvas.depthLoadsEncoded, canvas.depthStoresEncoded)
    }

    /// 完了条件 4 — 走るフレームと、止まっている間に描き切らせないスケッチは、奥行きの読み書きを増やさない。
    ///
    /// 奥行きは、フレームの最初のパスで消し、最後のパスで捨てる。書き出すのも読み込むのも、
    /// フレームを何回かに分けて描き切るとき (途中の描き切り) だけである。分けないフレームは
    /// 1 バイトも払わない。止まっている間に読むだけ (`get()`) のコールバックは、溜めたものが無い
    /// 空の描き切りで画素を映す。それは奥行きを書き出す (直す前から) が、読み込まない — 直す前は、
    /// 前のフレームが捨てた奥行きを読み込んでいた。次のフレームは分けなければ、消して始める。
    @Test("走るフレームと、描き切らせない止まっている間は、奥行きの読み書きを増やさない", arguments: Surface.allCases)
    func runningFramesAndReadOnlyCallbacksPayNoMore(surface: Surface) throws {
        let canvas = try surface.make()
        let plane = canvas.createShape {
            canvas.noStroke()
            canvas.plane(60, 60)
        }
        let scene = Scene.spread
        func traffic(_ body: () throws -> Void) rethrows -> (loads: Int, stores: Int) {
            let before = Self.depthTraffic(canvas)
            try body()
            let after = Self.depthTraffic(canvas)
            return (after.loads - before.loads, after.stores - before.stores)
        }

        // 分けずに描き切るフレーム: 消して始め、捨てて終わる
        let whole = try traffic {
            for _ in 0..<3 {
                try canvas.draw {
                    canvas.background(235)
                    canvas.shape(plane, at: [scene.front, scene.back])
                }
            }
        }
        #expect(whole == (0, 0), "分けないフレームが奥行きを読み書きした: \(whole)")

        // 途中で 1 回分けるフレーム: 途中の描き切りが書き出し、最後の描き切りが読み込む (捨てて終わる)
        let split = try traffic {
            for _ in 0..<3 {
                try canvas.draw {
                    canvas.background(235)
                    canvas.shape(plane, at: [scene.front])
                    _ = canvas.get(0, 0)
                    canvas.shape(plane, at: [scene.back])
                }
            }
        }
        #expect(split == (3, 3), "分けたフレームの読み書きが変わった: \(split)")

        // 止まっている間は読むだけ。書き出すのは空の描き切りが 1 回で、読み込まない
        let reading = traffic { Self.inTheInterval(canvas) { _ = canvas.get(80, 80) } }
        #expect(reading == (0, 1), "読むだけの区間の読み書きが変わった: \(reading)")
        // 次のフレームも分けなければ、消して始めて捨てて終わる
        let next = try traffic { try canvas.draw { canvas.shape(plane, at: [scene.middle]) } }
        #expect(next == (0, 0), "読むだけの区間の後のフレームが奥行きを読み書きした: \(next)")
    }

    /// 完了条件 2・3 の費用の側 — 区間で描き切らせた描き切りは、奥行きを読まずに消して始め、書き出す。
    /// 書き出した奥行きは次のフレームの最初のパスが読み込み、そのパスが最後なので捨てて終わる。
    ///
    /// 直す前は、区間の描き切りが捨てた奥行きを読み込み (中身は決まっていない)、次のフレームの
    /// 最初のパスは消して始めていた。**根そのものを数で見る** — 毒の検査 (絵で見る) が、機械の
    /// 都合で緑になるのを補う。
    @Test(
        "区間で描き切らせると、奥行きは読まずに書き出し、次のフレームの最初のパスが読む",
        arguments: Variant.all)
    func settlingWritesDepthAndTheNextFrameReadsIt(_ variant: Variant) throws {
        let (surface, effects, interval) = (variant.surface, variant.effects, variant.interval)
        let canvas = try surface.make()
        let plane = canvas.createShape {
            canvas.noStroke()
            canvas.plane(60, 60)
        }
        let scene = Scene.spread
        if interval == .stopped {
            try canvas.draw {
                canvas.background(235)
                if effects == .with { canvas.effects(Self.darkening) }
            }
        }
        let before = Self.depthTraffic(canvas)
        Self.inTheInterval(canvas) {
            canvas.shape(plane, at: [scene.front])
            _ = canvas.get(0, 0)
        }
        var now = Self.depthTraffic(canvas)
        #expect(now.loads == before.loads, "区間の描き切りが、決まっていない奥行きを読み込んだ")
        #expect(now.stores - before.stores == 1, "区間の描き切りが奥行きを書き出していない")

        try canvas.draw {
            canvas.shape(plane, at: [scene.middle])
            if interval == .setup, effects == .with { canvas.effects(Self.darkening) }
        }
        now = Self.depthTraffic(canvas)
        #expect(now.loads - before.loads == 1, "次のフレームの最初のパスが、区間の奥行きを読み込んでいない")
        #expect(now.stores - before.stores == 1, "最後のパスが奥行きを書き出した")
    }

    // MARK: - ランタイムを通す

    /// `setup()` か、止まっている間のコールバックで手前と奥を置き、`draw()` で真ん中を置くスケッチ。
    ///
    /// 止まっている間は、1 枚目で下地を描いて止まり、キー `p` のコールバックで置き、キー `r` で
    /// `redraw()` する (2 枚目)。`setup()` は、下地と手前・奥を置いて止まり、1 枚目で真ん中を置く。
    /// 描き切らせるのは、置いた後の `get()` である。
    final class SolidPlacer: Sketch {
        let interval: Interval
        let settling: Settling
        let scene: Scene
        private var tile: Shape?

        init(interval: Interval, settling: Settling, scene: Scene) {
            self.interval = interval
            self.settling = settling
            self.scene = scene
        }
        convenience init() { self.init(interval: .stopped, settling: .carried, scene: .issue) }

        var settings: SketchSettings { SketchSettings(width: 160, height: 160) }

        func setup() {
            noLoop()
            tile = createShape {
                noStroke()
                plane(60, 60)
            }
            if interval == .setup {
                background(235)
                placeFrontAndBack()
            }
        }

        private func placeFrontAndBack() {
            guard let tile else { return }
            shape(tile, at: [scene.front])
            if settling == .eachTime { _ = get(0, 0) }
            shape(tile, at: [scene.back])
            if settling != .carried { _ = get(0, 0) }
        }

        func draw() {
            guard let tile else { return }
            if interval == .stopped, frameCount == 1 {
                background(235)
            } else {
                shape(tile, at: [scene.middle])
            }
        }

        func keyPressed() {
            switch key {
            case "p": placeFrontAndBack()
            case "r": redraw()
            default: break
            }
        }
    }

    /// 2 枚目までをランタイムで走らせ、出口を通した絵を返す。
    private static func runtimePicture(
        _ interval: Interval, _ settling: Settling, _ scene: Scene
    ) throws -> DisplayImage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-solid-depth-\(UUID().uuidString)", isDirectory: true)
        let facet = directory.appendingPathComponent("facet", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtime = try SketchRuntime(
            sketch: SolidPlacer(interval: interval, settling: settling, scene: scene),
            gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        if interval == .stopped {
            for (index, key) in ["p", "r"].enumerated() {
                try AtomicFile.write(
                    Data(
                        #"{"id":"k\#(index)","events":[{"type":"keyDown","code":0,"characters":"\#(key)","isRepeat":false},{"type":"keyUp","code":0}]}"#
                            .utf8),
                    to: facet.appendingPathComponent("request.json"))
                try runtime.advance()
            }
        }
        return try runtime.target.encodeToImage().read()
    }

    /// 完了条件 1・3 をランタイムの経路で — `setup()` と、`noLoop()` の後のキーのコールバックで置いて
    /// `get()` で描き切らせても、次のフレームの絵は、描き切らせなかったときと全画素で一致する。
    @Test(
        "ランタイムを通しても、区間で描き切らせた立体の前後は持ち越した立体と同じになる",
        arguments: Interval.allCases, Scene.allCases)
    func aSketchKeepsTheDepthOfSolidsItSettled(interval: Interval, scene: Scene) throws {
        let carried = try Self.runtimePicture(interval, .carried, scene)
        for point in scene.expectations {
            let scale = Float(carried.width) / 160
            let value = carried[Int(point.x * scale), Int(point.y * scale)]
            try #require(point.color.matches(value), "持ち越した絵が奥行きどおりでない ((\(point.x), \(point.y)): \(point.why)): \(value)")
        }
        for settling in [Settling.once, .eachTime] {
            let settled = try Self.runtimePicture(interval, settling, scene)
            let differing = zip(settled.bytes, carried.bytes).filter { $0 != $1 }.count
            #expect(settled == carried, "\(settling.testDescription)描き切らせると絵が違う (\(differing) バイト)")
        }
    }
}
