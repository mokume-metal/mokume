// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCLI

/// 案内文が名乗る名前。
///
/// 配布物は `mokume` で入り、開発中は `swift run mokume-cli` で呼ばれる (#383)。
/// **印字された行がそのまま打てること**を、どちらの呼ばれ方でも保つ。
@Suite("案内文は起動された名前で名乗る")
struct CommandNameTests {
    @Test("起動に使われた道の末尾を名前にする")
    func takesTheNameItWasInvokedWith() {
        #expect(Command.invokedName("/Users/who/.local/bin/mokume") == "mokume")
        #expect(Command.invokedName(".build/debug/mokume-cli") == "mokume-cli")
        #expect(Command.invokedName("mokume") == "mokume")
    }

    @Test("名前が取れなければ配布時の名前に倒す")
    func fallsBackToTheNameItShipsUnder() {
        #expect(Command.invokedName("") == "mokume")
        #expect(Command.invokedName("/") == "mokume")
    }

    @Test("使い方はその名前で名乗る")
    func theUsageAnnouncesThatName() {
        #expect(Command.usage("mokume").hasPrefix("使い方: mokume <コマンド>"))
        #expect(Command.usage("mokume-cli").hasPrefix("使い方: mokume-cli <コマンド>"))
    }

    @Test("使い方の案内は、道具の版を名乗る")
    func theUsageNamesTheToolVersion() {
        #expect(Command.usage().contains(ToolVersion.describe()))
    }
}
