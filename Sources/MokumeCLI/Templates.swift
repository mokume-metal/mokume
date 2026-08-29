// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// スケッチ一式のひな形。
///
/// テンプレートはソースとして持ち (`Templates/`)、実体は作るときに組み立てる。
/// 生成物をリポジトリに置かない ([ADR-0001] 原則 8) のと同じ理由で、出来上がりを
/// どこかに保存しておくことはしない。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
enum Templates {
    /// 生成するスケッチが依存する版の**下限**。
    ///
    /// **現行版ではない。古いままでよい。** `from:` は次の major 未満を許すので、
    /// この値が何世代か古くても、生成されたスケッチが解決するのは常に最新の 0.x に
    /// なる。だから「版が上がったらここを更新する」を誰にも覚えさせなくてよい。
    ///
    /// **上限を切らない** ([#214])。上限を切ると、この値が古くなった時点で新しく作った
    /// スケッチが古い 0.x に固定され、**壊れないまま腐る** — 誰も気付かない類の腐り方を
    /// する。上限が守れるのは新しく作るスケッチだけで、そこで引くべきものはむしろ最新の
    /// 0.x である (ひな形の `Sketch.swift` は現行の面で書かれている)。既に作られた
    /// スケッチは `Package.resolved` が固定するので、後から勝手に版が動くことはない
    /// (生成する `.gitignore` は `Package.resolved` を除外しない)。
    ///
    /// [#214]: https://github.com/mokume-metal/mokume/issues/214
    static let libraryMinimumVersion = "0.1.0"

    /// テンプレートの置き場。
    static func directory() throws -> URL {
        guard let url = Bundle.module.url(forResource: "Templates", withExtension: nil) else {
            throw CommandFailure.templatesMissing
        }
        return url
    }

    /// テンプレートを読み、差し込みを済ませた中身を返す。
    static func render(_ name: String, _ values: [String: String]) throws -> String {
        let url = try directory().appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CommandFailure.templateUnreadable(name: name)
        }
        return substitute(text, values)
    }

    /// `{{鍵}}` を置き換える。
    ///
    /// **置き換え残しは失敗にしない** — テンプレートに新しい鍵を足したときに気付ける
    /// よう、残った鍵はそのまま出力に現れる (検査が見つける)。
    static func substitute(_ text: String, _ values: [String: String]) -> String {
        values.reduce(text) { partial, entry in
            partial.replacingOccurrences(of: "{{\(entry.key)}}", with: entry.value)
        }
    }
}
