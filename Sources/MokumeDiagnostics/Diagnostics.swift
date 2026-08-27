// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 基盤層 — 何にも依存しない要素だけを置く ([ADR-0016] 決定 1 の最下層)。
///
/// ライブラリが人へ伝えることを 1 箇所に集める。**素の `print` で書かない** —
/// 出力先はスケッチの標準出力であり、そこはスケッチ自身のものだからである。
///
/// 持っているのは ``warn(_:)`` 1 つだけで、段階も分類もまだ無い。**要るものが
/// 分かった時点で足す** ([ADR-0001] 原則 4 / [ADR-0008] 決定 2)。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0016]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0016-package-structure.md
public enum Diagnostics {
    /// 名乗り。どの出力がライブラリのものかを、行を見ただけで分かるようにする。
    static let prefix = "mokume"

    /// ライブラリからの注意を 1 行、標準エラーへ書く。
    ///
    /// **標準出力ではなく標準エラーへ書く。** 標準出力はスケッチが自分の用途で使う
    /// ものなので、ライブラリの都合で混ぜない。見張っている道具が出力を読んでいても、
    /// 注意は別の流れで届く。
    ///
    /// 何度も言うかどうかは呼び出し側が決める — 毎フレーム起きうることをそのまま
    /// 流すと、本当に読むべき 1 行が埋まる。
    public static func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(prefix): \(message)\n".utf8))
    }
}
