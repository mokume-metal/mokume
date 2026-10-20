// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 資材の名前から並べた候補の場所を順に見て、在るものを採る ([#2838])。
///
/// **「見つからない」と言うのは、本当に無いときだけ。** 候補を `FileManager.fileExists(atPath:)` で
/// 見ていた頃は、親のディレクトリに検索の権利が無いと `stat(2)` が `EACCES` で失敗して `false` が
/// 返り、**置いてあるファイルまで「見つからない」になって、資源の宣言を確かめよという的外れな
/// 助言が出た**。入れない親の下では、在るファイルと無いファイルの区別が付かない (実測)。
///
/// だから `stat(2)` の `errno` で分ける。**「無い」と数えるのは `ENOENT` と `ENOTDIR` (途中が
/// ディレクトリでなく、そこに在り得ない) だけ**で、次の候補へ進む。それ以外 (`EACCES`・`ELOOP`
/// ほか) と、宛先の無い symlink は「在るかもしれない場所」なので、**そこで探すのを止め**、その場所と
/// OS の事情を名乗る。後ろの候補に本物があっても採らない — 入れない場所を黙って飛ばすと、作者は
/// 原因に辿り着けない。CLI が #2314 で `ENOENT` のときだけ「無い」と言うのと同じ線引きである
/// (`GivenPath.Presence`)。
///
/// 資材を探す口 4 か所 (``SketchPart/assetURL(_:)``・画像・モデル・断片) が写しを持っていたので、
/// 判定をここに 1 つにした。割れると、同じ置き方が口によって「無い」と「入れない」に分かれる。
///
/// [#2838]: https://github.com/mokume-metal/mokume/issues/2838
package nonisolated enum AssetLookup {
    /// 候補 1 つの在り方。
    package enum Presence: Equatable, Sendable {
        /// 在る (`stat(2)` が通る。symlink は辿る)。
        case present
        /// 無い。
        case absent
        /// 在るかを確かめられない。`reason` は OS が名乗った事情。
        case unreachable(reason: String)
    }

    /// 候補 1 つを `stat(2)` で見て、`errno` で分ける。
    package static func presence(of url: URL) -> Presence {
        var info = stat()
        guard stat(url.path, &info) != 0 else { return .present }
        let code = errno
        switch code {
        case ENOENT:
            // 名前は在るのに辿ると無い — 宛先の無い symlink は「無い」と数えない
            var link = stat()
            return lstat(url.path, &link) == 0
                ? .unreachable(reason: "a symbolic link to something that is not there")
                : .absent
        case ENOTDIR:
            return .absent
        default:
            return .unreachable(reason: Diagnostics.posixReason(code))
        }
    }

    /// 候補を順に見て、最初に在るものを返す。
    ///
    /// - Throws: 全部無ければ ``AssetFailure/notFound(path:searched:)``。確かめられない候補に当たったら、
    ///   そこで止めて ``AssetFailure/unreachable(path:location:reason:)``。
    package static func locate(_ candidates: [URL], path: String) throws(AssetFailure) -> URL {
        for candidate in candidates {
            switch presence(of: candidate) {
            case .present:
                return candidate
            case .absent:
                continue
            case .unreachable(let reason):
                throw .unreachable(
                    path: path, location: candidate.standardizedFileURL.path, reason: reason)
            }
        }
        throw .notFound(path: path, searched: candidates.map(\.path))
    }
}
