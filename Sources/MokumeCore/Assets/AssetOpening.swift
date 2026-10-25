// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 名前が解けた場所を、資材として開けるかを確かめる ([#2358])。
///
/// **開けないことを、中身の形式や破損と名乗らない。** 画像・モデル・音・動画・断片の読み手は、
/// 渡された場所を道具立て (ImageIO・Model I/O・AVFoundation) に開かせる。道具立ては開けなかった
/// 事情を返さないか、形式の誤りと同じ形で返すので、そのままでは、ディレクトリや読む権利の無い
/// ファイルが「画像として読めない」「壊れている」と名乗られる。読み手は中身に触れる前にここを
/// 通し、開けなければ各型の `unopenable` を投げる (文字のファイルの
/// ``DataFailure/unopenable(path:location:reason:)`` と同じ形・#2341)。
///
/// 隔離の外で走れる形にしてあるのは、待たない読み込みが読む仕事を別の仕事として回すため。
///
/// [#2358]: https://github.com/mokume-metal/mokume/issues/2358
package nonisolated enum AssetOpening {
    /// 開けなかった場所と事情。
    package struct Refusal: Equatable, Sendable {
        /// 名前が解けた場所 (`..` を畳んだもの)。
        package var location: String
        /// OS が名乗った開けなかった事情 (`Is a directory`・`Permission denied` など)。
        package var reason: String
    }

    /// `url` を読むために開けるかを確かめる。開ければ `nil`、開けなければ場所と事情を返す。
    ///
    /// **中身は読まない。** 開いて (`open(2)`)、開けたものがディレクトリかだけを見る
    /// (ディレクトリは開けても読めない)。名前付きのパイプで書き手を待たないよう、待たずに開く。
    /// 事情の文面は ``Diagnostics/posixReason(_:)`` で引く。
    package static func refusal(at url: URL) -> Refusal? {
        let location = url.standardizedFileURL.path
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return Refusal(location: location, reason: Diagnostics.posixReason(errno))
        }
        defer { close(descriptor) }
        var status = stat()
        if fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR {
            return Refusal(location: location, reason: Diagnostics.posixReason(EISDIR))
        }
        return nil
    }

    /// 在るかを確かめられない場所の、事情の頭に置く句。``notice(path:location:reason:)`` はこの句で、
    /// 「見つかった」と言い切らない文面へ切り替える ([#2838])。
    ///
    /// 資材の失敗の型の `unopenable` は、`reason` に句を足す形で、この場合も運ぶ。関連値を足すと、
    /// 利用者の `case .unopenable(let path, let location, let reason)` の枝がすべて壊れる。
    ///
    /// [#2838]: https://github.com/mokume-metal/mokume/issues/2838
    package static let unreachablePhrase = "cannot tell whether it exists"

    /// OS の事情に、在るかを確かめられない句を足す (``AssetFailure/unreachable(path:location:reason:)`` を
    /// 資材の失敗の型の `unopenable` へ写すときに使う)。
    package static func unreachableReason(_ reason: String) -> String {
        "\(unreachablePhrase) (\(reason))"
    }

    /// 開けなかったことの説明。資材の失敗の型の `unopenable` が、どれもこの文面で名乗る。
    ///
    /// **形式・破損・資源宣言の助言を添えない** — 直すのは `location` にあるものの置き場か権利で
    /// ある。相対の名前は複数の場所を探して解く (``SketchPart/assetURL(_:)``) ので、渡した名前
    /// だけでは直す先が分からない。解けた場所を名乗る (名前と同じなら省く)。
    ///
    /// **開こうとして断られた場合 (ディレクトリ・ファイル自身の権利) だけが「見つかった」と言う。**
    /// 事情が ``unreachablePhrase`` で始まるときは、場所に入れず在るかを確かめられなかったので、
    /// 「見つかった」とは言わない。
    package static func notice(path: String, location: String, reason: String) -> String {
        if reason.hasPrefix(unreachablePhrase) {
            return location == path
                ? "\"\(path)\" cannot be reached: \(reason)"
                : "\"\(path)\" cannot be reached at \"\(location)\": \(reason)"
        }
        return location == path
            ? "\"\(path)\" was found but cannot be opened: \(reason)"
            : "\"\(path)\" was found at \"\(location)\" but cannot be opened: \(reason)"
    }
}
