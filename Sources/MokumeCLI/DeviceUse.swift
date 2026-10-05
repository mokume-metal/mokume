// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// スケッチが、許可の要る機材 (カメラ・マイク) を使っているかを見る。
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
/// - スケッチ自身の `Sources/` の外 (依存パッケージの中で機材を使うもの)
/// - 別名や変数を介した呼び出し
///
/// 見落としたときは今までと同じで、使うなら文言を書く (文書に書いてある)。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated enum DeviceUse {
    /// 文言が無いのにカメラかマイクを使っていれば投げる。両方欠けていれば、カメラから言う。
    static func check(in root: URL, identity: AppIdentity) throws(CommandFailure) {
        let path = root.appendingPathComponent(AppIdentity.fileName).path
        if identity.cameraUsage == nil {
            let users = cameraUsers(in: root)
            if !users.isEmpty { throw .cameraUsageMissing(path: path, files: users) }
        }
        if identity.microphoneUsage == nil {
            let users = microphoneUsers(in: root)
            if !users.isEmpty { throw .microphoneUsageMissing(path: path, files: users) }
        }
    }

    /// カメラを開く呼び出しを持つ Swift ファイル (スケッチからの相対・並べ替え済み)。
    static func cameraUsers(in root: URL) -> [String] {
        users(in: root, matching: opensCamera)
    }

    /// マイクを開く呼び出しを持つ Swift ファイル (スケッチからの相対・並べ替え済み)。
    static func microphoneUsers(in root: URL) -> [String] {
        users(in: root, matching: opensMicrophone)
    }

    private static func users(in root: URL, matching opens: (String) -> Bool) -> [String] {
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        guard let walker = FileManager.default.enumerator(atPath: sources.path) else { return [] }

        var found: [String] = []
        for case let relative as String in walker {
            guard relative.hasSuffix(".swift"), !isHidden(relative) else { continue }
            let url = sources.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if opens(text) { found.append("Sources/\(relative)") }
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
        withoutComments(source).range(
            of: #"\bcreateCapture\s*\((?!\s*frames\s*:)"#, options: .regularExpression) != nil
    }

    /// 1 本のソースが、マイクを開くかどうか (検査から呼べる形)。
    ///
    /// **`createAudioIn(file:)` と `createAudioIn(samples:sampleRate:)` は数えない。** 手元の音を
    /// 解析するだけで、機材も許可も使わない (``opensCamera(_:)`` の `frames:` と同じ理由)。
    static func opensMicrophone(_ source: String) -> Bool {
        withoutComments(source).range(
            of: #"\bcreateAudioIn\s*\((?!\s*(file|samples)\s*:)"#, options: .regularExpression)
            != nil
    }

    /// 注釈を空白に置き換える。注釈の中の名前は数えない。
    private static func withoutComments(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/|//[^\n]*"#, with: " ", options: .regularExpression)
    }

    /// 隠れたファイル・ディレクトリの下 (エディタの退避など) は見ない。
    private static func isHidden(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
