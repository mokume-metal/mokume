// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 持ち越しの区間 (`setup()` と止まっている間のコールバック) で、変換と積み降ろしが効く ([#3273])。
///
/// 置いた図形は置くときに変換を焼き付けるので、区間で書いた変換は、その後に置いたものに効く。区間を
/// 出るときに変換と積み履歴は既定へ戻り、次のコールバックにも次のフレームにも漏れない。光・視点・材質・
/// 切り抜きは区間でも従来どおり断る (``SceneOutsideFrameTests``)。区間の外は今までどおり断る。
///
/// [#3273]: https://github.com/mokume-metal/mokume/issues/3273
@Suite(
    "持ち越しの区間の変換",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CarriedTransformTests {
    /// 各口の本体を差し込めるスケッチ。黒い下地に、輪郭なしで白く塗る。
    final class Scene: Sketch {
        var settings = SketchSettings(width: 200, height: 200)
        var onSetup: (Scene) -> Void = { _ in }
        var onDraw: (Scene) -> Void = { _ in }
        var onPressed: (Scene) -> Void = { _ in }
        /// 偽なら下地を塗らない。溜め場が空のまま `setup()` の本体へ入る (背景の予定も溜め場の量に数えるので)。
        var preparesCanvas = true

        func setup() {
            if preparesCanvas {
                background(0)
                noStroke()
                fill(255)
            }
            onSetup(self)
        }

        func draw() { onDraw(self) }
        func mousePressed() { onPressed(self) }
    }

    private func firstFrame(of scene: Scene) throws -> (image: DisplayImage, runtime: SketchRuntime) {
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        try runtime.advance()
        return (try runtime.canvas.target.encodeForDisplay(), runtime)
    }

    private func isWhite(_ image: DisplayImage, _ x: Int, _ y: Int) -> Bool { image[x, y].green > 200 }
    private func isBlack(_ image: DisplayImage, _ x: Int, _ y: Int) -> Bool { image[x, y].green < 30 }

    // MARK: - 具体例 1

    /// 完了条件 2。`setup()` の `translate` が、その後に置いた円に効く。最初の `draw()` の円は原点 (変換は持ち越さない)。
    @Test("setup() で translate してから置いた円は (100, 100) に出て、draw() の円は原点に出る")
    func aTransformInSetupMovesWhatFollows() throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.translate(100, 100)
            s.circle(0, 0, 40)
        }
        scene.onDraw = { s in s.circle(0, 0, 20) }
        let (image, runtime) = try firstFrame(of: scene)
        #expect(isWhite(image, 100, 100), "setup() の円が (100, 100) に出ていない")
        #expect(isWhite(image, 3, 3), "draw() の円が原点に出ていない (変換が持ち越された)")
        #expect(!runtime.canvas.warnings.hasWarned(.transformOutsideFrame), "変換の警告が出ている")
        #expect(!runtime.canvas.warnings.hasWarned(.transformNotCarried))
    }

    /// 手本 (Processing の `Basics/Form/PointsLines`) の形。`setup()` で `translate` した後に描く。
    @Test("setup() の translate の後の線は、ずれた位置に出る (PointsLines の形)")
    func aTransformThenShapesInSetup() throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.translate(140, 0)
            s.rect(0, 40, 20, 20)
        }
        let (image, runtime) = try firstFrame(of: scene)
        #expect(isWhite(image, 150, 50), "translate の後の矩形が (140, 0) ずれた位置に出ていない")
        #expect(isBlack(image, 10, 50), "原点に出ている (変換が効いていない)")
        // 置いた後なので、持ち越さない旨の注意は出ない
        #expect(!runtime.canvas.warnings.hasWarned(.transformNotCarried))
    }

    // MARK: - 具体例 2

    /// 完了条件 3。`setup()` の `push { }` が、塗りと変換を戻す。
    @Test("setup() の push { } は塗りと変換を戻す")
    func aPushClosureInSetupRestoresStyleAndTransform() throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.push {
                s.fill(255, 0, 0)
                s.translate(100, 0)
                s.circle(0, 0, 40)
            }
            s.circle(0, 0, 40)
        }
        let (image, runtime) = try firstFrame(of: scene)
        let inside = image[100, 3]
        #expect(inside.red > 200 && inside.green < 60, "push の中の円が赤く (100, 0) に出ていない")
        let origin = image[3, 3]
        #expect(origin.red > 200 && origin.green > 200, "push の後の円が白く原点に出ていない (塗りか変換が漏れた)")
        #expect(!runtime.canvas.warnings.hasWarned(.transformOutsideFrame))
        #expect(!runtime.canvas.warnings.hasWarned(.styleOutsideFrame))
        #expect(!runtime.canvas.warnings.hasWarned(.pushLeftOpen))
    }

    @Test("setup() の pushMatrix / popMatrix と pushStyle / popStyle も効く")
    func pairsInSetupWork() throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.pushMatrix()
            s.pushStyle()
            s.fill(255, 0, 0)
            s.translate(100, 0)
            s.circle(0, 0, 40)
            s.popStyle()
            s.popMatrix()
            s.circle(0, 0, 40)
        }
        let (image, runtime) = try firstFrame(of: scene)
        #expect(image[100, 3].red > 200 && image[100, 3].green < 60)
        #expect(image[3, 3].green > 200)
        #expect(runtime.canvas.warnings.message(for: .popWithoutPush) == nil)
    }

    // MARK: - 具体例 3

    /// 完了条件 4。変換を書いた後に何も置かずに区間を抜けたら、`draw()` へ持ち越さないと 1 度言う。
    @Test("setup() が変換だけ書いて何も置かずに終わると、draw() へは持ち越さないと注意する")
    func aTransformAloneInSetupIsExplained() throws {
        let scene = Scene()
        scene.onSetup = { s in s.translate(s.width / 2, s.height / 2) }
        scene.onDraw = { s in s.circle(0, 0, 20) }
        let (image, runtime) = try firstFrame(of: scene)
        let said = try #require(runtime.canvas.warnings.message(for: .transformNotCarried))
        #expect(said.contains("draw()"), "\(said)")
        // 言った通り持ち越さない: draw() の円は原点
        #expect(isWhite(image, 3, 3))
    }

    @Test("変換の後に置いたものがあれば、持ち越さない旨は言わない")
    func aTransformFollowedByAShapeIsNotExplained() throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.translate(100, 100)
            s.circle(0, 0, 40)
        }
        let (_, runtime) = try firstFrame(of: scene)
        #expect(runtime.canvas.warnings.message(for: .transformNotCarried) == nil)
    }

    @Test("変換を書かない setup() は、何も置かなくても持ち越さない旨を言わない")
    func noTransformNoExplanation() throws {
        let scene = Scene()
        let (_, runtime) = try firstFrame(of: scene)
        #expect(runtime.canvas.warnings.message(for: .transformNotCarried) == nil)
    }

    @Test("変換を書いて push { } で戻し、何も置かなかったときは、持ち越さない旨を言わない")
    func aRestoredTransformIsNotExplained() throws {
        let scene = Scene()
        scene.onSetup = { s in s.push { s.translate(10, 10) } }
        let (_, runtime) = try firstFrame(of: scene)
        #expect(runtime.canvas.warnings.message(for: .transformNotCarried) == nil)
    }

    // MARK: - 具体例 4・区間の出口

    /// 完了条件 5。止まっている間のコールバックで書いた変換は、次のコールバックへ漏れない。
    /// 押す・離すを 2 回続けて配るので、2 つの `mousePressed()` は 1 回の配りの中で続けて呼ばれる。
    @Test("止まっている間の 2 つのコールバックは、変換を持ち越さない")
    func aTransformInAStoppedCallbackDoesNotReachTheNext() throws {
        let scene = Scene()
        var calls = 0
        scene.onSetup = { s in s.noLoop() }
        scene.onPressed = { s in
            calls += 1
            if calls == 1 { s.translate(100, 0) }
            s.circle(0, 100, 40)
            s.redraw()
        }
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        try runtime.advance()
        for _ in 0..<2 {
            runtime.input.enqueue(.mouseDown(x: 4, y: 4, button: .left))
            runtime.input.enqueue(.mouseUp(x: 4, y: 4, button: .left))
        }
        try runtime.advance()
        try #require(calls == 2, "mousePressed() が 2 回配られていない: \(calls)")
        let image = try runtime.canvas.target.encodeForDisplay()
        #expect(isWhite(image, 100, 100), "1 つ目のコールバックの円が (100, 100) に出ていない")
        #expect(isWhite(image, 3, 100), "2 つ目のコールバックの円が原点の側に出ていない (変換が漏れた)")
        #expect(runtime.canvas.transform == .identity, "区間を出た後に変換が残っている")
        #expect(!runtime.canvas.warnings.hasWarned(.transformOutsideFrame))
    }

    /// 完了条件 5 の後半。積んだまま抜けた段は、フレームと同じく注意して捨てる。
    @Test("コールバックで積んだまま抜けた段は、注意して捨てる")
    func aPushLeftOpenInACallbackIsDropped() throws {
        let scene = Scene()
        scene.onSetup = { s in s.noLoop() }
        scene.onPressed = { s in
            s.pushMatrix()
            s.translate(50, 0)
        }
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        try runtime.advance()
        runtime.input.enqueue(.mouseDown(x: 4, y: 4, button: .left))
        try runtime.advance()
        #expect(runtime.canvas.warnings.hasWarned(.pushLeftOpen), "積んだまま抜けた段を言っていない")
        #expect(runtime.canvas.transform == .identity)
        // 捨てたので、次の区間の pop は取る段が無い
        scene.onPressed = { s in s.popMatrix() }
        runtime.input.enqueue(.mouseDown(x: 4, y: 4, button: .left))
        try runtime.advance()
        #expect(runtime.canvas.warnings.hasWarned(.popWithoutPush), "前の区間の段が残っている")
    }

    // MARK: - 置く口の全数 (完了条件 7)

    /// 区間で書いた変換が効く置く口。原点を中心に置き、`translate(100, 100)` の後に置く。変換が効けば (100, 100) の
    /// まわりが塗られ、効かなければ原点のまわり (左上の隅) が塗られる。
    struct Placer: Sendable, CustomTestStringConvertible {
        let name: String
        let place: @MainActor @Sendable (Scene) throws -> Void
        var testDescription: String { name }
    }

    nonisolated static let placers: [Placer] = [
        Placer(name: "rect") { $0.rect(-20, -20, 40, 40) },
        Placer(name: "rect(角丸)") { $0.rect(-20, -20, 40, 40, 8) },
        Placer(name: "square") { $0.square(-20, -20, 40) },
        Placer(name: "circle") { $0.circle(0, 0, 40) },
        Placer(name: "ellipse") { $0.ellipse(0, 0, 40, 30) },
        Placer(name: "arc") { $0.arc(0, 0, 40, 40, 0, 4, .pie) },
        Placer(name: "triangle") { $0.triangle(-20, 20, 0, -20, 20, 20) },
        Placer(name: "quad") { $0.quad(-20, -20, 20, -20, 20, 20, -20, 20) },
        Placer(name: "line") {
            $0.stroke(255)
            $0.strokeWeight(8)
            $0.line(-20, 0, 20, 0)
        },
        Placer(name: "point") {
            $0.stroke(255)
            $0.strokeWeight(20)
            $0.point(0, 0)
        },
        Placer(name: "beginShape") {
            $0.beginShape()
            $0.vertex(-20, -20)
            $0.vertex(20, -20)
            $0.vertex(0, 20)
            $0.endShape(.close)
        },
        Placer(name: "text") {
            $0.textSize(48)
            $0.textAlign(.center, .center)
            $0.text("W", 0, 0)
        },
        Placer(name: "image(描き場所)") {
            let pg = try $0.createGraphics(40, 40)
            pg.beginDraw()
            pg.background(255)
            pg.endDraw()
            $0.image(pg, -20, -20)
        },
        Placer(name: "shape(createShape)") { s in
            let dot = s.createShape { s.rect(-20, -20, 40, 40) }
            s.shape(dot)
        },
        Placer(name: "box") { $0.box(40) },
        Placer(name: "sphere") { $0.sphere(24) },
    ]

    @Test("setup() の変換は、置く口のどれにも効く", arguments: placers)
    func everyPlacingPathHonoursTheTransform(_ placer: Placer) throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.translate(100, 100)
            try? placer.place(s)
        }
        let (image, runtime) = try firstFrame(of: scene)
        func lit(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> Int {
            var count = 0
            for y in ys { for x in xs where image[x, y].green > 60 { count += 1 } }
            return count
        }
        #expect(lit(80...120, 80...120) > 20, "\(placer.name): 変換した位置 (100, 100) に出ていない")
        #expect(lit(0...25, 0...25) == 0, "\(placer.name): 原点のまわりに出ている (変換が効いていない)")
        #expect(!runtime.canvas.warnings.hasWarned(.transformOutsideFrame))
        // 変換の後に置いたのだから、「何も置かなかった」とは言わない (どの置く口も置いた通し数を進める)
        #expect(
            runtime.canvas.warnings.message(for: .transformNotCarried) == nil,
            "\(placer.name): 変換の後に置いたのに、何も置かなかったと言っている")
    }

    // MARK: - 置いた後に描き切る口 (反証 4)

    /// 置いた後に溜め場を空にする口 (描き切る口)。`translate` の後に置いてから呼ぶと、溜め場は変換を書いた
    /// 時点と同じ量 (0) へ戻る。量だけで「置いたか」を見ると、ここで偽に「何も置かなかった」と言う。
    nonisolated static let flushers: [Placer] = [
        Placer(name: "loadPixels") { $0.loadPixels() },
        Placer(name: "get") { _ = $0.get(1, 1) },
        Placer(name: "filter") { $0.filter([.invert()]) },
    ]

    @Test("変換の後に置いてから描き切る口を呼んでも、何も置かなかったとは言わない", arguments: flushers)
    func placingThenFlushingIsNotMistakenForPlacingNothing(_ flusher: Placer) throws {
        let scene = Scene()
        scene.preparesCanvas = false  // 溜め場が空の状態で変換を書く
        scene.onSetup = { s in
            s.translate(s.width / 2, s.height / 2)
            s.circle(0, 0, 50)
            try? flusher.place(s)
        }
        let (_, runtime) = try firstFrame(of: scene)
        #expect(
            runtime.canvas.warnings.message(for: .transformNotCarried) == nil,
            "\(flusher.name): 置いた後に描き切ったのを、何も置かなかったと取り違えた")
    }

    @Test("変換の後に何も置かず、描き切る口だけ呼んだときは、持ち越さない旨を言う", arguments: flushers)
    func flushingWithoutPlacingStillExplains(_ flusher: Placer) throws {
        let scene = Scene()
        scene.preparesCanvas = false
        scene.onSetup = { s in
            s.circle(0, 0, 10)  // 変換より前に置いて、描き切りに捨てさせる
            s.translate(s.width / 2, s.height / 2)
            try? flusher.place(s)
        }
        let (_, runtime) = try firstFrame(of: scene)
        #expect(
            runtime.canvas.warnings.message(for: .transformNotCarried) != nil,
            "\(flusher.name): 変換の後に何も置いていないのに言わない")
    }

    // MARK: - 変換の口の全数 (反証 7)

    /// 変換の口 1 つ。`body` は同じ場面を、口を呼ぶ版 (`true`) と呼ばない版 (`false`) で書く。
    /// 区間 (`setup()`) と `draw()` の同じ本体が同じ絵になり、かつ口を呼ぶかどうかで絵が変わることを見る。
    struct Mouth: Sendable, CustomTestStringConvertible {
        let name: String
        let body: @MainActor @Sendable (Scene, Bool) -> Void
        var testDescription: String { name }
    }

    nonisolated static let mouths: [Mouth] = [
            Mouth(name: "translate(x,y)") { s, on in
                if on { s.translate(100, 100) }
                s.rect(-20, -20, 40, 40)
            },
            Mouth(name: "translate(Vector2)") { s, on in
                if on { s.translate(Vector2(100, 100)) }
                s.rect(-20, -20, 40, 40)
            },
            Mouth(name: "rotate") { s, on in
                if on { s.rotate(0.5) }
                s.rect(60, 20, 60, 20)
            },
            Mouth(name: "scale(s)") { s, on in
                if on { s.scale(2) }
                s.rect(20, 20, 30, 30)
            },
            Mouth(name: "scale(x,y)") { s, on in
                if on { s.scale(2, 3) }
                s.rect(20, 20, 30, 20)
            },
            Mouth(name: "shearX") { s, on in
                if on { s.shearX(0.6) }
                s.rect(20, 20, 40, 40)
            },
            Mouth(name: "shearY") { s, on in
                if on { s.shearY(0.6) }
                s.rect(20, 20, 40, 40)
            },
            Mouth(name: "applyMatrix") { s, on in
                var moved = Transform.identity
                moved.translate(x: 60, y: 40)
                if on { s.applyMatrix(moved) }
                s.rect(20, 20, 40, 40)
            },
            Mouth(name: "resetMatrix") { s, on in
                s.translate(100, 100)
                s.rect(-5, -5, 10, 10)
                if on { s.resetMatrix() }
                s.rect(20, 20, 40, 40)
            },
            Mouth(name: "pushMatrix / popMatrix") { s, on in
                if on { s.pushMatrix() }
                s.translate(100, 100)
                s.rect(-5, -5, 10, 10)
                if on { s.popMatrix() }
                s.rect(20, 20, 40, 40)
            },
            Mouth(name: "pushStyle / popStyle") { s, on in
                if on { s.pushStyle() }
                s.fill(255, 0, 0)
                s.rect(100, 100, 40, 40)
                if on { s.popStyle() }
                s.rect(20, 20, 40, 40)
            },
            // 立体の口 (`Canvas+Solid.swift` の 6 つ)。`box` で見る
            Mouth(name: "translate(x,y,z)") { s, on in
                if on { s.translate(100, 100, 0) }
                s.box(40)
            },
            Mouth(name: "translate(Vector3)") { s, on in
                if on { s.translate(Vector3(100, 100, 0)) }
                s.box(40)
            },
            Mouth(name: "rotateX") { s, on in
                s.translate(100, 100, 0)
                if on { s.rotateX(0.9) }
                s.box(60)
            },
            Mouth(name: "rotateY") { s, on in
                s.translate(100, 100, 0)
                if on { s.rotateY(0.9) }
                s.box(60)
            },
            Mouth(name: "rotateZ") { s, on in
                s.translate(100, 100, 0)
                if on { s.rotateZ(0.5) }
                s.box(60)
            },
            Mouth(name: "scale(x,y,z)") { s, on in
                s.translate(100, 100, 0)
                if on { s.scale(2, 1, 1) }
                s.box(30)
            },
    ]

    /// 同じ本体を `setup()` (区間) と `draw()` (フレーム) で書いて、絵を取る。
    private func picture(_ mouth: Mouth, on: Bool, inSetup: Bool) throws -> [UInt8] {
        let scene = Scene()
        if inSetup {
            scene.onSetup = { s in mouth.body(s, on) }
        } else {
            scene.onDraw = { s in mouth.body(s, on) }
        }
        return try firstFrame(of: scene).image.bytes
    }

    @Test("変換の口はどれも、setup() では draw() と同じ絵になり、口を呼ぶと絵が変わる", arguments: mouths)
    func everyTransformMouthWorksInSetup(_ mouth: Mouth) throws {
        let inSetup = try picture(mouth, on: true, inSetup: true)
        let inDraw = try picture(mouth, on: true, inSetup: false)
        let without = try picture(mouth, on: false, inSetup: false)
        #expect(inDraw != without, "\(mouth.name): 口を呼んでも絵が変わらない (この検査が効かない)")
        #expect(inSetup == inDraw, "\(mouth.name): setup() の絵が draw() と違う (区間で効いていない)")
    }

    // MARK: - コールバックの push { }・pushStyle (反証 7)

    @Test("止まっている間のコールバックの push { } は、塗りと変換を戻す")
    func aPushClosureInAStoppedCallbackRestoresStyleAndTransform() throws {
        let scene = Scene()
        scene.onSetup = { s in s.noLoop() }
        scene.onPressed = { s in
            s.push {
                s.fill(255, 0, 0)
                s.translate(100, 0)
                s.circle(0, 100, 40)
            }
            s.circle(0, 100, 40)
            s.redraw()
        }
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        try runtime.advance()
        runtime.input.enqueue(.mouseDown(x: 4, y: 4, button: .left))
        try runtime.advance()
        let image = try runtime.canvas.target.encodeForDisplay()
        #expect(image[100, 100].red > 200 && image[100, 100].green < 60, "push の中の円が赤く (100, 100) に出ていない")
        #expect(image[3, 100].red > 200 && image[3, 100].green > 200, "push の後の円が白く原点側に出ていない")
        #expect(!runtime.canvas.warnings.hasWarned(.styleOutsideFrame))
        #expect(!runtime.canvas.warnings.hasWarned(.transformOutsideFrame))
    }

    @Test("止まっている間のコールバックの pushStyle / popStyle は、塗りを戻す")
    func aStylePairInAStoppedCallbackRestoresTheFill() throws {
        let scene = Scene()
        scene.onSetup = { s in s.noLoop() }
        scene.onPressed = { s in
            s.pushStyle()
            s.fill(255, 0, 0)
            s.circle(100, 100, 40)
            s.popStyle()
            s.circle(0, 100, 40)
            s.redraw()
        }
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        try runtime.advance()
        runtime.input.enqueue(.mouseDown(x: 4, y: 4, button: .left))
        try runtime.advance()
        let image = try runtime.canvas.target.encodeForDisplay()
        #expect(image[100, 100].red > 200 && image[100, 100].green < 60, "積んだ中の円が赤くない")
        #expect(image[3, 100].green > 200, "popStyle() の後の円が白くない (塗りが戻っていない)")
        #expect(runtime.canvas.warnings.message(for: .popWithoutPush) == nil)
    }

    // MARK: - 区間の中でフレームを開く (反証 6)

    /// 区間の中で本体の面のフレームを開く (`canvas.draw { }`)。フレームの頭は変換と積み履歴を既定へ戻すが、
    /// 閉じた後は区間の変換へ戻す。
    @Test("setup() で translate した後に canvas.draw { } を開いて閉じても、続く図形に変換が効く")
    func aTransformSurvivesAFrameOpenedInsideTheSegment() throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.translate(100, 0)
            s.circle(0, 40, 30)
            try? s.canvas.draw { s.circle(0, 100, 30) }  // フレームの中は既定の変換
            s.circle(0, 160, 30)
        }
        let (image, runtime) = try firstFrame(of: scene)
        #expect(isWhite(image, 100, 40), "開く前の円が (100, 40) に出ていない")
        #expect(isWhite(image, 3, 100), "開いたフレームの中の円が原点側に出ていない")
        #expect(isWhite(image, 100, 160), "閉じた後の円が (100, 160) に出ていない (区間の変換が消えた)")
        #expect(isBlack(image, 3, 160), "閉じた後の円が原点側に出ている")
        #expect(runtime.canvas.warnings.message(for: .transformNotCarried) == nil)
    }

    @Test("setup() で pushMatrix した後に canvas.draw { } を開いて閉じても、popMatrix が対を取る")
    func aPushSurvivesAFrameOpenedInsideTheSegment() throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.pushMatrix()
            s.translate(100, 0)
            try? s.canvas.draw { s.circle(0, 40, 30) }
            s.circle(0, 100, 30)
            s.popMatrix()
            s.circle(0, 160, 30)
        }
        let (image, runtime) = try firstFrame(of: scene)
        #expect(isWhite(image, 100, 100), "閉じた後の円が (100, 100) に出ていない")
        #expect(isWhite(image, 3, 160), "popMatrix() の後の円が原点側に出ていない")
        #expect(runtime.canvas.warnings.message(for: .popWithoutPush) == nil, "積みが開いたフレームで消えた")
    }

    // MARK: - 区間の外・断るもの (完了条件 6・10)

    /// 完了条件 6。区間の外 (フレームの外の直に使う面) では、変換も積み降ろしも今までどおり断る。
    @Test("区間の外では、変換も push { } の積み降ろしも今までどおり警告して無視する")
    func outsideAnIntervalTransformsAreStillRefused() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 32, height: 32)
        canvas.translate(5, 5)
        #expect(canvas.transform == .identity)
        #expect(canvas.warnings.hasWarned(.transformOutsideFrame))
        var ran = false
        canvas.push { ran = true }
        #expect(ran, "本体は走らせる")
        #expect(canvas.warnings.hasWarned(.styleOutsideFrame))
    }

    /// 完了条件 10。光・視点・材質・切り抜きは、区間でも従来どおり断る。
    @Test("setup() の視点・光・切り抜きは今までどおり断る")
    func theSceneDescriptionIsStillRefusedInSetup() throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.perspective()
            s.lights()
        }
        let (_, runtime) = try firstFrame(of: scene)
        #expect(runtime.canvas.warnings.hasWarned(.cameraOutsideFrame))
        #expect(runtime.canvas.warnings.hasWarned(.lightOutsideFrame))
    }

    // MARK: - 形の組み立て

    /// 形の組み立ての中は、これまでどおり形自身の座標で記録し、出口で戻る。区間の変換は形に焼き付かない。
    @Test("setup() で translate した後の createShape は、変換を形に焼かず、置くときに効く")
    func aShapeBuiltAfterATransformKeepsItsOwnCoordinates() throws {
        let scene = Scene()
        scene.onSetup = { s in
            s.translate(100, 100)
            let dot = s.createShape { s.circle(0, 0, 40) }
            s.shape(dot)
        }
        let (image, _) = try firstFrame(of: scene)
        #expect(isWhite(image, 100, 100), "置いた形が (100, 100) に出ていない")
        #expect(isBlack(image, 3, 3), "形に変換が焼かれて原点に出ている")
    }
}
