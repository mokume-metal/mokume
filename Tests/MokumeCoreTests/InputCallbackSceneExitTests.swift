// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// ループ中 (と `redraw()` を頼んだ後) の入力のコールバックは、コールバック 1 つごとに、書いたシーンの記述を
/// 抜けるときに戻す ([#3408])。
///
/// この 2 つはフレームの内側 (`draw()` の前) で配られる。戻さないと、`mousePressed()` で書いた `translate()`・
/// `lights()`・`clip()` が、同じフレームの `draw()` へ漏れていた。止まっている間は #3273 の区間の出口が戻す
/// (``CarriedTransformTests``)。**戻す範囲は、境目の検査の表 (`CanvasTests.FrameState`) の「シーンの記述」の行**で、
/// 表を足せばそこで見る。ここは配る側 (ランタイム) が、出口を通すことを見る。
///
/// [#3408]: https://github.com/mokume-metal/mokume/issues/3408
@Suite(
    "ループ中の入力のコールバックの出口",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct InputCallbackSceneExitTests {
    /// 各口の本体を差し込めるスケッチ。黒い下地は `setup()` で 1 度だけ塗る (`draw()` は塗り直さない)。
    final class Scene: Sketch {
        var settings = SketchSettings(width: 200, height: 200)
        var stopsInSetup = false
        var onPressed: (Scene) -> Void = { _ in }
        var onReleased: (Scene) -> Void = { _ in }
        var onDraw: (Scene) -> Void = { _ in }

        func setup() {
            background(0)
            noStroke()
            fill(255)
            if stopsInSetup { noLoop() }
        }

        func draw() { onDraw(self) }
        func mousePressed() { onPressed(self) }
        func mouseReleased() { onReleased(self) }
    }

    /// 完了条件 1 の `mousePressed()`。変換・光・切り抜きを書く。
    private static let dirtyingPress: (Scene) -> Void = { s in
        s.translate(50, 0)
        s.lights()
        s.clip(0, 0, 10, 10)
    }

    private func press(_ runtime: SketchRuntime) {
        runtime.input.enqueue(.mouseDown(x: 4, y: 4, button: .left))
    }

    /// 押した次のフレームの絵。`pressed` が偽なら押さない (同じ回数だけ進める)。
    ///
    /// - Parameter redrawsOutside: 真なら `noLoop()` で止めておき、外から `redraw()` を頼む。止まっているのに
    ///   フレームの内側で配る道である (`!redrawRequested` の枝の外)。
    private func secondFrame(
        of scene: Scene, pressed: Bool, redrawsOutside: Bool = false
    ) throws -> (image: DisplayImage, runtime: SketchRuntime) {
        scene.stopsInSetup = redrawsOutside
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        try runtime.advance()
        if pressed { press(runtime) }
        if redrawsOutside { runtime.redraw() }
        try runtime.advance()
        return (try runtime.canvas.target.encodeForDisplay(), runtime)
    }

    /// `draw()` は、フレームごとに動く円と、光の有無で色の変わる立体を、下地を塗らずに置く。
    ///
    /// 下地を塗らないのは、切り抜きが下地の塗りも切るので (押したフレームの `draw()` の下地が、切り抜き越しに
    /// 前のフレームの絵を残す)、漏れても絵が変わらなくなるためである。円がフレームごとに動けば、2 枚目の円が
    /// 変換や切り抜きで動かされたり消えたりするのが、絵に出る。
    private func framePictureScene() -> Scene {
        let scene = Scene()
        scene.onDraw = { s in
            s.circle(40 + Float(s.frameCount) * 30, 50, 30)
            s.push {
                s.translate(100, 150)
                s.box(40)
            }
        }
        return scene
    }

    // MARK: - 完了条件 1

    /// 完了条件 1。押したフレームの絵が、押さないフレームの絵と画素で一致する。
    @Test("ループ中の mousePressed() で書いた変換・光・切り抜きは、同じフレームの draw() に効かない", arguments: [false, true])
    func theFrameAfterAPressMatchesAFrameWithoutOne(redrawsOutside: Bool) throws {
        let plain = try secondFrame(of: framePictureScene(), pressed: false, redrawsOutside: redrawsOutside).image
        let scene = framePictureScene()
        scene.onPressed = Self.dirtyingPress
        var presses = 0
        let counted = scene.onPressed
        scene.onPressed = { s in
            presses += 1
            counted(s)
        }
        let (pressed, runtime) = try secondFrame(of: scene, pressed: true, redrawsOutside: redrawsOutside)
        try #require(presses == 1, "mousePressed() が配られていない: \(presses)")
        #expect(pressed == plain, "押したフレームの絵が、押さないフレームと違う")
        // 前提: 立体が出ている (この検査が空の絵を比べていない)
        #expect(pressed[100, 150].green > 30, "立体が (100, 150) に出ていない")
        #expect(runtime.canvas.transform == .identity)
        #expect(runtime.canvas.style.clip == nil, "切り抜きが残っている")
    }

    /// 検査が効いていること。戻さなければ、押したフレームの円は 50 右へずれる。
    @Test("コールバックの中では、書いた変換が従来どおり効く")
    func theCallbackItselfStillSeesItsTransform() throws {
        let scene = Scene()
        scene.onPressed = { s in
            s.translate(50, 0)
            s.circle(100, 20, 20)  // 完了条件 3: コールバックの中では従来どおり効く
        }
        scene.onDraw = { s in s.circle(100, 100, 40) }
        let (image, _) = try secondFrame(of: scene, pressed: true)
        // コールバックで置いた円は (150, 20) に出る。`draw()` は下地を塗らないので残る
        #expect(image[150, 20].green > 200, "コールバックの中の変換が効いていない")
        #expect(image[100, 20].green < 30, "原点の側にも出ている")
        #expect(image[100, 100].green > 200, "draw() の円が原点の変換で出ていない")
        #expect(image[150, 100].green < 30, "draw() の円に変換が漏れた")
    }

    // MARK: - 完了条件 3

    @Test("コールバックで書いた塗りは戻らない (描き方はフレームを越える)")
    func theFillWrittenInACallbackStays() throws {
        let scene = Scene()
        scene.onPressed = { s in s.fill(255, 0, 0) }
        scene.onDraw = { s in
            s.background(0)
            s.circle(100, 100, 40)
        }
        let (image, _) = try secondFrame(of: scene, pressed: true)
        #expect(image[100, 100].red > 200 && image[100, 100].green < 60, "塗りが戻された")
    }

    /// 置いた立体は、コールバックで書いた光で描かれる (戻す前に列を閉じる)。`draw()` で同じ光と立体を
    /// 置いた絵と、画素で一致する。光を書かない絵とは違う。
    @Test("コールバックで光を書いて置いた立体は、その光で描かれる")
    func aSolidPlacedInTheCallbackIsLitByTheCallbacksLights() throws {
        func solid(_ s: Scene) {
            s.translate(100, 100)
            s.box(60)
        }
        let inCallback = Scene()
        inCallback.onPressed = { s in
            s.lights()
            solid(s)
        }
        let inDraw = Scene()
        inDraw.onDraw = { s in
            s.lights()
            solid(s)
        }
        let unlit = Scene()
        unlit.onPressed = { s in solid(s) }

        let callbackImage = try secondFrame(of: inCallback, pressed: true).image
        let drawImage = try secondFrame(of: inDraw, pressed: false).image
        let unlitImage = try secondFrame(of: unlit, pressed: true).image
        try #require(unlitImage != DisplayImage(width: 200, height: 200, bytes: [UInt8](repeating: 0, count: 200 * 200 * 4)), "立体が出ていない")
        #expect(callbackImage == drawImage, "コールバックで置いた立体が、光を書いた draw() の絵と違う")
        #expect(callbackImage != unlitImage, "コールバックの光が、置いた立体に効いていない")
    }

    // MARK: - 区間 (1 つごと)

    /// 押す・離すを続けて配ると 2 つのコールバックが 1 回の配りで続く。1 つ目の変換は 2 つ目へ漏れない。
    @Test("続けて配る 2 つのコールバックは、変換を持ち越さない")
    func aTransformInACallbackDoesNotReachTheNext() throws {
        let scene = Scene()
        scene.onPressed = { s in
            s.translate(100, 0)
            s.circle(0, 50, 30)
        }
        scene.onReleased = { s in s.circle(0, 150, 30) }
        scene.onDraw = { _ in }
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        try runtime.advance()
        runtime.input.enqueue(.mouseDown(x: 4, y: 4, button: .left))
        runtime.input.enqueue(.mouseUp(x: 4, y: 4, button: .left))
        try runtime.advance()
        let image = try runtime.canvas.target.encodeForDisplay()
        #expect(image[100, 50].green > 200, "1 つ目のコールバックの円が (100, 50) に出ていない")
        #expect(image[0, 150].green > 200 || image[3, 150].green > 200, "2 つ目のコールバックの円が原点の側に出ていない (変換が漏れた)")
        #expect(image[100, 150].green < 30, "2 つ目のコールバックへ変換が漏れた")
    }

    @Test("コールバックで積んだまま抜けた段は、注意して捨てる (フレームの内側でも)")
    func aPushLeftOpenInALoopCallbackIsDropped() throws {
        let scene = framePictureScene()
        scene.onPressed = { s in
            s.pushMatrix()
            s.translate(50, 0)
        }
        let plain = try secondFrame(of: framePictureScene(), pressed: false).image
        let (image, runtime) = try secondFrame(of: scene, pressed: true)
        let said = try #require(runtime.canvas.warnings.message(for: .pushLeftOpen), "積んだまま抜けた段を言っていない")
        #expect(said.contains("input callback"), "\(said)")
        #expect(image == plain, "積んだまま抜けた変換が draw() に漏れた")
        #expect(runtime.canvas.transform == .identity)
    }

    // MARK: - 止まっている間は変えない (完了条件 4)

    @Test("止まっている間のコールバックは、これまでどおり区間の出口で戻す")
    func theStoppedPathIsUnchanged() throws {
        let scene = Scene()
        scene.stopsInSetup = true
        scene.onPressed = { s in
            s.translate(100, 0)
            s.circle(0, 100, 40)
            s.redraw()
        }
        scene.onDraw = { _ in }
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        try runtime.advance()
        runtime.input.enqueue(.mouseDown(x: 4, y: 4, button: .left))
        try runtime.advance()
        let image = try runtime.canvas.target.encodeForDisplay()
        #expect(image[100, 100].green > 200, "コールバックの円が (100, 100) に出ていない")
        #expect(runtime.canvas.transform == .identity)
    }
}
