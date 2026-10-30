// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCLI

/// 口ごとのヘルプ (`<口> --help`・`-h`・`help <口>`) と、誤りの短い案内 (#3425)。
///
/// **口のヘルプは `usageEntry` から作る。** 新しい説明は書かない — 全体の使い方と同じ値から出る。
/// どの口でも、ヘルプを頼まれたら口を走らせずに 0 で終わる (ビルド・診断・窓口の待ち受け・
/// ファイルの作成をしない)。
@Suite("口ごとのヘルプと短い誤りの案内")
struct VerbHelpTests {
    /// ヘルプのある口 (`usageEntry` を持つ口から `help` を除く)。
    private static let verbsWithOwnHelp: [Command.Verb] = Command.Verb.allCases.filter {
        $0.usageEntry != nil && $0 != .help
    }

    /// 投げられた使い方の失敗の文面。
    private func usageText(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let failure as CommandFailure {
            guard case .usage(let text) = failure else { return nil }
            return text
        } catch {
            return nil
        }
    }

    // ------------------------------------------------------------ 口のヘルプの文

    /// 全部の口で、signature と説明の各行を含み、全体の使い方の中の同じ口の部分と一致する。
    @Test("口のヘルプは usageEntry から作られ、全体の使い方の中のその口の部分と一致する")
    func theHelpOfEveryVerbComesFromItsEntry() throws {
        let usage = Command.usage("mokume")
        for verb in Command.Verb.allCases {
            let help = Command.help(for: verb, "mokume")
            guard let entry = verb.usageEntry else {
                // 宣言を持たない口 (version) は全体を返す
                #expect(help == usage)
                continue
            }
            #expect(help.hasPrefix("Usage: mokume \(entry.signature)\n\n"), "\(verb.rawValue)")
            let lines = entry.description.split(separator: "\n").map { "      \($0)" }
            for line in lines { #expect(help.contains(line), "\(verb.rawValue) の説明の行が無い") }
            // 全体の使い方の中の同じ口の部分 (口の行と説明の行) と一致する
            let block = (["  \(entry.signature)"] + lines).joined(separator: "\n")
            #expect(usage.contains(block), "\(verb.rawValue) の部分が全体と違う")
            let body = lines.joined(separator: "\n")
            #expect(help == "Usage: mokume \(entry.signature)\n\n" + body)
            #expect(!help.contains("Tool:"), "口のヘルプに Tool: の行を付けない")
        }
    }

    @Test("help の説明は、口を 1 つ渡せることを言う")
    func helpSaysItTakesACommand() throws {
        let entry = try #require(Command.Verb.help.usageEntry)
        #expect(entry.signature == "help [<command>]")
        #expect(entry.description.contains("pass one"))
    }

    // ------------------------------------------------------------ 走らせずに 0 で終わる

    /// `--help` / `-h` / `help <口>` は、どの口でも投げずに戻る。**口を走らせない**
    /// (走らせれば、スケッチの無い場所で別の誤りになるか、窓口が標準入力を待つ)。
    @Test("どの口も、--help と -h と help <口> で、走らせずに戻る")
    func everyVerbAnswersHelpWithoutRunning() throws {
        for verb in Self.verbsWithOwnHelp {
            try Command.dispatch([verb.rawValue, "--help"])
            try Command.dispatch([verb.rawValue, "-h"])
            try Command.dispatch(["help", verb.rawValue])
        }
        // 名前や場所を足しても、後ろにあれば効く
        try Command.dispatch(["run", ".", "--help"])
    }

    @Test("new <名前> --help は、何も作らない")
    func newHelpCreatesNothing() throws {
        let place = try TestScratch.directory("mokume-help-new")
        defer { try? FileManager.default.removeItem(at: place) }
        try Command.dispatch(["new", "sketch", "--path", place.path, "--help"])
        #expect(
            !FileManager.default.fileExists(atPath: place.appendingPathComponent("sketch").path),
            "ヘルプを頼んだのにスケッチを作った")
    }

    @Test("doctor --help は、診断を走らせない")
    func doctorHelpDoesNotDiagnose() throws {
        #expect(DoctorCommand.asksForHelp(["--help"]))
        #expect(DoctorCommand.asksForHelp(["-h"]))
        #expect(DoctorCommand.asksForHelp(["/some/place", "--help"]))
        // ヘルプでない知らない引数は、これまでどおり脇へ置いて診断を続ける
        #expect(!DoctorCommand.asksForHelp(["--fast"]))
        #expect(!DoctorCommand.asksForHelp(["-c", "release"]))
        #expect(!DoctorCommand.asksForHelp([]))
        // 診断の文には、ヘルプの綴りが「脇へ置いた引数」として載らない
        let text = DoctorCommand.text(for: ["--fast"], workDirectory: nil)
        #expect(text.contains("Ignored arguments doctor does not take: --fast"))
    }

