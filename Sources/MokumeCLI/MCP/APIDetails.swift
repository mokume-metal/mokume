// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 公開 API の口ごとの説明と例 (Release の資産 `mokume-api-details-v<版>.json`)。
///
/// 索引 (`mokume-api-v<版>.md`) は宣言と型の説明の 1 行目だけを持ち、口の説明の全文はこちらが持つ
/// (ADR-0027 決定 1 の 2026-10-31 の改訂・#3420)。**形の正典は `Schemas/api-details.schema.json`** で、
/// ここは読む側の写し。説明は `///` の全文のまま載っていて、要約も書き直しもしない。
struct APIDetails: Equatable {
    /// 読める形の版。正典は `Schemas/api-details.schema.json` の `schemaVersion`。
    static let schemaVersion = 1

    /// 資産が組まれた版の綴り (`v0.38.0`・組み立てが版の外なら `(開発版)`)。
    let version: String
    /// 基底名 (引数部を落とした名前) ごとの、持ち主・宣言・説明の並び。並びは資産に書かれたまま。
    let symbols: [String: [Entry]]

    struct Entry: Equatable, Decodable {
        /// 口の持ち主の型。型そのものと最上位の宣言は空。
        let owner: String
        let declaration: String
        /// 説明の全文。無ければ空。
        let doc: String
    }

    /// 読めなかったとき。
    struct Failure: Error, Equatable {
        let reason: String
    }

    /// 資産のバイト列を読む。
    ///
    /// **形を読む前に `schemaVersion` だけを見る。** 新しい版は形そのものが変わっていることがあり、
    /// 全体を先に読むと「詳細ファイルではない」と言ってしまい、道具を上げれば読めることが伝わらない。
    static func parse(_ data: Data) -> Result<APIDetails, Failure> {
        struct Header: Decodable { let schemaVersion: Int }
        struct Wire: Decodable {
            let version: String
            let symbols: [String: [Entry]]
        }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            return .failure(Failure(reason: "it is not a details file (\(error.localizedDescription))"))
        }
        guard header.schemaVersion == schemaVersion else {
            // 依存の版が出した資産のほうが新しい形のときがある。道具を上げれば読める
            return .failure(
                Failure(
                    reason: """
                        it is in format \(header.schemaVersion), and this tool reads format \(schemaVersion) \
                        (update the tool to read it)
                        """))
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            return .success(APIDetails(version: wire.version, symbols: wire.symbols))
        } catch {
            return .failure(Failure(reason: "it is not a details file (\(error.localizedDescription))"))
        }
    }

    /// 頼まれた名前に合う口。
    enum Lookup: Equatable {
        /// 合った口 (資産の並びのまま。空ではない)
        case found([Entry])
        /// 名前が無い。`candidates` は、入れ子の型の case など `.` を含む名前で、後ろが一致するもの
        case unknown(candidates: [String])
        /// 基底名はあるが、頼んだ型 `type` に持ち主が無い。`owners` はその基底名を持つ型 (重複なし・並びは資産のまま。
        /// 型を持たない最上位の宣言は空の綴り)。`candidates` は `unknown` と同じ
        case notOnOwner(type: String, base: String, owners: [String], candidates: [String])
    }

    /// `symbol` で口を引く。
    ///
    /// 照合は**基底名** (宣言の名前の最初の `(` より前) で行い、`ambientLight` も `ambientLight(_:)` も
    /// 同じ口を指す。`型.基底名` (`SoundFile.play`) と書けば、その型が持ち主の口だけに絞る。
    /// 列挙の case や入れ子の型の名前は、キーそのものが `.` を含む (`ArcMode.pie`) ので、
    /// **先に全体を基底名として引き**、合わなければ最初の `.` で型と基底名に分ける。
    /// 空の並びは「無い」と同じに扱う (スキーマは 1 つ以上と決めている)。
    func lookup(_ symbol: String) -> Lookup {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = Self.baseName(trimmed)
        if let entries = symbols[whole], !entries.isEmpty { return .found(entries) }
        let candidates = candidates(for: whole)
        guard let dot = trimmed.firstIndex(of: ".") else { return .unknown(candidates: candidates) }
        let type = String(trimmed[..<dot])
        let base = Self.baseName(String(trimmed[trimmed.index(after: dot)...]))
        guard !type.isEmpty, let entries = symbols[base], !entries.isEmpty else {
            return .unknown(candidates: candidates)
        }
        let narrowed = entries.filter { $0.owner == type }
        if !narrowed.isEmpty { return .found(narrowed) }
        var owners: [String] = []
        for entry in entries where !owners.contains(entry.owner) { owners.append(entry.owner) }
        return .notOnOwner(type: type, base: base, owners: owners, candidates: candidates)
    }

    /// 名前の後ろが一致する、`.` を含むキー (`pie` や `Projection.perspective` に対する `Camera.Projection.perspective`)。
    /// 引けたことにはしない — 綴りを案内するだけ。多すぎる分は切る。
    private func candidates(for name: String) -> [String] {
        guard !name.isEmpty else { return [] }
        let matches = symbols.compactMap { key, entries -> String? in
            key.contains(".") && !entries.isEmpty && key.hasSuffix("." + name) ? key : nil
        }
        return Array(matches.sorted().prefix(Self.candidateLimit))
    }

    static let candidateLimit = 8

    /// 型 `type` の項を返すときに添える、辿り先。`init` と、`型.` で始まるキー (列挙の case・入れ子の型)。
    struct Members: Equatable {
        /// その型に `init` の項があるか
        let hasInit: Bool
        /// `型.` で始まるキー (並びは綴りの順・切った残りの数は `omitted`)
        let keys: [String]
        let omitted: Int

        var isEmpty: Bool { !hasInit && keys.isEmpty }
    }

    func members(of type: String) -> Members {
        let hasInit = symbols["init"]?.contains { $0.owner == type } ?? false
        let all = symbols.compactMap { key, entries -> String? in
            key.hasPrefix(type + ".") && !entries.isEmpty ? key : nil
        }.sorted()
        let shown = Array(all.prefix(Self.memberLimit))
        return Members(hasInit: hasInit, keys: shown, omitted: all.count - shown.count)
    }

    static let memberLimit = 12

    /// 引数部を落とした名前。
    static func baseName(_ name: String) -> String {
        String(name.prefix { $0 != "(" })
    }
}
