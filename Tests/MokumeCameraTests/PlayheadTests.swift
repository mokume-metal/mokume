// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCamera

/// 動画のどこを映すか (#1960)。時計にも AVFoundation にも触れないので、GPU も動画も要らない。
@Suite("動画の再生位置")
nonisolated struct PlayheadTests {
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

    @Test("止まっている間に、同じフレームで終わりへ飛んで流すと、頭から流れる (フレームを分けても同じ)")
    func playRightAfterJumpingToTheEndStartsFromTheTop() {
        // 同じフレーム: 飛び先がまだ受け付けられていない間に流す
        var sameFrame = Playhead(duration: 2)
        _ = sameFrame.jump(to: 2)
        sameFrame.play()
        #expect(sameFrame.reported == 0, "飛び先の終わりを残さない")
        #expect(advance(&sameFrame, [0, 0.5, 1]) == [0, 0.5, 1])
        #expect(sameFrame.isPlaying)
        // フレームを分ける: 飛び先を映してから流す
        var split = Playhead(duration: 2)
        _ = split.jump(to: 2)
        #expect(advance(&split, [0]) == [2])
        split.play()
        #expect(advance(&split, [1, 1.5]) == [0, 0.5])
        // 範囲の外 (長さより先) も同じ
        var beyond = Playhead(duration: 2)
        _ = beyond.jump(to: 5)
        beyond.play()
        #expect(advance(&beyond, [0, 0.5]) == [0, 0.5])
        // 終わりの手前へ飛んで流すなら、その位置から
        var near = Playhead(duration: 2)
        _ = near.jump(to: 1.5)
        near.play()
        #expect(advance(&near, [0, 0.25]) == [1.5, 1.75])
        // 流してから飛ぶ (終わりへ) のは、そのまま終わりを映す
        var after = Playhead(duration: 2)
        after.play()
        _ = after.jump(to: 2)
        #expect(advance(&after, [0]) == [2])
    }

    @Test("スケッチの時刻が後ろへ飛んでも、頭より前へは行かない")
    func neverGoesBeforeTheTop() {
        var head = Playhead(duration: 10)
        head.play()
        #expect(advance(&head, [5, 6, 2]) == [0, 1, 0])
    }

    // MARK: - 状態を進めずに覗く (#2357)

    @Test("覗く位置は、状態を進めずに、起点から指定の時刻のぶんだけ先を返す")
    func positionAtPeeksWithoutAdvancing() {
        var head = Playhead(duration: 3)
        head.play()
        _ = head.advance(to: 1)  // 起点 (時刻 1 で位置 0)
        let before = head
        // 長さを越える時刻でも終わりのコマ。状態 (再生中・起点) は変わらない
        #expect(head.position(at: 5) == 3)
        #expect(head.position(at: 1.5) == 0.5)
        #expect(head.position(at: 0) == 0, "起点より前の時刻は頭")
        #expect(head == before, "覗いただけで状態が動いた")
        #expect(head.isPlaying)
        #expect(head.advance(to: 1.5) == 0.5, "覗いた後も、進めれば作者の時刻のぶんだけ進む")
    }

    @Test("覗く位置は、ループなら折り返し、止めていればいまの位置")
    func positionAtFollowsLoopingAndPause() {
        var looping = Playhead(duration: 3)
        looping.loop()
        _ = looping.advance(to: 0)
        #expect(looping.position(at: 4) == 1)
        var paused = Playhead(duration: 3)
        paused.play()
        _ = paused.advance(to: 0)
        _ = paused.advance(to: 1)
        paused.pause()
        #expect(paused.position(at: 9) == 1)
    }

    /// 観測でない枚では、覗いた位置と進めた位置は同じ (映す位置を二通りに数えない)。
    @Test("同じ時刻なら、覗く位置は進めた位置と一致する")
    func positionAtAgreesWithAdvance() {
        for looping in [false, true] {
            var head = Playhead(duration: 2.5)
            looping ? head.loop() : head.play()
            for frame in 1...120 {
                let t = time(frame, fps: 30)
                let advanced = head.advance(to: t)
                #expect(head.position(at: t) == advanced, "\(looping ? "loop" : "play") \(frame) 枚目")
            }
        }
    }

    /// 作者の時計の秒でちょうど終わりに達する枚でも、観測の秒が手前なら、手前のコマを映す
    /// (終わりに達した枚は止まった状態になるが、その枚の起点から数え直す)。
    @Test("その枚で終わりに達しても、手前の時刻を覗けば手前の位置")
    func positionAtCountsBackWhenTheFrameReachedTheEnd() {
        var head = Playhead(duration: 3)
        head.play()
        _ = head.advance(to: 0)  // 起点
        #expect(head.advance(to: 3) == 3)  // 作者の時計の 3 秒で終わりに達する
        #expect(!head.isPlaying)
        #expect(head.position(at: 0.2) == 0.2)
        #expect(head.position(at: 9) == 3)
        // 次の枚は、止まった状態のまま
        #expect(head.advance(to: 4) == 3)
        #expect(head.position(at: 0.2) == 3, "覗く元が古い枚の起点のまま")
    }
}
