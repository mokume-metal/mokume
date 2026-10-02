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

        var testDescription: String { rawValue }
    }

    /// 1 枚の面と、場面が使う道具。
    @MainActor
    private struct Rig {
        let canvas: Canvas
        let layer: Canvas
        let numbers: Numbers
        let stamp: Computation
        let show: Shader
        /// 影の場面で影を有効にするか。比べる側が影を持つかを見るときだけ偽にする。
        var shadows = true

        init(gpu: RenderDevice) throws {
            canvas = try CanvasFixture.make(gpu: gpu, width: MidFrameCutTests.side, height: MidFrameCutTests.side)
            layer = try canvas.createGraphics(8, 8)
            layer.beginDraw()
            layer.background(.linear(red: 0.25, green: 0.5, blue: 0.75))
            layer.endDraw()
            numbers = try canvas.makeNumbers(count: 1)
            stamp = try canvas.makeComputation(MidFrameCutTests.stamp, name: "stamp", values: ["amount": 0])
            show = try canvas.makeShader(MidFrameCutTests.showFirst)
        }

        func cut(_ cut: Cut) {
            switch cut {
            case .get: _ = canvas.get(40, 40)
            case .loadPixels: canvas.loadPixels()
            case .pixels: _ = canvas.pixels[40, 40]
            // 置いた描き場所の色 (左上の 8×8) をそのまま書き直す。書く口は書く前に描き切る
            case .set: canvas.set(2, 2, .linear(red: 0.25, green: 0.5, blue: 0.75))
            case .noise: canvas.noiseSeed(4242)
            case .placedLayer:
                layer.beginDraw()
                layer.background(.linear(red: 1, green: 0, blue: 1))
                layer.endDraw()
            }
        }

        /// 場面を 1 フレーム描く。`cut` が `nil` なら区切らない。
        func draw(_ scene: Scene, cut: Cut?) throws -> DisplayImage {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                // **どの場面も、最初に描き場所を置く** — 置いた描き場所の描き換え (`placedLayer`) を
                // ほかの口と同じ場所で区切れるようにする
                canvas.image(layer, 0, 0)
                body(scene, cut: { if let cut { self.cut(cut) } })
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

        private func body(_ scene: Scene, cut: () -> Void) {
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

    // MARK: - 取り返せる向き (完了条件 1・2・4・5)

    @Test("区切りを入れても、分けずに描いた絵と変わらない", arguments: Scene.allCases, Cut.allCases)
    func aCutKeepsTheFrame(scene: Scene, cut: Cut) throws {
        let gpu = try RenderDevice()
        let plain = try Rig(gpu: gpu).draw(scene, cut: nil)
        let cutFrame = try Rig(gpu: gpu).draw(scene, cut: cut)
        let gap = differing(plain, cutFrame)
        #expect(gap == 0, "\(cut) で区切ると \(scene) の絵が \(gap) 画素違う")
    }

    @Test("影の場面は、区切らなくても床に影が落ちている (比べる側が影を持つ)")
    func theShadowSceneHasAShadow() throws {
        // **比べる側に影が無いと、上の一致は何も見ていない。** 影を切った絵と比べて床が暗い
        let gpu = try RenderDevice()
        let rig = try Rig(gpu: gpu)
        let shadowed = try rig.draw(.shadow, cut: nil)
        var withoutShadows = try Rig(gpu: gpu)
        withoutShadows.shadows = false
        let unshadowed = try withoutShadows.draw(.shadow, cut: nil)
        var darker = 0
        for y in 0..<shadowed.height {
            for x in 0..<shadowed.width
            where Int(unshadowed[x, y].red) - Int(shadowed[x, y].red) > 20 { darker += 1 }
        }
        #expect(darker > 50, "床に影が落ちていない (\(darker) 画素)")
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
