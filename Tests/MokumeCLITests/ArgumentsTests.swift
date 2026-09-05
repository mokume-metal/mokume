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
            options: [Arguments.Option(["--path"]) { "\($0) のあとに場所が要る" }],
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

    /// **値の欠落は、打たれた綴りで名指す。** `-c` と打った人に `--configuration` の話を
    /// しても、直す手がかりにならない。
    @Test("値が欠けたときは、打たれた綴りで言う")
    func namesTheSpellingAsTyped() {
        let option = Arguments.Option(["-c", "--configuration"]) { "\($0) のあとに構成が要る" }
        #expect(
            usageMessage { _ = try Arguments.parse(["-c"], options: [option], surplus: .ignore) }
                == "-c のあとに構成が要る")
        #expect(
            usageMessage {
                _ = try Arguments.parse(["--configuration"], options: [option], surplus: .ignore)
            } == "--configuration のあとに構成が要る")
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
                _ = try Arguments.parse(["a", "b"], surplus: .reject { "場所は 1 つだけ: \($0)" })
            } == "場所は 1 つだけ: b")
    }

    // ------------------------------------------------ 口ごとの文面 (畳む前と同じか)

    /// **知らない選択肢の文面だけは、どの口でも同じ。** 畳んだ先が持つ唯一の文である。
    @Test("知らない選択肢は、3 つの口で同じ言い方と使い方を出す")
    func unknownOptionsReadTheSameEverywhere() {
        let expected = "知らない選択肢: --fast\n\n" + Command.usage()
        #expect(usageMessage { _ = try Invocation.parse(["--fast"]) } == expected)
        #expect(usageMessage { _ = try NewCommand.parse(["--fast"]) } == expected)
        #expect(usageMessage { _ = try BundleCommand.parse(["--fast"]) } == expected)
    }

    @Test("走らせる口の文面")
    func theRunningVerbsKeepTheirWording() {
        #expect(
            usageMessage { _ = try Invocation.parse(["-c"]) }
                == "-c のあとに構成の名前が要る (debug / release)")
        #expect(
            usageMessage { _ = try Invocation.parse(["--configuration"]) }
                == "--configuration のあとに構成の名前が要る (debug / release)")
        #expect(usageMessage { _ = try Invocation.parse(["a", "b"]) } == "場所は 1 つだけ: b")
    }

    @Test("作る口の文面")
    func theNewVerbKeepsItsWording() {
        #expect(
            usageMessage { _ = try NewCommand.parse(["--path"]) } == "--path のあとに場所が要る")
        #expect(
            usageMessage { _ = try NewCommand.parse(["--local"]) }
                == "--local のあとにライブラリの場所が要る")
        #expect(usageMessage { _ = try NewCommand.parse(["a", "b"]) } == "名前は 1 つだけ: b")
    }

    /// **`--out` だけが使い方を連れてくる。** 揃っていないのは畳む前からで、揃えるのは
    /// 振る舞いを変えることなので、この PR ではしない (#854 の「1 文字も変えない」)。
    @Test("束ねる口の文面")
    func theBundleVerbKeepsItsWording() {
        #expect(
            usageMessage { _ = try BundleCommand.parse(["--out"]) }
                == "--out には置き場が要る\n\n" + Command.usage())
        #expect(usageMessage { _ = try BundleCommand.parse(["a", "b"]) } == "場所は 1 つだけ: b")
    }

    /// **切り分けの口は使い方で止まらない。** いちばん要るときに読めなくなるため。
    @Test("切り分けの口は、知らない引数を無視したと言って続ける")
    func theDoctorVerbNeverStops() {
        let text = DoctorCommand.text(for: ["--fast", "-x"], workDirectory: nil)
        #expect(text.hasPrefix("知らない引数は無視した: --fast -x\n"))
        #expect(text.contains("環境の前提"))
    }

    /// 場所は取る。2 つ目からは余りへ回る (畳む前と同じ)。
    @Test("切り分けの口も、場所は 1 つだけ取る")
    func theDoctorVerbStillTakesOnePlace() throws {
        let parsed = try Arguments.parse(["/tmp/a", "/tmp/b"], surplus: .ignore)
        #expect(parsed.positional == "/tmp/a")
        #expect(parsed.ignored == ["/tmp/b"])
    }
}
