// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 走っているスケッチへ差込口を足す・外す。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension SketchPart {

    /// 入り口を、走っているスケッチへ足す。
    ///
    /// **呼べば使える機能を作るための口である** ([ADR-0042] 決定 2)。カメラのような機能は、
    /// 利用者に ``Sketch/plugins`` へ書かせず、作る口の中でこれを呼ぶ。外のパッケージも同じ形を
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
    /// 機能を作る側は、同じ呼び出しを作る口の中に置く。**返す `false` を捨てない** — 走っている実行の外から
    /// 呼ばれると足されず、捨てた口は生きていない入り口を黙って返す。足せたかを見て、足せなければ作る口が
    /// 自分の名前で断る。このリポジトリのパッケージの作る口は、確かめて足すまでを 1 回で行う内部の道具を通り、
    /// 素の `attach` を呼ばない (#2794)。
    ///
    /// - 呼んだ時点で ``Inlet/open()`` する。投げたら診断に出して `false` を返す
    ///   ([ADR-0024] 決定 7)
    /// - `setup()` や入力のコールバックの中で足せば、そのフレームの `draw()` の前から
    ///   ``Inlet/supply()`` が呼ばれる。`draw()` の中で足せば、次のフレームから
    /// - 同じものを 2 度足しても 1 つのまま (開き直さない)
    /// - ``Inlet/supply()`` の中から頼んだときは、その巡回が終わってから開いて足す
    ///   (戻り値は `true`。開けなければ診断に出る)
    /// - ``Sketch/plugins`` で宣言したものと同じ並びに入る。閉じるのは ``detach(_:)-(Inlet)`` か、
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
            OutsideRun.log.warn(.attach)
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
            OutsideRun.log.warn(.attach)
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
    /// **走っている実行の中で起こした `Task` の続きからも外せる** (`Task.detached` からも)。足した実行を
    /// 差込口が控えているので、実行が走っている間は、呼んだ場所によらず外れる。`setup()`・`draw()`・
    /// 入力のコールバックの外でも効くのは、**足した実行が走っている間だけ**である。足していない入り口と、
    /// スケッチが終わった後 (終わりの処理が既に閉じている) は何もせず、そのことを診断に出す。
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
        guard let runtime = SeamHomes.runtime(of: inlet) ?? runningSketch else {
            return OutsideRun.log.warn(.detach)
        }
        runtime.detach(inlet)
    }

    /// 出口を外して閉じる。決まりは ``detach(_:)-(Inlet)`` と同じ。
    ///
    /// 下の例は、受け取ったフレームの番号を控える出口を `setup()` で足し、40 フレーム目の
    /// `draw()` で外している。上の列は描いたフレーム、下の列は出口が受け取ったフレームで、
    /// 閉じた出口は色を変える。
    ///
    /// **外す直前に描き終えた絵は、外す出口に渡してから閉じる。** 出口へは、描き終えた絵が 1 枚遅れて
    /// 渡る (次のフレームの終わりか、スケッチの終わりで届く) ので、そのまま閉じると最後の 1 枚が
    /// 届かない。下の例で 40 フレーム目に外すと、出口は 39 フレーム目までを受け取ってから閉じる
    /// (連番を書き出す出口なら、最後の 1 枚が欠けない)。渡すのは外す出口だけで、ほかの出口は今までどおり
    /// 次のフレームの終わりで同じ絵を受け取る。足したフレームより前に描いた絵は、外すときにも渡さない
    /// (``attach(_:)-(Outlet)``)。
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
        guard let runtime = SeamHomes.runtime(of: outlet) ?? runningSketch else {
            return OutsideRun.log.warn(.detach)
        }
        runtime.detach(outlet)
    }
}

