// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 読み手が書きかけを掴まないように書く (ADR-0018 決定 3)。
///
/// ライブラリ側にも同じもの (`AtomicFile`) があるが、道具からは使えない (外へ出して
/// いない)。規約は文章で共有し、実装はそれぞれが持つ。
///
/// **「外から使う人が現れてから決める」は、もう決められる。** かつてこの型は
/// ``WatchSession`` のファイルの末尾に居て、コメントもそう書いていたが、道具の中だけで
/// 既に ``WatchSession``・``Facets``・``APIListLocator`` の 3 人が使っている。**ここが
/// 自分のファイルを持つのは、その事実を置き場に出したもの**である。ライブラリ側と 1 本に
/// するか (`MokumeCore` から `public` で出すか) の判断は
/// [#814](https://github.com/mokume-metal/mokume/issues/814) に残っている — そちらは
/// 失敗の扱いを揃える話 (投げる / 黙って捨てる / 名乗る の 3 通りがある) と同じ 1 手に
/// なるので、切り離して先に決めない。
enum AtomicWrite {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp", isDirectory: false)
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
