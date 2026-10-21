// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 要求の中の、読み手が読まない鍵を数えて名乗る口。
///
/// **断らず、読まないだけにする** ([ADR-0018] 決定 3「知らないキーは無視する」。新しい書き手が足した
/// キーを古いスケッチが断らない)。ただし黙って捨てない — `sacle` や `buton` のような綴りの誤りが、
/// 警告なしの等倍・左クリックとして通る ([#2392], [#2843])。名乗りは応答の `warnings` に載せる。
///
/// `RequestFile` が規約を「区画によらず 1 か所で守る」と言うのに合わせ、観測の要求と入力の要求が
/// 同じ口を使う。**綴りの近さから鍵を推し量って読むことはしない** (`buton` を `button` として読まない)。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [#2392]: https://github.com/mokume-metal/mokume/issues/2392
/// [#2843]: https://github.com/mokume-metal/mokume/issues/2843
nonisolated enum UnknownKeys {
    /// 名乗る名前の数と、1 つあたりの長さの上限。書き手が置いた長さのまま応答へ返さない。
    static let namedKeyLimit = 5
    static let namedKeyLength = 32

    /// 鍵の全集合から、`Key` が持つ鍵を引いたもの (名前順)。オブジェクトでない値は解けずに throw する。
    static func names<Key: CodingKey & CaseIterable>(in decoder: any Decoder, known _: Key.Type)
        throws -> [String]
    {
        let known = Set(readKeys(Key.self))
        return try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
            .filter { !known.contains($0) }
            .sorted()
    }

    /// `Key` が読む鍵 (宣言順)。スキーマの `properties` と突き合わせる検査もここから引く。
    static func readKeys<Key: CodingKey & CaseIterable>(_ type: Key.Type) -> [String] {
        Key.allCases.map(\.stringValue)
    }

    /// 名乗る名前を、上限で切って並べる。
    static func named(_ keys: [String]) -> String {
        let shown = keys.prefix(namedKeyLimit).map { key in
            key.count > namedKeyLength ? "\(key.prefix(namedKeyLength))…" : key
        }
        let rest = keys.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    /// 読まなかった鍵を名乗る 1 行。`subject` は読まれなかったものを含む単位 (`request`・`event`)、
    /// `known` は読む鍵。名前が無ければ `nil`。
    static func warning(unknown: [String], in subject: String, known: [String]) -> String? {
        guard !unknown.isEmpty else { return nil }
        return "Not read, so the \(subject) was taken without them: \(named(unknown)) "
            + "(the keys read are \(known.joined(separator: ", ")))"
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