// 外のモジュールの作る口 (MokumeAudio・MokumeNetwork の `loadSound`・`createTCPServer` など) が使う入口 ([#2740])。
//
// **呼んだ口の名前で言う。** 公開の ``SketchPart/attach(_:)-(Inlet)`` を素で呼ぶと、足せない所での警告が
// 利用者の呼んでいない `attach()` を名乗り、投げる口も黙って生きていないものを返す。
//
// [#2740]: https://github.com/mokume-metal/mokume/issues/2740
extension SketchPart {
    /// 走っている実行へ入り口を足せる所から呼ばれたかを確かめる (投げる作る口)。足せなければ、`call` の名前で
    /// 1 度だけ警告して `notRunning(call:)` を投げる (文面は ``OutsideRun/notAttachedNotice(_:)``)。
    ///
    /// ファイルを読む・ポートを開く前に呼ぶ。**作る口が直に呼ぶのではなく、確かめて足すまでを 1 回で行う
    /// ``attached(_:calledAs:making:)`` が呼ぶ** (確かめと足すを分けると、足した結果の `false` を捨てる古い形を写す・#2794)。
    /// #2683 の ``requireSurface(_:calledAs:)`` と同じ形で、理由が面でないことだけが違う。
    package func requireAttachable<Failure: NotRunningFailure>(
        _ failure: Failure.Type, calledAs call: String
    ) throws(Failure) {
        guard runningSketch != nil else {
            // 投げるだけでは `try?` で受けた側に何も残らないので、口ごとに 1 度言う
            OutsideRun.log.warn(call, .thrownUnattached)
            throw Failure.notRunning(call: call)
        }
    }

    /// **確かめて、作って、足すまでを 1 回で行う** (投げる作る口・[#2794])。足せなければ、作る前に ``requireAttachable(_:calledAs:)`` と
    /// 同じく `call` の名前で 1 度だけ警告して `notRunning(call:)` を投げる。足せる所なら `make` で入り口を作り、足して返す。
    ///
    /// **作る口は、公開の ``attach(_:)-(Inlet)`` を素で呼ばず、これを通る。** 素の `attach` は足せなかったとき
    /// (`false`) を返すだけで、呼ぶ側が捨てると黙って生きていない入り口を返す。確かめるのと足すのが 2 回の呼びに
    /// 分かれると、新しい口が古い形を写す (#2297・#2295)。写しは `scripts/check-attach-result.py` が `ci-static` で赤くする。
    ///
    /// 足した結果の `false` は、ここで 1 か所だけ捨てる (`attachAfterCheck(_:)`)。`false` になるのは、閉じた後で断られたとき
    /// (入り口の `state` は変わらず、診断に 1 行だけ出る) と、`open()` が投げたとき (入り口の `state` が言う。ポートが
    /// 使用中なら `unavailable` など) で、どちらも作る口は作ったものをそのまま返す。
    ///
    /// - Parameters:
    ///   - failure: 投げる型。呼ぶ口の `throws` の型を渡す。
    ///   - call: エラーと警告に載せる口の名前。呼ぶ側の `#function` が入る。
    ///   - make: 入り口を作る。ファイルを読む・ポートを開く仕事は、確かめた後のここに置く。
    ///
    /// [#2794]: https://github.com/mokume-metal/mokume/issues/2794
    package func attached<Failure: NotRunningFailure, Part: Inlet>(
        _ failure: Failure.Type, calledAs call: String, making make: () throws(Failure) -> Part
    ) throws(Failure) -> Part {
        try requireAttachable(failure, calledAs: call)
        return attachAfterCheck(try make())
    }

    /// ``attached(_:calledAs:making:)`` の、作るのが投げない口。足せない所で投げるのは確かめだけ。
    package func attached<Failure: NotRunningFailure, Part: Inlet>(
        _ failure: Failure.Type, calledAs call: String, making make: () -> Part
    ) throws(Failure) -> Part {
        try requireAttachable(failure, calledAs: call)
        return attachAfterCheck(make())
    }

