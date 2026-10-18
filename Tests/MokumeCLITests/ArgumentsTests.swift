// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 引数を解く 1 本のパーサと、そこに寄せた 4 つの口。
///
/// **見張っているのは「文面が変わっていないこと」である** ([#854]・親は [#814])。
/// 4 本の while ループを 1 本へ畳んだので、畳み方を間違えると打った人へ届く言葉が
/// 変わる — そして**変わっても既存の検査は緑のまま**だった (`#expect(throws:)` は
/// 型しか見ない)。ここが文面を留める。
///
/// [#854]: https://github.com/mokume-metal/mokume/issues/854
/// [#814]: https://github.com/mokume-metal/mokume/issues/814
@Suite("引数の解き方")
struct ArgumentsTests {
    /// 投げられた使い方の失敗から、打った人が読む文面を取り出す。
    private func usageMessage(_ body: () throws -> Void) -> String? {
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

    // ------------------------------------------------------------ 宣言そのもの

    @Test("宣言に無い綴りは、値を取らずに余りへ回る")
    func onlyDeclaredFlagsTakeAValue() throws {
        let parsed = try Arguments.parse(
            ["--path", "/tmp", "--other", "x"],
            options: [Arguments.Option(["--path"]) { "\($0) needs a directory after it" }],
            surplus: .ignore)
        // `--other` は宣言に無いので値を食わない。`x` は位置引数として残る
        #expect(parsed.values == ["--path": "/tmp"])
        #expect(parsed.ignored == ["--other"])
        #expect(parsed.positional == "x")
    }

    /// **値は打たれた綴りではなく、宣言の先頭の綴りで引く。** `-c` と `--configuration`
    /// のどちらで打たれても、受け取る側は 1 つの鍵だけを知っていればよい。
    @Test("別名で打たれても、値は宣言の先頭の綴りに載る")
    func aliasesLandUnderTheFirstSpelling() throws {
        let option = Arguments.Option(["-c", "--configuration"]) { "\($0) が要る" }
        #expect(
            try Arguments.parse(["--configuration", "release"], options: [option], surplus: .ignore)
                .values == ["-c": "release"])
        #expect(
            try Arguments.parse(["-c", "release"], options: [option], surplus: .ignore)
                .values == ["-c": "release"])
    }

    /// **宣言した選択肢は、余りを `ignore` にしても値を食う** (#2484)。食わないと、`doctor -c release`
    /// の `release` が場所になる。値は `values` に載せたまま (余りの扱いで契約を変えない)、
    /// 表示用の `setAside` に打たれた綴りと値を 1 つにして、打たれた順に載せる。`ignored` は
    /// 宣言に載っていないものだけ。
    @Test("余りを ignore にしても、宣言した選択肢は値ごと脇へ置く")
    func ignoringSurplusSetsDeclaredOptionsAsideWithTheirValues() throws {
        let option = Arguments.Option(["-c", "--configuration"]) { "\($0) needs a configuration" }
        let parsed = try Arguments.parse(
            ["/tmp/a", "-c", "release", "--fast", "--configuration", "debug"],
            options: [option], surplus: .ignore)
        #expect(parsed.positional == "/tmp/a")
        #expect(parsed.values == ["-c": "debug"])
        #expect(parsed.ignored == ["--fast"])
        #expect(parsed.setAside == ["-c release", "--fast", "--configuration debug"])

        // 値は場所に化けない。場所は後ろにあってもよい
        let before = try Arguments.parse(
            ["-c", "release", "/tmp/b"], options: [option], surplus: .ignore)
        #expect(before.positional == "/tmp/b")
        #expect(before.setAside == ["-c release"])
    }

    /// 切り分けの口は止まらない: 値が欠けていても、脇へ置いて続ける。
    @Test("余りを ignore にすると、値の欠けた宣言済みの選択肢でも止まらず、値が無かったと言う")
    func ignoringSurplusDoesNotStopOnAMissingValue() throws {
        let option = Arguments.Option(["-c", "--configuration"], takesPlace: true) {
            "\($0) needs a configuration"
        }
        let parsed = try Arguments.parse(["/tmp/a", "-c"], options: [option], surplus: .ignore)
        #expect(parsed.positional == "/tmp/a")
        #expect(parsed.setAside == ["-c (no value)"])
        #expect(parsed.values.isEmpty)
        // 場所を取る選択肢の空の値も、断らずに脇へ置く。**空は空と読める形で出す**
        let empty = try Arguments.parse(["-c", ""], options: [option], surplus: .ignore)
        #expect(empty.setAside == ["-c ''"])
    }

    /// **`-` 始まりの語は値に取らない** (走らせる口と同じ)。`doctor -c --scratch-path out` で
    /// 次の選択肢を値に食うと、その値の `out` が場所になる。
    @Test("余りを ignore にすると、- 始まりの語は値に取らず、元の位置のまま読む")
    func ignoringSurplusDoesNotTakeAnOptionAsAValue() throws {
        let options = [
            Arguments.Option(["-c"]) { "\($0) needs a configuration" },
            Arguments.Option(["--scratch-path"]) { "\($0) needs a directory" },
        ]
        let parsed = try Arguments.parse(
            ["-c", "--scratch-path", "out", "/tmp/a"], options: options, surplus: .ignore)
        #expect(parsed.positional == "/tmp/a")
        #expect(parsed.values == ["--scratch-path": "out"])
        #expect(parsed.setAside == ["-c (no value)", "--scratch-path out"])
    }

    /// **値の取り得る範囲が決まっている選択肢は、範囲外の語を値に取らない** (`ignore` のとき)。
    /// `doctor -c /path/to/sketch` の場所を `-c` の値に食うと、渡した場所でなく走らせた場所を診る。
    @Test("余りを ignore にすると、範囲外の語は値に取らず場所として残す")
    func ignoringSurplusLeavesAWordOutsideTheRangeAsThePlace() throws {
        let option = Arguments.Option(["-c"], accepts: { ["debug", "release"].contains($0) }) {
            "\($0) needs a configuration"
        }
        let outside = try Arguments.parse(["-c", "/tmp/a"], options: [option], surplus: .ignore)
        #expect(outside.positional == "/tmp/a")
        #expect(outside.setAside == ["-c (no value)"])
        // 範囲の中なら取る
        let inside = try Arguments.parse(["-c", "release"], options: [option], surplus: .ignore)
        #expect(inside.positional == nil)
        #expect(inside.values == ["-c": "release"])
        // 断る口は変わらない: 取ってから、使う口が自分の言い方で断る
        let rejecting = try Arguments.parse(
            ["-c", "/tmp/a"], options: [option], surplus: .reject { "Only one directory: \($0)" })
        #expect(rejecting.values == ["-c": "/tmp/a"])
    }

    /// 脇へ置いた語は、読み手がシェルの 1 語として読める形で出す。
    @Test("脇へ置いた語は、空・空白入りでも境目が読める")
    func setAsideWordsReadAsShellWords() throws {
        let option = Arguments.Option(["--out"]) { "\($0) needs somewhere to write" }
        let parsed = try Arguments.parse(
            ["--out", "my take.mov", "--out", "", "a b", "it's"], options: [option],
            surplus: .ignore)
        #expect(parsed.positional == "a b")
        #expect(
            parsed.setAside == ["--out 'my take.mov'", "--out ''", "'it'\\''s'"])
    }

    /// **値の欠落は、打たれた綴りで名指す。** `-c` と打った人に `--configuration` の話を
    /// しても、直す手がかりにならない。
    @Test("値が欠けたときは、打たれた綴りで言う")
    func namesTheSpellingAsTyped() {
        let option = Arguments.Option(["-c", "--configuration"]) { "\($0) needs a configuration" }
        #expect(
            usageMessage {
                _ = try Arguments.parse(
                    ["-c"], options: [option], surplus: .reject { "Only one directory: \($0)" })
            } == "-c needs a configuration")
        #expect(
            usageMessage {
                _ = try Arguments.parse(
                    ["--configuration"], options: [option],
                    surplus: .reject { "Only one directory: \($0)" })
            } == "--configuration needs a configuration")
    }

    /// **余りの扱いは宣言の 1 値である。** `doctor` の特例が 4 本目の別実装として
    /// 表れていたのを、`Surplus` の選択に落とした。
    @Test("余りを ignore にすると、知らない選択肢でも止まらず打った順に並ぶ")
    func ignoringSurplusNeverStops() throws {
        let parsed = try Arguments.parse(["--fast", "/tmp", "-x", "extra"], surplus: .ignore)
        #expect(parsed.positional == "/tmp")
        #expect(parsed.ignored == ["--fast", "-x", "extra"])
    }

    @Test("余りを reject にすると、位置引数の 2 つ目で止まる")
    func rejectingSurplusStopsAtTheSecondPositional() {
        #expect(
            usageMessage {
                _ = try Arguments.parse(["a", "b"], surplus: .reject { "Only one directory: \($0)" })
            } == "Only one directory: b")
    }

    // ------------------------------------------------ 口ごとの文面 (畳む前と同じか)

    /// **知らない選択肢の文面だけは、どの口でも同じ。** 畳んだ先が持つ唯一の文である。
    @Test("知らない選択肢は、3 つの口で同じ言い方と使い方を出す")
    func unknownOptionsReadTheSameEverywhere() {
        let expected = "Unknown option: --fast\n\n" + Command.usage()
        #expect(usageMessage { _ = try Invocation.parse(["--fast"]) } == expected)
        #expect(usageMessage { _ = try NewCommand.parse(["--fast"]) } == expected)
        #expect(usageMessage { _ = try BundleCommand.parse(["--fast"]) } == expected)
    }

    @Test("走らせる口の文面")
    func theRunningVerbsKeepTheirWording() {
        #expect(
            usageMessage { _ = try Invocation.parse(["-c"]) }
                == "-c needs a configuration after it (debug / release)")
        #expect(
            usageMessage { _ = try Invocation.parse(["--configuration"]) }
                == "--configuration needs a configuration after it (debug / release)")
        #expect(usageMessage { _ = try Invocation.parse(["a", "b"]) } == "Only one directory: b")
    }

    @Test("作る口の文面")
    func theNewVerbKeepsItsWording() {
        #expect(
            usageMessage { _ = try NewCommand.parse(["--path"]) } == "--path needs a directory after it")
        #expect(
            usageMessage { _ = try NewCommand.parse(["--local"]) }
                == "--local needs the library's path after it")
        #expect(usageMessage { _ = try NewCommand.parse(["a", "b"]) } == "Only one name: b")
    }

    /// **`--out` だけが使い方を連れてくる。** 揃っていないのは畳む前からで、揃えるのは
    /// 振る舞いを変えることなので、この PR ではしない (#854 の「1 文字も変えない」)。
    @Test("束ねる口の文面")
    func theBundleVerbKeepsItsWording() {
        #expect(
            usageMessage { _ = try BundleCommand.parse(["--out"]) }
                == "--out needs a directory\n\n" + Command.usage())
        #expect(usageMessage { _ = try BundleCommand.parse(["a", "b"]) } == "Only one directory: b")
    }

    /// **切り分けの口は使い方で止まらない。** いちばん要るときに読めなくなるため。
    @Test("切り分けの口は、知らない引数を無視したと言って続ける")
    func theDoctorVerbNeverStops() {
        let text = DoctorCommand.text(for: ["--fast", "-x"], workDirectory: nil)
        #expect(text.hasPrefix("Ignored arguments doctor does not take: --fast -x\n"))
        #expect(text.contains("What the environment provides"))
    }

    /// 場所は取る。2 つ目からは余りへ回る (畳む前と同じ)。
    ///
    /// **切り分けの口を通して見る。** 解析だけを呼ぶと、口が解析の結果のどれを場所に
    /// 使うかを取り違えても緑のままになる (#2282)。区画の基準の行は場所から決まるので、
    /// そこに 1 つ目が出ていれば 1 つ目を場所に取っている。
    @Test("切り分けの口も、場所は 1 つだけ取る")
    func theDoctorVerbStillTakesOnePlace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-doctor-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("a", isDirectory: true)
        let second = root.appendingPathComponent("b", isDirectory: true)
        let text = DoctorCommand.text(
            for: [first.path, second.path], workDirectory: nil, environment: [:], home: root)
        #expect(text.hasPrefix("Ignored arguments doctor does not take: \(second.path)\n"), "\(text)")
        #expect(text.contains(StartupReadsReport.baseLine(base: first, given: false)), "\(text)")
    }

    // ------------------------------------------------------- `--x=値` の綴り (#2484)

    /// **受け付ける形は増やさない。** `=` の前が宣言済みの綴りなら、`Unknown option` ではなく
    /// 空白で区切るよう案内する。`Arguments.parse` を通る全ての口で同じ。
    @Test(
        "宣言済みの綴りの = 付きは、空白で区切るよう案内して使い方の誤りで終わる",
        arguments: [
            ("--configuration=release", "--configuration release"),
            ("-c=release", "-c release"),
            ("--scratch-path=out", "--scratch-path out"),
            ("--configuration=", "--configuration <value>"),
            // 値は貼って動く 1 語にする (#2320 の規律): 空白入りは引用符で包む
            ("--scratch-path=my out", "--scratch-path 'my out'"),
        ])
    func separatedSpellingIsExplained(argument: String, advice: String) {
        let expected =
            "\(argument) is not accepted: separate the value from "
            + "\(argument.split(separator: "=", omittingEmptySubsequences: false)[0]) with a space,"
            + " as in \(advice)\n\n" + Command.usage()
        #expect(usageMessage { _ = try Invocation.parse([argument]) } == expected)
        #expect(usageMessage { _ = try Invocation.parse([argument, "x"]) } == expected)
    }

    @Test("口ごとの宣言済みの綴りも、= 付きなら空白で区切るよう案内する")
    func separatedSpellingIsExplainedByEveryVerb() throws {
        for arguments in [["--path=out"], ["--local=lib"]] {
            let message = try #require(usageMessage { _ = try NewCommand.parse(["demo"] + arguments) })
            #expect(message.hasPrefix("\(arguments[0]) is not accepted: separate the value from"))
        }
        let bundle = try #require(usageMessage { _ = try BundleCommand.parse(["--out=out"]) })
        #expect(bundle.hasPrefix("--out=out is not accepted: separate the value from --out"))
        // 選択肢を宣言しない口 (窓口) には、案内する綴りが無い。いまどおり知らない選択肢
        #expect(
            usageMessage {
                _ = try MCPCommand.directories(
                    arguments: ["--configuration=release"], environment: [:],
                    currentDirectory: URL(fileURLWithPath: "/"))
            }?.hasPrefix("Unknown option: --configuration=release\n") == true)
    }

    @Test("宣言されていない綴りの = 付きは、いまどおり知らない選択肢")
    func undeclaredSpellingWithEqualsStaysUnknown() {
        let expected = "Unknown option: --nope=1\n\n" + Command.usage()
        #expect(usageMessage { _ = try Invocation.parse(["--nope=1"]) } == expected)
        #expect(usageMessage { _ = try NewCommand.parse(["--nope=1"]) } == expected)
        #expect(usageMessage { _ = try BundleCommand.parse(["--nope=1"]) } == expected)
    }
}
