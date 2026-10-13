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
    static func directory() throws(CommandFailure) -> URL {
        guard let url = Bundle.module.url(forResource: "Templates", withExtension: nil) else {
            throw CommandFailure.templatesMissing
        }
        return url
    }

    /// テンプレートを読み、差し込みを済ませた中身を返す。
    static func render(_ name: String, _ values: [String: String]) throws(
        CommandFailure
    ) -> String {
        let url = try directory().appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CommandFailure.templateUnreadable(name: name)
        }
        return substitute(text, values)
    }

    /// `{{鍵}}` を置き換える。
    ///
    /// **テンプレートを 1 回だけ走査する。** 値を 1 つずつ順に置換すると、差し込んだ値の中の
    /// `{{鍵}}` が後から差し込む鍵に置き換えられ、結果が `Dictionary` の並びで変わる
    /// ([#2489](https://github.com/mokume-metal/mokume/issues/2489))。差し込んだ値は打たれた
    /// とおりに出る。
    ///
    /// **置き換え残しは失敗にしない** — テンプレートに新しい鍵を足したときに気付ける
    /// よう、値の無い鍵はそのまま出力に現れる (検査が見つける)。
    static func substitute(_ text: String, _ values: [String: String]) -> String {
        var output = ""
        var rest = text[...]
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            if let close = afterOpen.range(of: "}}"),
                let value = values[String(afterOpen[..<close.lowerBound])]
            {
                output += value
                rest = afterOpen[close.upperBound...]
            } else {
                // 鍵でない `{{`。**1 文字だけ進む** — `{{{A}}}` の 2 つ目からの `{{A}}` を見落とさない
                output += "{"
                rest = rest[rest.index(after: open.lowerBound)...]
            }
        }
        return output + rest
    }
}
