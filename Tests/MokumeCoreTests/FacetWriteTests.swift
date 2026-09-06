// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 区画へ JSON を置く口。
///
/// **形はここが決める。** かつては置く側が銘々 `JSONEncoder` を組んでいて、同じ規約に
/// 乗っている面の応答なのに鍵の並びが面ごとに違った
/// ([#989](https://github.com/mokume-metal/mokume/issues/989))。
@Suite("区画へ置く口")
struct FacetWriteTests {
    private struct Sample: Encodable, Equatable {
        let zebra: String
        let apple: Int
        let path: String
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-facet-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("report.json")
    }

    @Test("鍵は整列し、人が読める形で、パスは escape しない")
    func theShapeIsFixed() throws {
        let url = temporaryURL()
        try AtomicFile.write(json: Sample(zebra: "z", apple: 1, path: "a/b"), to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(
            text == """
                {
                  "apple" : 1,
                  "path" : "a/b",
                  "zebra" : "z"
                }
                """)
    }

    @Test("途中のディレクトリは置く側が用意しなくてよい")
    func theDirectoryIsMadeOnTheWay() throws {
        let url = temporaryURL()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try AtomicFile.write(json: Sample(zebra: "z", apple: 1, path: "p"), to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// **置けたかどうかを呼ぶ側へ返す。** 返さないと、置けていないのに
    /// 「置いた」ことにして次へ進む (保存の回数を数える・要求の識別子を覚える)。
    @Test("置けたら true、置けなければ false")
    func theOutcomeIsReturned() throws {
        var log = FrameFailureLog()

        let good = temporaryURL()
        let placed = AtomicFile.place(
            json: Sample(zebra: "z", apple: 1, path: "p"), to: good, naming: "見本", noting: &log)
        #expect(placed)

        // 書けない先 — 親がファイルなので、ディレクトリを作れない
        let blocked = temporaryURL().deletingLastPathComponent()
        try Data().write(to: blocked)
        let refused = AtomicFile.place(
            json: Sample(zebra: "z", apple: 1, path: "p"),
            to: blocked.appendingPathComponent("report.json"), naming: "見本", noting: &log)
        #expect(!refused)
    }
}

/// 続けて失敗した数の数え方。
///
/// **「回復したら 0 へ戻す」を落とすと、以後 1 度も言わなくなる。** 症状は
/// [#221](https://github.com/mokume-metal/mokume/issues/221) が塞いだ穴 —
/// 絵が止まったのに理由がどこにも残らない — にそのまま戻る。落としてもコンパイルは
/// 通り、ほかの検査も通るので、ここが留める。
@Suite("続けて失敗した数")
struct FrameFailureLogTests {
    @Test("言うのは始まりの 1 回だけ")
    func onlyTheFirstFailureSpeaks() {
        var log = FrameFailureLog()
        let first = log.note()
        let second = log.note()
        let third = log.note()
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test("回復したら、飛ばした数を言う")
    func recoveryReportsHowManyWereSkipped() {
        var log = FrameFailureLog()
        _ = log.note()
        _ = log.note()
        #expect(log.recovered() == 2)
    }

    @Test("転んでいなければ、回復しても何も言わない")
    func aQuietRunSaysNothing() {
        var log = FrameFailureLog()
        #expect(log.recovered() == nil)
    }

    /// **回復のたびに数え直す。** 戻し忘れると 2 度目の不調で何も言わなくなる。
    @Test("2 度目の不調も、また始まりを言う")
    func theSecondSpellSpeaksAgain() {
        var log = FrameFailureLog()
        let spoke = log.note()
        let firstRecovery = log.recovered()
        let spokeAgain = log.note()
        let secondRecovery = log.recovered()
        #expect(spoke)
        #expect(firstRecovery == 1)
        #expect(spokeAgain)
        #expect(secondRecovery == 1)
    }
}
