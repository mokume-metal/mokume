// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// スケッチが、許可の要る機材 (カメラ) を使っているかを見る。
///
/// ## なぜ束ねる前に止めるのか
///
/// 文言を書かずにカメラへ触れる包みは、**触れた時点で OS に止められる**。作った手元では
/// 端末のアプリに付いた許可で動くので気付けず、配った先でだけ、ダイアログも出ずに止まる
/// ([ADR-0042] 決定 8 の「破れたとき」)。
///
/// ## ADR-0029 の「ソースを走査して推測しない」とどう折り合うか
///
/// あちらが避けているのは、**何を入れるかを走査で決める**こと — 外すと黙って欠ける。
/// ここで入れるものを決めるのは作者が書いた宣言 (``AppIdentity``) のままで、走査が決める
/// のは**宣言を求めるか**だけである。外しても今までと同じ状態に戻るだけで、悪くはならない。
/// 当たったときだけ止め、直し方 (足す 1 行) を見せる — ``ResourceDeclaration`` が資材に
/// していることと同じ形で、**判定は呼び出しの有無だけ**を見る。
///
/// ## 見ないもの
///
/// - スケッチ自身の `Sources/` の外 (依存パッケージの中でカメラを使うもの)
/// - 別名や変数を介した呼び出し
///
/// 見落としたときは今までと同じで、使うなら文言を書く (文書に書いてある)。
///
/// マイクは**まだ見ない** — 使う口が無い ([#1978])。口を足す変更が、ここへ足す。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
/// [#1978]: https://github.com/mokume-metal/mokume/issues/1978
nonisolated enum DeviceUse {
    /// 文言が無いのにカメラを使っていれば投げる。
    static func check(in root: URL, identity: AppIdentity) throws(CommandFailure) {
        guard identity.cameraUsage == nil else { return }
        let users = cameraUsers(in: root)
        guard !users.isEmpty else { return }
        throw .cameraUsageMissing(
            path: root.appendingPathComponent(AppIdentity.fileName).path, files: users)
    }

    /// カメラを開く呼び出しを持つ Swift ファイル (スケッチからの相対・並べ替え済み)。
    static func cameraUsers(in root: URL) -> [String] {
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        guard let walker = FileManager.default.enumerator(atPath: sources.path) else { return [] }

        var found: [String] = []
        for case let relative as String in walker {
            guard relative.hasSuffix(".swift"), !isHidden(relative) else { continue }
            let url = sources.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if opensCamera(text) { found.append("Sources/\(relative)") }
        }
        return found.sorted()
    }

    /// 1 本のソースが、カメラを開くかどうか (検査から呼べる形)。
    ///
    /// **`createCapture(frames:)` は数えない。** 記録した絵を流すだけで、機材も許可も使わない
    /// ([ADR-0042] 決定 4 の「差し替えた先では許可を要求しない」)。数えると、機材に触れない
    /// 作品に、使わない許可の文言を書かせることになる。注釈の中の名前も数えない。
    ///
    /// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
    static func opensCamera(_ source: String) -> Bool {
        let code = source.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/|//[^\n]*"#, with: " ", options: .regularExpression)
        return code.range(
            of: #"\bcreateCapture\s*\((?!\s*frames\s*:)"#, options: .regularExpression) != nil
    }

    /// 隠れたファイル・ディレクトリの下 (エディタの退避など) は見ない。
    private static func isHidden(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
