// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import Testing

@testable import MokumeCore

/// 検査 1 本ごとに、自分だけの警告の溜め場を差して走らせる trait ([#2903])。
///
/// 観測の応答の `warnings` は、スケッチが言った警告を `Diagnostics` の溜め場から取って載せる
/// (``Diagnostics/takeUnreported()``)。溜め場はプロセスで 1 つなので、差さずに並べて走らせると、
/// ほかの検査が言った警告が混ざって数が変わり、ほかの検査へ自分の警告を持っていかれる。
/// suite に付ければ、その suite の検査は 1 本ずつ別の溜め場を使う (``Diagnostics/digest``)。
///
/// **差せるのは検査と同じタスクが言う警告まで。** `Task.detached` へ逃がした仕事が言った警告は
/// タスクローカル値が届かないので、プロセスの溜め場に入る。そこから言われた警告を数える検査は、
/// この trait では読めない。
///
/// 検査の本体の中で差す形 (`Diagnostics.$digest.withValue(WarningDigest()) { … }`) も、そのまま使える。
///
/// [#2903]: https://github.com/mokume-metal/mokume/issues/2903
nonisolated struct OwnWarningDigest: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // suite 自身には差さない。検査ごとに別の溜め場を差すのは、各 case の側である
        guard testCase != nil else { return try await function() }
        try await Diagnostics.$digest.withValue(WarningDigest()) { try await function() }
    }
}

extension Trait where Self == OwnWarningDigest {
    /// 検査 1 本ごとに自分だけの警告の溜め場を差す (``OwnWarningDigest``)。
    static var ownWarningDigest: Self { Self() }
}
