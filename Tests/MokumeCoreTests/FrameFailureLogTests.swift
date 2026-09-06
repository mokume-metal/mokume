// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 続けて失敗した数の数え方 (#1011)。GPU も窓も要らない — 数えるところだけの構造体である。
///
/// **「回復したら 0 へ戻す」を落とすと、以後 1 度も言わなくなる。** 症状は
/// [#221](https://github.com/mokume-metal/mokume/issues/221) が塞いだ穴 — 絵が止まったのに
/// 理由がどこにも残らない — にそのまま戻る。落としてもコンパイルは通り、ほかの検査も
/// 通るので、ここが留める。
@Suite("続けて失敗した数")
struct FrameFailureLogTests {
    /// **毎フレーム言わない。** 1 秒に 60 行流れると、本当に読むべき行が埋まる。
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

    /// **終わりには枚数が要る。** 黙っていた間に何枚落ちたかは、ここにしか残らない。
    @Test("回復したら、飛ばした数を言う")
    func recoveryReportsHowManyWereSkipped() {
        var log = FrameFailureLog()
        _ = log.note()
        _ = log.note()
        #expect(log.recovered() == 2)
    }

    /// **何も無かった回に「回復しました」と言わない。** 呼び出し側は毎フレーム
    /// `recovered()` を打つので、転んでいない回にも通る。
    @Test("転んでいなければ、回復しても何も言わない")
    func aQuietRunSaysNothing() {
        var log = FrameFailureLog()
        #expect(log.recovered() == nil)
    }

    /// **回復のたびに数え直す。** 戻し忘れると 2 度目の不調で何も言わなくなる — この検査
    /// だけが `recovered()` の `defer { consecutive = 0 }` を留めている。
    @Test("2 度目の不調も、また始まりを言う")
    func theSecondSpellSpeaksAgain() {
        var log = FrameFailureLog()
        let spoke = log.note()
        let firstRecovery = log.recovered()
        let spokeAgain = log.note()
        let secondRecovery = log.recovered()
        #expect(spoke)
        #expect(firstRecovery == 1)
        #expect(spokeAgain, "回復で 0 へ戻していないと、ここが黙る")
        #expect(secondRecovery == 1)
    }
}
