// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import QuartzCore

/// 時刻の出どころ。
///
/// フレームを進める仕組みと、時刻をどこから取るかは別の話である。同じ進め方でも
/// 時刻の出どころを変えれば、絵が再現するかどうかが変わる。
public enum Clock: Equatable, Sendable {
    /// 実際に流れた時間。画面に出しながら動かすときの既定。
    case wallClock

    /// フレーム番号から導く。
    ///
    /// **同じスケッチを 2 回走らせると、同じ絵になる。** 実時間を混ぜると、走らせる
    /// たびに数フレームぶんずれた絵が出る — 機械が「変わっていない」と言えなくなる。
    case frameIndex(frameRate: Int)
}

/// 時刻を配り、フレームの進みを数える。
///
/// 実時間で動かすときの落とし穴を 1 つ引き受ける: **止めている間も実時間は進む。**
/// 止めて再開したとき起点を寄せ直さないと、止めていた時間まるごとが 1 フレームの
/// 経過時間として渡り、それを積分に使う側は 1 回で破綻する。``resync()`` がその役。
@MainActor
final class FrameTiming {
    private let clock: Clock
    /// 実時間の出どころ。検査が時間を操れるよう差し替えられる形にしてある。
    private let now: () -> Double
    private let started: Double
    private var previous: Double

    /// これまでに進めたフレームの数。最初のフレームの最中は 1。
    private(set) var frameCount = 0
    /// いまのフレームの時刻 (秒)。
    private(set) var time: Float = 0
    /// 前のフレームからの経過 (秒)。
    private(set) var deltaTime: Float = 0

    init(clock: Clock, now: @escaping () -> Double = { CACurrentMediaTime() }) {
        self.clock = clock
        self.now = now
        let start = now()
        self.started = start
        self.previous = start
    }

    /// フレームを 1 つ進め、時刻を更新する。
    func advance() {
        let now = now()
        frameCount += 1
        switch clock {
        case .wallClock:
            let elapsed = now - started
            time = Float(elapsed)
            deltaTime = Float(max(0, now - previous))
            previous = now
        case .frameIndex(let frameRate):
            let rate = Double(max(1, frameRate))
            // 最初のフレームを 0 秒にする
            time = Float(Double(frameCount - 1) / rate)
            deltaTime = Float(1 / rate)
        }
    }

    /// フレームを 1 枚も進めずに時刻だけが進んだときに、起点を寄せ直す。
    ///
    /// 実時間で動かしているときにしか効かない — フレーム番号から導く時刻は
    /// そもそも実時間に依存しないので、寄せ直すものがない。
    func resync() {
        previous = now()
    }
}