    @Test("mcp --help は、窓口を回さずに戻る")
    func mcpHelpDoesNotServe() throws {
        let scratch = try TestScratch.directory("mokume-help-mcp")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var served = false
        #expect(throws: CommandFailure.helpRequested) {
            try MCPCommand.run(["--help"], scratch: scratch) { _ in served = true }
        }
        #expect(!served)
        // 口からは、待たずに戻る
        try Command.dispatch(["mcp", "--help"])
    }

    /// 値を取る選択肢の値の位置に来た `-h` は値のまま。
    @Test("値を取る位置の -h は、ヘルプではなく値")
    func aValueNamedLikeHelpIsAValue() throws {
        let parsed = try Arguments.parse(
            ["--out", "-h"], options: [Arguments.Option(["--out"]) { "\($0) needs a path" }],
            surplus: .reject { "Only one: \($0)" })
        #expect(parsed.values["--out"] == "-h")
        #expect(throws: CommandFailure.helpRequested) {
            _ = try Arguments.parse(
                ["x", "--help"], options: [], surplus: .reject { "Only one: \($0)" })
        }
    }

    // ------------------------------------------------------------ help と version

    @Test("help の後ろの知らない口は、全体を出さずに断る")
    func helpRefusesAnUnknownCommand() {
        let text = usageText { try Command.dispatch(["help", "nope"]) }
        #expect(text == "Unknown command: nope\nSee \(Command.name) help for the commands.")
    }

    @Test("help <口> の余りは、名指して断る")
    func helpNamesTheSurplus() {
        let text = usageText { try Command.dispatch(["help", "run", "extra"]) }
        #expect(text?.hasPrefix("\(Command.name) help takes at most one command (got extra)") == true)
        #expect(text?.contains("Usage:") == false)
    }

    @Test("version の余りは、名指して断る")
    func versionNamesTheSurplus() {
        let text = usageText { try Command.dispatch(["version", "extra"]) }
        #expect(text == "\(Command.name) version takes no arguments (got extra)")
    }

    @Test("help version と version --help は、全体の使い方を出して戻る")
    func versionHelpIsTheWholeUsage() throws {
        try Command.dispatch(["help", "version"])
        try Command.dispatch(["version", "--help"])
        try Command.dispatch(["version", "-h"])
        #expect(Command.help(for: .version) == Command.usage())
    }

    @Test("口のない呼び方は全体の使い方で断り、知らない口は 2 行で断る")
    func noCommandKeepsTheWholeUsage() {
        #expect(usageText { try Command.dispatch([]) } == Command.usage())
        let unknown = usageText { try Command.dispatch(["rn"]) }
        #expect(unknown == "Unknown command: rn\nSee \(Command.name) help for the commands.")
    }

    // ------------------------------------------------------------ 誤りの短い形

    /// 口の中の使い方の誤りは、誤りの文と案内の 1 行だけ。全体の使い方を付けない。
    @Test("使い方の誤りは、誤りの文と help <口> の案内の 1 行だけ")
    func aUsageErrorIsShort() {
        let text = usageText { try Command.dispatch(["run", "--fast"]) }
        #expect(
            text == "Unknown option: --fast\nSee \(Command.name) help run for what run takes.")

        for (verb, arguments) in [
            ("new", ["--fast"]), ("watch", ["--fast"]), ("render", ["--fast"]),
            ("bundle", ["--fast"]), ("mcp", ["--fast"]), ("bundle", ["--out"]),
            ("examples", ["extra"]), ("run", ["a", "b"]),
        ] {
            let message = usageText { try Command.dispatch([verb] + arguments) }
            #expect(message != nil, "\(verb) \(arguments) が使い方の誤りで止まらなかった")
            #expect(
                message?.hasSuffix("\nSee \(Command.name) help \(verb) for what \(verb) takes.")
                    == true, "\(verb) \(arguments): \(message ?? "nil")")
            #expect(message?.contains("Usage:") == false, "\(verb) \(arguments) が全体の使い方を付けた")
            #expect(message?.split(separator: "\n").count ?? 0 <= 4)
        }
    }

    /// #2484 の決定は変えない — `--x=値` は受けず、案内の文はそのまま、後ろだけが 1 行になる。
    @Test("--x=値 の案内の文は、そのまま残り、後ろは 1 行になる")
    func separatedSpellingKeepsItsSentence() {
        let text = usageText { try Command.dispatch(["run", "-c=release"]) }
        #expect(
            text
                == "-c=release is not accepted: separate the value from -c with a space, as in -c release\n"
                + "See \(Command.name) help run for what run takes.")
    }
}
