// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 依存している mokume が、どの面を持つか。
///
/// ## なぜ読み手が突き合わせるのか
///
/// 面は版によって増えており (`observe` → `input` / `params`)、**古い版に無い面へ要求を
/// 置いても無応答になる**。無応答は [ADR-0018] 決定 3 が名指しした「相手が死んでいる」と
/// 区別が付かない。書き手が古ければ自分では名乗れない — 既に出た版は書き換えられないので、
/// 突き合わせるのは読み手の仕事になる (同 決定 6・[#647])。
///
/// ## 版と面の対応表を持たない
///
/// **依存の実体を読む。** 取ってきた世代の `Schemas/` がそのまま置かれているので、面が
/// 増えても道具側に足すものが無い (決定 6)。在処の解決は ``SchemasLocator`` が既に持って
/// いるものを使う — パスで指した依存も取ってきた依存も、あちらが同じ形で解く。
///
/// ## 道具自身の `Schemas/` へは落ちない
///
/// ``SchemasLocator/directory(workDirectory:executable:)`` は依存が見つからないとき**道具
/// 自身の**仕様へ落ちる (面の仕様を配るときはそれが正しい)。**面の有無をそれで見てはいけない**
/// — 依存が何であれ「全部持っている」と答えることになる。だからここは
/// ``SchemasLocator/resolvedPackage(workDirectory:)`` だけを見て、解決できなければ判定しない。
///
/// ## 規律
///
/// **断定できないときは断定しない。** 判定できなければ「持たない」ではなく `nil` を返す。
/// 誤った断定は正しい原因から人を遠ざけるので、沈黙より悪い (`DoctorCommand` の規律 3)。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [#647]: https://github.com/mokume-metal/mokume/issues/647
enum DependencyFacets {
    /// 面の仕様の名前 (``SchemasLocator/names(in:)`` が返す綴り)。
    ///
    /// **綴りを組み立てない。** 面はみな `<key>-report` だと思って組み立てていたが、
    /// 一方通行の面 (`viewport`) は応答を持たないので当たらない — 実在しない名前を
    /// 探すと、その面はどの版でも「持たない」と答えることになる (#703)。名乗るのは
    /// 一覧の側である。
    static func schemaName(for entry: StartupReads.Entry) -> String { entry.schemaName }

    /// v0.1.0 から在る面。**そこが本当に仕様の置き場かを確かめる錨**にする。
    static let anchor = StartupReads.observe

    /// 依存が持たない面。判定できなければ `nil`。
    static func absent(forPackageAt package: URL) -> [StartupReads.Entry]? {
        guard let resolved = SchemasLocator.resolvedPackage(workDirectory: package) else {
            return nil
        }
        let root = resolved.appendingPathComponent("Schemas", isDirectory: true)
        let names = Set(SchemasLocator.names(in: root))
        // 錨が居ないなら、そこは仕様の置き場ではない (構造が変わった・まだ取ってきていない)。
        // 「面を 1 つも持たない」と答えるより、判定しないほうがよい
        guard names.contains(schemaName(for: anchor)) else { return nil }
        return StartupReads.all.filter {
            $0.origin == .facet && !names.contains(schemaName(for: $0))
        }
    }

    /// この面を、依存が持たないと言い切れるか。判定できなければ `nil`。
    static func lacks(_ entry: StartupReads.Entry, forPackageAt package: URL) -> Bool? {
        absent(forPackageAt: package).map { $0.contains(entry) }
    }
}
