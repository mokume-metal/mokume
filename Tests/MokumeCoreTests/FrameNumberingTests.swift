// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import Testing

@testable import MokumeCore

/// 番号と時刻が、**どの番号から数えるか**まで約束どおりであること。GPU を要する。
///
/// 番号の起点は、ずれても絵が壊れないので気付かれにくい。既存の検査はどれも、ずれても
/// 通る形で書かれていた ([#1386](https://github.com/mokume-metal/mokume/issues/1386)):
///
/// - 連番はフレーム 1 から撮り始めていたので、フレーム番号 − 1 で振っても 0 から並ぶ
/// - 既定の時計は既定と同じ 60 fps でしか見ておらず、設定を読まずに 60 で刻んでも通る
/// - 出口の 1 枚遅れは `frame` だけを見ており、`time` と大きさが配る側のフレームの値に
///   すり替わっても通る
@Suite(
    "番号と時刻の起点",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FrameNumberingTests {

    // MARK: - 連番の番号

    /// フレームごとに明るさを変え、決めたフレームの間だけ連番に撮る。
    final class Recording: Sketch {
        var pattern = ""
        var startsAt = 0
        var endsAt = 0
        init() {}
        var settings: SketchSettings { SketchSettings(width: 24, height: 16) }
        func draw() {
            // 灰色は書いた数と書き出したバイトが一致する (``LinearRGBA/display(red:green:blue:alpha:)``)
            let level = Self.level(atFrame: frameCount)
            background(.display(red: level, green: level, blue: level))
            if frameCount == startsAt { beginRecord(pattern) }
            if frameCount == endsAt { endRecord() }
        }

        /// そのフレームの明るさ (0…1)。フレームごとに 20/255 ずつ上がる。
        static func level(atFrame frame: Int) -> Float { Float(frame * 20) / 255 }
    }

    /// **番号はこの録りの中での通し番号で、0 から始まる** (``Sketch/beginRecord(_:)`` の
    /// 「フレーム番号ではない — 途中から撮り始めても連番は 0 から続く」)。
    ///
    /// フレーム 4 で撮り始め 7 で止めるので、撮るのは 4・5・6 の 3 枚である
    /// (止めたフレームは入らない — `SaveFramesTests` の「endRecord から返った時点で」と同じ数え方)。
    @Test("途中のフレームから撮り始めても、連番は 0 から振られる")
    func sequenceNumbersStartAtZeroWhereverTheRecordingStarts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-numbering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sketch = Recording()
        sketch.pattern = directory.appendingPathComponent("f-###.png").path
        sketch.startsAt = 4
        sketch.endsAt = 7
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        for _ in 0..<8 { try runtime.advance() }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["f-000.png", "f-001.png", "f-002.png"])

        // 番号が撮った順を指していること: 0 番がフレーム 4 の絵
        for (index, name) in names.enumerated() {
            let frame = sketch.startsAt + index
            let written = try firstByte(of: directory.appendingPathComponent(name))
            let expected = Int(Recording.level(atFrame: frame) * 255)
            #expect(abs(Int(written) - expected) <= 1, "\(name) はフレーム \(frame) の絵ではない")
        }
    }

    /// 書いた PNG の左上の画素の、最初のバイト (赤)。
    private func firstByte(of url: URL) throws -> UInt8 {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = try #require(image.dataProvider?.data as Data?)
        return try #require(data.first)
    }

    // MARK: - 既定の時計

    final class Clocked: Sketch {
        var seenTimes: [Float] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 30) }
        func draw() {
            seenTimes.append(time)
            background(.display(red: 0, green: 0, blue: 0))
        }
    }

    /// 既定の時計は**設定のフレームレートから導く** (``SketchRuntime/init(sketch:gpu:clock:)``)。
    /// 最初のフレームは 0 (``Sketch/time``) で、以後 1/30 秒ずつ進む。
    @Test("frameRate: 30 の既定の時計は、1/30 秒ずつ進む")
    func theDefaultClockFollowsTheDeclaredFrameRate() throws {
        let sketch = Clocked()
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        for _ in 0..<3 { try runtime.advance() }

        let expected: [Double] = [0, 1.0 / 30, 2.0 / 30]
        #expect(sketch.seenTimes.count == expected.count)
        for (seen, want) in zip(sketch.seenTimes, expected) {
            #expect(abs(Double(seen) - want) < 1e-6, "\(sketch.seenTimes)")
        }
    }

    // MARK: - 出口が受け取る 1 枚

    /// 受け取った 1 枚の番号・時刻・大きさと、**受け取った時点でランタイムが何枚目まで
    /// 描いていたか**を控える出口。
    final class Watching: Outlet {
        struct Received {
            let frame: Int
            let time: Double
            let width: Int
            let height: Int
            /// 受け取ったときのランタイムのフレーム番号。1 枚遅れていれば `frame + 1`
            let runtimeFrame: Int?
        }
        private(set) var received: [Received] = []
        weak var runtime: SketchRuntime?

        func receive(_ frame: OutputFrame) {
            received.append(
                Received(
                    frame: frame.frame, time: frame.time, width: frame.width,
                    height: frame.height, runtimeFrame: runtime?.frameCount))
        }
    }

    struct WatchingPlugin: Plugin {
        let outlet: Watching
        func register(into registry: PluginRegistry) { registry.add(outlet: outlet) }
    }

    /// 縦横の違う面を 30 fps で回す。**幅と高さ・時刻の刻みがどれも既定と違う**ので、
    /// 取り違えても既定の値に紛れない。
    final class Watched: Sketch {
        var declared: [any Plugin] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 40, height: 24, frameRate: 30) }
        var plugins: [any Plugin] { declared }
        func draw() { background(.display(red: 0.2, green: 0.2, blue: 0.2)) }
    }

    /// 出口へ渡すのは 1 枚遅れる — 組んだフレームでは配らず、次のフレームの頭で配る
    /// ([#927](https://github.com/mokume-metal/mokume/issues/927))。**それでも番号・時刻・
    /// 大きさは、その絵を描いたフレームの値である** (``OutputFrame`` の「何枚目か」
    /// 「このフレームの時刻」)。配る時点の値を詰めると、1 枚ずつずれた番号と時刻が付く。
    @Test("1 枚遅れで配られても、番号・時刻・大きさはその絵のフレームの値")
    func theDelayedFrameCarriesItsOwnNumbers() throws {
        let outlet = Watching()
        let sketch = Watched()
        sketch.declared = [WatchingPlugin(outlet: outlet)]
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        outlet.runtime = runtime

        for _ in 0..<3 { try runtime.advance() }
        // 閉じるときに、まだ配っていない最後の 1 枚が届く
        runtime.closePlugins()

        #expect(outlet.received.map(\.frame) == [1, 2, 3])
        // **遅れが効いていること。** 配った時点のランタイムは 1 枚先を描いている —
        // ここが同じ番号なら遅れていないので、下の照合は何も見ていない
        #expect(outlet.received.prefix(2).map(\.runtimeFrame) == [2, 3])
        for received in outlet.received {
            let want = Double(received.frame - 1) / 30
            #expect(abs(received.time - want) < 1e-6, "\(received.frame) 枚目の時刻が \(received.time)")
            #expect(received.width == 40)
            #expect(received.height == 24)
        }
    }
}
