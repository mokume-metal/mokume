// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCamera

/// 動画のどこを映すか (#1960)。時計にも AVFoundation にも触れないので、GPU も動画も要らない。
@Suite("動画の再生位置")
struct PlayheadTests {
    /// 時刻の並びで進め、映す位置の並びを返す。
    private func advance(_ head: inout Playhead, _ times: [Double]) -> [Double] {
        times.map { head.advance(to: $0) }
    }

    /// 固定の時計 (`fps` 枚/秒) の `frame` 枚目の時刻。スケッチが渡すのと同じく単精度を通す。
    private func time(_ frame: Int, fps: Int = 30) -> Double {
        Double(Float(Double(frame - 1) / Double(fps)))
    }

    @Test("作っただけでは進まず、頭に留まる")
    func staysAtTheStartUntilPlayed() {
        var head = Playhead(duration: 2)
        #expect(advance(&head, [0, 1.5]) == [0, 0])
        #expect(!head.isPlaying)
    }

    @Test("流し始めたフレームの位置から、スケッチの時刻が進んだぶんだけ進む")
    func followsTheSketchTimeFromWhereItStarted() {
        var head = Playhead(duration: 10)
        _ = head.advance(to: 5)
        head.play()
        // 頼んだ次のフレームが始めた位置 (0)。時刻 5.5 秒は起点で、位置ではない
        #expect(advance(&head, [5.5, 6, 7.5]) == [0, 0.5, 2])
    }

    @Test("止めると映している位置で止まり、流し直すと次のフレームからそこから進む")
    func pauseHoldsAndPlayResumes() {
        var head = Playhead(duration: 10)
        head.play()
        #expect(advance(&head, [0, 1]) == [0, 1])
        head.pause()
        #expect(advance(&head, [2, 3]) == [1, 1])
        head.play()
        // 止めていた間の時刻は飛ばさない
        #expect(advance(&head, [4, 4.5]) == [1, 1.5])
    }

    @Test("1 度だけ流すと終わりで止まり、もう一度流すと頭から")
    func playStopsAtTheEndAndRestartsFromTheTop() {
        var head = Playhead(duration: 1)
        head.play()
        #expect(advance(&head, [0, 0.5, 1.2]) == [0, 0.5, 1])
        #expect(!head.isPlaying)
        #expect(advance(&head, [2]) == [1])
        head.play()
        #expect(advance(&head, [3, 3.25]) == [0, 0.25])
    }

    // MARK: - ループの継ぎ目

    @Test("繰り返すと、ちょうど長さに乗った時刻が頭になる")
    func loopWrapsExactlyAtTheLength() {
        var head = Playhead(duration: 1)
        head.loop()
        #expect(advance(&head, [0, 0.5, 1, 2.25]) == [0, 0.5, 0, 0.25])
        #expect(head.isPlaying)
    }

    @Test("継ぎ目をわずかに割った時刻も頭とみなし、終わりのコマを 1 枚余計に映さない")
    func loopTreatsTheSeamWithinToleranceAsTheTop() {
        var head = Playhead(duration: 1)
        head.loop()
        // 単精度の丸めで 1 秒をわずかに割った時刻は頭。余裕より手前は終わりの側
        #expect(advance(&head, [0, 1 - 1e-6, 1 - 0.01]) == [0, 0, 1 - 0.01])
    }

    @Test("30 fps の時計で 1 秒の動画を繰り返すと、31 枚目と 61 枚目で頭に戻る")
    func loopReturnsToTheTopOnTheFixedClock() {
        var head = Playhead(duration: 1)
        head.loop()
        let positions = advance(&head, (1...61).map { time($0) })
        #expect(positions[0] == 0)
        #expect(positions[30] == 0)
        #expect(positions[60] == 0)
        #expect(positions[29] > 0.96)
    }

    @Test("ループの途中で play() にすると、その周の終わりで止まる")
    func playAfterLoopStopsAtTheEndOfThisRound() {
        var head = Playhead(duration: 1)
        head.loop()
        #expect(advance(&head, [0, 1.5]) == [0, 0.5])
        head.play()
        #expect(head.isPlaying)
        // 2 周目の 0.5 から続けて進み (頭へ戻らず、すぐにも終わらない)、この周の終わりで止まる
        #expect(advance(&head, [1.75, 2.25]) == [0.75, 1])
        #expect(!head.isPlaying)
    }

    // MARK: - 飛ぶ

    @Test("飛ぶと次のフレームにその位置が出て、流していればそこから進む")
    func jumpLandsOnTheNextFrame() {
        var head = Playhead(duration: 10)
        head.loop()
        #expect(advance(&head, [0, 1]) == [0, 1])
        let accepted = head.jump(to: 7)
        #expect(accepted)
        #expect(head.reported == 7)
        #expect(advance(&head, [2, 2.5]) == [7, 7.5])
    }

    @Test("止めたまま飛ぶと、その位置で止まっている")
    func jumpWhilePausedHolds() {
        var head = Playhead(duration: 10)
        _ = head.jump(to: 3)
        #expect(advance(&head, [1, 2]) == [3, 3])
    }

    @Test("範囲の外は端へ寄せ、数でない値は受け取らない")
    func jumpClampsAndRefusesNonNumbers() {
        var head = Playhead(duration: 4)
        _ = head.jump(to: -5)
        #expect(advance(&head, [0]) == [0])
        _ = head.jump(to: 99)
        #expect(advance(&head, [0]) == [4])
        let refused = [head.jump(to: .nan), head.jump(to: .infinity), head.jump(to: -.infinity)]
        #expect(refused == [false, false, false])
        #expect(head.reported == 4)
        #expect(advance(&head, [0]) == [4])
    }

    @Test("終わりへ飛んでから繰り返すと、頭から流れる")
    func loopAfterJumpingToTheEnd() {
        var head = Playhead(duration: 2)
        _ = head.jump(to: 2)
        _ = head.advance(to: 0)
        head.loop()
        #expect(advance(&head, [1, 1.5]) == [0, 0.5])
    }

    @Test("スケッチの時刻が後ろへ飛んでも、頭より前へは行かない")
    func neverGoesBeforeTheTop() {
        var head = Playhead(duration: 10)
        head.play()
        #expect(advance(&head, [5, 6, 2]) == [0, 1, 0])
    }
}
