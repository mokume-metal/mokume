// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// `advance()` はフレームごとに autorelease の置き場を空にする (#4081)。GPU を要する。
///
/// ウィンドウ・書き出し・流す経路は run loop の 1 回ごとに `advance()` を叩くので、run loop が置き場を空にする。
/// 検査や、`advance()` を自分のループで回す道具には run loop の区切りが無い。`draw()` の中で描き場所を作っては
/// 捨てる書き方では、描き場所と面の持ち主が死んだ後も、autorelease されたものが確保を掴み続け、区切りの無い
/// ループでは `MTLDevice.currentAllocatedSize` が伸び続けた。**区切りは `advance()` 自身が持つ。**
///
/// GPU のメモリの量は同じプロセスで並んで走る検査の確保と混ざるので、ここでは数えない。代わりに、フレームの中で
/// autorelease した印が、呼び手が置き場を持たないまま `advance()` から返った時点で死んでいるかを見る。
@Suite(
    "フレームごとの autorelease の区切り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FrameAutoreleaseTests {
    /// autorelease して手放す印。生きているかを弱い参照で見る。
    final class Marker: NSObject {}

    /// 作った印を autorelease の置き場へ預けて返す。呼び手が弱く受ければ、置き場だけが印を持つ。
    @inline(never)
    private static func autoreleased() -> Marker {
        let marker = Marker()
        _ = Unmanaged.passRetained(marker).autorelease()
        return marker
    }

    /// `draw()` (と、`throwsInSetup` なら `setup()`) で印を autorelease し、描き場所を作っては置いて捨てる。
    final class ChurningSketch: Sketch {
        static let perFrame = 4
        var throwsInSetup = false
        private(set) var markers: [() -> Bool] = []
        private(set) var failures = 0
        private(set) var made: [Canvas.WeakCanvas] = []
        var settings: SketchSettings { SketchSettings(width: 64, height: 32) }

        struct Refused: Error {}

        private func mark() {
            weak var marker = FrameAutoreleaseTests.autoreleased()
            markers.append { marker != nil }
        }

        func setup() throws {
            mark()
            if throwsInSetup { throw Refused() }
        }

        func draw() {
            mark()
            background(20)
            for index in 0..<Self.perFrame {
                guard let graphics = try? createGraphics(19, 15) else {
                    failures += 1
                    continue
                }
                draw(into: graphics) {
                    background(Float(index * 60), 80, 120)
                    fill(255)
                    circle(9, 7, 6)
                }
                image(graphics, Float(index * 16), 0)
                made.append(Canvas.WeakCanvas(canvas: graphics))
            }
        }

        var aliveMarkers: Int { markers.filter { $0() }.count }
    }

    @Test("呼び手が置き場を持たずに回しても、フレームの中で autorelease したものは advance() から返った時点で手放されている")
    func eachFrameDrainsWhatItAutoreleased() throws {
        let sketch = ChurningSketch()
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        for frame in 1...30 {
            try runtime.advance()
            // 1 枚目は setup() と draw() の 2 つ
            try #require(
                sketch.aliveMarkers == 0,
                "\(frame) 枚目の後に、autorelease した \(sketch.markers.count) 個のうち \(sketch.aliveMarkers) 個が生きている")
        }
        try #require(sketch.failures == 0, "描き場所を \(sketch.failures) 回作れなかった")
        #expect(sketch.markers.count == 31)
        // 捨てた描き場所の持ち主も、投入した仕事を終わらせた後には死んでいる (生きてよいのは最後の 1 枚ぶん)
        try runtime.canvas.gpu.settle()
        let alive = sketch.made.filter { $0.canvas != nil }.count
        #expect(alive <= ChurningSketch.perFrame, "捨てた描き場所が \(sketch.made.count) 枚のうち \(alive) 枚生きている")
    }

    @Test("面を直に回すループでも、draw { } が返った時点で、その中で autorelease したものは手放されている")
    func canvasDrawDrainsWhatItAutoreleased() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 64, height: 32)
        let canvas = try Canvas(target: target, gpu: gpu)
        var made: [Canvas.WeakCanvas] = []
        for frame in 1...10 {
            weak var marker: Marker?
            try canvas.draw {
                marker = Self.autoreleased()
                canvas.background(20, 20, 20)
                guard let graphics = try? canvas.createGraphics(19, 15) else { return }
                graphics.beginDraw()
                graphics.background(200, 80, 120)
                graphics.endDraw()
                canvas.image(graphics, 0, 0)
                made.append(Canvas.WeakCanvas(canvas: graphics))
            }
            try #require(marker == nil, "\(frame) 枚目の draw { } の後に、autorelease したものが生きている")
        }
        #expect(made.count == 10, "描き場所を作れなかった")
    }

    @Test("包んだ仕事が投げても、autorelease したものを手放してから同じ失敗を投げ直す")
    func aFailedWorkStillDrains() {
        weak var marker: Marker?
        #expect {
            try drainingAutoreleased { () throws(RenderFailure) in
                marker = Self.autoreleased()
                throw RenderFailure.commandBufferUnavailable
            }
        } throws: { error in
            guard case RenderFailure.commandBufferUnavailable = error else { return false }
            return true
        }
        #expect(marker == nil, "投げた後も autorelease したものが生きている")
    }

    @Test("setup() が投げたフレームも、autorelease したものを手放してから投げる")
    func aFailedFrameStillDrains() throws {
        let sketch = ChurningSketch()
        sketch.throwsInSetup = true
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        #expect {
            try runtime.advance()
        } throws: { error in
            guard case RenderFailure.setupFailed = error else { return false }
            return true
        }
        #expect(sketch.markers.count == 1, "setup() が印を置いていない")
        #expect(sketch.aliveMarkers == 0, "投げたフレームで autorelease したものが生きている")
    }
}
