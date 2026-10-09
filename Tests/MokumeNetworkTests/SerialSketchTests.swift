// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ。
final class SerialSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (SerialSketch) -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (SerialSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// 作る口で作ったシリアルの入り口を、走っているスケッチの中で回す (#1961)。GPU を要する。
///
/// 注入した行の列で回すので、ポートは開かない。**どの行がどのフレームの `draw()` に届くかが
/// フレームの数え方だけで決まる**ことが約束で、これが水準 2 を名乗れる根拠になる
/// (ADR-0028 決定 7)。
@Suite(
    "シリアルの入り口 (走っているスケッチ)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SerialSketchTests {
    /// 注入した列を流し、`draw()` ごとに届いた行を集める。
    private func record(
        _ batches: [[String]], frames: Int, stopAt: Int? = nil
    ) throws -> (frames: [[String]], serial: Serial?) {
        var serial: Serial?
        var seen: [[String]] = []
        SerialSketch.onSetup = { sketch in serial = sketch.createSerial(lines: batches) }
        SerialSketch.onDraw = { _ in
            seen.append(serial?.lines ?? [])
            if seen.count == stopAt { serial?.stop() }
        }
        let runtime = try SketchRuntime(sketch: SerialSketch(), gpu: try RenderDevice())
        for _ in 0..<frames { try runtime.advance() }
        return (seen, serial)
    }

    @Test("setup() で作った注入の入り口は、最初の draw() から 1 束ずつ、同じ並びで渡す")
    func injectedLinesReachDrawInOrder() throws {
        let batches = [["0"], [], ["512", "1023"]]
        let first = try record(batches, frames: 5)
        #expect(first.frames == batches + batches.prefix(2))
        #expect(first.serial?.state == .running)
        #expect(first.serial?.lastArrival?.frame != nil)

        // 何度回しても、同じ行が同じフレームに届く
        let second = try record(batches, frames: 5)
        #expect(second.frames == first.frames)
    }

    @Test("stop() の後は何も届かず、状態は stopped を名乗る")
    func stopEndsDelivery() throws {
        let batches = [["512"]]
        let result = try record(batches, frames: 4, stopAt: 2)
        #expect(result.frames.prefix(2).allSatisfy { $0 == batches[0] })
        #expect(result.frames.dropFirst(2).allSatisfy { $0.isEmpty })
        #expect(result.serial?.state == .stopped)
    }
}
