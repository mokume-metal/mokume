// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// ホストのコード (`SketchView` の隣のボタンの処理など) から語彙を呼ぶ ([#3847])。
///
/// ホストのコードは `withActiveRuntime` の外で走るので、差している実行は無い。以前は実体のメソッドから
/// `width` を読んでも 0 になり、警告が出た。いまの規則 (``activeRun(for:from:)``):
///
/// - ``Sketch`` の実体は、自分に結ばれた実行を読む (``SketchHomes``)
/// - 部品は、映している実行が 1 つだけならそれを読む (案 Y)。無い・2 つ以上なら、いまどおり 0 と警告
/// - 描く口は、どちらでもいまどおり何もせず警告
///
/// **どの検査も `await` を挟まない。** 映している実行の印 (`markRunningForTesting`) はプロセスで 1 つなので、
/// 待つ間に他の検査へ番が回ると、その検査に印が見える。控え (``OutsideRun/current``) を差すので、載せた実行は
/// この検査の中でしか数えない。
///
/// [#3847]: https://github.com/mokume-metal/mokume/issues/3847
@MainActor
@Suite(
    "ホストのコードから呼んだ語彙",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct HostCallTests {
    /// Issue の例のスケッチ。ホストのボタンが `reset()` を呼ぶ。
    final class Game: Sketch {
        var x: Float = -1
        var settings: SketchSettings { SketchSettings(width: 800, height: 600) }
        func reset() { x = width / 2 }
        func draw() { circle(x, height / 2, 40) }
    }

    /// 映すだけのスケッチ。
    final class Host: Sketch {
        var settings: SketchSettings { SketchSettings(width: 640, height: 480) }
        func draw() {}
    }

    /// ホストのボタンから呼ぶ部品。
    struct Player: SketchPart {
        var x: Float = -1
        mutating func reset() { x = width / 2 }
        func paint() { circle(x, 10, 10) }
    }

    /// 走る前 (部品の `init()`) に面の大きさを読む部品。
    struct EarlyPlayer: SketchPart {
        var x: Float = -1
        init() { x = width / 2 }
    }

    /// `SketchView` が映しているのと同じ印を立てる。`body` は `await` を挟まずに返す。
    private func presenting(_ sketch: any Sketch, _ body: () throws -> Void) throws {
        let application = try SketchApplication(sketch: sketch, gpu: RenderDevice(), embedded: true)
        application.markRunningForTesting()
        defer { application.unmarkRunningForTesting() }
        try body()
    }

    @Test("走っているスケッチの実体のメソッドをフレームの外から呼ぶと、その実行の width を読み、警告しない")
    func instanceMethodReadsItsOwnRun() throws {
        let game = Game()
        let runtime = try SketchRuntime(sketch: game, gpu: try RenderDevice())
        try runtime.advance()
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) { game.reset() }
        #expect(game.x == 400, "x = \(game.x)")
        #expect(log.messages.isEmpty, "警告は出ない: \(log.messages)")
        runtime.closePlugins()
    }

    @Test("映している実行が 1 つなら、部品のメソッドをフレームの外から呼んでもその width を読み、警告しない")
    func partReadsTheSolePresentedRun() throws {
        let log = OutsideRun()
        try OutsideRun.$current.withValue(log) {
            try presenting(Host()) {
                var player = Player()
                player.reset()
                #expect(player.x == 320, "x = \(player.x)")
            }
        }
        #expect(log.messages.isEmpty, "警告は出ない: \(log.messages)")
    }

    @Test("映している実行が無いとき、部品の init() で読んだ width はいまどおり 0 で、警告が 1 行出る")
    func readingBeforeAnyRunStillReturnsZero() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let player = EarlyPlayer()
            #expect(player.x == 0)
        }
        #expect(log.messages.count == 1, "\(log.messages)")
        #expect(log.messageForRead(of: "width")?.contains("0 was returned instead") == true)
    }

    @Test("映している実行が 2 つ以上なら、部品はどちらも選ばず 0 を返して警告する")
    func twoPresentedRunsAreNotGuessed() throws {
        let first = try SketchRuntime(sketch: Host(), gpu: try RenderDevice())
        let second = try SketchRuntime(sketch: Game(), gpu: try RenderDevice())
        let log = OutsideRun()
        log.present(first)
        log.present(second)
        OutsideRun.$current.withValue(log) {
            var player = Player()
            player.reset()
            #expect(player.x == 0, "x = \(player.x)")
        }
        #expect(log.messageForRead(of: "width") != nil, "\(log.messages)")
        log.withdraw(first)
        #expect(log.solePresented === second, "降ろした後は、残った 1 つを読む")
    }

    @Test("映している実行が 1 つでも、フレームの外から描く口を呼ぶといまどおり何もせず警告する")
    func drawingFromTheHostStillDoesNothing() throws {
        let log = OutsideRun()
        try OutsideRun.$current.withValue(log) {
            try presenting(Host()) { Player().paint() }
        }
        #expect(log.messages.count == 1, "\(log.messages)")
        #expect(log.messages.first?.hasPrefix("circle") == true, "\(log.messages)")
    }

    @Test("止まった実行の実体は、映している別の実行を拾わず、0 を返して警告する")
    func stoppedSketchDoesNotPickAnotherRun() throws {
        let game = Game()
        let runtime = try SketchRuntime(sketch: game, gpu: try RenderDevice())
        try runtime.advance()
        runtime.closePlugins()
        let log = OutsideRun()
        try OutsideRun.$current.withValue(log) {
            try presenting(Host()) { game.reset() }
        }
        #expect(game.x == 0, "x = \(game.x)")
        #expect(log.messageForRead(of: "width") != nil, "\(log.messages)")
    }
}
