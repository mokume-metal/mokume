// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// `setup()` は `throws` で書ける ([#2401])。
///
/// 約束は 3 つ。**投げない `func setup()` はこれまでどおり組めて、呼ばれる** / **投げたら、`draw()` を 1 度も呼ばずに
/// 起動の失敗として止まり、失敗の全文が運ばれる** / **どの経路 (`SketchRuntime` を直に回す・書き出す・窓) でも同じ
/// 失敗で止まる**。
///
/// [#2401]: https://github.com/mokume-metal/mokume/issues/2401
@Suite(
    "setup() が投げたとき",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SetupThrowsTests {
    /// 投げない `func setup()` を書いた、これまでの形のスケッチ。
    final class Quiet: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        var setups = 0
        var draws = 0
        init() {}
        func setup() { setups += 1 }
        func draw() {
            draws += 1
            background(20)
        }
    }

    /// 読み込みの失敗を `try` で通すスケッチ。`var cat: Image!` と `cat = try loadImage(…)` の形。
    final class Missing: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        var cat: Image!
        /// 投げる前に、読み込みの失敗そのものから取った文面。運ばれた文面と突き合わせる
        var original: String?
        var draws = 0
        init() {}
        func setup() throws {
            do {
                cat = try loadImage("assets/does-not-exist.png")
            } catch {
                original = "\(error)"
                throw error
            }
        }
        func draw() { draws += 1 }
    }

    /// 型を問わない — 資源ごとの失敗でなくても、自分の型で投げてよい。
    struct Custom: Error, CustomStringConvertible {
        var description: String { "my own failure\nfix it and run again" }
    }

    final class Plain: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        var draws = 0
        init() {}
        func setup() throws { throw Custom() }
        func draw() { draws += 1 }
    }

    /// 1 枚進めて、投げた失敗を返す。
    private func failure(of runtime: SketchRuntime) -> RenderFailure? {
        do {
            try runtime.advance()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 投げない setup はこれまでどおり

    @Test("投げない func setup() は組めて、1 度だけ呼ばれ、draw() も呼ばれる")
    func aNonThrowingSetupStillRuns() throws {
        let sketch = Quiet()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        try runtime.advance()
        #expect(sketch.setups == 1, "setup() が 1 度だけ呼ばれていない: \(sketch.setups)")
        #expect(sketch.draws == 2)
        #expect(runtime.setupFailure == nil)
    }

    // MARK: - 投げたら止まる

    @Test("setup() が loadImage の失敗を投げたら、draw() を呼ばずに止まり、失敗の全文を運ぶ")
    func aThrownLoadFailureStopsTheSketch() throws {
        let sketch = Missing()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        let first = try #require(failure(of: runtime), "setup() が投げたのに、フレームが進んだ")
        let original = try #require(sketch.original, "loadImage が失敗していない")
        #expect(original.contains("does-not-exist.png"), "検体が読み込みの失敗を起こしていない: \(original)")
        #expect(first == .setupFailed(reason: original), "投げた失敗の全文が運ばれていない: \(first)")
        #expect(sketch.draws == 0, "draw() が呼ばれた")
        #expect(runtime.frameCount == 0, "時計が進んだ")

        // 呼び直しても同じ失敗が返り、draw() は 1 度も呼ばれない
        #expect(failure(of: runtime) == first)
        #expect(sketch.draws == 0)
    }

    @Test("起動の失敗の文面は、名乗りと失敗の全文 (次にすることまで) を持つ")
    func theStartupTextCarriesTheWholeFailure() throws {
        let sketch = Missing()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        let thrown = try #require(failure(of: runtime))
        let original = try #require(sketch.original)
        let text = startupFailureText(thrown)
        #expect(text.hasPrefix("The sketch could not start.\n"))
        #expect(text.contains(original), "失敗の全文が文面に入っていない")
        #expect(text.split(separator: "\n").count >= 3, "次にすることまで書かれていない")
    }

    @Test("投げる型は問わない。自分の型で投げた失敗の文面も運ばれる")
    func anyErrorTypeIsCarried() throws {
        let sketch = Plain()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        #expect(failure(of: runtime) == .setupFailed(reason: Custom().description))
        #expect(sketch.draws == 0)
    }

    @Test("1 枚だけ書き出す口も、同じ失敗で止まり、ファイルを書かない")
    func renderingOneFrameStopsTheSameWay() throws {
        let sketch = Missing()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-setup-throws-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: RenderFailure.self) { try runtime.renderFrame(to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path), "止まったのにファイルを書いた")
        #expect(sketch.draws == 0)
    }

    // MARK: - 窓の経路

    @Test("窓の経路は、起動の失敗として 1 を終了コードに終わり、draw() を呼ばない")
    func theApplicationStopsWithStatusOne() throws {
        let sketch = Missing()
        let application = try SketchApplication(sketch: sketch, gpu: RenderDevice())
        var statuses: [Int32] = []
        application.exitProcess = { statuses.append($0) }
        application.didFinishLaunching()
        for _ in 0..<3 { application.displayLinkFired() }
        #expect(statuses == [1], "終了コードが 1 を 1 度だけ渡していない: \(statuses)")
        #expect(sketch.draws == 0, "draw() が呼ばれた")
    }
}
