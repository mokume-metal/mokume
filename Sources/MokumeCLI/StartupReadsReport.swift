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
            ? "\(StartupReads.workDirectory.key) が指している"
            : "\(StartupReads.workDirectory.key) は未設定 — スケッチの場所を使っている"
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
            "起動の瞬間に決まるもの。**どれも走っている最中に変えても効かない** —",
            "効かせるにはスケッチを起動し直す。",
            "",
            "いま見えている値:",
            "",
            "  \(baseLine(base: base, given: given))",
        ]
        // 依存が持たない面は、区画が在っても応答が来ない。**在る / 無いだけでは足りない**
        // (#647)。判定できなければ空のまま — 添えないことで「判定していない」を表す
        let absent = package.flatMap { DependencyFacets.absent(forPackageAt: $0) } ?? []
        for entry in StartupReads.all where entry.origin == .facet {
            let facet = base.appendingPathComponent(".mokume/\(entry.key)", isDirectory: true)
            var line = "  \(entry.name): \(facet.path) (\(exists(facet) ? "在る" : "無い"))"
            if absent.contains(entry) {
                line += " — 依存している mokume はこの面を持たない"
            }
            lines.append(line)
        }
        lines += ["", "一覧:", ""]
        for entry in StartupReads.all {
            lines.append("  \(entry.name) — \(source(entry)) / \(decider(entry))")
            lines.append("    \(entry.note)")
        }
        lines += [
            "",
            """
            走らせる側 (`\(Command.name) watch`) は起動のときに「\(StartupReads.workDirectory.name)」を
            名乗る。それがここの値と違っていたら、走らせる側と窓口は**別の区画を見ている** —
            起動し直しても直らないので、同じ \(StartupReads.workDirectory.key) の下で両方を起動し直す。
            """,
        ]
        return lines.joined(separator: "\n")
    }

    /// 何から読むか。
    private static func source(_ entry: StartupReads.Entry) -> String {
        switch entry.origin {
        case .environment: "環境変数 \(entry.key)"
        case .facet: "区画 .mokume/\(entry.key) が在るか"
        }
    }

    /// 誰が決めるか。
    private static func decider(_ entry: StartupReads.Entry) -> String {
        switch entry.decidedBy {
        case .user: "利用者が決める"
        case .tool: "道具が渡す"
        }
    }

    private static func exists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
