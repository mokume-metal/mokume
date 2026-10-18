// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
    package static func refusal(at url: URL) -> Refusal? {
        let location = url.standardizedFileURL.path
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return Refusal(location: location, reason: reason(errno: errno))
        }
        defer { close(descriptor) }
        var status = stat()
        if fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR {
            return Refusal(location: location, reason: reason(errno: EISDIR))
        }
        return nil
    }

    /// POSIX の失敗の番号を、人が読む短い句にする。引けなければ `error <番号>`。
    ///
    /// **C の文面 (`strerror_r`) で引く。** Foundation の説明は言語の設定に左右されうるが、道具が
    /// 話す言葉は英語で、設定で切り替えない ([ADR-0038] 決定 1・2)。`strerror` ではなく
    /// `strerror_r` なのは、待たない口が別の thread で読むため。
    ///
    /// [ADR-0038]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0038-language-of-the-tool.md
    package static func reason(errno code: Int32) -> String {
        text(errno: code) ?? "error \(code)"
    }

    /// POSIX の失敗の番号の C の文面。引けなければ `nil`。
    package static func text(errno code: Int32) -> String? {
        var text = [CChar](repeating: 0, count: 256)
        guard strerror_r(code, &text, text.count) == 0 else { return nil }
        return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// 開けなかったことの説明。資材の失敗の型の `unopenable` が、どれもこの文面で名乗る。
    ///
    /// **形式・破損・資源宣言の助言を添えない** — 直すのは `location` にあるものの置き場か権利で
    /// ある。相対の名前は複数の場所を探して解く (``SketchPart/assetURL(_:)``) ので、渡した名前
    /// だけでは直す先が分からない。解けた場所を名乗る (名前と同じなら省く)。
    package static func notice(path: String, location: String, reason: String) -> String {
        location == path
            ? "\"\(path)\" was found but cannot be opened: \(reason)"
            : "\"\(path)\" was found at \"\(location)\" but cannot be opened: \(reason)"
    }
}
