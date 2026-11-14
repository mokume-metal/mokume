// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// フレーム (書き出しなら 1 枚) ごとに autorelease の置き場を空にする (#4081)。GPU を要する。
///
/// ウィンドウ・書き出し・流す経路は run loop の 1 回ごとに `advance()` を叩くので、run loop が置き場を空にする。
/// 検査や、`advance()` や `Canvas.draw { }` を自分のループで回す道具には run loop の区切りが無い。フレームの中で
/// Metal が autorelease で返したもの (列の置き場の `MTLBuffer` など) は、描き場所と置き場の持ち主が死んだ後も
/// 置き場に残って確保を掴み、区切りの無いループでは `MTLDevice.currentAllocatedSize` が伸び続けた。
/// **区切りは入口 (`advance()`・`Canvas.draw { }`・書き出しの仕事 1 つ) が自分で持つ。**
///
/// GPU のメモリの量は同じプロセスで並んで走る検査の確保と混ざるので数えない。症状は、捨てた描き場所の列の
/// 置き場 (`MTLBuffer`) が入口から返った後も生きているかで見る。入口ごとの範囲は、その中で autorelease した印が
/// 入口から返った時点で死んでいるかで見る。
@Suite(
    "フレームごとの autorelease の区切り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FrameAutoreleaseTests {
    /// autorelease して手放す印。生きているかを弱い参照で見る。
    nonisolated final class Marker: NSObject {}

    /// 作った印を autorelease の置き場へ預けて返す。呼び手が弱く受ければ、置き場だけが印を持つ。
    @inline(never)
    nonisolated static func autoreleased() -> Marker {
        let marker = Marker()
        _ = Unmanaged.passRetained(marker).autorelease()
        return marker
    }

    /// 置き場を弱く持つ。
    struct WeakBuffer {
        weak var buffer: (any MTLBuffer)?
    }

    /// 描き場所が持つ `MTLBuffer` を全部弱く覚える: 環に載る列の置き場 (``GrowableBuffer`` の全スロット) と、
    /// 直に持つ置き場 (混ぜ方の番号・頁の印・空の数の並び)。
    ///
    /// **`Mirror` で非公開の格納まで辿る。** 区切りが無いと残るのは、そのフレームで描くのに束ねた置き場
    /// (`coverages`・`flatInstances`・`formInstances`・`uniforms`・`matrices` のスロット 0 と直に持つ 3 本) で、
    /// どれも非公開である。種類を名指して並べると、置き場を足したときに見落とす。
    static func watchBuffers(of graphics: Canvas) -> [WeakBuffer] {
        var watched: [WeakBuffer] = []
        func visit(_ value: Any, depth: Int) {
            if let buffer = value as? any MTLBuffer {
                watched.append(WeakBuffer(buffer: buffer))
                return
            }
            if let buffers = value as? [any MTLBuffer] {
                watched += buffers.map { WeakBuffer(buffer: $0) }
                return
            }
            // 辿るのは描き場所自身・列の置き場・値の型 (``ShadowBake`` など) だけ。ほかの参照の型 (装置・本体の面・
            // 時刻の置き場) は描き場所の持ち物ではなく、生きていて当たり前の置き場を持つ
            let mirror = Mirror(reflecting: value)
            let owned = depth == 0 || value is GrowableBuffer || mirror.displayStyle == .struct
                || mirror.displayStyle == .optional
            guard depth < 4, owned else { return }
            for child in mirror.children { visit(child.value, depth: depth + 1) }
        }
        visit(graphics, depth: 0)
        return watched
    }

    // MARK: - 症状: 捨てた描き場所の確保

    @Test("面を直に回すループでも、draw { } の後には、捨てた描き場所の列の置き場が手放されている")
    func discardedGraphicsBuffersAreReleasedAfterCanvasDraw() throws {
        let gpu = try RenderDevice()
        let main = try Canvas(target: try RenderTarget(gpu: gpu, width: 64, height: 32), gpu: gpu)
        var watched: [WeakBuffer] = []
        for index in 0..<4 {
            try main.draw {
                main.background(20, 20, 20)
                guard let graphics = try? main.createGraphics(19, 15) else { return }
                graphics.beginDraw()
                graphics.background(Float(index * 60), 80, 120)
                graphics.circle(9, 7, 6)
                graphics.endDraw()
                main.image(graphics, Float(index * 16), 0)
                watched += Self.watchBuffers(of: graphics)
            }
        }
        // 投入した仕事を終わらせ、終わった番号のぶんの保持と常駐を手放させる
        try gpu.settle()
        try #require(!watched.isEmpty, "描き場所が列の置き場を取っていない")
        let alive = watched.compactMap { $0.buffer.map { "\($0.label ?? "unlabeled") (\($0.allocatedSize) B)" } }
        #expect(alive.isEmpty, "捨てた描き場所の置き場が \(watched.count) 本のうち \(alive.count) 本生きている: \(alive)")
    }

    // MARK: - 入口ごとの範囲

    /// `draw()` (と、`throwsInSetup` なら `setup()`) で印を autorelease し、描き場所を作っては置いて捨てる。
    /// `stops` なら `setup()` で止め、押したときのコールバック (描くフレームの外) で印を autorelease する。
    final class MarkingSketch: Sketch {
        var throwsInSetup = false
        var stops = false
        private(set) var markers: [() -> Bool] = []
        private(set) var pressed = false
        var settings: SketchSettings { SketchSettings(width: 64, height: 32) }

        struct Refused: Error {}

        private func mark() {
            weak var marker = FrameAutoreleaseTests.autoreleased()
            markers.append { marker != nil }
        }

        func setup() throws {
            mark()
            if stops { noLoop() }
            if throwsInSetup { throw Refused() }
        }

        func draw() {
            mark()
            background(20)
            guard let graphics = try? createGraphics(19, 15) else { return }
            draw(into: graphics) {
                background(200, 80, 120)
                circle(9, 7, 6)
            }
            image(graphics, 0, 0)
        }

        func mousePressed() {
            pressed = true
            mark()
        }

        var aliveMarkers: Int { markers.filter { $0() }.count }
    }

    @Test("呼び手が置き場を持たずに回しても、setup() と draw() で autorelease したものは advance() から返った時点で手放されている")
    func eachFrameDrainsWhatItAutoreleased() throws {
        let sketch = MarkingSketch()
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        for frame in 1...10 {
            try runtime.advance()
            try #require(
                sketch.aliveMarkers == 0,
                "\(frame) 枚目の後に、autorelease した \(sketch.markers.count) 個のうち \(sketch.aliveMarkers) 個が生きている")
        }
        #expect(sketch.markers.count == 11)
    }

    @Test("止まっている間に描くフレームの外で配ったコールバックが autorelease したものも、advance() から返った時点で手放されている")
    func callbacksOutsideTheFrameAreDrained() throws {
        let facet = try TestScratch.directory("mokume-frame-autorelease")
        let sketch = MarkingSketch()
        sketch.stops = true
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        let markedBefore = sketch.markers.count
        try AtomicFile.write(
            Data(
                #"{"id":"press","events":[{"type":"mouseDown","x":4,"y":4,"button":0},{"type":"mouseUp","x":4,"y":4,"button":0}]}"#
                    .utf8),
            to: facet.appendingPathComponent("request.json"))
        try runtime.advance()
        try #require(sketch.pressed, "コールバックが配られていない")
        #expect(runtime.frameCount == 1, "描き直していない回 (描くフレームの外で配った回) を見る")
        #expect(sketch.markers.count == markedBefore + 1)
        #expect(sketch.aliveMarkers == 0, "描くフレームの外で配ったコールバックが autorelease したものが生きている")
    }

    @Test("setup() が投げたフレームも、autorelease したものを手放してから投げる")
    func aFailedFrameStillDrains() throws {
        let sketch = MarkingSketch()
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

    @Test("面を直に回すループでも、draw { } が返った時点で、その中で autorelease したものは手放されている")
    func canvasDrawDrainsWhatItAutoreleased() throws {
        let gpu = try RenderDevice()
        let canvas = try Canvas(target: try RenderTarget(gpu: gpu, width: 64, height: 32), gpu: gpu)
        for frame in 1...5 {
            weak var marker: Marker?
            try canvas.draw {
                marker = Self.autoreleased()
                canvas.background(20, 20, 20)
            }
            try #require(marker == nil, "\(frame) 枚目の draw { } の後に、autorelease したものが生きている")
        }
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

    // MARK: - 書き出しの仕事

    /// 書き手の仕事どうしで受け渡す箱。
    nonisolated final class LaneProbe: @unchecked Sendable {
        let lock = NSLock()
        weak var firstMarker: Marker?
        var firstAliveWhenSecondStarted: Bool?
        let firstRunning = DispatchSemaphore(value: 0)
        let secondQueued = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
    }

    @Test("書き出しの書き手は、控えが続いてループを抜けなくても、仕事 1 つごとに autorelease したものを手放す")
    func writeLanesDrainEachJob() {
        let lanes = WriteLanes()
        let probe = LaneProbe()
        lanes.enqueue("lane", drop: {}) {
            probe.lock.withLock { probe.firstMarker = FrameAutoreleaseTests.autoreleased() }
            probe.firstRunning.signal()
            // 2 つ目が控えに入るまで、この仕事を終えない (同じループの続きで 2 つ目を書かせる)
            _ = probe.secondQueued.wait(timeout: .now() + 10)
        }
        // **待つ側が期限を持つ。** 書き手が来なければ赤で返る
        guard probe.firstRunning.wait(timeout: .now() + 10) == .success else {
            Issue.record("1 つ目の仕事が 10 秒のうちに走らなかった")
            return
        }
        lanes.enqueue("lane", drop: { probe.secondDone.signal() }) {
            probe.lock.withLock { probe.firstAliveWhenSecondStarted = probe.firstMarker != nil }
            probe.secondDone.signal()
        }
        probe.secondQueued.signal()
        guard probe.secondDone.wait(timeout: .now() + 10) == .success else {
            Issue.record("2 つ目の仕事が 10 秒のうちに終わらなかった")
            return
        }
        let alive = probe.lock.withLock { probe.firstAliveWhenSecondStarted }
        #expect(alive == false, "2 つ目の仕事が始まった時点で、1 つ目が autorelease したものが生きている (\(String(describing: alive)))")
    }
}
