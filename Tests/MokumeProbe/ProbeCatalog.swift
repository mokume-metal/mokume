// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 帰属の表 `Tests/probe-catalog.tsv` (#3207 の K2) の読み手。
///
/// 1 行が 1 つの suite で、列はタブ区切りの `suite の型名`・`提案の名`・`sub-issue の番号`。`#` で
/// 始まる行と空行は読まない。生成の仕組み (``Probe``) を使う suite は、ここに載っていなければ
/// 述語を回す前に赤になる。逆向き (表の行の suite が `Tests/` に無い) は `ProbeCatalogTests` が見る。
///
/// 表は木の中のテキストで、検査のプロセスはこのファイルの場所 (`#filePath`) から読む
/// (`SceneLedgerTests` の台帳と同じ読み方)。
public nonisolated enum ProbeCatalog {
    /// 表の 1 行。
    public struct Entry: Sendable, Equatable {
        public let suite: String
        public let name: String
        public let issue: Int
    }

    /// 表のファイルの場所。
    public static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("probe-catalog.tsv")

    /// 表の行。読めない・書式が崩れた行があれば理由を投げる。
    public static func entries(text: String? = nil) throws -> [Entry] {
        let body = try text ?? String(contentsOf: url, encoding: .utf8)
        var out: [Entry] = []
        for (number, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 3, !columns[0].isEmpty, !columns[1].isEmpty, let issue = Int(columns[2])
            else {
                throw CatalogError(message: "\(url.lastPathComponent) の \(number + 1) 行目が `suite<TAB>提案の名<TAB>番号` でない: \(line)")
            }
            out.append(Entry(suite: columns[0], name: columns[1], issue: issue))
        }
        return out
    }

    /// `suite` が `name` の提案として表に載っていなければ、その理由。載っていれば `nil`。
    static func missing(suite: String, name: String) -> String? {
        let rows: [Entry]
        do { rows = try entries() } catch { return "帰属の表を読めない: \(error)" }
        guard let row = rows.first(where: { $0.suite == suite }) else {
            return "\(suite) が \(url.lastPathComponent) に無い (生成の仕組みを使う suite は表に 1 行足す・#3207 の K2)"
        }
        guard row.name == name else {
            return "\(suite) は表では提案 \(row.name) だが、\(name) の名で呼んでいる"
        }
        return nil
    }

    struct CatalogError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
