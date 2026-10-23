// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 走っているスケッチの `Task` を取り消したまま、絵・モデル・SVG を読む ([#2920])。
///
/// 面を取る口 (``Sketch/requestImage(_:)`` ほか) は、走っている実行から起こした `Task` の
/// 中で呼ぶ必要があるので、GPU の要る実行の上で見る。ファイルの読み込みは取消を見ない
/// (`Task.detached` か専用の thread へ渡すので、呼んだ `Task` の取消は届かない)。文字・表・
/// JSON・XML と URL の取消は ``RequestCancellationTests`` が見る。
///
/// **A の後に B を要求して A の `Task` を取り消す例** (``Sketch/requestImage(_:)`` の説明文の例と
/// 同じ書き方) も、ここで動かして確かめる: 取り消した A も読み終えて届き、番号が違うので採られない。
///
/// [#2920]: https://github.com/mokume-metal/mokume/issues/2920
@Suite(
    "取り消した Task から、絵・モデル・SVG を待たずに読む",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RequestCancellationOnASurfaceTests {
    /// 起こした `Task` が自分を取り消してから、読む口を呼ぶスケッチ。
    final class Cancelling: Sketch {
        var settings = SketchSettings(width: 8, height: 4)
        var imagePath: String?
        var modelPath: String?
        var shapePath: String?
        var loading: Task<Void, Never>?
        /// 口を呼んだ時点で `Task` が取り消されていたか。呼んだ順に並ぶ。
        var cancelledWhenCalled: [Bool] = []
        var picture: Image?
        var arrivedModel: Model?
        var mark: Shape?

        init() {}

        func setup() {
            loading = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                if let imagePath {
                    cancelledWhenCalled.append(Task.isCancelled)
                    picture = try? await requestImage(imagePath)
                }
                if let modelPath {
                    cancelledWhenCalled.append(Task.isCancelled)
                    arrivedModel = try? await requestModel(modelPath)
                }
                if let shapePath {
                    cancelledWhenCalled.append(Task.isCancelled)
                    mark = try? await requestShape(shapePath)
                }
            }
        }

        func draw() { background(0) }
    }

    /// 説明文の例と同じ書き方で、最後に要求したものだけを採るスケッチ。
    final class Switching: Sketch {
        var settings = SketchSettings(width: 8, height: 4)
        var photo: Image?
        var loading: Task<Void, Never>?
        var latest = 0
        /// どの要求も、届いた回数 (採ったかどうかによらない)。
        var arrivals = 0
        /// 読み込みを起こした `Task` を、呼んだ順に持つ (検査が全部待つため)。
        var started: [Task<Void, Never>] = []

        /// `setup()` が続けて要求する 2 枚 (走っている実行の中から `Task` を起こすため)。
        var first = ""
        var second = ""

        init() {}

        func setup() {
            showPhoto(first)
            showPhoto(second)
        }

        func draw() { background(0) }

        func showPhoto(_ path: String) {
            loading?.cancel()
            latest += 1
            let mine = latest
            let task = Task {
                let arrived = try? await requestImage(path)
                if arrived != nil { arrivals += 1 }
                guard mine == latest else { return }
                photo = arrived
            }
            loading = task
            started.append(task)
        }
    }

    /// 1 色の絵を書き出す。大きい絵ほど復号に時間がかかるので、遅れて届く A を作れる。
    private func writePicture(red: UInt8, blue: UInt8, side: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-cancel-\(UUID().uuidString).png")
        let bytes = [UInt8]((0..<(side * side)).flatMap { _ in [red, 0, blue, 255] })
        try PNGFile.write(DisplayImage(width: side, height: side, bytes: bytes), to: url)
        return url
    }

    @Test("取り消した Task からでも、絵・モデル・SVG は読み終えて届く")
    func arrivalsDespiteCancellation() async throws {
        let png = try writePicture(red: 255, blue: 0)
        defer { try? FileManager.default.removeItem(at: png) }
        let svg = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-cancel-\(UUID().uuidString).svg")
        let body = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#
        try Data(body.utf8).write(to: svg)
        defer { try? FileManager.default.removeItem(at: svg) }

        let sketch = Cancelling()
        sketch.imagePath = png.path
        sketch.modelPath = ModelFixture.pyramid
        sketch.shapePath = svg.path
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        runtime.start()

        await sketch.loading?.value
        #expect(sketch.cancelledWhenCalled == [true, true, true], "取り消した Task から呼べていない")
        #expect(sketch.picture != nil, "取り消した Task の絵が、読み終えずに捨てられている")
        #expect(sketch.arrivedModel?.triangleCount == 6, "取り消した Task のモデルが届いていない")
        #expect(sketch.mark != nil, "取り消した Task の SVG が届いていない")
    }

    @Test("A の後に B を要求して A の Task を取り消しても A は届き、番号で照合して B だけを採る")
    func theLaterRequestWinsByNumber() async throws {
        // A は大きい絵にして、B より遅れて届くようにする (遅れた A を採ると B が負ける)
        let a = try writePicture(red: 255, blue: 0, side: 1024)
        let b = try writePicture(red: 0, blue: 255)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let sketch = Switching()
        sketch.first = a.path
        sketch.second = b.path
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        runtime.start()

        for task in sketch.started { await task.value }

        #expect(sketch.arrivals == 2, "取り消した A が届いていない (取消で止まるようになった)")
        let photo = try #require(sketch.photo)
        let pixel = photo.get(0, 0)
        #expect(pixel.blue > 0.99 && pixel.red < 0.01, "B ではなく A を採っている: \(pixel)")
    }
}
