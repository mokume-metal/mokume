// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 組み立てで受け取る数が 1 を割ったら、型のついたエラーで断る。GPU を要する。
///
/// **約束は [ADR-0020] 決定 5 の 2 行目** — 資源の生成は「失敗したら別の道を選ぶ」判断が
/// 要るので、黙って既定へ倒さない。組み立てで数を受け取る口のうち、次の 5 つが 0 以下を
/// `max(1, …)` で黙って 1 に丸めていた ([#1642])。
///
/// | 口 | 断り方 |
/// | --- | --- |
/// | ``SketchSettings/frameRate`` (と時計の刻み) | ``RenderFailure/invalidFrameRate(_:)`` |
/// | `createGraphics(_:_:)` の幅・高さ | ``RenderFailure/invalidSize(width:height:)`` |
/// | `createImage(_:_:)` の幅・高さ | ``ImageFailure/unplaceable(width:height:)`` |
/// | `makeNumbers(count:)` | ``RenderFailure/invalidCount(_:)`` |
/// | `makeParticles(count:)` | ``RenderFailure/invalidCount(_:)`` |
///
/// **範囲を回す。** どの口も 0 と負で断り、下の端 (1) では作れることを同じ形で確かめる
/// ([ADR-0040] 決定 1)。1 例だけ見ると、残りの口の丸めが見えないまま残る。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0040]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0040-bugs-as-broken-promises.md
/// [#1642]: https://github.com/mokume-metal/mokume/issues/1642
@Suite(
    "組み立てで受け取る数の下の端",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SetupValueRangeTests {
    /// 1 を割る値。0 と、負の小さい値・大きい値。
    static let belowOne = [0, -1, -30, Int.min]

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    // MARK: - frameRate

    /// 宣言したフレームレートで何もしないスケッチ。
    private final class Scene: Sketch {
        var settings = SketchSettings(width: 10, height: 10)
        init() {}
        convenience init(frameRate: Int) {
            self.init()
            settings.frameRate = frameRate
        }
        func draw() {}
    }

    /// 組み立ての入口は 2 つある (公開の入口と、観測の窓口を差し替える検査用の入口)。
    /// **どちらからでも断る** — 片方だけで断ると、もう片方が丸めたまま走る。
    private func assemble(_ sketch: any Sketch, clock: Clock?, entry: Int) throws(RenderFailure) {
        let gpu = try RenderDevice()
        switch entry {
        case 0: _ = try SketchRuntime(sketch: sketch, gpu: gpu, clock: clock)
        default: _ = try SketchRuntime(sketch: sketch, gpu: gpu, clock: clock, now: { 0 }, observer: nil)
        }
    }

    @Test("frameRate が 1 を割ると、どちらの入口の組み立ても断る", arguments: [0, 1])
    func refusesAFrameRateBelowOne(entry: Int) throws {
        for rate in Self.belowOne {
            // 時計を省いたとき (窓の経路) も、書き出しの経路と同じ刻みの時計を渡したときも
            for clock in [nil, Clock.wallClock, .frameIndex(frameRate: 30)] {
                #expect(throws: RenderFailure.invalidFrameRate(rate), "frameRate \(rate)・時計 \(String(describing: clock))") {
                    try assemble(Scene(frameRate: rate), clock: clock, entry: entry)
                }
            }
        }
    }

    /// **時計の刻みも同じ組み立てで受け取る。** 宣言が正しくても、差し替えた時計の刻みが
    /// 1 を割れば、フレーム番号から導く時刻が黙って 1 fps で進む。
    @Test("差し替えた時計の刻みが 1 を割ると、組み立てが断る", arguments: [0, 1])
    func refusesAClockRateBelowOne(entry: Int) throws {
        for rate in Self.belowOne {
            #expect(throws: RenderFailure.invalidFrameRate(rate)) {
                try assemble(Scene(frameRate: 60), clock: .frameIndex(frameRate: rate), entry: entry)
            }
        }
    }

    /// 起票の再現 (probes の `badFrameRate`) の逆側。1 は正しい値で、1 秒に 1 枚進む。
    @Test("frameRate 1 なら組み立てられ、1 秒ずつ進む")
    func assemblesAtOneFramePerSecond() throws {
        let runtime = try SketchRuntime(sketch: Scene(frameRate: 1), gpu: RenderDevice())
        defer { runtime.closePlugins() }
        try runtime.advance()
        try runtime.advance()
        #expect(runtime.time == 1)
        #expect(runtime.deltaTime == 1)
    }

    // MARK: - createGraphics

    @Test("描き場所の幅・高さが 1 を割ると断り、1 なら作れる")
    func graphicsRefuseASideBelowOne() throws {
        let canvas = try makeCanvas()
        for side in Self.belowOne {
            #expect(throws: RenderFailure.invalidSize(width: side, height: 8)) {
                _ = try canvas.createGraphics(side, 8)
            }
            #expect(throws: RenderFailure.invalidSize(width: 8, height: side)) {
                _ = try canvas.createGraphics(8, side)
            }
        }
        let smallest = try canvas.createGraphics(1, 1)
        #expect(smallest.output.width == 1 && smallest.output.height == 1)
    }

    // MARK: - createImage

    @Test("絵の幅・高さが 1 を割ると断り、1 なら作れる")
    func imagesRefuseASideBelowOne() throws {
        let canvas = try makeCanvas()
        for side in Self.belowOne {
            #expect(throws: ImageFailure.unplaceable(width: side, height: 8)) {
                _ = try canvas.createImage(side, 8)
            }
            #expect(throws: ImageFailure.unplaceable(width: 8, height: side)) {
                _ = try canvas.createImage(8, side)
            }
        }
        let smallest = try canvas.createImage(1, 1)
        #expect(smallest.width == 1 && smallest.height == 1)
    }

    // MARK: - makeNumbers / makeParticles

    @Test("数の並びの数が 1 を割ると断り、1 なら作れる")
    func numbersRefuseACountBelowOne() throws {
        let canvas = try makeCanvas()
        for count in Self.belowOne {
            #expect(throws: RenderFailure.invalidCount(count)) {
                _ = try canvas.makeNumbers(count: count)
            }
        }
        #expect(try canvas.makeNumbers(count: 1).count == 1)
    }

    @Test("粒の数が 1 を割ると断り、1 なら作れる")
    func particlesRefuseACountBelowOne() throws {
        let canvas = try makeCanvas()
        for count in Self.belowOne {
            #expect(throws: RenderFailure.invalidCount(count)) {
                _ = try canvas.makeParticles(count: count)
            }
        }
        #expect(try canvas.makeParticles(count: 1).capacity == 1)
    }
}
