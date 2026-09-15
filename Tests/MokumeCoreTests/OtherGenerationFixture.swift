// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

@testable import MokumeCore

/// 同じ区画を見ている、**別のプロセスの世代**。
///
/// 区画に応える権利 (``FacetClaim``) は錠ファイルへの `flock` で、`flock` は**開いた記述
/// ごと**の錠である。検査が錠ファイルを自分で開いて錠を掛ければ、同じプロセスの中でも
/// 「別のプロセスが持っている」状態を作れる — 見張りが 2 世代を重ねる形を、子を起こさずに
/// 表すための口 ([#1162](https://github.com/mokume-metal/mokume/issues/1162))。
///
/// **区画の持ち手より先に作る。** 先に作られた持ち手は権利を取り終えているので、後から
/// 錠を掛けても取れない (``init(holding:)`` は投げる)。
nonisolated final class OtherGenerationFixture {
    private var descriptor: Int32

    struct CouldNotHold: Error {}

    /// その区画の権利を持つ。
    init(holding facet: URL) throws {
        let url = WorkDirectory.claimURL(under: facet)
        let opened = open(url.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard opened >= 0 else { throw CouldNotHold() }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            throw CouldNotHold()
        }
        descriptor = opened
    }

    /// 居なくなる。**プロセスが終わったときと同じく、錠が外れる。**
    func leave() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { leave() }
}
