// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 「そこにディレクトリが在るか」の判定。
///
/// **道具の中ではここ 1 箇所。** 区画が在るか (``Facets/hasFacet(_:)``)・面の仕様の置き場が
/// 在るか (``SchemasLocator/directory(workDirectory:executable:)``)・一覧に並べる区画が在るか
/// (``StartupReadsReport/document(base:given:package:)``) は、同じ 3 行を別々に書いていた。
/// **同じであることを文章で約束していた** — `hasFacet` のコメントは「判定は
/// `FrameObserver.makeIfEnabled` と同じ形にする」と書いており、約束を守る機械は居なかった
/// ([#814](https://github.com/mokume-metal/mokume/issues/814))。
///
/// **ライブラリの側にはまだ 4 箇所ある** (`FrameObserver` / `InputInbox` / `ParamSurface` /
/// `SharedFrameSurface`)。あちらと 1 本にするには `WorkDirectory` へ `public` で置くことに
/// なり、その判断は #814 に残っている。ここでは**道具の側が増えないこと**だけを保つ。
enum DirectoryPresence {
    /// その場所がディレクトリとして在るか。
    ///
    /// **ファイルが在るだけでは真にしない。** 区画は必ずディレクトリなので、同じ名前の
    /// ファイルを「在る」と読むと、要求を置けないまま待ちに入ることになる。
    static func exists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
