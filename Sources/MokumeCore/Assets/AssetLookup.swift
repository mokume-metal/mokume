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
/// 原因に辿り着けない。作業ディレクトリが候補の先頭なので、そこに入れないと、後ろの束の資源に本物が
/// あっても採らずに名乗る (メンテナの決定・#2838)。
///
/// **CLI が #2314 で `ENOENT` のときだけ「無い」と言う線引き (`GivenPath.Presence`) とは、2 点違う。**
/// 1. `ENOTDIR` (途中が普通のファイル) を「無い」と数える。CLI は在る場所を探す (起点の作業ディレクトリ
///    などを 1 つ指す) ので辿り着けないと読むが、ここは候補を並べて探す。`assets/data.csv` の `assets` が
///    普通のファイルなら、そこに資材は在り得ず、次の候補を探すのが自然である
/// 2. 途中の段にある宛先の無い symlink も辿り着けないと読む (CLI は最後の段だけ)。`ENOENT` のとき、
///    候補の親を上から `lstat` して調べる (``presence(of:)``)
///
/// 包みの置き場を数えられない (``Search/unlistable``) ときも、在るかを確かめられない: どこにも無かった
/// ときに、数えられなかった置き場を名乗る。
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

    /// 探す場所の並びと、**包みを数えられなかった置き場**。
    package struct Search: Equatable, Sendable {
        /// 候補の場所を、探す順に並べたもの。
        package var places: [URL]
        /// 包みの置き場のうち、数えられなかったもの。
        package var unlistable: [Unlistable] = []
    }

    /// 包みを数えられなかった置き場 (読む権利が無いなど)。そこに在るはずの包みの候補は落ちている。
    package struct Unlistable: Equatable, Sendable {
        package var root: URL
        /// OS が名乗った事情。
        package var reason: String
    }

    /// 候補 1 つを `stat(2)` で見て、`errno` で分ける。
    package static func presence(of url: URL) -> Presence {
        var info = stat()
        guard stat(url.path, &info) != 0 else { return .present }
        let code = errno
        switch code {
        case ENOENT:
            // 名前は在るのに辿ると無い — 宛先の無い symlink は「無い」と数えない。**途中の段**の
            // symlink (`assets` が外したドライブへの symlink など) は、最後の段の `stat` も `lstat` も
            // `ENOENT` になるので、上から段ごとに `lstat` して見つける
            if let link = danglingLink(on: url) {
                return .unreachable(
                    reason: "a symbolic link (\(link)) on the way points to something that is not there")
            }
            return .absent
        case ENOTDIR:
            return .absent
        default:
            return .unreachable(reason: Diagnostics.posixReason(code))
        }
    }

    /// 候補の道のうち、宛先の無い symlink である段 (最初のもの)。無ければ `nil`。
    private static func danglingLink(on url: URL) -> String? {
        var current = ""
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current += "/" + component
            var followed = stat()
            if stat(current, &followed) == 0 { continue }
            var link = stat()
            return lstat(current, &link) == 0 ? current : nil
        }
        return nil
    }

    /// 候補を順に見て、最初に在るものを返す。
    ///
    /// - Parameter unlistable: 包みを数えられなかった置き場。**どこにも無かったときだけ**効く — 先に
    ///   在るものが見つかれば、それを採る。
    /// - Throws: 全部無ければ ``AssetFailure/notFound(path:searched:)`` (数えられなかった置き場があれば、
    ///   代わりに ``AssetFailure/unreachable(path:location:reason:)``)。確かめられない候補に当たったら、
    ///   そこで止めて ``AssetFailure/unreachable(path:location:reason:)``。
    package static func locate(
        _ candidates: [URL], unlistable: [Unlistable] = [], path: String
    ) throws(AssetFailure) -> URL {
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
        if let hidden = unlistable.first {
            // 包みの中に在るかもしれないものを、無いとは言わない
            throw .unreachable(
                path: path, location: hidden.root.standardizedFileURL.path,
                reason: "the folder that may hold bundled resources cannot be listed: \(hidden.reason)")
        }
        throw .notFound(path: path, searched: candidates.map(\.path))
    }

    /// ``Search`` を受けて探す。
    package static func locate(_ search: Search, path: String) throws(AssetFailure) -> URL {
        try locate(search.places, unlistable: search.unlistable, path: path)
    }
}
