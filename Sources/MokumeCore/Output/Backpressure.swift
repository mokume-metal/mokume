// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 抱える枚数に上限を置き、上限に達したら**頼む側を待たせる**。
///
/// 書き込みが追いつかないとき、待つのは頼む側である ([ADR-0023] 決定 5 と同じ姿勢 —
/// 長く回したときにだけ重くなる形を作らない)。上限に達すると ``take()`` が返らなくなるので、
/// 遅いディスクではフレームが遅くなる。**代わりにメモリは伸びない。**
///
/// ## なぜ 1 つなのか
///
/// 静止画 (``FrameWriter``) と動画 (``MovieWriter``) が別々に持っていた。取り込みの 5 行が
/// 逐語同文だったが、**それは畳む理由ではない** ([ADR-0008] 決定 6)。畳んだのは
/// **順序が不変条件**だからである。
///
/// 仕事の側は「終わりの合図を先に、枠を後に」出さなければならない。逆にすると、待っていた
/// 側が起きた時点でまだ合図が出ておらず、抱えている数を数え損なう。数え損なうと
/// ``drain()`` が**書き終わる前に返る** — ファイルが欠けたまま「書けた」ことになる。
/// 片方だけ順序が入れ替わってもコンパイルは通り、検査も通る。順序は ``Release`` の
/// 1 箇所に閉じ込めてある。
///
/// ## 待つのをやめる期限がある
///
/// ``drain()`` の待ちには期限がある。**外の何かが永久に用意できないと、待ちが永久に
/// 終わらない**からである (返らないディスク・返らない符号化)。待つのは main actor の上なので、
/// 固まると絵も観測も入力も一緒に黙り、プロセスを殺すしかなくなる。
///
/// 期限は**総時間ではなく「1 つも進まなくなってから」**を測る。総時間で測ると、長く撮った
/// 動画の符号化を、進んでいるのに諦めることになる。
///
/// **``take()`` には期限を置かない。** そこに期限を置くことは「上限に達したらフレームを
/// 落とす」という意味になり、このパッケージが選んでいる「待たせる」の反対側になる。時刻は
/// フレーム自身のものなので、遅れても絵を落とす理由が無い ([ADR-0025] 決定 2)。
///
/// ## 待ち方は 2 通りあるが、期限の測り方は 1 つ
///
/// 塞いで待つ (``Patience/block``) のは `endRecord()` の経路で、利用者の同期の `draw()` から
/// 呼ばれるので塞ぐしかない。終わりの経路は塞がずに見に来る (``Patience/peek``・[#978])。
/// **測り方をそれぞれに書かない** — 片方だけが「総時間で測る」へ戻っても、どちらの検査も
/// 通ってしまう。
///
/// [#978]: https://github.com/mokume-metal/mokume/issues/978
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
final class Backpressure {
    /// 同時に抱える枚数の既定の上限。
    ///
    /// 960x540 なら 1 枚あたり約 2 MB なので、既定では 8 MB を上限に抱える。
    static let defaultLimit = 4

    /// **1 つも進まなくなった**とみなすまでの既定の秒数。
    ///
    /// ``RenderDevice/waitLimitSeconds`` と同じ 5 秒にしてある。あちらは GPU の完了を待つ
    /// 上限で、こちらは書き込みが 1 つ進む間隔 — 測っているものは違うが、**どちらも
    /// 「これだけ音沙汰が無ければ壊れている」の見立て**なので、2 つの数を持たない。
    static let defaultStallLimitSeconds = 5.0

    /// 仕事の側が「1 つ終わった」と言う口。**隔離の外へ渡せる。**
    ///
    /// 背圧そのものを渡さないのは、隔離の外から数を触らせないためである。ここが渡すのは
    /// 2 つの合図だけで、**出す順**を持っている。
    nonisolated struct Release: Sendable {
        fileprivate let finished: DispatchSemaphore
        fileprivate let slots: DispatchSemaphore

        /// 1 つ終わった。
        ///
        /// **終わりの合図を先に、枠を後に出す。** 枠を先に返すと、待っていた側が起きた
        /// 時点でまだ終わりの合図が出ておらず、抱えている数を数え損なう。
        func callAsFunction() {
            finished.signal()
            slots.signal()
        }
    }

    /// 空いている枠。**取れなければ待つ** — これが背圧そのものである。
    private let slots: DispatchSemaphore
    /// 終わった数。``drain()`` はこれを投げた本数ぶん受け取る。
    private let finished = DispatchSemaphore(value: 0)

