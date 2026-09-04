// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 名前の対応が、型の話になっているか。
///
/// コマンドの綴りは dispatch と案内文に、道具の名前は一覧の定義と `call` の `switch` に、
/// それぞれ**別々の文字列リテラル**で並んでいた ([#854]・親は [#814])。対応を保つ機械が
/// 居なかったので、`version` は dispatch にあって案内文には無い、という状態が誰にも
/// 気付かれずに続いていた。
///
/// 列挙に寄せたいまは、口や道具を足すと網羅 `switch` がコンパイラに問われる。**ここが
/// 見るのは、その列挙から出た 2 つの面 (案内文・一覧) が列挙と食い違わないこと**である
/// — コンパイラは「書いたか」までしか見ず、「案内に並べたか」までは見ない。
///
/// [#854]: https://github.com/mokume-metal/mokume/issues/854
/// [#814]: https://github.com/mokume-metal/mokume/issues/814
@Suite("名前の対応")
struct NameCorrespondenceTests {
    // ------------------------------------------------------------ 打てる口

    /// **列挙が綴りの正典。** 名前も慣習の綴りも、そこから dispatch へ解ける。
    @Test("列挙にある綴りは、すべて口として解ける")
    func everySpellingResolvesToAVerb() {
        for verb in Command.Verb.allCases {
            #expect(Command.Verb.named(verb.rawValue) == verb, "\(verb.rawValue) が解けない")
            for alias in verb.aliases {
                #expect(Command.Verb.named(alias) == verb, "\(alias) が解けない")
            }
        }
        #expect(Command.Verb.named("なにか") == nil)
    }

    /// 慣習の綴りは help と version の 2 つだけが持つ。
    @Test("慣習の綴りは、help と version だけが受ける")
    func onlyHelpAndVersionCarryAliases() {
        #expect(Command.Verb.named("--help") == .help)
        #expect(Command.Verb.named("-h") == .help)
        #expect(Command.Verb.named("--version") == .version)
        #expect(Command.Verb.named("-v") == .version)
        let withAliases = Command.Verb.allCases.filter { !$0.aliases.isEmpty }
        #expect(withAliases == [.help, .version])
    }

    /// **案内に並べないなら、並べないと書くことになる。** 口を足した人が案内を書き忘れ
    /// たら、ここが赤くなる。
    @Test("案内に並べる口は、すべて案内文に現れる")
    func everyListedVerbAppearsInTheUsage() {
        let usage = Command.usage("mokume")
        for verb in Command.Verb.allCases {
            guard let entry = verb.usageEntry else { continue }
            #expect(usage.contains(entry.signature), "案内に \(verb.rawValue) の行が無い")
            for line in entry.description.split(separator: "\n") {
                #expect(usage.contains(String(line)), "案内に \(verb.rawValue) の説明が無い")
            }
        }
    }

    /// `version` を並べないのは意図である (#634 の完了条件 3) — 古い版を持つ人はこの綴りを
    /// 知らないので、到達できる口は help のほうであり、案内は末尾で道具の版を既に名乗る。
    /// **並べないのはここ 1 つだけ**で、増えたらそれは意図ではなく書き忘れである。
    @Test("案内に並べないのは version だけ")
    func onlyVersionStaysOutOfTheUsage() {
        let unlisted = Command.Verb.allCases.filter { $0.usageEntry == nil }
        #expect(unlisted == [.version])
        #expect(!Command.usage("mokume").contains("  version"))
    }

    /// 案内文の形。**印字された行がそのまま打てる**ように、口の行は 2 字下げで始まる。
    @Test("案内文は、名前・口の並び・道具の版の 3 段でできている")
    func theUsageKeepsItsShape() {
        let usage = Command.usage("mokume")
        let lines = usage.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "使い方: mokume <コマンド>")
        #expect(lines.dropFirst().first == "")
        #expect(lines.last == "道具: \(ToolVersion.describe())")
        // 口の行は 2 字下げ、説明は 6 字下げ (畳む前と同じ)
        #expect(usage.contains("\n  new <名前> [--path <場所>] [--local <ライブラリの場所>]\n"))
        #expect(usage.contains("\n      -c は debug / release (省くと道具立ての既定)\n"))
    }

    // ------------------------------------------------------------ 差し出す道具

    /// **一覧は列挙から出す。** かつては定義と `call` の `switch` が別々のリテラルだった。
    @Test("一覧に並ぶ名前は、列挙と同じ並びで同じ数")
    func theListingComesFromTheEnumeration() {
        let listed = Tools.definitions.compactMap { $0["name"] as? String }
        #expect(listed == Tools.ToolName.allCases.map(\.rawValue))
        #expect(listed == ["observe", "build_status", "input", "reference"])
    }

    /// 名前だけでなく、一覧が差し出す 3 つの欄が全部埋まっていること。
    @Test("一覧の各項目は、説明と引数の形を持つ")
    func everyDefinitionCarriesItsDescriptionAndSchema() {
        for definition in Tools.definitions {
            let name = definition["name"] as? String
            #expect(name != nil)
            #expect((definition["description"] as? String)?.isEmpty == false, "\(name ?? "?")")
            let schema = definition["inputSchema"] as? [String: Any]
            #expect(schema?["type"] as? String == "object", "\(name ?? "?")")
        }
    }

    /// **一覧に載っているものには、全部応える。** 載せたのに `call` が知らない、という
    /// ずれが起きないことを見る (列挙が網羅 `switch` を強いるので、ここは面の側の確認)。
    @Test("一覧に載る道具は、すべて呼べる")
    func everyListedToolAnswers() throws {
        let place = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: place) }

        let tools = Tools(facets: Facets(directory: place, waitLimit: 0.2), makeID: { "fixed" })
        for name in Tools.ToolName.allCases.map(\.rawValue) {
            let outcome = tools.call(name, arguments: [:])
            // 走っていないので失敗して構わない。**知らない道具だとは言わないこと**を見る
            #expect(!outcome.text.contains("知らない道具です"), "\(name) に応えていない")
            #expect(!outcome.text.isEmpty, "\(name) が何も言わない")
        }
        #expect(tools.call("なにか", arguments: [:]).isError)
    }
}
