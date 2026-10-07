// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeAudio

/// 再生位置の移り変わり (#1979)。純粋な型なので、機材も GPU も要らない。
@Suite("再生位置")
struct PlayheadTests {
    /// 標本の値が「位置 + 1」になる列 (1, 2, 3, …)。窓を見れば、どこを切り出したかが読める。
    /// 0 を含めないので、窓の 0 は「鳴っていない」としか読めない。
    private let indices: [Float] = (0..<2000).map { Float($0 + 1) }

    @Test("1 度だけ鳴らすと、鳴った数だけ進み、終わりまで鳴ったら止まって頭へ戻る")
    func playOnceEndsAtTheEnd() {
        var head = Playhead(length: 2000)
        head.play(looping: false)
        #expect(head.position(after: 800) == 800)
        #expect(!head.hasEnded(after: 1999))
        // 終わりちょうどで鳴り終わる
        #expect(head.hasEnded(after: 2000))
        #expect(head.position(after: 2400) == 2000)
        let early = head.settle(after: 1999)
        #expect(!early)
        #expect(head.isPlaying)
        let ended = head.settle(after: 2000)
        #expect(ended)
        #expect(!head.isPlaying)
        #expect(head.start == 0)
    }

    @Test("止めると位置を覚え、次に鳴らすとそこから。頭へ戻すと頭から")
    func pauseResumesAndStopRewinds() {
        var head = Playhead(length: 2000)
        head.play(looping: false)
        head.pause(after: 700)
        #expect(!head.isPlaying)
        #expect(head.start == 700)
        // 止まっている間は、鳴った数を渡しても動かない
        #expect(head.position(after: 5000) == 700)
        head.play(looping: false)
        #expect(head.position(after: 100) == 800)
        head.stop()
        #expect(head.start == 0)
        head.play(looping: false)
        #expect(head.position(after: 0) == 0)
    }

    @Test("鳴っている最中に鳴らすと、頭から鳴らし直す")
    func playWhilePlayingRestarts() {
        var head = Playhead(length: 2000)
        head.play(looping: true)
        head.pause(after: 500)
        head.play(looping: false)  // 止めた位置から
        #expect(head.start == 500)
        head.play(looping: false)  // 鳴っている最中なので頭から
        #expect(head.start == 0)
        #expect(!head.isLooping)
    }

    @Test("鳴り終わった後で止めると、位置は頭へ戻る")
    func pauseAfterTheEndRewinds() {
        var head = Playhead(length: 2000)
        head.play(looping: false)
        head.pause(after: 2500)
        #expect(head.start == 0)
    }

    @Test("ループは継ぎ目で頭へ戻り、途中から始めても長さで巡る")
    func loopWrapsAtTheSeam() {
        var head = Playhead(length: 2000)
        head.play(looping: true)
        #expect(head.position(after: 1999) == 1999)
        #expect(head.position(after: 2000) == 0)
        #expect(head.position(after: 4300) == 300)
        #expect(!head.hasEnded(after: 10_000))
        let ended = head.settle(after: 10_000)
        #expect(!ended)
        #expect(head.isPlaying)
        head.pause(after: 2300)
        #expect(head.start == 300)
        head.play(looping: true)
        #expect(head.position(after: 1700) == 0)
    }

    @Test("窓は鳴ったところで終わり、区切りの前は 0。ループの継ぎ目では終わりと頭が並ぶ")
    func windowEndsWherePlayed() {
        var head = Playhead(length: 2000)
        // 止まっている間は全部 0
        #expect(head.window(of: indices, after: 500, size: 4) == [0, 0, 0, 0])
        head.play(looping: false)
        #expect(head.window(of: indices, after: 6, size: 4) == [3, 4, 5, 6])
        // 鳴らし始めた直後は、まだ鳴っていない前を 0 で埋める
        #expect(head.window(of: indices, after: 2, size: 4) == [0, 0, 1, 2])
        // 1 度だけなら、終わりより後は 0
        #expect(head.window(of: indices, after: 2002, size: 4) == [1999, 2000, 0, 0])

        head.stop()
        head.play(looping: true)
        #expect(head.window(of: indices, after: 2002, size: 4) == [1999, 2000, 1, 2])

        // 途中から鳴らし直すと、窓は止めた位置から始まる区切りで切る
        head.pause(after: 2700)
        head.play(looping: true)
        #expect(head.start == 700)
        #expect(head.window(of: indices, after: 2, size: 4) == [0, 0, 701, 702])
        #expect(head.window(of: indices, after: 1302, size: 4) == [1999, 2000, 1, 2])
    }

    @Test("長さ 0 を渡しても、1 標本として扱って割り算で落ちない")
    func emptyLengthIsGuarded() {
        var head = Playhead(length: 0)
        head.play(looping: true)
        #expect(head.length == 1)
        #expect(head.position(after: 5) == 0)
    }
}