    /// ``attached(_:calledAs:making:)`` の、**面を取れる所かを確かめる** 版 (投げる作る口・[#2794])。絵の置き場 (面) の上に
    /// 作る入り口 (``Capture``・``Movie``) の道具である。
    ///
    /// 確かめるのは ``requireSurface(_:calledAs:)`` で、外で呼んだときの警告は資源を作る口の名乗り (`thrown`) のまま変わらない
    /// (``attached(_:calledAs:making:)`` の確かめは、足せない所の名乗り `thrownUnattached` になる)。面を取れなければ
    /// `make` の前に断るので、ファイルを開くなどの重い仕事も走らない。**確かめは道具自身が行う** — 作る側が先に確かめたことを
    /// 前提にしない。足した結果の `false` は ``attached(_:calledAs:making:)`` と同じ 1 か所で捨てる。
    ///
    /// [#2794]: https://github.com/mokume-metal/mokume/issues/2794
    package func attachedOnSurface<Failure: NotRunningFailure, Part: Inlet>(
        _ failure: Failure.Type, calledAs call: String, making make: () throws(Failure) -> Part
    ) throws(Failure) -> Part {
        try requireSurface(failure, calledAs: call)
        return attachAfterCheck(try make())
    }

    /// 確かめた所から、作った入り口を続けて足す。**足せなかった結果 (`false`) を捨てるのは、作る口の道具のうちここだけ**で、
    /// ``attached(_:calledAs:making:)``・``attachedOnSurface(_:calledAs:making:)`` だけが呼ぶ。確かめてから続けて呼ぶので足せる。
    private func attachAfterCheck<Part: Inlet>(_ part: Part) -> Part {
        _ = attach(part)
        return part
    }

    /// 走っている実行へ入り口を足せる所から呼ばれたかを確かめる (投げない作る口)。足せなければ、`call` の名前で
    /// 1 度だけ警告して `false` を返す。`value` は、代わりに返すものの人が読む綴り。
    ///
    /// 返すものが 0 個かもしれない口 (`gamepads()` は繋がっているパッドの数だけ足す) が、数に依らず外なら 1 度言うために、
    /// 先に呼ぶ。足すのはその後の ``attach(_:calledAs:returning:)`` で、同じ口の名前・同じ綴りなら重ねて言わない。
    package func canAttach(calledAs call: String, returning value: String) -> Bool {
        guard runningSketch != nil else {
            OutsideRun.log.warn(call, .make(returning: value))
            return false
        }
        return true
    }

    /// 入り口を、走っている実行へ足す (投げない作る口)。足せない所から呼ばれたら、`attach()` ではなく `call` の
    /// 名前で 1 度だけ警告し、`false` を返す。`value` は、代わりに返したものの人が読む綴り
    /// (`a sound that is never heard` など)。
    @discardableResult
    package func attach(_ inlet: any Inlet, calledAs call: String, returning value: String) -> Bool {
        guard let runtime = runningSketch else {
            OutsideRun.log.warn(call, .make(returning: value))
            return false
        }
        return runtime.attach(inlet)
    }

    /// 入り口を、走っている実行から外す (止める口 `stop()`)。外から呼ばれたら、利用者が呼んでいない `detach()` ではなく
    /// `call` の名前で 1 度だけ警告し、何もしない ([#2793])。
    ///
    /// 走っている実行が足した入り口なら、`Task` の中からでも外れる (``detach(_:)-(Inlet)`` と同じ)。外で断るのは、足していない入り口と
    /// 後片付けの後だけで、変わるのは名乗りだけである。`call` は型を付けた口の名前
    /// (`AudioIn.stop()` など)。型を付けるのは、``OutsideRun`` が口の名前ごとに 1 度だけ言うので、`Task` の中で
    /// `mic.stop(); camera.stop()` と続けて呼んだとき、先に言った型が後の型を黙らせないためである
    /// (`Countdown.restart()` と同じ)。警告は「何もしなかった」と言う (``OutsideRun/Use/act``) ので、呼んだ場所が `Task` の中でも、
    /// スケッチが終わった後 (終わりの処理が既に閉じている) でも事実である。
    ///
    /// [#2793]: https://github.com/mokume-metal/mokume/issues/2793
    package func detach(_ inlet: any Inlet, calledAs call: String) {
        guard let runtime = SeamHomes.runtime(of: inlet) ?? runningSketch else {
            return OutsideRun.log.warn(call, .act)
        }
        runtime.detach(inlet)
    }
}
