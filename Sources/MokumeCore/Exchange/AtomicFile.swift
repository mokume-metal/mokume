// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 読み手が書きかけを掴まないように書く ([ADR-0018] 決定 3)。
///
/// 同じディレクトリの一時ファイルへ書いてから `rename` で所定の名前にする。
/// `rename(2)` は同一ボリューム内で不可分なので、読み手から見えるのは「前の内容」か
/// 「新しい内容」のどちらかだけになる。**別のディレクトリの一時ファイルからでは
/// この保証が無い** (ボリュームをまたぐとコピーになる) ので、必ず隣に作る。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
enum AtomicFile {
    /// 中身を原子的に置く。途中のディレクトリは必要なら作る。
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp", isDirectory: false)
        try data.write(to: temporary)
        // 置換は 1 回の syscall で済ませる。先に消してから rename すると、
        // その隙間に読み手が「ファイルが無い」状態を見る
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// 書き手にファイルを作らせて、出来上がりを原子的に置く。
    ///
    /// URL にしか書けない道具 (画像の書き出しなど) を、同じ規約に乗せるための入口。
    static func write(to url: URL, using body: (URL) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp", isDirectory: false)
        try body(temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// 消す。無ければ何もしない。
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
