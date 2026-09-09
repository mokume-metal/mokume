// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 起動の瞬間に決まるものを、読んだ人が使える文にする。
///
/// **並べるものの正典は `StartupReads`** で、ここが持つのは見せ方だけである。一覧に 1 行
/// 足せば、`watch` の名乗りも・応えないときの案内も・`reference` の文書も同時に増える —
/// 読む時点ごとに文面を書き足す形をやめるための置き方である (#380)。
enum StartupReadsReport {
    /// 走らせる側と読む側で**照らし合わせるための 1 行**。
    ///
    /// 区画の基準が食い違うと両者は別の区画を見るが、そのとき出る症状 (誰も応えない) は
    /// 「まだ起動していない」と見分けが付かない。**両方が同じ言葉でこれを名乗る**ことが、
    /// 割れに気付く唯一の手掛かりになる (#380 着手条件 2)。
    static func baseLine(base: URL, given: Bool) -> String {
        "\(StartupReads.workDirectory.name): \(base.path) (\(origin(given: given)))"
    }

    /// 基準を決めたものの言い方。
    static func origin(given: Bool) -> String {
        given
            ? "pointed at by \(StartupReads.workDirectory.key)"
            : "\(StartupReads.workDirectory.key) is unset — using the sketch's own directory"
    }

    /// 一覧そのもの。`reference` の文書として配り、`doctor` が端末へも出す。
    ///
    /// **いまの値と、決まり方の両方を出す。** 値だけでは何と比べればよいか分からず、
    /// 決まり方だけでは自分の環境がどちらなのか分からない。
    /// - Parameter package: スケッチのパッケージの場所。**区画の基準とは別の軸**で、渡されて
    ///   いれば依存している版が持たない面まで名乗れる。渡されなければその判定はしない
    ///   (`DependencyFacets` の規律 — 断定できないときは断定しない)。
    static func document(base: URL, given: Bool, package: URL? = nil) -> String {
        var lines = [
            "Decided the moment the process starts.",
            "**None of these take effect while the sketch is running** — restart it to apply a change.",
            "",
            "What is visible now:",
            "",
            "  \(baseLine(base: base, given: given))",
        ]
        // 依存が持たない面は、区画が在っても応答が来ない。**在る / 無いだけでは足りない**
        // (#647)。判定できなければ空のまま — 添えないことで「判定していない」を表す
        let absent = package.flatMap { DependencyFacets.absent(forPackageAt: $0) } ?? []
        // **持たないと言うなら、いくつなのかも言う。** 版が分からないと、読み手は
        // どこまで上げればよいかを知れない (#684)
        let version = package.flatMap { DependencyVersion.resolved(forPackageAt: $0) }
        for entry in StartupReads.all where entry.origin == .facet {
            // 区画の URL は ``WorkDirectory`` から出す。`.mokume` を綴り直すと、
            // 一覧が名乗る場所とスケッチが書く場所が黙って割れうる (#814)
            let facet = WorkDirectory.facet(entry.key, under: base)
            let presence = WorkDirectory.directoryExists(at: facet) ? "present" : "absent"
            var line = "  \(entry.name): \(facet.path) (\(presence))"
            if absent.contains(entry) {
                let named = version.map { "mokume \($0)" } ?? "the mokume you depend on"
                line += " — \(named) does not have this facet"
            }
            lines.append(line)
        }
        lines += ["", "All of them:", ""]
        for entry in StartupReads.all {
            lines.append("  \(entry.name) — \(source(entry)) / \(decider(entry))")
            lines.append("    \(entry.note)")
        }
        lines += [
            "",
            """
            The runner (`\(Command.name) watch`) names its "\(StartupReads.workDirectory.name)"
            as it starts. If that differs from the value here, the runner and the interface
            are **looking at different facets** — restarting alone does not fix it, so start
            both under the same \(StartupReads.workDirectory.key).
            """,
        ]
        return lines.joined(separator: "\n")
    }

    /// 何から読むか。
    private static func source(_ entry: StartupReads.Entry) -> String {
        switch entry.origin {
        case .environment: "environment variable \(entry.key)"
        // ここの `.mokume` は**人が読む文面**で、URL の組み立てではない
        case .facet: "whether the facet .mokume/\(entry.key) exists"
        }
    }

    /// 誰が決めるか。
    private static func decider(_ entry: StartupReads.Entry) -> String {
        switch entry.decidedBy {
        case .user: "you decide it"
        case .tool: "the tool passes it"
        }
    }
}
