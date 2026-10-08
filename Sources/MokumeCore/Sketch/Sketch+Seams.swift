// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 走っているスケッチへ差込口を足す・外す。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {

    /// 入り口を、走っているスケッチへ足す。
    ///
    /// **呼べば使える機能を作るための口である** ([ADR-0042] 決定 2)。カメラのような機能は、
    /// 利用者に ``plugins`` へ書かせず、作る口の中でこれを呼ぶ。外のパッケージも同じ形を
    /// 作れる — 呼べば入る手軽さは、組み込みだけのものではない。
    ///
    /// ```swift
    /// final class Ticker: Inlet {
    ///     private(set) var count = 0
    ///     func supply() { count += 1 }
    /// }
    ///
    /// final class Counting: Sketch {
    ///     let ticker = Ticker()
    ///     func setup() { attach(ticker) }
    ///     func draw() { text("\(ticker.count)", 20, 40) }
    /// }
    /// ```
    ///
    /// 機能を作る側は、同じ呼び出しを作る口 (`createCapture()` のような) の中に置く。
    ///
    /// - 呼んだ時点で ``Inlet/open()`` する。投げたら診断に出して `false` を返す
    ///   ([ADR-0024] 決定 7)
    /// - `setup()` や入力のコールバックの中で足せば、そのフレームの `draw()` の前から
    ///   ``Inlet/supply()`` が呼ばれる。`draw()` の中で足せば、次のフレームから
    /// - 同じものを 2 度足しても 1 つのまま (開き直さない)
    /// - ``Inlet/supply()`` の中から頼んだときは、その巡回が終わってから開いて足す
    ///   (戻り値は `true`。開けなければ診断に出る)
    /// - ``plugins`` で宣言したものと同じ並びに入る。閉じるのは ``detach(_:)-(Inlet)`` か、
    ///   スケッチの終わり
    ///
    /// 下の例は、呼ばれた回数を数える入り口を 3 つ足し、数を棒の長さにしている。上の 2 つは
    /// `setup()` で足し (中の 1 つは 2 度足す)、下の 1 つは 30 フレーム目の `draw()` で足す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     let early = Ticker()
    ///     let twice = Ticker()
    ///     let late = Ticker()
    ///
    ///     func setup() {
    ///         attach(early)
    ///         attach(twice)
    ///         attach(twice)
    ///     }
    ///
    ///     func draw() {
    ///         if frameCount == 30 { attach(late) }
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         rect(20, 20, early.count * 6, 30)
    ///         fill(89, 166, 242)
    ///         rect(20, 60, twice.count * 6, 30)
    ///         fill(242, 217, 89)
    ///         rect(20, 100, late.count * 6, 30)
    ///     }
    ///
    ///     final class Ticker: Inlet {
    ///         private(set) var count = 0
    ///         func supply() { count += 1 }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上から橙・水色・黄色の棒。橙と水色は同じ速さで伸びて最後まで同じ長さのままで、2 度足した水色も速くならない。黄色は 30 フレーム目に足された後、次のフレームから遅れて伸び始める | size=400x150 frames=60 -->
    ///     ![上から橙・水色・黄色の棒。橙と水色は同じ速さで伸びて最後まで同じ長さのままで、2 度足した水色も速くならない。黄色は 30 フレーム目に足された後、次のフレームから遅れて伸び始める](https://i.gyazo.com/42a568b99fd062dbb0370d220886ecb4.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (中で起こした `Task` を含む) からは
    /// 頼めない。頼んでも足さずに診断に出し、`false` を返す。
    ///
    /// - Returns: 並びに居るか。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    /// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
    // shot: 1 snippet=5e96e124
    @discardableResult
    public func attach(_ inlet: any Inlet) -> Bool {
        guard let runtime = runningSketch else {
            Diagnostics.warn(OutsideCall.attach.notice)
            return false
        }
        return runtime.attach(inlet)
    }

    /// 出口を、走っているスケッチへ足す。
    ///
    /// 決まりは ``attach(_:)-(Inlet)`` と同じ。**受け取るのは、足したフレームから後に描いた
    /// 絵だけである** — 足す前に描かれた絵は渡さない。
    ///
    /// 下の例は、受け取ったフレームの番号を控える出口を 20 フレーム目に足し、描いたフレーム
    /// (上の列) と出口が受け取ったフレーム (下の列) を、番号の位置に 1 本ずつ並べている。
    /// 出口が絵を受け取るのはそのフレームを描き終えた後なので、`draw()` から見ると下の列は
    /// 上の列より遅れて伸びる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     let tape = Tape()
    ///
    ///     func draw() {
    ///         if frameCount == 20 { attach(tape) }
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(90)
    ///         for frame in 1...frameCount { rect(14 + frame * 6, 30, 4, 30) }
    ///         fill(242, 115, 64)
    ///         for frame in tape.frames { rect(14 + frame * 6, 80, 4, 30) }
    ///     }
    ///
    ///     final class Tape: Outlet {
    ///         private(set) var frames: [Int] = []
    ///         func receive(_ frame: OutputFrame) { frames.append(frame.frame) }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の目盛りは描いたフレーム、橙色の目盛りは出口が受け取ったフレームで、同じ番号は同じ横の位置に並ぶ。橙は 20 フレーム目の位置から始まって左が空いたままになり、灰色より少し遅れて伸びる | size=400x150 frames=60 -->
    ///     ![灰色の目盛りは描いたフレーム、橙色の目盛りは出口が受け取ったフレームで、同じ番号は同じ横の位置に並ぶ。橙は 20 フレーム目の位置から始まって左が空いたままになり、灰色より少し遅れて伸びる](https://i.gyazo.com/a33bf44b12d9a99320d04c68b2e5a143.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Returns: 並びに居るか。
    // shot: 1 snippet=88bc7e3f
    @discardableResult
    public func attach(_ outlet: any Outlet) -> Bool {
        guard let runtime = runningSketch else {
            Diagnostics.warn(OutsideCall.attach.notice)
            return false
        }
        return runtime.attach(outlet)
    }

    /// 入り口を外して閉じる。
    ///
    /// ``Inlet/close()`` を 1 度だけ呼び、以後 ``Inlet/supply()`` は呼ばれない。並びに
    /// 居なければ何もしない。``Inlet/supply()`` の中から頼んだときは、その巡回が終わって
    /// から外す。
    ///
    /// 下の例は、呼ばれた回数を数える入り口を `setup()` で足し、30 フレーム目の `draw()` で
    /// 外している。上の灰色の棒はフレームの数、下の棒は入り口が数えた回数で、閉じた入り口は
    /// 色を変える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     let ticker = Ticker()
    ///
    ///     func setup() {
    ///         attach(ticker)
    ///     }
    ///
    ///     func draw() {
    ///         if frameCount == 30 { detach(ticker) }
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(90)
    ///         rect(20, 30, frameCount * 6, 30)
    ///         if ticker.isClosed { fill(89, 166, 242) } else { fill(242, 115, 64) }
    ///         rect(20, 80, ticker.count * 6, 30)
    ///     }
    ///
    ///     final class Ticker: Inlet {
    ///         private(set) var count = 0
    ///         private(set) var isClosed = false
    ///         func supply() { count += 1 }
    ///         func close() { isClosed = true }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上の灰色の棒は最後まで伸び続ける。下の橙色の棒は同じ速さで伸びるが、30 フレーム目で外されるとそこで止まり、閉じたので水色に変わる | size=400x150 frames=60 -->
    ///     ![上の灰色の棒は最後まで伸び続ける。下の橙色の棒は同じ速さで伸びるが、30 フレーム目で外されるとそこで止まり、閉じたので水色に変わる](https://i.gyazo.com/f30714e3f641c3797bab6ae218c67192.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=4e5e0378
    public func detach(_ inlet: any Inlet) {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.detach.notice)
        }
        runtime.detach(inlet)
    }

    /// 出口を外して閉じる。決まりは ``detach(_:)-(Inlet)`` と同じ。
    ///
    /// 下の例は、受け取ったフレームの番号を控える出口を `setup()` で足し、40 フレーム目の
    /// `draw()` で外している。上の列は描いたフレーム、下の列は出口が受け取ったフレームで、
    /// 閉じた出口は色を変える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     let tape = Tape()
    ///
    ///     func setup() {
    ///         attach(tape)
    ///     }
    ///
    ///     func draw() {
    ///         if frameCount == 40 { detach(tape) }
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(90)
    ///         for frame in 1...frameCount { rect(14 + frame * 6, 30, 4, 30) }
    ///         if tape.isClosed { fill(89, 166, 242) } else { fill(242, 115, 64) }
    ///         for frame in tape.frames { rect(14 + frame * 6, 80, 4, 30) }
    ///     }
    ///
    ///     final class Tape: Outlet {
    ///         private(set) var frames: [Int] = []
    ///         private(set) var isClosed = false
    ///         func receive(_ frame: OutputFrame) { frames.append(frame.frame) }
    ///         func close() { isClosed = true }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上の灰色の目盛りは最後まで増え続ける。下の橙色の目盛りは少し遅れて増えるが、40 フレーム目で外されると増えなくなり、閉じたので水色に変わる | size=400x150 frames=60 -->
    ///     ![上の灰色の目盛りは最後まで増え続ける。下の橙色の目盛りは少し遅れて増えるが、40 フレーム目で外されると増えなくなり、閉じたので水色に変わる](https://i.gyazo.com/b35dabb2e53fb4763078c902e889a127.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=751061ce
    public func detach(_ outlet: any Outlet) {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.detach.notice)
        }
        runtime.detach(outlet)
    }
}