    /// 抱えている数の上限。
    let limit: Int
    /// 1 つも進まなくなったとみなすまでの秒数。
    let stallLimitSeconds: Double
    /// いま抱えている数 (取り込み済みの完了を差し引いたもの)。
    private(set) var outstanding = 0
    /// 抱えた数の最大。**背圧が効いたことを検査から見るための目印。**
    private(set) var peak = 0
    /// 待っている最中の、最後に 1 つ進んだ時刻。**決着したら消す** — 次に待つときは測り直す。
    ///
    /// 持っているのは ``Patience/peek`` で呼び直されたときに続きから測るためである。呼ぶ
    /// たびに測り直すと、見に来る間隔が期限より短い限り、止まった相手を永久に諦めない。
    ///
    /// 時計は semaphore の期限と同じ `DispatchTime` に揃える (スリープ中は進まない)。
    private var lastProgressAt: DispatchTime?

    init(
        limit: Int = Backpressure.defaultLimit,
        stallLimitSeconds: Double = Backpressure.defaultStallLimitSeconds
    ) {
        self.limit = max(1, limit)
        self.stallLimitSeconds = stallLimitSeconds
        slots = DispatchSemaphore(value: self.limit)
    }

    /// **枠を戻してから手放す。**
    ///
    /// `DispatchSemaphore` は作ったときの値より小さいまま解放すると落ちる (libdispatch が
    /// 「Semaphore object deallocated while in use」で止める)。抱えたまま手放される道は
    /// **``drain()`` に期限を置いたことで初めて通れるようになった** — 諦めると
    /// ``outstanding`` が残るからである。ここで戻さないと、固まりを直した代わりに落ちる。
    isolated deinit {
        for _ in 0..<outstanding { slots.signal() }
    }

    /// 仕事の側へ渡す口。
    var release: Release { Release(finished: finished, slots: slots) }

    /// 枠を 1 つ取る。**上限に達していたら、空くまで返らない。**
    func take() {
        harvest()
        slots.wait()
        // 枠が空いたということは、終わったものが 1 つ以上ある。取り込んでおかないと
        // 抱えている数が実態より多いままになる
        harvest()

        outstanding += 1
        peak = max(peak, outstanding)
    }

    /// 終わっているものを取り込む。**待たない。**
    func harvest() {
        while outstanding > 0, finished.wait(timeout: .now()) == .success {
            outstanding -= 1
        }
    }

    /// 抱えている全部が終わるまで待つ。**1 つも進まなくなったら諦める。**
    ///
    /// 2 度呼んでも安全 (抱えている数が 0 なら何もしない)。
    ///
    /// - Returns: 諦めたときに**まだ残っていた数**。全部終わったなら `nil`。
    func drain() -> Int? {
        drain(.block)
        return outstanding > 0 ? outstanding : nil
    }

    /// 抱えている全部が終わるのを、選んだ待ち方で待つ。**1 つも進まなくなったら諦める。**
    ///
    /// 諦めたかどうかは ``outstanding`` が 0 でないことで分かる。
    ///
    /// - Parameter patience: まだ終わっていないとき、塞いで待つか、その場で返るか。
    /// - Returns: 決着したか (全部終わった・諦めた)。``Patience/block`` なら必ず `true`。
    @discardableResult
    func drain(_ patience: Patience) -> Bool {
        var lastProgress = lastProgressAt ?? .now()
        while true {
            let before = outstanding
            harvest()
            if outstanding < before { lastProgress = .now() }
            let deadline = lastProgress + stallLimitSeconds
            // **諦めても 0 に戻さない。** 諦めた後に仕事が終わって合図を出すので、戻して
            // おくと次の取り込みがその合図を数えて、抱えている数が実態より小さくなる。
            // 残しておけば、次に待つときが正しくまた待つ
            if outstanding == 0 || DispatchTime.now() >= deadline {
                lastProgressAt = nil
                return true
            }
            guard case .block = patience else {
                lastProgressAt = lastProgress
                return false
            }
            if finished.wait(timeout: deadline) == .success {
                outstanding -= 1
                lastProgress = .now()
            }
        }
    }
}

/// 終わりを待つときの、待ち方。
///
/// **変わるのは「まだ終わっていないときに塞ぐか」だけで、期限の測り方は変わらない**
/// (``Backpressure`` の「待ち方は 2 通りあるが、期限の測り方は 1 つ」)。
///
/// `async` にしないのは、終わりの経路が main actor に頼れないためである。`terminate(_:)` が
/// main actor の仕事の中から呼ばれると、AppKit が返事を待って run loop を回している間も
/// main キューは入れ子では捌かれず、`await` の続きが永久に来ない ([#978] で実測)。
///
/// [#978]: https://github.com/mokume-metal/mokume/issues/978
nonisolated enum Patience: Sendable {
    /// 終わるか諦めるまで塞いで待つ。`endRecord()` の経路 (利用者の `draw()` は同期)。
    case block
    /// 塞がずに見て、まだならその場で返る。終わりの経路 ([#978])。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    case peek
}
