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
            #expect(throws: ImageFailure.notRunning(call: "createCapture(_:_:device:)")) {
                try sketch.createCapture()
            }
            #expect(throws: ImageFailure.notRunning(call: "createCapture(frames:)")) {
                try sketch.createCapture(frames: [])
            }
            #expect(log.message(for: "createCapture(_:_:device:)") != nil)
            #expect(log.message(for: "createCapture(frames:)") != nil)
            #expect(log.message(for: "createImage(_:_:)") == nil, "中で使った口の名前で言っている")
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
