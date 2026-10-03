// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Testing

@testable import MokumeCore

/// 走者のプロセスに 1 つずつしかない、終わりの合図の受け口と旗 ([#1937])。
///
/// **控えて戻す口はこれ 1 つ。** 合図を扱う検査は、書き換える前に ``current()`` で控え、
/// `defer` で ``restore()`` する。**控えてから戻すまでの間に main actor を手放さない**
/// (`await` を挟まない・実行ループを回さない)。手放すと、その間に走ったほかの検査の控えと
/// 戻しが、この検査の内側に収まらない。
///
/// 戻し忘れは ``SignalStateKept`` (suite に付ける trait) が赤にする。道具の検査
/// (`MokumeCLITests`) にも同じ名前の型があり、そちらは道具の印も控える。受け口の控え方と
/// 比べ方は ``StopSignals/snapshot(_:)`` / ``StopSignals/changed(since:)`` を分け持つ。
///
/// [#1937]: https://github.com/mokume-metal/mokume/issues/1937
nonisolated struct SignalState: @unchecked Sendable {
    /// 控える合図。子と道具が受け口を置くものと、見張りが無視にする SIGPIPE。
    static let numbers: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGALRM, SIGPIPE]

    private let receivers: [(number: Int32, previous: sigaction)]
    private let sketchStop: sig_atomic_t

    private init() {
        receivers = StopSignals.snapshot(Self.numbers)
        sketchStop = sketchStopRequested
    }

    /// いまの受け口と旗を控える。
    static func current() -> SignalState { SignalState() }

    /// 控えた形へ戻す。
    func restore() {
        StopSignals.restore(receivers)
        sketchStopRequested = sketchStop
    }

    /// 控えた時から変わったもの。**変わっていなければ空。**
    func changes() -> [String] {
        var changed = StopSignals.changed(since: receivers).map {
            "受け口 \($0) (\(String(cString: strsignal($0))))"
        }
        if sketchStopRequested != sketchStop {
            changed.append("旗 sketchStopRequested (\(sketchStop) → \(sketchStopRequested))")
        }
        return changed
    }
}

/// 検査の後、合図の受け口と旗が前の形へ戻ったかを見る trait ([#1937])。
///
/// **見るだけで、戻すのは検査の本体である。** trait の前後と本体の間では main actor を手放す
/// ので、ここで戻すと、その間に走ったほかの検査の控えを崩しうる。戻っていなければ赤を
/// 記録し、そのときに限って控えへ戻す (後の検査を巻き込まないため)。
///
/// 読むのは main actor の上である。範囲の検査は受け口と旗を main actor の上で書き換えるので、
/// 書き換えている最中を読まない。
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
                "検査の後、合図の受け口と旗が前の形へ戻っていない: \(changed.joined(separator: "・"))")
            before.restore()
        }
        if let failure { throw failure }
    }
}

extension Trait where Self == SignalStateKept {
    /// 検査の後、合図の受け口と旗が前の形へ戻ったかを見る (``SignalStateKept``)。
    static var signalStateKept: Self { Self() }
}
