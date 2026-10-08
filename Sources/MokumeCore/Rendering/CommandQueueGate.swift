// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Synchronization

/// コマンドの発行口 (`MTL4CommandQueue`) を作る関所。**GPU が一度答えなくなったプロセスでは、もう作らない**
/// ([#2052])。
///
/// ## なぜ要るか
///
/// 発行口を作る場所は 2 つある — ``RenderDevice`` の初期化子と、``RenderDevice/isAvailable`` の
/// 使い捨てである。どちらも、GPU が答えていなくても作れてしまう。#2052 では、GPU が詰まった後も
/// 検査が次の手順を約 5 分繰り返した。
///
/// 1. 待ちを期限 (``RenderDevice/waitLimitSeconds``) で打ち切る
/// 2. 土台を畳む
/// 3. 次の検査が新しい土台を作る
///
/// これで止まった発行口が溜まり (カーネルの中で止まった発行のスレッドが約 37 本)、画面の描画
/// (WindowServer) ごと機械が止まって、カーネルパニックになった (推定・確度は中〜高)。並列の幅を 1 に
/// しても、直列に溜まった。
///
/// ## 何をするか
///
/// **印は一方向で、一度立てたら下ろさない。** 立てるのは、合図の待ちが期限を越えたとき
/// (`RenderDevice` の `signalReached(_:)` — GPU の待ち 4 つがすべて通る 1 本) である。
/// 印が立つと、``makeQueue(on:)`` は作らずに ``RenderFailure/gpuNotResponding`` で断る。
/// 回復したかを見て下ろす形は採らない。GPU が答えるようになったかを確かめるには、発行口に仕事を
/// 積んで待つほかなく、それ自体が答えない GPU へ積み増す側に回るからである。プロセスを起こし直せば、
/// 印も消える。
///
/// 既にある土台は止めない。その待ちは、自分の期限で今までどおり打ち切られる。
///
/// **プロセスで 1 つ** (``process``) が本物である。検査だけが自前の関所を土台へ渡す。そうすれば、
/// 印を立てる検査が同じプロセスの他の検査を巻き添えにしない。
///
/// Metal 側の糸からは触らないが、``RenderDevice/isAvailable`` が隔離の外から呼ぶので、錠で
/// 守る (``CoalescedNotices`` と同じ作法)。
///
/// [#2052]: https://github.com/mokume-metal/mokume/issues/2052
nonisolated final class CommandQueueGate: Sendable {
    private struct State {
        var closed = false
        var queuesMade = 0
    }

    private let state = Mutex(State())

    /// プロセスで 1 つの関所。製品の経路と、自前の関所を渡さない検査はここを通る。
    static let process = CommandQueueGate()

    /// 発行口を作る。**印が立っていれば作らずに断る。**
    ///
    /// **作る間は錠を握らない。** 詰まった GPU では作る呼び出しそのものがドライバの中で待たされうる
    /// (#2052 では `RenderDevice.init` が WindowServer を待って止まっていた)。握ったまま待つと、印を
    /// 立てる側 (main actor) まで錠で止まる。見てから作るまでの間に別の糸が印を立てれば 1 本は
    /// 作られうるが、溜まり続ける形にはならない。
    func makeQueue(on device: any MTLDevice) throws(RenderFailure) -> any MTL4CommandQueue {
        guard !isClosed else { throw .gpuNotResponding }
        guard let queue = device.makeMTL4CommandQueue() else { throw .commandQueueUnavailable }
        state.withLock { $0.queuesMade += 1 }
        return queue
    }

    /// 合図の待ちが期限を越えた。**印を立てる。** 今回立てたなら `true` を返す (既に立っていれば
    /// `false`)。呼ぶ側は、`true` のときだけ人へ伝える。
    func close() -> Bool {
        state.withLock { state in
            defer { state.closed = true }
            return !state.closed
        }
    }

    /// 印が立っているか。
    var isClosed: Bool { state.withLock { $0.closed } }

    /// 診断: この関所を通って作った発行口の数。
    ///
    /// 検査は、印が立った後にこれが増えないことを見る。投げたことだけを見ると、作ってから投げる
    /// 形に崩れても気付けない。
    var queuesMade: Int { state.withLock { $0.queuesMade } }
}
