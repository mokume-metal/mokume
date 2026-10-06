// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 走っている最中の `settings.frameRate` への代入は、1 度だけ警告して断る
/// ([#1323](https://github.com/mokume-metal/mokume/issues/1323))。
///
/// 速さは起動のときに 1 度だけ読む。`var settings` と持てば代入は通り、読み返しても代入した
/// 値が返るので、黙っていると変えられたように見える。断るといっても枚数・`time`・`deltaTime`
/// は起動のときのままで、変わっていないことを言うだけである。
@Suite(
    "走っている最中の frameRate の代入",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FrameRateAssignmentTests {
    /// 設定を `var` で持ち、指定の枚目に `frameRate` を代入するスケッチ。
    final class Reassigning: Sketch {
        var settings = SketchSettings(width: 32, height: 16, frameRate: 60)
        /// 何枚目に何を代入するか。枚目は `frameCount`。
        var assignments: [Int: Int] = [:]
        /// `setup()` で代入する値。
        var assignInSetup: Int?
        var seenDeltas: [Float] = []
        var seenTimes: [Float] = []

        init() {}
        func setup() {
            if let assignInSetup { settings.frameRate = assignInSetup }
        }
        func draw() {
            if let value = assignments[frameCount] { settings.frameRate = value }
            seenDeltas.append(deltaTime)
            seenTimes.append(time)
            background(0)
        }
    }

    private func run(_ sketch: Reassigning, frames: Int) throws -> SketchRuntime {
        // 時計を渡さないので、フレーム番号から導く既定の時計 (起動のときの 60) で刻む
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice(), clock: nil)
        for _ in 0..<frames { try runtime.advance() }
        return runtime
    }

    @Test("30 枚目に 5 を代入すると警告が 1 度だけ出て、deltaTime と time は 60 fps のまま")
    func assigningWhileRunningWarnsOnceAndChangesNothing() throws {
        let sketch = Reassigning()
        sketch.assignments = [30: 5]
        let runtime = try run(sketch, frames: 29)
        #expect(!runtime.warnings.hasWarned(.frameRateChangedWhileRunning), "代入する前に言った")

        for _ in 0..<31 { try runtime.advance() }

        let message = try #require(
            runtime.warnings.message(for: .frameRateChangedWhileRunning), "代入しても言わなかった")
        #expect(message.contains("settings.frameRate"))
        #expect(message.contains("5"), "代入した値を名乗っていない")
        #expect(message.contains("60"), "効いている値を名乗っていない")
        // 枚数・時刻は起動のときのまま
        #expect(sketch.seenDeltas.count == 60)
        #expect(sketch.seenDeltas.allSatisfy { $0 == Float(1.0 / 60) })
        #expect(abs((sketch.seenTimes.last ?? 0) - Float(59.0 / 60)) < 1e-6)
        // 読み返せば代入した値が返る (断るのは効かせることで、値を戻すことではない)
        #expect(sketch.settings.frameRate == 5)
    }

    /// **繰り返さない。** 鍵が 1 つなので、別の値を代入し直しても 2 度目は言わない。
    /// 言った文面は最初の代入のもののまま残る。
    @Test("別の値を代入し直しても、2 度目は言わない")
    func reassigningAgainDoesNotWarnTwice() throws {
        let sketch = Reassigning()
        sketch.assignments = [3: 5, 6: 120, 9: 60, 12: 24]
        let runtime = try run(sketch, frames: 15)

        let message = try #require(runtime.warnings.message(for: .frameRateChangedWhileRunning))
        #expect(message.contains(" 5 "), "最初の代入の文面ではない: \(message)")
        #expect(!message.contains("120"))
    }

    @Test("代入しないスケッチでは言わない")
    func untouchedSettingsSayNothing() throws {
        let runtime = try run(Reassigning(), frames: 10)
        #expect(!runtime.warnings.hasWarned(.frameRateChangedWhileRunning))
    }

    /// **同じ値の代入は変えたことにならない。** 起動のときの値と比べるので、`60` へ代入しても
    /// 言わない (手本の癖で `frameRate(60)` を毎フレーム書く例を、警告で埋めない)。
    @Test("起動のときと同じ値を代入しても言わない")
    func assigningTheSameValueSaysNothing() throws {
        let sketch = Reassigning()
        sketch.assignments = [2: 60, 3: 60]
        let runtime = try run(sketch, frames: 5)
        #expect(!runtime.warnings.hasWarned(.frameRateChangedWhileRunning))
    }

    /// **`setup()` での代入も効かない。** 速さは `setup()` より前、組み立てで読むので、ここで
    /// 代入しても同じく黙って落ちる。最初の 1 枚を進めた時点で言う。
    @Test("setup() で代入しても、最初の 1 枚で言う")
    func assigningInSetupWarnsOnTheFirstFrame() throws {
        let sketch = Reassigning()
        sketch.assignInSetup = 30
        let runtime = try run(sketch, frames: 1)
        #expect(runtime.warnings.hasWarned(.frameRateChangedWhileRunning))
        #expect(sketch.seenDeltas == [Float(1.0 / 60)])
    }
}
