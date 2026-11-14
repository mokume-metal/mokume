// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCamera

/// 先読みの係が最新の頼みを見て列を埋め終える (``MoviePrefetcher/isSettled``) まで待つ検査の道具。
///
/// 待つ側が期限を持つ。期限は、係が最初のコマで面の色の表を作る (debug で数秒) 間を含む。越えたら、
/// 係の状態 (``MoviePrefetcher/diagnosis``) を失敗の説明に載せる: 係が進んでいるのに遅いのか、頼みが
/// 新しいのに休んでいるのかを、記録 1 回で読み分けるため。
enum PrefetcherSettle {
    static let limit: Duration = .seconds(60)

    /// 係が列を埋め終えるまで待つ。期限を越えたら落とす。
    static func wait(_ prefetcher: MoviePrefetcher, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + limit
        while !prefetcher.isSettled {
            try #require(
                ContinuousClock.now < deadline, "係が \(limit) で列を埋め終えない: \(prefetcher.diagnosis)",
                sourceLocation: sourceLocation)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// ``wait(_:sourceLocation:)`` の、同期の文脈 (`draw()` の中) から呼べる形。呼んだスレッドを塞ぐ
    /// (係は別のスレッドで走る)。期限を越えたら失敗を記録して `false` を返す。
    @discardableResult
    static func waitBlocking(_ prefetcher: MoviePrefetcher, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let deadline = ContinuousClock.now + limit
        while !prefetcher.isSettled {
            guard ContinuousClock.now < deadline else {
                Issue.record("係が \(limit) で列を埋め終えない: \(prefetcher.diagnosis)", sourceLocation: sourceLocation)
                return false
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }
}
