// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 投入ごとの GPU の時刻から、フレームの幅 (`min(start)`〜`max(end)`) を出す計算
/// ([#2378](https://github.com/mokume-metal/mokume/issues/2378))。GPU は要らない。
///
/// 幅は**投入の幅**で、GPU の稼働時間でも使用率でもない。投入ごとの `end − start` の和でもない —
/// 重なりを二重に数えず、投入の隙間は含む。ここで見るのは、その定義どおりに出ることと、**届いていない
/// 投入があるときに小さな幅を返さない**こと (欠けたまま返すと、実際より軽く見える)。
@Suite("フレームの GPU 時間 (投入の幅)")
struct GPUTimeLogTests {
    @Test("1 つの投入の幅は end − start")
    func oneSubmission() throws {
        let log = GPUTimeLog()
        log.note(1, start: 10.0, end: 10.004, failed: false)
        let span = try #require(log.span(of: 1..<2))
        #expect(span.submissions == 1)
        #expect(span.start == 10.0 && span.end == 10.004)
        #expect(abs(span.width - 0.004) < 1e-12)
    }

    /// 重なりは二重に数えない。隙間は含む。和 (4 + 3 = 7 ms) でも稼働時間でもなく、幅 (6 ms) である。
    @Test("複数の投入は min(start)〜max(end)。重なりは二重に数えず、隙間は含む")
    func widthIsMinToMaxNotTheSum() throws {
        let log = GPUTimeLog()
        log.note(1, start: 1.000, end: 1.004, failed: false)  // 4 ms
        log.note(2, start: 1.003, end: 1.006, failed: false)  // 重なる 3 ms
        let overlapped = try #require(log.span(of: 1..<3))
        #expect(abs(overlapped.width - 0.006) < 1e-12, "和 (7 ms) や最大 (4 ms) になった: \(overlapped.width)")

        log.note(3, start: 1.010, end: 1.011, failed: false)  // 隙間の後ろの 1 ms
        let gapped = try #require(log.span(of: 1..<4))
        #expect(abs(gapped.width - 0.011) < 1e-12, "隙間 (4 ms) を含んでいない: \(gapped.width)")
        #expect(gapped.submissions == 3)
    }

    @Test("範囲の投入が 1 つでも届いていなければ、幅は返さない")
    func nothingIsReturnedWhileASubmissionIsMissing() throws {
        let log = GPUTimeLog()
        log.note(1, start: 1.0, end: 1.001, failed: false)
        log.note(3, start: 1.002, end: 1.003, failed: false)
        #expect(log.span(of: 1..<4) == nil, "2 番が届いていないのに、軽い幅を返した")
        log.note(2, start: 1.001, end: 1.002, failed: false)
        #expect(try #require(log.span(of: 1..<4)).submissions == 3)
    }

    @Test("打ち切られた投入・使えない時刻は幅に入れず、飛ばす。全部が使えなければ nil")
    func unusableTimesAreSkipped() throws {
        let log = GPUTimeLog()
        log.note(1, start: 2.0, end: 2.002, failed: false)
        log.note(2, start: 0, end: 0, failed: true)
        log.note(3, start: 5.0, end: 4.0, failed: false)  // 終わりが始まりより前
        log.note(4, start: .nan, end: 1, failed: false)
        let span = try #require(log.span(of: 1..<5))
        #expect(span.submissions == 1, "使えない時刻を数えた")
        #expect(abs(span.width - 0.002) < 1e-12)

        log.note(10, start: 0, end: 0, failed: true)
        #expect(log.span(of: 10..<11) == nil)
    }

    @Test("空の範囲は nil")
    func anEmptyRangeHasNoSpan() {
        let log = GPUTimeLog()
        log.note(1, start: 1, end: 2, failed: false)
        #expect(log.span(of: 1..<1) == nil)
    }

    @Test("上限を越えて忘れた番号を含む範囲は、揃っていたか確かめられないので nil")
    func forgottenNumbersAreNotAnswered() throws {
        let log = GPUTimeLog()
        let total = UInt64(GPUTimeLog.remembered) + 10
        for submission in 1...total {
            log.note(submission, start: Double(submission), end: Double(submission) + 0.5, failed: false)
        }
        #expect(log.count == GPUTimeLog.remembered)
        #expect(log.span(of: 1..<5) == nil, "忘れた番号の範囲に答えた")
        #expect(log.span(of: (total - 2)..<(total + 1)) != nil, "覚えている新しい範囲に答えない")

        // 忘れた範囲の投入が遅れて届いても、記録へ戻さない (揃っていたかを確かめられないまま)
        log.note(3, start: 1, end: 2, failed: false)
        #expect(log.count == GPUTimeLog.remembered)
        #expect(log.span(of: 3..<4) == nil)
    }

    /// 毎投入ハンドラから呼ばれるので、記録が際限なく伸びない・順を飛ばして届いても覚える数が上限を
    /// 越えない。
    @Test("順が前後して届いても、覚える数は上限を越えない")
    func outOfOrderArrivalsStayBounded() {
        let log = GPUTimeLog()
        let total = GPUTimeLog.remembered * 3
        // 2 つずつ入れ替えて届ける
        for pair in stride(from: 1, through: total, by: 2) {
            log.note(UInt64(pair + 1), start: Double(pair + 1), end: Double(pair + 1) + 0.1, failed: false)
            log.note(UInt64(pair), start: Double(pair), end: Double(pair) + 0.1, failed: false)
            #expect(log.count <= GPUTimeLog.remembered + 2)
        }
        #expect(log.span(of: UInt64(total - 3)..<UInt64(total + 1)) != nil)
    }
}
