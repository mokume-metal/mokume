// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCamera
@testable import MokumeCore

/// 面を取れない所 (`setup()`・`draw()`・入力のコールバックの外) から、カメラと動画の口を呼ぶ ([#2683])。
///
/// **利用者が呼んだ口を名乗る。** 中で ``SketchPart/createImage(_:_:)`` を素で呼ぶと、
/// `notRunning(call:)` にも警告にも `"createImage(_:_:)"` が入っていた。``Sketch/createVideo(_:)`` は
/// 絵を作る失敗をまとめて大きさの失敗 (`unplaceable`) に言い換えていたので、面を取れないことが
/// 「辺は 1 以上の画素に」という大きさの話で届いていた。
///
/// 面を作らずに投げることを見るので、GPU は要らない。機材も開かない (絵を作る前に投げる)。
///
/// [#2683]: https://github.com/mokume-metal/mokume/issues/2683
@MainActor
@Suite("面を取れない所から呼んだカメラと動画の口")
struct CameraOutsideRunTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    @Test("createCapture の 2 つの形は、呼んだ形の名前で notRunning を投げ、その名前で警告する")
    func captureNamesItself() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let sketch = Bare()
            #expect(throws: ImageFailure.notRunning(call: "createCapture(_:_:device:mirrored:)")) {
                try sketch.createCapture()
            }
            #expect(throws: ImageFailure.notRunning(call: "createCapture(frames:mirrored:)")) {
                try sketch.createCapture(frames: [])
            }
            #expect(log.message(for: "createCapture(_:_:device:mirrored:)") != nil)
            #expect(log.message(for: "createCapture(frames:mirrored:)") != nil)
            #expect(log.message(for: "createImage(_:_:)") == nil, "中で使った口の名前で言っている")
        }
    }

    /// GPU を作る検査は、GPU の条件を掛けた入れ子の `@Suite` に置く (`GPUGateTests` の規則)。
    @MainActor
    @Suite("走らせた後", .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"))
    struct AfterARun {
        /// `setup()` で絵を流すカメラを足すスケッチ。走り終えた後に `stop()` を呼ぶ側が控える。
        final class Filming: Sketch {
            var capture: Capture?
            init() {}
            var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
            func setup() throws {
                let red = DisplayImage(width: 4, height: 4, bytes: Array(repeating: [255, 0, 0, 255], count: 16).flatMap { $0 })
                capture = try createCapture(frames: [red])
            }
            func draw() { background(0, 0, 0) }
        }

        /// 走っている実行の中で起こした `Task` から止める ([#2840])。`stop()` を呼ぶ側が実行を持たなくても、
        /// 足した実行が走っている間は効く。警告は出ない。
        ///
        /// [#2840]: https://github.com/mokume-metal/mokume/issues/2840
        @Test("走っている間は、Task から Capture の stop() を呼ぶと止まり、警告は出ない (#2840)")
        func stopFromATaskWhileRunning() async throws {
            let sketch = Filming()
            let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
            try runtime.advance()
            let capture = try #require(sketch.capture)
            #expect(capture.state != .stopped)
            let log = OutsideRun()
            await Task {
                OutsideRun.$current.withValue(log) { capture.stop() }
            }.value
            #expect(capture.state == .stopped, "Task から止まる")
            #expect(log.messages.isEmpty, "\(log.messages)")
            runtime.closePlugins()
        }

        /// `Capture` は面の絵を持つので、足せる所で作るには GPU を要する。外で呼ぶ側は何も使わない。
        ///
        /// 後片付け (`closePlugins()`) の後に呼ぶ。外の中でも、終わりの処理が既に閉じた後が文面の分かれ目になる。
        @Test("後片付けの後に Capture の stop() を呼ぶと、呼んでいない detach() ではなく Capture.stop() を名乗る (#2793)")
        func stopAfterTeardownNamesItself() throws {
            let sketch = Filming()
            let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
            try runtime.advance()
            let capture = try #require(sketch.capture)
            runtime.closePlugins()
            #expect(capture.state == .stopped, "終わりの処理が閉じている")
            let log = OutsideRun()
            OutsideRun.$current.withValue(log) {
                capture.stop()
                capture.stop()
            }
            #expect(log.messages.count == 1, "2 度呼んでも 1 行")
            let message = log.message(for: "Capture.stop()")
            #expect(message?.hasPrefix("Capture.stop() only works inside setup()") == true)
            #expect(message?.contains("so it did nothing") == true)
            #expect(log.message(for: "detach") == nil)
        }
    }

    @Test("読める動画でも、createVideo は大きさの失敗ではなく notRunning を投げる")
    func videoSaysItCannotReachTheSurface() async throws {
        try #require(TestMovie.canWrite, "この機械には H.264 の符号化器が無い")
        let url = try await TestMovie.write(frames: 2)
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            #expect(throws: MovieFailure.notRunning(call: "createVideo(_:)")) {
                try Bare().createVideo(url.path)
            }
            #expect(log.message(for: "createVideo(_:)") != nil)
            #expect(log.message(for: "createImage(_:_:)") == nil)
            // ファイルを開く前に断る — 無いファイルでも、探しに行かずに同じ場合で返る
            #expect(throws: MovieFailure.notRunning(call: "createVideo(_:)")) {
                try Bare().createVideo("no-such-clip.mov")
            }
        }
        // 文面は資源の口と同じで、大きさの話をしない
        let text = MovieFailure.notRunning(call: "createVideo(_:)").description
        #expect(text == ImageFailure.notRunning(call: "createVideo(_:)").description)
        #expect(!text.contains("pixels"))
    }
}
