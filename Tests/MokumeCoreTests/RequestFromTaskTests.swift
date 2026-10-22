// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// スケッチが起こした `Task` から、待つ読み込みの口を呼ぶ ([#1367])。
///
/// 待つ読み込みの口 (`requestImage` / `requestModel`) は `async` なので、スケッチからは
/// `Task` の中でしか呼べない。`Task` の中身が走るのは `setup()` / `draw()` が返った後で、
/// そのとき ``runningSketch`` は外れている。修正の前は、そこで口が ``Sketch/canvas`` を
/// 取って `fatalError` で止まっていた — 呼べる場所が 1 つも無かった。
///
/// **呼んだ時点で差し込みが外れていたことを、検査が自分で確かめる。** これが無いと、
/// 何かの拍子に差し込みが残ったまま呼ばれる形になっても緑のままで、落ちていた経路を
/// 通っていないことに気付けない。
///
/// 期待値は書いた中身から導く ([ADR-0019] 決定 4)。絵は既知の色の 2 画素を書き出して
/// 読み、モデルは面の数が分かっている四角錐を読む。
///
/// [#1367]: https://github.com/mokume-metal/mokume/issues/1367
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "Task から待たずに読む",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RequestFromTaskTests {
    /// `Task` を起こして、絵とモデルを待たずに読むスケッチ。
    final class Requesting: Sketch {
        var settings = SketchSettings(width: 8, height: 4)
        /// 読む絵の場所。`nil` なら絵は読まない。
        var imagePath: String?
        /// 読むモデルの場所。`nil` ならモデルは読まない。
        var modelPath: String?
        /// `Task` を `setup()` ではなく最初の `draw()` で起こすか。
        var startsInDraw = false
        /// 起こした `Task`。検査はこれを待ってから、届いたものを見る。
        var loading: Task<Void, Never>?
        /// 届いた絵。**届くまでは `nil`**。
        var picture: Image?
        /// 届いたモデル。
        var arrivedModel: Model?
        /// 口を呼んだ時点で、差し込み (``runningSketch``) が外れていたか。呼んだ順に並ぶ。
        var detachedWhenCalled: [Bool] = []
        /// 絵を持たないまま描いたフレームの数。
        var framesWithoutPicture = 0
        /// `Task` の中で、待つ読み込みの前に同期の資源の口 (`createImage`) も呼ぶか (#2683)。
        var alsoMakesImage = false
        /// そのとき同期の口が返した絵と、投げた失敗。
        var madeImage: Image?
        var madeImageFailure: ImageFailure?

        init() {}

        func setup() {
            if !startsInDraw { startLoading() }
        }

        func draw() {
            if startsInDraw, loading == nil { startLoading() }
            background(0)
            guard let picture else {
                framesWithoutPicture += 1
                return
            }
            image(picture, 0, 0)
        }

        private func startLoading() {
            loading = Task {
                if alsoMakesImage { makeImageInTask() }
                if let imagePath {
                    detachedWhenCalled.append(runningSketch == nil)
                    picture = try? await requestImage(imagePath)
                }
                if let modelPath {
                    detachedWhenCalled.append(runningSketch == nil)
                    arrivedModel = try? await requestModel(modelPath)
                }
            }
        }

        /// 同期の資源の口を、起こした `Task` の中から呼ぶ。待つ読み込みと違い、持ち越した面を読まない。
        private func makeImageInTask() {
            do {
                madeImage = try createImage(2, 1)
            } catch {
                madeImageFailure = error
            }
        }
    }

    /// 左が赤・右が青の 2 画素を PNG に書き出す。**色は端の値だけを使う** — 途中の値だと
    /// 読み込みと書き出しの丸めが期待値に混ざる。
    private func writePicture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-request-from-task-\(UUID().uuidString).png")
        try PNGFile.write(
            DisplayImage(width: 2, height: 1, bytes: [255, 0, 0, 255, 0, 0, 255, 255]), to: url)
        return url
    }

    private func makeRuntime(_ sketch: Requesting) throws -> SketchRuntime {
        try SketchRuntime(sketch: sketch, gpu: RenderDevice())
    }

    private func isClose(_ color: Color, _ red: Float, _ green: Float, _ blue: Float) -> Bool {
        abs(color.premultipliedRed - red) < 1e-3 && abs(color.premultipliedGreen - green) < 1e-3
            && abs(color.premultipliedBlue - blue) < 1e-3
    }

    @Test("setup() で起こした Task から requestImage を呼んでも落ちず、絵が届く")
    func anImageArrivesAtATaskStartedInSetup() async throws {
        let url = try writePicture()
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Requesting()
        sketch.imagePath = url.path
        let runtime = try makeRuntime(sketch)

        // **最初のフレームは届く前に描かれる。** Task に番が回るのは、この検査が待って
        // main actor を明け渡してからである
        try runtime.advance()
        #expect(sketch.picture == nil)
        #expect(sketch.framesWithoutPicture == 1)

        await sketch.loading?.value
        // 修正の前に止まっていた条件を、実際に通っている
        #expect(sketch.detachedWhenCalled == [true])
        let picture = try #require(sketch.picture, "Task から頼んだ絵が届いていない")
        #expect(picture.width == 2)
        #expect(picture.height == 1)
        #expect(isClose(picture.get(0, 0), 1, 0, 0), "左の画素: \(picture.get(0, 0))")
        #expect(isClose(picture.get(1, 0), 0, 0, 1), "右の画素: \(picture.get(1, 0))")

        // 届いた次のフレームで置かれる
        try runtime.advance()
        let frame = try runtime.target.encodeForDisplay()
        #expect(frame[0, 0] == (255, 0, 0, 255))
        #expect(frame[1, 0] == (0, 0, 255, 255))
        #expect(frame[2, 0] == (0, 0, 0, 255))
    }

    @Test("setup() で起こした Task から requestModel を呼んでも落ちず、モデルが届く")
    func aModelArrivesAtATaskStartedInSetup() async throws {
        let sketch = Requesting()
        sketch.modelPath = ModelFixture.pyramid
        let runtime = try makeRuntime(sketch)
        runtime.start()

        await sketch.loading?.value
        #expect(sketch.detachedWhenCalled == [true])
        let model = try #require(sketch.arrivedModel, "Task から頼んだモデルが届いていない")
        // 四角錐は三角形 4 枚と四角形 1 枚 (三角形 2 枚に割られる) でできている
        #expect(model.triangleCount == 6)
        // **このスケッチの面へ整えられている。** いちばん長い辺は読んだ面の短いほうの半分に
        // なるので、どの面へ読み込んだかが届いたモデルに残る (面は 8×4 → 半分は 2)
        let longest = max(model.size.x, max(model.size.y, model.size.z))
        #expect(abs(longest - 2) < 0.001, "いちばん長い辺: \(longest)")
    }

    @Test("draw() で起こした Task からも呼べる")
    func anImageArrivesAtATaskStartedInDraw() async throws {
        let url = try writePicture()
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Requesting()
        sketch.imagePath = url.path
        sketch.startsInDraw = true
        let runtime = try makeRuntime(sketch)
        try runtime.advance()

        await sketch.loading?.value
        #expect(sketch.detachedWhenCalled == [true])
        let picture = try #require(sketch.picture)
        #expect(isClose(picture.get(0, 0), 1, 0, 0), "左の画素: \(picture.get(0, 0))")
    }

    /// **同期の資源の口は、走っている実行の中で起こした `Task` から呼んでも面を取れない** (#2683)。
    /// 持ち越した面 (``LaunchingSketch``) を読むのは待つ読み込みだけで、同じ `Task` の中でも割れる。
    /// `draw()` が回っている最中でもそうなので、文面は「走っていない」と言わない (#1322)。
    @Test(
        "setup() / draw() で起こした Task から、同期の createImage は notRunning を投げ、待つ読み込みは読める",
        arguments: [false, true])
    func synchronousResourcesFromARunningTaskThrow(startsInDraw: Bool) async throws {
        let url = try writePicture()
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Requesting()
        sketch.imagePath = url.path
        sketch.alsoMakesImage = true
        sketch.startsInDraw = startsInDraw
        let runtime = try makeRuntime(sketch)
        try runtime.advance()

        await sketch.loading?.value
        #expect(sketch.madeImage == nil, "同期の口が Task の中で面を取れている")
        #expect(sketch.madeImageFailure == .notRunning(call: "createImage(_:_:)"))
        #expect(sketch.picture != nil, "同じ Task の中の待つ読み込みが読めていない")
        // 実行は畳まれていない — 走っている最中でもこの場合になる
        try runtime.advance()
    }

    /// **終わった後に届いても落ちない。** 持ち越すのは面だけで、実行そのものは `Task` に
    /// 生かされない (``LaunchingSketch``) — 先に実行が畳まれていることも確かめる。
    @Test("実行が畳まれた後に届いても落ちず、絵はそのまま返る")
    func anImageStillArrivesAfterTheRunIsGone() async throws {
        let url = try writePicture()
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Requesting()
        sketch.imagePath = url.path
        weak var gone: SketchRuntime?
        do {
            let runtime = try makeRuntime(sketch)
            runtime.start()
            gone = runtime
        }
        #expect(gone == nil, "Task が実行そのものを生かしている")

        await sketch.loading?.value
        #expect(sketch.detachedWhenCalled == [true])
        let picture = try #require(sketch.picture)
        #expect(isClose(picture.get(1, 0), 0, 0, 1), "右の画素: \(picture.get(1, 0))")
    }
}
