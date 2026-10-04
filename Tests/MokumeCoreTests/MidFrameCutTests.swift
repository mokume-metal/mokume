// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// フレームの途中の描き切り (区切り) で、そのフレームの絵が割れないか ([#1656])。GPU を要する。
///
/// 約束は「フレームの途中で描き切っても、そのフレームの絵は、分けずに描き切ったときと変わらない」
/// である (`loadPixels()` の説明・`RenderTarget.makeRenderPass` のコメント (#456)・影の説明)。
/// 区切りが入る口 (画素の口 4 つ・揺らぎの書き換え・置いた描き場所の描き換え) と、`flush` が
/// フレームで 1 度だけ決めるもの (範囲の表の行) を掛け合わせ、区切りを入れた絵と入れない絵を
/// 比べる。**表に行を足すときは ``Scene`` に 1 つ足す** — 足した行が割れていれば、どの口でも赤になる。
///
/// 区切りより前に描いた面へ、区切りの後に置いたもの (立体の影・計算・書いた値) を効かせることは
/// できない (描き直すしかない)。その向きは説明に書いて引き受けた (案 A)。ここでは、その向きが
/// 説明どおりに割れることも見る (``theWayThatCannotBeRecovered``)。
///
/// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
@Suite(
    "フレームの途中の描き切り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MidFrameCutTests {
    private static let side = 96

    /// 値をそのまま並びへ書く計算。
    private static let stamp = """
        kernel void stamp(device float *out [[buffer(0)]],
                          constant Values &values [[buffer(MOKUME_VALUES)]],
                          uint id [[thread_position_in_grid]])
        {
            out[id] = values.amount;
        }
        """

    /// 並びの先頭を明るさにする塗り。
    private static let showFirst = """
        float4 paint(Fragment in, Values values) {
            float v = in.numbers[0];
            return float4(v, v, v, 1);
        }
        """

    /// 区切りの入れ方。**途中の描き切りが入る口の全部** (#1656 の範囲)。
    enum Cut: String, CaseIterable, CustomTestStringConvertible {
        case get
        case loadPixels
        case pixels
        case set
        /// 揺らぎの設定を書き換える (#1503 が、揺らぎを読む面を描き切らせる)。
        case noise
        /// 置いた描き場所を描き換える。**案 A2 では区切りにならない** (置いた時点の絵を写しに取る)。
        case placedLayer

        var testDescription: String { rawValue }
    }

    /// 範囲の表の行。どれも、区切りを入れても分けずに描いた絵と一致しなければならない。
    enum Scene: String, CaseIterable, CustomTestStringConvertible {
        /// 区切りより前に置いた立体の影が、後に置いた面に落ちる (完了条件 1・この Issue の再現)。
        case shadow
        /// 光と影の有効化を区切りの後に置いても、前に置いた立体が後の面に影を落とす。
        case shadowEnabledAfterCut
        /// 区切りの後の塗り直しは、前に描いたものも消す。
        case repaint
        /// 区切りの後に塗り直すと、前に置いた立体はもう影を落とさない (分けずに描けば、塗り直しが
        /// 立体ごと捨てる)。
        case repaintDropsCasters
        /// 区切りより前の立体が、後に置いた奥の立体を隠す。
        case depth
        /// 区切りより前に頼んだ計算の結果を、後の図形が読む (完了条件 4 の取り返せる向き)。
        case computation
        /// 区切りより前に数の並びへ書いた値を、後の図形が読む (同上)。
        case upload
        /// 区切りの前と後で同じ群の粒を置く。区切りより前の粒の影が、後の呼び出しの粒の影に
        /// 置き換わらない (粒の置き場の組を、持ち越した落とす列が読んでいるうちは使い回さない)。
        case particlesTwice
        /// 落とす立体を置くたびに区切る (4 回)。区切りごとに、前の区切りで焼いた面へその回の立体を
        /// 足して焼く形 (持ち越した列を焼き直さない) でも、分けずに描いた影と一致する。
        case casterPerCut

        var testDescription: String { rawValue }
    }

    /// 1 枚の面と、場面が使う道具。
    @MainActor
    private final class Rig {
        let canvas: Canvas
        let layer: Canvas
        let numbers: Numbers
        let stamp: Computation
        let show: Shader
        let dust: Particles
        var randomness = Randomness(seed: 1656)
        var seed = 4242
        /// 影の場面で影を有効にするか。比べる側が影を持つかを見るときだけ偽にする。
        var shadows = true

        init(gpu: RenderDevice) throws {
            canvas = try CanvasFixture.make(gpu: gpu, width: MidFrameCutTests.side, height: MidFrameCutTests.side)
            layer = try canvas.createGraphics(8, 8)
            numbers = try canvas.makeNumbers(count: 1)
            stamp = try canvas.makeComputation(MidFrameCutTests.stamp, name: "stamp", values: ["amount": 0])
            show = try canvas.makeShader(MidFrameCutTests.showFirst)
            dust = try canvas.makeParticles(count: 64)
            resetLayer()
        }

        /// 描き場所を最初の青に塗り直す (描き換えて区切る口が、前のフレームで描き換えている)。
        func resetLayer() {
            layer.beginDraw()
            layer.background(.linear(red: 0.25, green: 0.5, blue: 0.75))
            layer.endDraw()
        }

        func cut(_ cut: Cut) {
            switch cut {
            case .get: _ = canvas.get(40, 40)
            case .loadPixels: canvas.loadPixels()
            case .pixels: _ = canvas.pixels[40, 40]
            // 置いた描き場所の色 (左上の 8×8) をそのまま書き直す。書く口は書く前に描き切る
            case .set: canvas.set(2, 2, .linear(red: 0.25, green: 0.5, blue: 0.75))
            // 種は毎回変える (同じ値の書き直しは描き切らない)
            case .noise:
                seed += 1
                canvas.noiseSeed(seed)
            case .placedLayer:
                layer.beginDraw()
                layer.background(.linear(red: 1, green: 0, blue: 1))
                layer.endDraw()
            }
        }

        /// 場面を 2 フレーム描き、2 枚目を返す。`cut` が `nil` なら区切らない。
        ///
        /// **2 枚目を見る** — 区切りで落とす側を控えるのは影を 1 度でも有効にした面だけなので
        /// (``Canvas/shadowsEverEnabled``)、影を区切りの後で初めて有効にする場面は、1 枚目だけ説明どおりに
        /// 割れる (``theFirstFrameThatEnablesShadowsLateIsTheException()``)。
        func draw(_ scene: Scene, cut: Cut?) throws -> DisplayImage {
            for _ in 0..<2 {
                resetLayer()
                try canvas.draw {
                    canvas.background(.linear(red: 0, green: 0, blue: 0))
                    // 断片はフレームを越えるので、前のフレームの塗り (計算・届けの場面) を外す
                    canvas.resetShader()
                    // **どの場面も、最初に描き場所を置く** — 置いた描き場所の描き換え (`placedLayer`)
                    // をほかの口と同じ場所で区切れるようにする
                    canvas.image(layer, 0, 0)
                    body(scene, cut: { if let cut { self.cut(cut) } })
                }
            }
            return try canvas.output.encodeForDisplay()
        }

        private func floorAndSphere(lightsBeforeCut: Bool, cut: () -> Void) {
            canvas.camera(48, -36, 120, 48, 48, 0, 0, 1, 0)
            if lightsBeforeCut {
                canvas.lights()
                canvas.shadows(shadows)
            }
            canvas.noStroke()
            canvas.fill(.linear(red: 0.8, green: 0.8, blue: 0.8))
            canvas.push()
            canvas.translate(48, 36, 0)
            canvas.sphere(15)
            canvas.pop()
            cut()
            if !lightsBeforeCut {
                canvas.lights()
                canvas.shadows(shadows)
            }
            canvas.castShadow(false)
            canvas.push()
            canvas.translate(48, 72, 0)
            canvas.box(96, 4, 96)
            canvas.pop()
        }

        func body(_ scene: Scene, cut: () -> Void) {
            switch scene {
            case .shadow:
                floorAndSphere(lightsBeforeCut: true, cut: cut)
            case .shadowEnabledAfterCut:
                floorAndSphere(lightsBeforeCut: false, cut: cut)
            case .repaint:
                canvas.noStroke()
                canvas.fill(.linear(red: 1, green: 0, blue: 0))
                canvas.rect(10, 10, 40, 40)
                cut()
                canvas.background(.linear(red: 0, green: 0, blue: 1))
                canvas.fill(.linear(red: 0, green: 1, blue: 0))
                canvas.rect(30, 30, 40, 40)
            case .repaintDropsCasters:
                floorAndSphere(lightsBeforeCut: true) {
                    cut()
                    canvas.background(.linear(red: 0, green: 0, blue: 0))
                }
            case .depth:
                canvas.lights()
                canvas.noStroke()
                canvas.fill(.linear(red: 1, green: 0.2, blue: 0.2))
                canvas.push()
                canvas.translate(48, 48, 30)
                canvas.box(24)
                canvas.pop()
                cut()
                canvas.fill(.linear(red: 0.2, green: 0.2, blue: 1))
                canvas.push()
                canvas.translate(48, 48, -30)
                canvas.box(50)
                canvas.pop()
            case .computation:
                stamp.set("amount", 0.6)
                canvas.compute(stamp, over: 1, writes: [numbers])
                cut()
                canvas.noStroke()
                canvas.numbers(numbers)
                canvas.shader(show)
                canvas.rect(20, 20, 50, 30)
            case .upload:
                numbers.set(0.6, at: 0)
                cut()
                canvas.noStroke()
                canvas.numbers(numbers)
                canvas.shader(show)
                canvas.rect(20, 20, 50, 30)
            case .particlesTwice:
                canvas.camera(48, -36, 120, 48, 48, 0, 0, 1, 0)
                canvas.lights()
                canvas.shadows(shadows)
                canvas.noStroke()
                canvas.emit(
                    dust, from: .point(36, 36), rate: 600, speed: 0...0, angle: 0...0,
                    life: 5...5, size: 24...24, color: .linear(red: 0.9, green: 0.9, blue: 0.9),
                    using: &randomness)
                canvas.particles(dust)
                cut()
                // 後の呼び出しは横へずらす。組を使い回すと、前の呼び出しの置き場所がこれで上書きされる
                canvas.push()
                canvas.translate(24, 0, 0)
                canvas.particles(dust)
                canvas.pop()
                canvas.castShadow(false)
                canvas.fill(.linear(red: 0.8, green: 0.8, blue: 0.8))
                canvas.push()
                canvas.translate(48, 72, 0)
                canvas.box(96, 4, 96)
                canvas.pop()
            case .casterPerCut:
                canvas.camera(48, -36, 120, 48, 48, 0, 0, 1, 0)
                canvas.lights()
                canvas.shadows(shadows)
                canvas.noStroke()
                canvas.fill(.linear(red: 0.8, green: 0.8, blue: 0.8))
                for index in 0..<4 {
                    canvas.push()
                    canvas.translate(18 + Float(index) * 20, 36, 0)
                    canvas.sphere(7)
                    canvas.pop()
                    cut()
                }
                canvas.castShadow(false)
                canvas.push()
                canvas.translate(48, 72, 0)
                canvas.box(96, 4, 96)
                canvas.pop()
            }
        }
    }

    /// 成分の差が表示の 1 段 (1/255) を越える画素の数。
    private func differing(_ a: DisplayImage, _ b: DisplayImage) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let (p, q) = (a[x, y], b[x, y])
                let gap = max(
                    abs(Int(p.red) - Int(q.red)), abs(Int(p.green) - Int(q.green)),
                    abs(Int(p.blue) - Int(q.blue)), abs(Int(p.alpha) - Int(q.alpha)))
                if gap > 1 { count += 1 }
            }
        }
        return count
    }

    /// 最初に違う画素と、その 2 つの値 (赤のときの手がかり)。
    private func firstDifference(_ a: DisplayImage, _ b: DisplayImage) -> String {
        for y in 0..<a.height {
            for x in 0..<a.width where a[x, y] != b[x, y] {
                return "(\(x), \(y)): \(a[x, y]) と \(b[x, y])"
            }
        }
        return "無し"
    }

    // MARK: - 取り返せる向き (完了条件 1・2・4・5)

    @Test("区切りを入れても、分けずに描いた絵と変わらない", arguments: Scene.allCases, Cut.allCases)
    func aCutKeepsTheFrame(scene: Scene, cut: Cut) throws {
        let gpu = try RenderDevice()
        let plain = try Rig(gpu: gpu).draw(scene, cut: nil)
        let cutFrame = try Rig(gpu: gpu).draw(scene, cut: cut)
        let gap = differing(plain, cutFrame)
        #expect(
            gap == 0,
            "\(cut) で区切ると \(scene) の絵が \(gap) 画素違う (最初の画素 \(firstDifference(plain, cutFrame)))")
    }

    @Test("影の場面は、区切らなくても床に影が落ちている (比べる側が影を持つ)",
        arguments: [Scene.shadow, .particlesTwice])
    func theShadowSceneHasAShadow(scene: Scene) throws {
        // **比べる側に影が無いと、上の一致は何も見ていない。** 影を切った絵と比べて床が暗い
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        let shadowed = try rig.draw(scene, cut: nil)
        let withoutShadows = try Rig(gpu: gpu)
        withoutShadows.shadows = false
        let unshadowed = try withoutShadows.draw(scene, cut: nil)
        var darker = 0
        for y in 0..<shadowed.height {
            for x in 0..<shadowed.width
            where Int(unshadowed[x, y].red) - Int(shadowed[x, y].red) > 20 { darker += 1 }
        }
        #expect(darker > 50, "床に影が落ちていない (\(darker) 画素)")
    }

    // MARK: - 区切りが払うもの (#1656 の反証 3・6、2 回目の反証 4・6・10・11)

    @Test("区切りのたびに、持ち越した落とす列は焼き直さず、上げ直さない")
    func casterPerCutAddsInsteadOfRebaking() throws {
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        var segments = -1
        try rig.canvas.draw {
            rig.canvas.background(.linear(red: 0, green: 0, blue: 0))
            rig.body(.casterPerCut, cut: { rig.cut(.get) })
            segments = rig.canvas.frameCasters.segments.count
        }
        // 区切り 4 回で区画は 4 本 (区切りごとにその回の分だけ上げる)。焼くのは 1 回目の区切りの
        // 全部と、2〜4 回目の区切りで足す 3 回 (終わりの描き切りは、持ち越した列だけなので使い回す)
        #expect(segments == 4)
        #expect(rig.canvas.shadowBakesAdded == 3, "足して焼いた回数: \\(rig.canvas.shadowBakesAdded)")
        #expect(rig.canvas.shadowBakesEncoded == 4, "焼いた回数: \\(rig.canvas.shadowBakesEncoded)")
    }

    @Test("区切らない影の場面は、焼き付けの頭で前の読みを待たない")
    func anUncutFrameDoesNotWaitBeforeBaking() throws {
        let gpu = try RenderDevice()
        let plain = try Rig(gpu: gpu)
        _ = try plain.draw(.shadow, cut: nil)
        #expect(plain.canvas.shadowBakesEncoded > 0)
        #expect(plain.canvas.shadowRebakeBarriersEncoded == 0)
        let cutting = try Rig(gpu: gpu)
        _ = try cutting.draw(.casterPerCut, cut: .get)
        #expect(cutting.canvas.shadowRebakeBarriersEncoded > 0)
    }

    @Test("形の組み立ての出口の安全網は、前の区切りで描いた立体の影を捨てない")
    func theShapeSafetyNetKeepsEarlierCasters() throws {
        let gpu = try RenderDevice()
        func picture(drawsOutAShape: Bool) throws -> DisplayImage {
            let rig = try Rig(gpu: gpu)
            let canvas = rig.canvas
            for _ in 0..<2 {
                try canvas.draw {
                    canvas.background(.linear(red: 0, green: 0, blue: 0))
                    canvas.camera(48, -36, 120, 48, 48, 0, 0, 1, 0)
                    canvas.lights()
                    canvas.shadows(true)
                    canvas.noStroke()
                    canvas.fill(.linear(red: 0.8, green: 0.8, blue: 0.8))
                    canvas.push()
                    canvas.translate(48, 36, 0)
                    canvas.sphere(15)
                    canvas.pop()
                    _ = canvas.get(0, 0)
                    // 画面の外の小さな平面 (揺らぎの書き換えが描き切る溜めたもの)
                    canvas.rect(-10, -10, 1, 1)
                    if drawsOutAShape {
                        rig.seed += 1
                        _ = canvas.createShape { canvas.noiseSeed(rig.seed) }
                    }
                    canvas.castShadow(false)
                    canvas.push()
                    canvas.translate(48, 72, 0)
                    canvas.box(96, 4, 96)
                    canvas.pop()
                }
            }
            return try canvas.output.encodeForDisplay()
        }
        let gap = differing(try picture(drawsOutAShape: false), try picture(drawsOutAShape: true))
        #expect(gap == 0, "安全網の後で \\(gap) 画素違う")
    }

    @Test("細かさを下げた面の途中の描き切りは出す先を変えないので、置いた側は写さない")
    func aCutThatLeavesTheOutputAloneCopiesNothing() throws {
        let gpu = try RenderDevice()
        let placer = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        let placed = try Canvas(
            output: try RenderTarget(gpu: gpu, width: 64, height: 64), gpu: gpu,
            pixelDensity: 0.5, upscale: .spatial)
        try placed.draw { placed.background(.linear(red: 0, green: 0, blue: 1)) }
        var copiedByTheCut = -1
        try placer.draw {
            placer.background(.linear(red: 0, green: 0, blue: 0))
            placer.image(placed, 0, 0)
            try? placed.draw {
                placed.background(.linear(red: 1, green: 0, blue: 0))
                _ = placed.get(0, 0)
                copiedByTheCut = placer.placedPicturesCopied
            }
        }
        #expect(copiedByTheCut == 0, "出す先が変わらない途中の描き切りで写した")
        #expect(placer.placedPicturesCopied == 1, "出す先が変わる描き切りで写していない")
        // 置いた時点の絵 (青) が出る
        let point = try placer.output.encodeForDisplay()[8, 8]
        #expect(point.blue > 200 && point.red < 30, "置いた時点の絵が出ていない: \\(point)")
    }

    // MARK: - 描き切りの外で出す先を書く口 (#1942)

    private static let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private static let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
    private static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)

    /// 置いた時点の絵 (青) が出ているか。
    private static func isBlue(_ point: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)) -> Bool {
        point.blue > 200 && point.red < 30 && point.green < 30
    }

    /// 置いた側に出るのは置いた時点の絵である ([#1656] の案 A2) — **出す先を書く口が、描き切り
    /// (`flush`) の外にもある**。その口も、書く前に置いた側へ置いた時点の絵を写させる。
    ///
    /// 面 (`Canvas`) が自分の出す先を書く口は、描き切りのほかに 4 つある: 細かさを下げた面の追い付き
    /// (`catchUpOutput()`)・細かさ 1 の面の書き戻し (`writeBackPendingPixels()`)・出力段の書き戻し
    /// (`RenderTarget.encode(into:)`)・出す先を直に塗る `fill(with:)`。ここはその口ごとに 1 本置く。
    ///
    /// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
    @Test("細かさを下げた面の出す先を読む口が追い付いても、置いた側には置いた時点の絵が出る (#1942)")
    func catchingUpTheOutputKeepsThePlacedPicture() throws {
        let gpu = try RenderDevice()
        let placer = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        let placed = try Canvas(
            output: try RenderTarget(gpu: gpu, width: 64, height: 64), gpu: gpu,
            pixelDensity: 0.5, upscale: .spatial)
        try placed.draw { placed.background(Self.blue) }
        try placer.draw {
            placer.background(Self.black)
            placer.image(placed, 0, 0)
            try? placed.draw {
                placed.background(Self.red)
                // 途中の描き切り: 描く先だけが赤になる (出す先は青のまま。置いた側は写さない)
                _ = placed.get(0, 0)
                // 読む口が追い付く: 出す先が赤になる。**書く前に置いた側へ写させる**
                _ = try? placed.output.readPixels()
            }
        }
        let point = try placer.output.encodeForDisplay()[8, 8]
        #expect(Self.isBlue(point), "置いた時点の絵が出ていない: \(point)")
        // 置いた側が持つのは置いた時点の絵で、描き場所の絵は赤に変わっている
        let placed8 = try placed.output.encodeForDisplay()[8, 8]
        #expect(placed8.red > 200 && placed8.blue < 30, "描き場所の絵が変わっていない: \(placed8)")
    }

    @Test("細かさ 1 の面を出力段が書き戻しても、置いた側には置いた時点の絵が出る (#1942)")
    func writingBackFromTheOutputStageKeepsThePlacedPicture() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        let pg = try canvas.createGraphics(16, 16)
        try canvas.draw {
            canvas.background(Self.black)
            pg.beginDraw()
            pg.background(Self.blue)
            pg.loadPixels()  // 描き切り (まだ誰も置いていない)
            canvas.image(pg, 0, 0)  // 置いた時点の絵 = 青
            pg.set(0, 0, Self.red)  // 読み込み済みなので描き切らない。書き込み待ちになる
            // 出力段が書き戻す: 描き場所の出す先の (0, 0) が赤になる。**書く前に置いた側へ写させる**
            _ = try? pg.output.encodeForDisplay()
            pg.endDraw()
        }
        let point = try canvas.output.encodeForDisplay()[0, 0]
        #expect(Self.isBlue(point), "置いた時点の絵が出ていない: \(point)")
        let written = try pg.output.encodeForDisplay()[0, 0]
        #expect(written.red > 200 && written.blue < 30, "描き場所の絵に書いた画素が出ていない: \(written)")
    }

    @Test("出す先を直に塗っても、置いた側には置いた時点の絵が出る (#1942)")
    func fillingTheOutputKeepsThePlacedPicture() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        let pg = try canvas.createGraphics(16, 16)
        try pg.draw { pg.background(Self.blue) }
        try canvas.draw {
            canvas.background(Self.black)
            canvas.image(pg, 0, 0)  // 置いた時点の絵 = 青
            // 出す先を直に塗る。**塗る前に置いた側へ写させる**
            try? pg.output.fill(with: Self.red)
        }
        let point = try canvas.output.encodeForDisplay()[8, 8]
        #expect(Self.isBlue(point), "置いた時点の絵が出ていない: \(point)")
        let filled = try pg.output.encodeForDisplay()[8, 8]
        #expect(filled.red > 200 && filled.blue < 30, "塗った絵が出す先に出ていない: \(filled)")
    }

    @Test("出す先が変わらない口は、置いた側に写させない (#1942)")
    func readingWithoutAChangeCopiesNothing() throws {
        let gpu = try RenderDevice()
        let placer = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        let spatial = try Canvas(
            output: try RenderTarget(gpu: gpu, width: 64, height: 64), gpu: gpu,
            pixelDensity: 0.5, upscale: .spatial)
        let pg = try placer.createGraphics(16, 16)
        try spatial.draw { spatial.background(Self.blue) }
        try pg.draw { pg.background(Self.blue) }
        var copied = -1
        try placer.draw {
            placer.background(Self.black)
            placer.image(spatial, 0, 0)
            placer.image(pg, 32, 0)
            // どちらも変えていない。読む口は、追い付かず書き戻さず、置いた側へ写させない
            _ = try? spatial.output.readPixels()
            _ = try? pg.output.encodeForDisplay()
            _ = try? pg.output.readPixels()
            copied = placer.placedPicturesCopied
        }
        #expect(copied == 0, "出す先が変わらないのに、置いた側へ写させた")
        #expect(placer.placedPicturesCopied == 0)
    }

    /// 出す先を書く口 ([#1942])。**描き切りの外に 4 つある。**
    enum Outlet: CaseIterable, CustomTestStringConvertible {
        /// 細かさを下げた面を、出す先を読む口 (`readPixels()`) で追い付かせる (`catchUpOutput()`)。
        case catchUp
        /// 細かさ 1 の描き場所の書き込み待ちを、出力段 (`encodeForDisplay()`) が書き戻す。
        case outputStage
        /// 細かさ 1 の描き場所の書き込み待ちを、配った直後の追い付き (`catchUpOutputWithoutThrowing()`)
        /// が書き戻す (`writeBackPendingPixels()`)。
        case writeBack
        /// 出す先を直に塗る (`fill(with:)`)。
        case fill

        var testDescription: String {
            switch self {
            case .catchUp: "細かさ 0.5 の追い付き"
            case .outputStage: "出力段の書き戻し"
            case .writeBack: "配った直後の書き戻し"
            case .fill: "出す先を直に塗る"
            }
        }

        /// 書き込み待ちを作る口か。描き場所を開いたまま、読み込んでから画素を書く。
        var writesPixels: Bool { self == .outputStage || self == .writeBack }
    }

    /// 口の 1 つを、置いたあとに踏む面。**青く描いた面を置き、置いた後に口を踏んで赤く変える。**
    /// 変わる画素は (0, 0) で、置いた側のその位置に青 (置いた時点の絵) が出るはずである。
    private final class Face {
        let canvas: Canvas
        let outlet: Outlet

        init(outlet: Outlet, gpu: RenderDevice, parent: Canvas) throws {
            self.outlet = outlet
            switch outlet {
            case .catchUp:
                canvas = try Canvas(
                    output: try RenderTarget(gpu: gpu, width: 16, height: 16), gpu: gpu,
                    pixelDensity: 0.5, upscale: .spatial)
                try canvas.draw { canvas.background(MidFrameCutTests.blue) }
            case .fill:
                canvas = try parent.createGraphics(16, 16)
                try canvas.draw { canvas.background(MidFrameCutTests.blue) }
            case .outputStage, .writeBack:
                canvas = try parent.createGraphics(16, 16)
            }
        }

        /// 置く前。書き込み待ちを作る口は、描き場所を開いて読み込んでおく (読み込み済みなら、画素を
        /// 書いても描き切らず、描き切りの頭の関所を通らない)。
        func prepare() {
            guard outlet.writesPixels else { return }
            canvas.beginDraw()
            canvas.background(MidFrameCutTests.blue)
            canvas.loadPixels()
        }

        /// 置いた後。出す先を書く口を踏む。**関所を通らなければ、置いた側に赤が出る。**
        func change() {
            switch outlet {
            case .catchUp:
                try? canvas.draw {
                    canvas.background(MidFrameCutTests.red)
                    // 途中の描き切り: 描く先だけが赤になる (出す先は青のまま)
                    _ = canvas.get(0, 0)
                    // 読む口が追い付く: 出す先が赤になる
                    _ = try? canvas.output.readPixels()
                }
            case .outputStage:
                canvas.set(0, 0, MidFrameCutTests.red)
                _ = try? canvas.output.encodeForDisplay()
            case .writeBack:
                canvas.set(0, 0, MidFrameCutTests.red)
                canvas.catchUpOutputWithoutThrowing()
            case .fill:
                try? canvas.output.fill(with: MidFrameCutTests.red)
            }
        }

        func finish() {
            if outlet.writesPixels { canvas.endDraw() }
        }
    }

    @Test(
        "写しの上限を越えて出す先を書いても、置いた側は描き切られ、置いた時点の絵が出る (#1942)",
        arguments: Outlet.allCases)
    func everyOutletFallsBackToDrawingOutAtTheLimit(outlet: Outlet) throws {
        // 写しを取れない (上限に達した) ときの関所は、置いた側を描き切らせる (#1656)。出す先を書く
        // 口が通す関所でも同じに働く。**描き切りはコマンドを開く前に走る** ので、入れ子にならない。
        // 置いた側が持てる写しは上限 (4) までで、越えた分の口は置いた側を描き切らせる
        let gpu = try RenderDevice()
        let board = try CanvasFixture.make(gpu: gpu, width: 120, height: 16)
        let rounds = Canvas.placedPictureCopyLimit + 2
        let faces = try (0..<rounds).map { _ in try Face(outlet: outlet, gpu: gpu, parent: board) }
        try board.draw {
            board.background(Self.black)
            for (index, face) in faces.enumerated() {
                face.prepare()
                board.image(face.canvas, Float(index * 20), 0)
                face.change()
                face.finish()
            }
        }
        #expect(board.placedPictureCopyLimitReached > 0, "上限に達していない (検査の前提)")
        let image = try board.output.encodeForDisplay()
        for index in 0..<rounds {
            let point = image[index * 20, 0]
            #expect(Self.isBlue(point), "\(index) 番目に置いた時点の絵が出ていない: \(point)")
        }
    }

    @Test(
        "同じ描き場所を置いた側が複数いても、どの置いた側にも置いた時点の絵が出る (#1942)",
        arguments: Outlet.allCases)
    func everyPlacerKeepsThePlacedPicture(outlet: Outlet) throws {
        let gpu = try RenderDevice()
        let first = try CanvasFixture.make(gpu: gpu, width: 32, height: 16)
        let second = try CanvasFixture.make(gpu: gpu, width: 32, height: 16)
        let face = try Face(outlet: outlet, gpu: gpu, parent: first)
        try first.draw {
            try? second.draw {
                first.background(Self.black)
                second.background(Self.black)
                face.prepare()
                first.image(face.canvas, 0, 0)
                second.image(face.canvas, 8, 0)
                // 口を踏む。**置いた側ごとに、書く前に写させる**
                face.change()
                face.finish()
            }
        }
        let one = try first.output.encodeForDisplay()[0, 0]
        let two = try second.output.encodeForDisplay()[8, 0]
        #expect(Self.isBlue(one), "1 つ目の置いた側に置いた時点の絵が出ていない: \(one)")
        #expect(Self.isBlue(two), "2 つ目の置いた側に置いた時点の絵が出ていない: \(two)")
        #expect(first.placedPicturesCopied == 1, "1 つ目の置いた側が写していない")
        #expect(second.placedPicturesCopied == 1, "2 つ目の置いた側が写していない")
    }

    @Test("組み立ての途中の面を守るのは、自分を直に置いた面だけ (写しで止まる先は見ない)")
    func onlyDirectPlacersGuardAShapeInProgress() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        let inner = try canvas.createGraphics(8, 8)
        let outer = try canvas.createGraphics(16, 16)
        var outerGuarded = false
        var innerGuarded = true
        try canvas.draw {
            outer.beginDraw()
            outer.image(inner, 0, 0)
            outer.endDraw()
            outer.beginDraw()
            outer.image(inner, 0, 0)
            canvas.image(outer, 0, 0)
            _ = canvas.createShape {
                outerGuarded = outer.isPlacedInAShapeInProgress
                innerGuarded = inner.isPlacedInAShapeInProgress
            }
            outer.endDraw()
        }
        #expect(outerGuarded, "組み立ての途中の面に直に置かれた面を守っていない")
        #expect(!innerGuarded, "写しで止まる先まで守った")
    }

    @Test("区切りを毎フレーム持つ静止した場面は、2 枚目から焼き直さない")
    func aStillSceneWithACutIsNotRebaked() throws {
        // 区切りの焼き (この回の列が球) と終わりの焼き (持ち越した列が球) は同じ指紋になり、
        // 終わりの焼きは区切りで焼いた面を使い回す。次のフレームの区切りも前のフレームと同じ指紋
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        _ = try rig.draw(.shadow, cut: .get)
        let afterTwoFrames = rig.canvas.shadowBakesEncoded
        _ = try rig.draw(.shadow, cut: .get)
        #expect(afterTwoFrames == 1, "最初のフレームで \(afterTwoFrames) 回焼いた (区切りの 1 回のはず)")
        #expect(rig.canvas.shadowBakesEncoded == afterTwoFrames, "静止した場面を焼き直した")
    }

    @Test("区切りの後に影を受ける立体が無ければ、終わりの描き切りは焼かない")
    func nothingToReceiveMeansNoBake() throws {
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        let canvas = rig.canvas
        for frame in 0..<2 {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.shadows(true)
                canvas.noStroke()
                canvas.push()
                canvas.translate(48, 48, 0)
                // 1 枚目と 2 枚目で動かす (焼き直しの省略に頼らない)
                canvas.rotateY(Float(frame))
                canvas.box(30)
                canvas.pop()
                _ = canvas.get(0, 0)
                // 手元の表示だけ
                canvas.fill(.linear(red: 1, green: 1, blue: 1))
                canvas.rect(0, 0, 20, 10)
            }
        }
        #expect(canvas.shadowBakesEncoded == 2, "区切りの焼き 2 回のほかに焼いた: \(canvas.shadowBakesEncoded)")
        // 終わりの描き切りは、焼いた面を使い回すこともしない (使い回すと、受けない絵のために束ねる)
        #expect(canvas.shadowBakesReused == 0, "受ける立体の無い描き切りが影を束ねた")
    }

    @Test("影を 1 度も使っていない面の区切りは、落とす側を写さない")
    func aSketchWithoutShadowsKeepsNoCasters() throws {
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        let canvas = rig.canvas
        var kept = -1
        try canvas.draw {
            canvas.lights()
            canvas.box(30)
            _ = canvas.get(0, 0)
            kept = canvas.frameCasters.casters.count
        }
        #expect(kept == 0)
        #expect(!canvas.shadowsEverEnabled)
    }

    @Test("フレームの外の区切りは、影を使う面でも落とす側を写さない (止まっている間に積み上がらない)")
    func aCutOutsideTheFrameKeepsNoCasters() throws {
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        let canvas = rig.canvas
        _ = try rig.draw(.shadow, cut: nil)
        canvas.carriesOver = true
        defer { canvas.carriesOver = false }
        for _ in 0..<3 {
            canvas.box(10)
            _ = canvas.get(0, 0)
        }
        #expect(canvas.frameCasters.isEmpty, "止まっている間の区切りで落とす側を写した")
    }

    @Test("影を初めて有効にしたフレームで、区切りの後に有効にすると、前の立体は影を落とさない (説明どおり)")
    func theFirstFrameThatEnablesShadowsLateIsTheException() throws {
        let gpu = try RenderDevice()
        func first(cut: MidFrameCutTests.Cut?) throws -> DisplayImage {
            let rig = try Rig(gpu: gpu)
            try rig.canvas.draw {
                rig.canvas.background(.linear(red: 0, green: 0, blue: 0))
                rig.body(.shadowEnabledAfterCut, cut: { if let cut { rig.cut(cut) } })
            }
            return try rig.canvas.output.encodeForDisplay()
        }
        #expect(differing(try first(cut: nil), try first(cut: .get)) > 50)
    }

    // MARK: - 案 A2: 置いた描き場所の描き換えは区切らない (完了条件 2)

    @Test("置いた描き場所を描き換えても、置いた側は途中で描き切られない")
    func redrawingAPlacedLayerDoesNotCutThePlacer() throws {
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        var before: Canvas.SettleMark?
        var after: Canvas.SettleMark?
        try rig.canvas.draw {
            rig.canvas.background(.linear(red: 0, green: 0, blue: 0))
            rig.canvas.image(rig.layer, 0, 0)
            before = rig.canvas.settleMark
            rig.cut(.placedLayer)
            after = rig.canvas.settleMark
            rig.canvas.image(rig.layer, 16, 0)
        }
        #expect(before == after, "描き換えの前に、置いた側が描き切られた")
        // 先に置いた場所は置いた時点の絵、後に置いた場所は描き換えた後の絵
        let image = try rig.canvas.output.encodeForDisplay()
        let first = image[4, 4]
        let second = image[20, 4]
        #expect(first.green > 100, "先に置いた場所が描き換えた後の絵になった")
        #expect(second.red > 200 && second.green < 30 && second.blue > 200, "後に置いた場所が描き換えた後の絵になっていない")
    }

    @Test("置いた時点の絵の写しは、同じ大きさなら毎フレーム作り直さない")
    func theCopyOfAPlacedPictureIsReused() throws {
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        for _ in 0..<4 {
            try rig.canvas.draw {
                rig.canvas.background(.linear(red: 0, green: 0, blue: 0))
                rig.canvas.image(rig.layer, 0, 0)
                rig.cut(.placedLayer)
            }
        }
        #expect(rig.canvas.placedPictureCopiesMade == 1)
        #expect(rig.canvas.placedPicturesCopied == 4)
    }

    @Test("止まっている間に置いた描き場所を描き直しても、置いた側は描き切られず、次のフレームに置いた時点の絵が出る")
    func aLayerRedrawnWhileStoppedKeepsThePlacedPicture() throws {
        // 止まっている間 (持ち越しの区間) に置いたものは、次のフレームの最初の描き切りに載る。描き場所を
        // 描き直す直前に置いた側を描き切らせていた間は、この形だけが止まっている間に面を変えていた
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        try rig.canvas.draw { rig.canvas.background(.linear(red: 0, green: 0, blue: 0)) }
        let mark = rig.canvas.settleMark
        rig.canvas.carriesOver = true
        rig.canvas.image(rig.layer, 0, 0)
        rig.cut(.placedLayer)
        rig.canvas.carriesOver = false
        #expect(rig.canvas.settleMark == mark, "止まっている間に、置いた側が描き切られた")

        try rig.canvas.draw {}
        let placed = try rig.canvas.output.encodeForDisplay()[4, 4]
        #expect(placed.green > 100 && placed.red < 200, "置いた時点の絵が出ていない: \(placed)")
    }

    @Test("1 フレームに置いて描き換えるのを上限より多く繰り返すと、越えた分は描き切り、写しは上限で止まる")
    func copiesStopAtTheLimit() throws {
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        let canvas = rig.canvas
        let rounds = Canvas.placedPictureCopyLimit + 2
        for _ in 0..<2 {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                for index in 0..<rounds {
                    rig.layer.beginDraw()
                    rig.layer.background(.linear(red: Float(index + 1) / Float(rounds), green: 0, blue: 0))
                    rig.layer.endDraw()
                    canvas.image(rig.layer, Float(index * 12), 0)
                }
                // 最後に置いた後にもう 1 度描き換える (最後の置き場も写すか描き切るかを通る)
                rig.layer.beginDraw()
                rig.layer.background(.linear(red: 0, green: 1, blue: 0))
                rig.layer.endDraw()
            }
        }
        #expect(canvas.placedPictureCopiesMade == Canvas.placedPictureCopyLimit)
        #expect(canvas.placedPictureCopyLimitReached > 0)
        // どの置き場にも、置いた時点の絵が出る (赤が置いた順に明るくなる・緑は出ない)
        let image = try canvas.output.encodeForDisplay()
        var previous = -1
        for index in 0..<rounds {
            let point = image[index * 12 + 4, 4]
            #expect(Int(point.red) > previous && point.green == 0, "\(index) 番目: \(point)")
            previous = Int(point.red)
        }
    }

    // MARK: - 取り返せない向き (完了条件 3・4。説明に書いて引き受けた)

    @Test("区切りより前に描いた面は、区切りの後に置いた立体の影を受けない (説明どおり)")
    func anEarlierSurfaceMissesALaterCastersShadow() throws {
        let gpu = try RenderDevice()
        func draw(cuts: Bool) throws -> DisplayImage {
            let rig = try Rig(gpu: gpu)
            let canvas = rig.canvas
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.camera(48, -36, 120, 48, 48, 0, 0, 1, 0)
                canvas.lights()
                canvas.shadows(true)
                canvas.noStroke()
                canvas.fill(.linear(red: 0.8, green: 0.8, blue: 0.8))
                canvas.castShadow(false)
                canvas.push()
                canvas.translate(48, 72, 0)
                canvas.box(96, 4, 96)
                canvas.pop()
                if cuts { canvas.loadPixels() }
                canvas.castShadow(true)
                canvas.push()
                canvas.translate(48, 36, 0)
                canvas.sphere(15)
                canvas.pop()
            }
            return try canvas.output.encodeForDisplay()
        }
        let plain = try draw(cuts: false)
        let cut = try draw(cuts: true)
        // 分けなければ床に影が落ち、区切ると落ちない (床は既に描かれている)
        var lighter = 0
        for y in 0..<plain.height {
            for x in 0..<plain.width where Int(cut[x, y].red) - Int(plain[x, y].red) > 20 {
                lighter += 1
            }
        }
        #expect(lighter > 50, "区切っても床に後の立体の影が落ちた (説明と違う)")
    }

    /// 区切りより前に置いた図形は、区切りの後に頼んだ計算・書いた値を読まない。
    enum LateChange: String, CaseIterable, CustomTestStringConvertible {
        case computation
        case upload
        var testDescription: String { rawValue }
    }

    @Test("区切りより前に置いた図形は、区切りの後に頼んだ計算・書いた値を読まない (説明どおり)",
        arguments: LateChange.allCases)
    func theWayThatCannotBeRecovered(change: LateChange) throws {
        let gpu = try RenderDevice()
        func draw(cuts: Bool) throws -> DisplayImage {
            let rig = try Rig(gpu: gpu)
            let canvas = rig.canvas
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.numbers(rig.numbers)
                canvas.shader(rig.show)
                canvas.rect(0, 0, 40, 40)
                if cuts { canvas.loadPixels() }
                switch change {
                case .computation:
                    rig.stamp.set("amount", 0.6)
                    canvas.compute(rig.stamp, over: 1, writes: [rig.numbers])
                case .upload:
                    rig.numbers.set(0.6, at: 0)
                }
                canvas.rect(50, 50, 40, 40)
            }
            return try canvas.output.encodeForDisplay()
        }
        let plain = try draw(cuts: false)
        let cut = try draw(cuts: true)
        // 後に置いた図形はどちらも新しい値を読む
        #expect(plain[70, 70].red > 100)
        #expect(cut[70, 70].red == plain[70, 70].red)
        // 前に置いた図形は、分ければ新しい値・区切れば区切りの時点の値 (0) を読む
        #expect(plain[20, 20].red > 100)
        #expect(cut[20, 20].red == 0)
    }
}
