// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 見張りの口。
///
/// 巡回そのもの (何をどの順で決めるか) は `WatchSessionTests` が見る。ここが見るのは
/// **見張りを始める前と、終えるとき**である — どちらも口の側にしか無い。
@Suite("見張りの口")
struct WatchCommandTests {
    /// 巡回を数えるだけの外側。
    @MainActor
    final class Stub {
        var builds = 0
        var stamp: String? = "aaa"

        func hooks() -> WatchSession.Hooks {
            WatchSession.Hooks(
                build: { _ in
                    self.builds += 1
                    return (0, "")
                },
                resolveExecutable: { _ in nil },
                launch: { _, _, _, _ in nil },
                now: { 0 },
                stamp: { _ in self.stamp })
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-watch-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 宣言の抜けを持つスケッチ。`Package.swift` は在るが `resources:` を書いていない。
    private func makeSketchWithUndeclaredAssets() throws -> URL {
        let root = try makeDirectory()
        let assets = root.appendingPathComponent("Sources/demo/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("画像のつもり".utf8).write(to: assets.appendingPathComponent("picture.png"))
        try Data(#"// swift-tools-version: 6.2"#.utf8)
            .write(to: root.appendingPathComponent("Package.swift"))
        return root
    }

    // MARK: - 始める前

    /// **走らせる口と同じものを、同じ形で通す。** 宣言の抜けはビルドを通ってしまうので、
    /// いちばん打つ口だけが素通りしていると、この検査はほとんど効かない ([#682])。
    ///
    /// [#682]: https://github.com/mokume-metal/mokume/issues/682
    @Test("宣言されていない資材があると、見張りは始まらない")
    func refusesToWatchUndeclaredResources() throws {
        let root = try makeSketchWithUndeclaredAssets()
        // 巡回は差し替える。**始める前に止まることを見る検査**なので、止まらなかった
        // ときに合図待ちで固まってはいけない (固まった検査は赤より読みにくい)
        #expect(throws: CommandFailure.resourcesNotDeclared(directory: "Sources/demo/assets")) {
            try WatchCommand.run([root.path], watching: { _, _ in })
        }
    }

    // MARK: - プレビューへ重ねる行

    /// **端末が正で、プレビューはそれを映す。**
    ///
    /// プレビューは端末の代わりではないので ([#705](https://github.com/mokume-metal/mokume/issues/705)
    /// 完了条件 5)、ここだけで名乗る事実を作らない。
    @Test("作り直しが通ったら、重ねる行は畳む")
    func clearsTheNoticeOnSuccess() {
        #expect(WatchCommand.notice(for: report(ok: true)) == nil)
    }

    /// **消すと見分けが付かなくなる。** 保存して印が消え、絵が変わらなければ、作り直しに
    /// 失敗したのか、変えた結果が同じだったのかが読めない。
    @Test("作り直しが通らなかったら、重ねる行は出したままにする")
    func keepsTheNoticeOnFailure() throws {
        let line = try #require(WatchCommand.notice(for: report(ok: false)))
        #expect(line.contains(WatchCommand.holdingLine))
    }

    private func report(ok: Bool) -> BuildReport {
        BuildReport(
            ok: ok, status: ok ? 0 : 1, output: "", stamp: nil, configuration: "debug",
            timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil))
    }

    // MARK: - 書くとき

    /// **端末では、速さの行を消してから書く。** 走らせているスケッチは同じ 1 行を書き換え
    /// 続けているので、消さずに書くと作り直しの記録がその行の途中から続く形になる。
    @Test("端末へ書くときは、速さの行を消してから書く")
    func clearsTheRateLineOnATerminal() {
        let line = WatchCommand.line("作り直した", isTerminal: true)
        #expect(line.hasPrefix("\r"))
        #expect(line.contains("[2K"))
        #expect(line.hasSuffix("作り直した"))
    }

    /// **記録へ落とすときは飾らない。** 制御の文字がそのまま残ると読めない。
    @Test("端末でなければ、飾りを付けない")
    func doesNotDecorateARecord() {
        #expect(WatchCommand.line("作り直した", isTerminal: false) == "作り直した")
    }

    // MARK: - 終えるとき

    /// **合図はハンドラの外で効く。** ハンドラは印を立てるだけで、終わらせるのは巡回。
    @Test("終わりの合図を受けると、印が立つ")
    func raisesTheStopFlagOnSignal() {
        WatchCommand.installStopHandlers()
        defer {
            for number in WatchCommand.stopSignals { signal(number, SIG_DFL) }
            watchStopRequested = 0
        }

        #expect(watchStopRequested == 0)
        raise(SIGTERM)
        #expect(watchStopRequested != 0)
    }

    /// **端末が消える形がいちばん多い。** 見張りを起こしたセッションが終わる経路で、
    /// [#454](https://github.com/mokume-metal/mokume/issues/454) の孤児はこの形をしている。
    @Test("受ける合図に、端末が消える形が入っている")
    func listensForTheHangUp() {
        #expect(WatchCommand.stopSignals.contains(SIGHUP))
        #expect(WatchCommand.stopSignals.contains(SIGINT))
        #expect(WatchCommand.stopSignals.contains(SIGTERM))
    }

    @Test("印が立つと、巡回を抜ける")
    func leavesTheLoopWhenStopped() throws {
        let stub = Stub()
        let session = WatchSession(directory: try makeDirectory(), hooks: stub.hooks())

        #expect(WatchCommand.step(session, stopped: { false }))
        #expect(!WatchCommand.step(session, stopped: { true }))
    }

    /// **終われと言われた後に、もう一度作り直さない。** 待っている間に来た合図を
    /// 見ないと、抜ける直前に子を 1 つ起こしてから終わることになる。
    @Test("待っている間に来た合図は、作り直しより先に効く")
    func doesNotRebuildAfterTheStopSignal() throws {
        let stub = Stub()
        let session = WatchSession(directory: try makeDirectory(), hooks: stub.hooks())
        session.start()
        #expect(stub.builds == 1)

        stub.stamp = "bbb"  // 変化はある。合図が無ければ作り直す状況
        WatchCommand.step(session, stopped: { true })

        #expect(stub.builds == 1)
        // 合図が無ければ作り直す状況であることを、同じ場面で確かめる
        WatchCommand.step(session, stopped: { false })
        #expect(stub.builds == 2)
    }

    /// **止めたかどうかは別の出来事。** 走らせていたものが既に死んでいた場合と、
    /// こちらが止めた場合を同じ言い方にすると、孤児を追うときの手掛かりが消える。
    @Test("走らせているものが居なければ、止めたとは名乗らない")
    func doesNotClaimToHaveStoppedNothing() throws {
        let stub = Stub()
        let session = WatchSession(directory: try makeDirectory(), hooks: stub.hooks())
        session.start()  // launch が nil を返すので子は居ない

        #expect(session.stop() == false)
    }
}
