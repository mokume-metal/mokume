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
    /// 生成するスケッチが依存する版。
    ///
    /// **上限を切って書く。** 1.0 未満では次のマイナーで形が変わりうるので、上限の
    /// 無い書き方だと、作った時点では動いていたものが後から壊れた組み合わせを引く。
    /// 版が上がったらここを更新する必要がある — 忘れても機械が拾えない — #214 で扱う。
    static let libraryVersion = "0.1.0"

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
