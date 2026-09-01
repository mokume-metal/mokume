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
            try WatchCommand.run([root.path], watching: { _ in })
        }
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

    @Test("印が立つと、巡回を抜ける")
    func leavesTheLoopWhenStopped() throws {
        let stub = Stub()
        let session = WatchSession(directory: try makeDirectory(), hooks: stub.hooks())
        var sleeps = 0

        WatchCommand.watch(session, sleep: { _ in sleeps += 1 }, stopped: { sleeps >= 2 })

        #expect(sleeps == 2)
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
        var sleeps = 0
        WatchCommand.watch(session, sleep: { _ in sleeps += 1 }, stopped: { sleeps >= 1 })

        #expect(stub.builds == 1)
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
