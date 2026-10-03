// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// 走者のプロセスに 1 つずつしかない、合図の受け口と印 ([#1937])。
///
/// **控えて戻す口はこれ 1 つ。** 合図を扱う検査は、書き換える前に ``current()`` で控え、
/// `defer` で ``restore()`` する。**控えてから戻すまでの間に main actor を手放さない**
/// (`await` を挟まない・実行ループを回さない)。手放すと、その間に走ったほかの検査の控えと
/// 戻しが、この検査の内側に収まらない。
///
/// 控えるのは、受け口 (道具と子が置くもの・見張りが無視にする SIGPIPE) と、道具の印
/// (`runChildPID`・`runStopSignal`・`watchStopRequested`・`WatchCommand.teardownDone`)、子の旗
/// (`sketchStopRequested`) である。`teardownDone` は一度立つと下りない印で、残すと後に走る
/// 見張りの後始末が冒頭で抜ける (窓を閉じず、駆動源が実行ループに残る)。
///
/// 戻し忘れは ``SignalStateKept`` (suite に付ける trait) が赤にする。本体の検査
/// (`MokumeCoreTests`) にも同じ名前の型があり、受け口の控え方と比べ方は
/// ``StopSignals/snapshot(_:)`` / ``StopSignals/changed(since:)`` を分け持つ。
///
/// [#1937]: https://github.com/mokume-metal/mokume/issues/1937
nonisolated struct SignalState: @unchecked Sendable {
    /// 控える合図。
    static let numbers: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGALRM, SIGPIPE]

    private let receivers: [(number: Int32, previous: sigaction)]
    private let childPID: pid_t
    private let runStop: sig_atomic_t
    private let watchStop: sig_atomic_t
    private let teardownDone: Bool
    private let sketchStop: sig_atomic_t

    private init() {
        receivers = StopSignals.snapshot(Self.numbers)
        childPID = runChildPID
        runStop = runStopSignal
        watchStop = watchStopRequested
        teardownDone = MainActor.assumeIsolated { WatchCommand.teardownDone }
        sketchStop = sketchStopRequested
    }

    /// いまの受け口と印を控える。**main actor の上で呼ぶ。**
    static func current() -> SignalState { SignalState() }

    /// 控えた形へ戻す。**main actor の上で呼ぶ。**
    func restore() {
        StopSignals.restore(receivers)
        runChildPID = childPID
        runStopSignal = runStop
        watchStopRequested = watchStop
        let teardownDone = teardownDone
        MainActor.assumeIsolated { WatchCommand.teardownDone = teardownDone }
        sketchStopRequested = sketchStop
    }

    /// 控えた時から変わったもの。**変わっていなければ空。**
    func changes() -> [String] {
        var changed = StopSignals.changed(since: receivers).map {
            "受け口 \($0) (\(String(cString: strsignal($0))))"
        }
        let now = SignalState()
        if now.childPID != childPID {
            changed.append("宛先 runChildPID (\(childPID) → \(now.childPID))")
        }
        if now.runStop != runStop {
            changed.append("印 runStopSignal (\(runStop) → \(now.runStop))")
        }
        if now.watchStop != watchStop {
            changed.append("印 watchStopRequested (\(watchStop) → \(now.watchStop))")
        }
        if now.teardownDone != teardownDone {
            changed.append("印 WatchCommand.teardownDone (\(teardownDone) → \(now.teardownDone))")
        }
        if now.sketchStop != sketchStop {
            changed.append("旗 sketchStopRequested (\(sketchStop) → \(now.sketchStop))")
        }
        return changed
    }
}

/// 検査の後、合図の受け口と印が前の形へ戻ったかを見る trait ([#1937])。
///
/// **見るだけで、戻すのは検査の本体である。** trait の前後と本体の間では main actor を手放す
/// ので、ここで戻すと、その間に走ったほかの検査の控えを崩しうる。戻っていなければ赤を
/// 記録し、そのときに限って控えへ戻す (後の検査を巻き込まないため)。
///
/// 読むのは main actor の上である。範囲の検査は受け口と印を main actor の上で書き換えるので、
/// 書き換えている最中を読まない。本体の検査 (`MokumeCoreTests`) の同名の trait と同じ形で、
/// 検査ターゲットどうしはコードを分け持てないので 2 つある。
///
/// [#1937]: https://github.com/mokume-metal/mokume/issues/1937
nonisolated struct SignalStateKept: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        let before = await MainActor.run { SignalState.current() }
        var failure: (any Error)?
        do { try await function() } catch { failure = error }
        await MainActor.run {
            let changed = before.changes()
            guard !changed.isEmpty else { return }
            Issue.record(
                "検査の後、合図の受け口と印が前の形へ戻っていない: \(changed.joined(separator: "・"))")
            before.restore()
        }
        if let failure { throw failure }
    }
}

extension Trait where Self == SignalStateKept {
    /// 検査の後、合図の受け口と印が前の形へ戻ったかを見る (``SignalStateKept``)。
    static var signalStateKept: Self { Self() }
}
