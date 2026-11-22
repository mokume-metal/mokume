// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// ファイルの最終更新時刻。**変わったかを比べるためだけに使う** ([#1786])。
///
/// `FileManager.attributesOfItem(atPath:)` は所有者名などを含む属性の辞書を毎回組むので、
/// 1 回 40 µs かかる。見張りは毎フレーム (観測・入力・つまみの区画) や毎リフレッシュ
/// (ビューア)、控えの照合のたび (`loadImage`) に読むので、ここは `stat` の 1 回 (1 µs) で
/// 足りる。**リンクは辿り、読む先の時刻を取る** (#3994) — 呼び手は皆リンクを辿って中身を読むので、
/// リンクそのものの時刻 (`attributesOfItem`・`lstat` が返すもの) を控えると、先だけを差し替えた
/// ときに控えが古いまま残る。切れたリンクは読む先が無いので `nil`。
///
/// 時刻は秒とナノ秒のまま比べる。`Date` へ直すと倍精度の丸めで近い 2 つの時刻が潰れうる
/// ので、変化の検出は細かくなる側にしか動かない。読めないときは `nil`。
///
/// [#1786]: https://github.com/mokume-metal/mokume/issues/1786
nonisolated struct FileStamp: Equatable, Sendable {
    let seconds: Int
    let nanoseconds: Int

    /// `url` (リンクなら辿った先) の最終更新時刻。読めなければ `nil`。
    static func of(_ url: URL) -> FileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileStamp(
            seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec))
    }
}
