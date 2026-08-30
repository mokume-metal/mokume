// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 束ねた作品の名乗り — 表示名・識別子・版。
///
/// ## なぜ作品の設定と分けて持つのか
///
/// 名乗りは**作品の振る舞いとは変更の理由も頻度も違う**。絵は毎日変わるが、名乗りは
/// 配る相手が決まったときに 1 度決まってほとんど動かない。同じ場所に置くと、片方を
/// 触るたびにもう片方を読み直すことになる ([ADR-0029] 決定 4)。
///
/// ## なぜひな形に同梱しないのか
///
/// **書かなくても動くが、書かないまま配ると事故になる**、という性質のものだからである。
/// とくに識別子は**権限の許可がぶら下がる鍵**で、仮の値のまま配ると許可の状態が別の
/// 作品と混ざる。ひな形に置けば全員が同じ仮の値を持つので、**置かないほうが安全側**に
/// なる。代わりに、束ねようとした時点で無いことを言う。
///
/// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
/// **どこからでも読める** (`nonisolated`)。書き方の見本は失敗の側にも書かれており
/// ([CommandFailure])、そちらは隔離を持たないため。
nonisolated struct AppIdentity: Equatable {
    /// 表示名。包みの名前と、メニューに出る名前になる。
    var name: String
    /// 識別子。**権限の許可がぶら下がる鍵**なので、作品ごとに違うものにする。
    var identifier: String
    /// 版。
    var version: String

    /// 置き場。スケッチの直下。
    static let fileName = "mokume-app.json"

    /// 書き方の見本。**止めるときは必ずこれを見せる** — 「何か足りない」だけでは、
    /// 読んだ人が次に何をすればよいか決められない。
    static let example = """
        {
          "name": "Grain",
          "identifier": "org.example.grain",
          "version": "0.1.0"
        }
        """

    /// スケッチの直下から読む。
    static func read(in root: URL) throws(CommandFailure) -> AppIdentity {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            throw .identityMissing(path: url.path)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .identityUnreadable(path: url.path)
        }
        return try make(from: object, path: url.path)
    }

    /// 読んだ中身から組み立てる。
    ///
    /// **空白だけの値は書かれていないものとして扱う。** 鍵があることではなく、名乗れる
    /// 中身があることを見る。
    static func make(from object: [String: Any], path: String) throws(CommandFailure) -> AppIdentity
    {
        var missing: [String] = []
        var values: [String: String] = [:]
        for key in ["name", "identifier", "version"] {
            let value = (object[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                missing.append(key)
            } else {
                values[key] = value
            }
        }
        guard missing.isEmpty else {
            throw .identityIncomplete(path: path, missing: missing)
        }
        return AppIdentity(
            name: values["name"]!, identifier: values["identifier"]!, version: values["version"]!)
    }

    /// 包みが名乗るための一覧。
    ///
    /// **最低限の対しか置かない。** 用途文言 (権限の説明) はここに並べたくなるが、許可を
    /// 要る受け口がまだ無いので、いま置くと想定だけの面になる ([ADR-0001] 原則 4)。
    /// 受け口ができた日に、同じファイルへ足す。
    ///
    /// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
    func infoPlist(executable: String, minimumSystemVersion: String) -> [String: Any] {
        [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": minimumSystemVersion,
            // 画面の密度に合わせて描く。これが無いと、細かい画面で引き伸ばされた絵になる
            "NSHighResolutionCapable": true,
        ]
    }
}
