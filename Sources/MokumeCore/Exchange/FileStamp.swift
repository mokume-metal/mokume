// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// 読む先のファイルの改訂の印。**変わったかを比べるためだけに使う** ([#1786])。
///
/// **別の改訂と見るのは、最終更新時刻・大きさ・ファイル番号 (inode)・ボリューム (device) のどれかが
/// 変わったとき** (#4148)。時刻だけでは、時刻の同じ別のファイルへ読む先が替わったこと (リンクの付け替え・
/// 時刻を保った写しを `rename` で置き換える) を表せない。どの欄も同じ `stat` の 1 回から取る。
/// **代償**: 同じファイルを同じ大きさで書き換えて時刻を手で戻したとき (と、時刻の刻みの粗い置き場で同じ刻みの
/// 中に同じ大きさで書き換えたとき) は見分けない。
///
/// `FileManager.attributesOfItem(atPath:)` は所有者名などを含む属性の辞書を毎回組むので、
/// 1 回 40 µs かかる。見張りは毎フレーム (観測・入力・つまみの区画) や毎リフレッシュ
/// (ビューア)、控えの照合のたび (`loadImage`) に読むので、ここは `stat` の 1 回 (1 µs) で
/// 足りる。**リンクは辿り、読む先の印を取る** (#3994) — 呼び手は皆リンクを辿って中身を読むので、
/// リンクそのものの印 (`attributesOfItem`・`lstat` が返すもの) を控えると、先だけを差し替えた
/// ときに控えが古いまま残る。切れたリンクは読む先が無いので `nil`。
///
/// 時刻は秒とナノ秒のまま比べる。`Date` へ直すと倍精度の丸めで近い 2 つの時刻が潰れうる
/// ので、変化の検出は細かくなる側にしか動かない。読めないときは `nil`。
///
/// [#1786]: https://github.com/mokume-metal/mokume/issues/1786
package nonisolated struct FileStamp: Equatable, Sendable, CustomStringConvertible {
    let seconds: Int
    let nanoseconds: Int
    let size: Int64
    /// ファイル番号はボリュームの中でしか一意でないので、ボリュームと組で見る。
    let device: Int32
    let inode: UInt64

    /// `url` (リンクなら辿った先) の印。読めなければ `nil`。
    package static func of(_ url: URL) -> FileStamp? {
        guard case .stamped(let stamp) = lookUp(url) else { return nil }
        return stamp
    }

    /// 読む先の印の見え方。**無いのか、在るのに辿れないのかを分ける。**
    enum Lookup: Equatable, Sendable {
        /// 読む先の印。
        case stamped(FileStamp)
        /// 無い。切れたリンクも、無いファイルと同じくここ。
        case absent
        /// リンク自身は在るが、辿れない (循環する・検索の権利の無い場所を通る)。値はリンク自身の印で、
        /// 改訂を見分けるためだけに使う。読みに行けば理由の付いた失敗になる (`AssetLookup` と同じ線引き)。
        case unreachable(link: FileStamp)
    }

    /// `url` を辿って印を取る。**取れなかったときだけ**、`ENOENT` 以外ならリンク自身を `lstat` で見る —
    /// 無いファイル・切れたリンクは `stat` の 1 回で済む。
    static func lookUp(_ url: URL) -> Lookup {
        var info = stat()
        if stat(url.path, &info) == 0 { return .stamped(FileStamp(info)) }
        guard errno != ENOENT, lstat(url.path, &info) == 0 else { return .absent }
        return .unreachable(link: FileStamp(info))
    }

    /// 全部の欄を並べた文字列。**同一性の鍵を文字列で作る呼び手は、欄を選ばずこれを使う。**
    package var description: String {
        "\(seconds).\(nanoseconds) \(size)B \(device):\(inode)"
    }

    private init(_ info: stat) {
        self.init(
            seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size), device: Int32(info.st_dev), inode: UInt64(info.st_ino))
    }

    init(seconds: Int, nanoseconds: Int, size: Int64, device: Int32, inode: UInt64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
        self.size = size
        self.device = device
        self.inode = inode
    }
}
