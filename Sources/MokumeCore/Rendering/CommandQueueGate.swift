// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
/// (`RenderDevice` の `signalReached(_:while:)` — GPU の待ち 4 つがすべて通る 1 本) である。
/// 印が立つと、``makeQueue(on:)`` は作らずに ``RenderFailure/gpuNotResponding`` で断る。
/// 回復したかを見て下ろす形は採らない。GPU が答えるようになったかを確かめるには、発行口に仕事を
/// 積んで待つほかなく、それ自体が答えない GPU へ積み増す側に回るからである。プロセスを起こし直せば、
/// 印も消える。
///
/// **重い 1 フレームでも印は立つ。** 期限を越えた待ちからは、「1 フレームが描きすぎた」(``RenderFailure/timedOut(seconds:)``
/// が名乗る側) と「GPU が答えなくなった」を見分けられない。見分けずに立てる代償は、そのプロセスで
/// 新しい土台を作れなくなることである。製品の経路で 1 プロセスが作る土台は 1 つなので、効くのは
/// 土台を作り直し続ける道具と検査だけになる。だから文面 (印を立てた時の警告と
/// ``RenderFailure/gpuNotResponding``) は、どちらの場合もあると名乗り、起こし直すよう促す。
/// 描きすぎの側だけを名乗ると、読んだ人は減らせば済むと考えて、同じプロセスで作り直しを続ける
/// (#2052 の反証)。
///
/// **最初に印を立てた待ちを控える** (``closure``)。検査は全 suite を 1 つのプロセスで走らせるので、
/// 印が立つと以後の GPU の検査がすべて ``RenderFailure/gpuNotResponding`` で赤になる。期限切れが
/// 土台を畳む時 (`deinit`・投げない) なら、原因の検査は記録の上で緑のまま残る。最初の赤から原因を
/// 辿れるように、待ちの種類・期限・時刻を文面に添える (#2052 の反証)。
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
    /// 期限を越えた待ちの種類。GPU の待ちは 4 つで、どれも `RenderDevice` の `signalReached(_:while:)` を通る。
    enum Wait: Sendable, Equatable {
        /// 土台を畳む前の待ち (`deinit`)。**投げない**ので、待った検査は緑のまま残りうる
        case takingDown
        /// 投入済みの全部を待つ (`settle()`)
        case finishing
        /// 置き場が空くのを待つ (`waitForSlot`)
        case allocator
        /// 名指しの投入を待つ (`waitForSubmission`)
        case frameSlot

        /// 文面に入れる句 (`while …` に続く)。
        var phrase: String {
            switch self {
            case .takingDown: "taking down a drawing foundation"
            case .finishing: "waiting for the GPU to finish"
            case .allocator: "waiting for a command allocator to free up"
            case .frameSlot: "waiting for a frame slot to free up"
            }
        }
    }

    /// 最初に印を立てた待ち。
    struct Closure: Sendable, Equatable {
        let wait: Wait
        /// その待ちの期限
        let limit: Duration
        /// 印を立てた時刻
        let date: Date

        /// 文面に添える句。時刻は手元の時間帯の ISO 8601 で、検査の記録 (`.build/test-log.txt`) や
        /// gpu-slot の起動元の記録と突き合わせられる形にする。
        var summary: String {
            "the first was while \(wait.phrase), past \(limit), at \(date.formatted(Date.ISO8601FormatStyle(timeZone: .current)))"
        }
    }

    private struct State {
        var closure: Closure?
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
    /// `false`)。呼ぶ側は、`true` のときだけ人へ伝える。控えるのは最初の 1 回だけである。
    func close(after wait: Wait, limit: Duration, at date: Date = Date()) -> Bool {
        state.withLock { state in
            guard state.closure == nil else { return false }
            state.closure = Closure(wait: wait, limit: limit, date: date)
            return true
        }
    }

    /// 印が立っているか。
    var isClosed: Bool { closure != nil }

    /// 最初に印を立てた待ち。立っていなければ `nil`。
    var closure: Closure? { state.withLock { $0.closure } }

    /// 診断: この関所を通って作った発行口の数。
    ///
    /// 検査は、印が立った後にこれが増えないことを見る。投げたことだけを見ると、作ってから投げる
    /// 形に崩れても気付けない。
    var queuesMade: Int { state.withLock { $0.queuesMade } }
}
