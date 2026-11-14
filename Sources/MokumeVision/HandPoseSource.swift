// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore
import MokumeDiagnostics
import Synchronization

/// 手の関節点の出どころ。**記録した結果の再生も、推論も、同じ入れ物 (``ExternalInput``) へ入れる**
/// ([ADR-0028] 決定 6・[ADR-0042] 決定 4 の「供給元を差し替えられる」)。
///
/// 入れ物から先 (``HandPose``) は出どころを知らない。だから記録の再生で回した検査が、実機のときの
/// 受け取りの正しさをそのまま固定する。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
protocol HandPoseSource: AnyObject {
    /// 始める。結果と状態は `input` へ入れる。
    func start(into input: ExternalInput<HandPoseResult>)
    /// フレームごとに、取り出す前に呼ばれる (main actor)。
    func pump(into input: ExternalInput<HandPoseResult>)
    /// 止める。止めた後に終わった推論の結果は入れない。
    func stop()
}

// MARK: - 記録した結果の再生

/// 記録した結果の列を、フレームごとに 1 つずつ入れる出どころ。**推論も Vision も使わない。**
///
/// どの結果が入るかはフレームの数え方だけで決まる (作ってから何番目のフレームか) ので、同じ列からは何度
/// 回しても同じ結果が同じフレームに出る ([ADR-0028] 決定 7)。外して足し直しても数え方は変わらない
/// (時刻どおり・[#3152])。
///
/// [#3152]: https://github.com/mokume-metal/mokume/issues/3152
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class RecordedHandPoseSource: HandPoseSource {
    private let frames: [HandPoseResult?]
    private var next = 0
    private var stopped = false
    private var detached: DetachedFrames

    /// - Parameter owner: 外していた間に進んだフレームを数える持ち主。`nil` なら足し直しでも位置を進めない。
    init(frames: [HandPoseResult?], owner: (any Sketch)? = nil) {
        self.frames = frames
        detached = DetachedFrames(owner: owner)
    }

    func start(into input: ExternalInput<HandPoseResult>) {
        stopped = false
        if !frames.isEmpty { next = (next + detached.reopen()) % frames.count }
        input.setState(frames.isEmpty ? .unavailable : .running)
    }

    func pump(into input: ExternalInput<HandPoseResult>) {
        guard !frames.isEmpty, !stopped else { return }
        let frame = frames[next % frames.count]
        next += 1
        // `nil` のフレームは、新しい結果がまだ届いていない (前の結果が最新のまま)
        guard let frame else { return }
        input.send(frame, hostTime: frame.hostTime)
    }

    func stop() {
        stopped = true
        detached.close()
    }
}

// MARK: - 推論

/// 推論に渡す、1 枚の絵の写し。
///
/// ``Image`` は main actor の持ち物で `Sendable` ではないので、推論 (main actor の外) へは渡せない。
/// main actor の上で画素を ``Image/readPixels()`` で読み出した写し (``PixelBuffer``) を持たせて渡す。
/// 画素の要らない推論 (検査の偽物) には `pixels` を持たせない。
///
/// `Equatable` にしない: 画素の中身まで比べる手段が main actor の外に無く (#4098)、中身を比べない `==` は取り違えを見逃す。
/// 検査は見たい欄 (`hostTime` など) を直に比べる。
nonisolated struct HandPoseInput: Sendable {
    /// 絵の幅 (画素)。
    let width: Int
    /// 絵の高さ (画素)。
    let height: Int
    /// 絵が届いた瞬間の host time。
    let hostTime: UInt64
    /// 絵の画素。線形・アルファ乗算済み (``PixelBuffer`` のとおり)。`nil` なら画素を持たない写し。
    let pixels: PixelBuffer?

    init(width: Int, height: Int, hostTime: UInt64, pixels: PixelBuffer? = nil) {
        self.width = width
        self.height = height
        self.hostTime = hostTime
        self.pixels = pixels
    }

    /// 読み出した画素から作る。大きさは画素のもの。
    @MainActor
    init(pixels: PixelBuffer, hostTime: UInt64) {
        self.init(width: pixels.width, height: pixels.height, hostTime: hostTime, pixels: pixels)
    }
}

/// 推論が返す関節点 1 つ。**Vision の座標のまま** (0〜1・左下が原点・y は上向き)。
nonisolated struct RawJoint: Sendable, Equatable {
    let x: Float
    let y: Float
    let confidence: Float
}

/// 推論が返す手 1 つ。**Vision の座標のまま。** 利用者へ見せる前に ``HandPoseResult`` へ写す。
nonisolated struct RawHand: Sendable, Equatable {
    let handedness: Handedness
    let joints: [RawJoint]
}

/// 絵 1 枚から手を取り出すもの。**差し替えられる** — 実物の推論 (Vision) も、検査の偽物 (遅い・決まった
/// 点を返す) も、同じ口に差す。
///
/// main actor の外で呼ばれる。手が写っていなければ空を返し、投げない。
nonisolated protocol HandPoseEstimator: Sendable {
    /// 推論できるようにする (モデルの読み込みなど)。返ったら推論できる。何度呼んでもよく、2 度目からはすぐ返る。
    func prepare() async
    func estimate(_ frame: HandPoseInput) async -> [RawHand]
}

nonisolated extension HandPoseEstimator {
    /// 用意の要らない推論は、すぐ返る。
    func prepare() async {}
}

nonisolated extension HandPoseResult {
    /// 推論の結果を、利用者へ見せる形へ写す。捨てた手の数は ``converting(_:of:)`` が数える。
    init(raw hands: [RawHand], of frame: HandPoseInput) {
        self = Self.converting(hands, of: frame).result
    }

    /// 推論の結果を、利用者へ見せる形へ写し、**捨てた手の数**を添える。
    ///
    /// Vision の座標 (0〜1・左下が原点) を、入力の絵の画素の座標 (左上が原点・y は下向き) にする
    /// ([ADR-0014] の改訂 (2026-10-23)・[ADR-0020] 決定 6)。**正規化の値は画素の角の座標である** — x の 0 は
    /// 絵の左端、1 は右端で幅 `width` に写り (`width - 1` ではない)、y の 0 は下端で高さ `height`、1 は上端で 0 に写る。
    /// 画素 i の中心は i + 0.5 に当たり、半画素の補正はしない。**左右は入れ替えない** — 入力の絵が既に
    /// 入れ替えた後のもの (カメラの `mirrored`) なら、点はその絵の上に重なる。範囲の外 (0〜1 を越える点) は
    /// そのまま写す — 絵の外を指すだけである。
    ///
    /// **捨てる手:** 関節が 21 に満たない・越える手と、関節に有限でない値 (`NaN`・無限大) を持つ手。
    /// 手ごと捨てる (欠けた関節を埋めると、存在しない点が描かれる)。信頼度が 0〜1 を外れた値は 0〜1 に収める。
    /// 捨てたことは「手が写らなかった」と区別がつかないので、呼ぶ側が数を名乗る (``DroppedHands``)。
    ///
    /// [ADR-0014]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0014-machine-learning-role.md
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    static func converting(
        _ hands: [RawHand], of frame: HandPoseInput
    ) -> (result: HandPoseResult, dropped: Int) {
        let width = Float(frame.width)
        let height = Float(frame.height)
        var kept: [Hand] = []
        var dropped = 0
        for raw in hands {
            let joints = raw.joints.compactMap {
                HandJoint(position: Vector2($0.x * width, (1 - $0.y) * height), confidence: $0.confidence)
            }
            // 1 つでも関節を作れなかった手は、数が 21 に見えても捨てる
            guard joints.count == raw.joints.count,
                let hand = Hand(handedness: raw.handedness, joints: joints)
            else {
                dropped += 1
                continue
            }
            kept.append(hand)
        }
        return (HandPoseResult(hostTime: frame.hostTime, hands: kept), dropped)
    }
}

/// 推論が返した手のうち、**読めずに捨てた数** ([#3586])。
///
/// 捨てた手は、結果の上では手が写らなかったときと区別がつかない。数を持ち、**最初の 1 度だけ**診断へ名乗る
/// (MIDI の「読めずに捨てた」と同じ。毎フレームの推論で言い続けると、読むべき 1 行が埋まる)。2 度目からは数だけが増える。
///
/// [#3586]: https://github.com/mokume-metal/mokume/issues/3586
nonisolated final class DroppedHands: Sendable {
    private struct State {
        var total = 0
        var told = false
    }

    private let state = Mutex(State())
    private let tell: @Sendable (String) -> Void

    /// - Parameter tell: 名乗る先。既定は診断 (標準エラーと観測の応答の `warnings`)。
    init(tell: @escaping @Sendable (String) -> Void = { Diagnostics.warn($0) }) {
        self.tell = tell
    }

    /// これまでに捨てた手の数。
    var total: Int { state.withLock { $0.total } }

    /// `count` 個の手を捨てたと数える。0 なら何もしない。
    func note(_ count: Int) {
        guard count > 0 else { return }
        let message = state.withLock { state -> String? in
            state.total += count
            guard !state.told else { return nil }
            state.told = true
            return "hand pose: \(count) \(count == 1 ? "hand was" : "hands were") dropped because "
                + "the estimator gave them fewer or more than 21 joints, or joints that were not finite numbers. "
                + "The result looks the same as a picture with no hands. This is said once; later drops are only counted"
        }
        if let message { tell(message) }
    }
}

/// 推論を main actor の外で走らせ、最新の絵だけを渡す係。**溜めない。**
///
/// 推論中に届いた絵は最新の 1 枚だけを持ち、古いものは捨てる ([ADR-0028] 決定 2)。重い推論でも、
/// 描くほう (``submit(_:)`` を呼ぶフレーム) は止まらない。結果は元の絵の host time を持って入れ物へ入る。
///
/// **止めると世代が替わる。** 止める前に始めた推論は、終わっても結果を入れない。終わらない推論 (固まった
/// 推論) も、足し直した後の新しい絵を待たせない — 足し直した後の ``submit(_:)`` は、前の世代の推論の終わりを
/// 待たずに新しい推論を起こす。同時に走る推論は世代ごとに 1 つで、古い世代のものには `Task.cancel` を送る
/// (``HandPoseEstimator/estimate(_:)`` が協調キャンセルを受ければ、早く終わる)。
///
/// **待つ側が手放した推論が終わるまでは、新しい推論を起こさない。** ``estimateHere(_:timeout:)`` が期限で手放した
/// 推論は `Task.cancel` を受けても、Vision の同期の推論 (`perform`) は止まらない。その間に新しい推論を起こすと、
/// 同じ推定器で 2 本が並ぶ。手放した推論が終わったら、待っていた絵があればそこで推論を起こす。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
nonisolated final class HandPoseWorker: Sendable {
    private struct State {
        /// 推論待ちの最新の 1 枚。
        var pending: HandPoseInput?
        /// 今の世代の推論の列が走っているか。
        var running = false
        /// 止められているか。止めた後に終わった推論の結果は入れない。
        var stopped = false
        /// 止められた回数 (世代)。止める前に始めた推論は、足し直された後に終わっても結果を入れない。
        var stops = 0
        /// 今の世代の推論の列。止めるときに `Task.cancel` を送る。
        var task: Task<Void, Never>?
        /// 待つ側が期限で手放し、まだ終わっていない推論の数。0 になるまで推論の列を起こさない。
        var abandoned = 0

        /// 推論の列を起こせるなら、起こしたことにして世代を返す。
        mutating func claim() -> Int? {
            guard !stopped, !running, abandoned == 0, pending != nil else { return nil }
            running = true
            return stops
        }
    }

    private let estimator: any HandPoseEstimator
    private let output: ExternalInput<HandPoseResult>
    private let dropped: DroppedHands
    private let preparation: HandPosePreparation?
    private let state = Mutex(State())

    /// - Parameter preparation: 結果を入れる前に ``SourceState/running`` を名乗らせる係。`nil` なら状態に触れない。
    init(
        estimator: any HandPoseEstimator, output: ExternalInput<HandPoseResult>,
        dropped: DroppedHands = DroppedHands(), preparation: HandPosePreparation? = nil
    ) {
        self.estimator = estimator
        self.output = output
        self.dropped = dropped
        self.preparation = preparation
    }

    /// 推論待ちの絵。**検査が読む。**
    var waiting: HandPoseInput? { state.withLock { $0.pending } }

    /// 推論の列も、手放した推論も走っておらず、待っている絵も無いか。`true` の間に渡した絵は、すぐ推論が始まる。
    var isIdle: Bool { state.withLock { !$0.running && $0.abandoned == 0 && $0.pending == nil } }

    /// 次に推論する絵を渡す。待っていた絵があれば置き換える。**すぐ返る。**
    func submit(_ frame: HandPoseInput) {
        let generation = state.withLock { state -> Int? in
            // 止められている間に届いた絵は捨てる (足し直した最初の推論に、外していた間の絵を当てない)
            guard !state.stopped else { return nil }
            state.pending = frame
            return state.claim()
        }
        launch(generation)
    }

    /// `generation` の推論の列を起こす。`nil` なら何もしない。
    private func launch(_ generation: Int?) {
        guard let generation else { return }
        let task = Task.detached(priority: .userInitiated) { [self] in await drain(generation: generation) }
        // 起こす間に止められていたら、この世代の推論は要らない
        let superseded = state.withLock { state -> Bool in
            guard state.stops == generation else { return true }
            state.task = task
            return false
        }
        if superseded { task.cancel() }
    }

    /// 開く。止めた後に足し直されたときも呼ばれる。
    func resume() {
        state.withLock { $0.stopped = false }
    }

    /// 止める。待っている絵は捨て、走っている推論の結果は入れない。
    ///
    /// 走っている推論の終わりは待たない — 足し直した後の絵は、新しい世代の推論が受ける。
    func stop() {
        let old = state.withLock { state -> Task<Void, Never>? in
            state.stopped = true
            state.stops += 1
            state.pending = nil
            state.running = false
            defer { state.task = nil }
            return state.task
        }
        old?.cancel()
    }

    /// 待っている絵がなくなるまで、1 枚ずつ推論する。止められて世代が替わったら、そこで抜ける。
    private func drain(generation: Int) async {
        while true {
            let next = state.withLock { state -> HandPoseInput? in
                // 世代が替わった: 後の世代が自分の推論を持つ (`running` はそちらのもの)
                guard state.stops == generation else { return nil }
                if let frame = state.pending {
                    state.pending = nil
                    return frame
                }
                state.running = false
                state.task = nil
                return nil
            }
            guard let frame = next else { return }
            let converted = HandPoseResult.converting(await estimator.estimate(frame), of: frame)
            // 推論を始めた後に止められていなければ入れる。確かめてから入れるまでの間に止められないよう、錠の内側で入れる
            let accepted = state.withLock { state -> Bool in
                guard state.stops == generation else { return false }
                // 結果が見えるフレームでは、状態は必ず running (preparing のまま結果を出さない)
                preparation?.announceRunning()
                output.send(converted.result, hostTime: frame.hostTime)
                return true
            }
            if accepted { dropped.note(converted.dropped) }
        }
    }

    /// 推論を 1 枚だけ走らせ、終わるまでこの場で待つ。**待つ側が期限を持つ** — 越えたら推論に `Task.cancel` を送り、
    /// `nil` を返す。推論は main actor の外で走るので、main actor から待ってもよい。
    ///
    /// 期限で手放した推論は、終わるまで ``submit(_:)`` の推論を起こさせない (同じ推定器で 2 本を並べない)。
    func estimateHere(_ frame: HandPoseInput, timeout: Duration) -> [RawHand]? {
        let slot = Slot()
        let task = Task.detached(priority: .userInitiated) { [self] in
            let hands = await estimator.estimate(frame)
            if slot.finish(hands) { releaseAbandoned() }
        }
        if slot.done.wait(timeout: .now() + timeout.seconds) == .success { return slot.hands }
        // 期限を越えた。確かめてから手放すまでの間に終わっていれば、その結果を使う
        guard slot.abandon(onAbandon: { state.withLock { $0.abandoned += 1 } }) else { return slot.hands }
        task.cancel()
        return nil
    }

    /// 手放した推論が終わった。待っている絵があれば、推論の列を起こす。
    private func releaseAbandoned() {
        launch(
            state.withLock { state -> Int? in
                state.abandoned -= 1
                return state.claim()
            })
    }

    /// ``estimateHere(_:timeout:)`` の、待つ側と推論の間の受け渡し。
    private final class Slot: Sendable {
        private struct Content {
            var hands: [RawHand]?
            var abandoned = false
        }

        private let content = Mutex(Content())
        let done = DispatchSemaphore(value: 0)

        var hands: [RawHand]? { content.withLock { $0.hands } }

        /// 推論が終わった。待つ側が既に手放していれば `true`。
        func finish(_ hands: [RawHand]) -> Bool {
            let abandoned = content.withLock { content -> Bool in
                content.hands = hands
                return content.abandoned
            }
            done.signal()
            return abandoned
        }

        /// 待つ側が手放す。まだ終わっていなければ、錠の内側で `onAbandon` を呼んで `true`。終わっていれば `false`。
        func abandon(onAbandon: () -> Void) -> Bool {
            content.withLock { content -> Bool in
                guard content.hands == nil else { return false }
                content.abandoned = true
                onAbandon()
                return true
            }
        }
    }
}

/// 届いた絵が新しいかを、到着の host time で見分ける。**同じ到着は 2 度新しいと言わない。**
///
/// 止めたら忘れる (``forget()``)。絵が 1 枚きり (静止画・1 度きりの到着) の入力で、推論中に外して足し直しても、
/// 同じ到着をもう 1 度推論に回せる。
final class ArrivalFilter {
    private var last: UInt64?

    /// `hostTime` が前に見たものと違えば `true`。届いていなければ (`nil`) `false`。
    func isNew(_ hostTime: UInt64?) -> Bool {
        guard let hostTime, hostTime != last else { return false }
        last = hostTime
        return true
    }

    /// 見たことを忘れる。
    func forget() { last = nil }
}

/// 推論の用意 (モデルの読み込みなど) を 1 度だけ走らせ、済んだら入れ物の状態を ``SourceState/running`` にする係。
///
/// 用意は main actor の外で走り、描くほうは止まらない。用意の間の状態は ``SourceState/preparing``。
/// **止めている間に用意が済んでも ``SourceState/running`` にしない** — 確かめてから名乗るまでを錠の内側で行うので、
/// 止めた直後に済んだ用意が ``SourceState/stopped`` を上書きしない。用意は 1 度きりで、足し直したときに済んでいれば
/// すぐ ``SourceState/running`` を名乗る。
///
/// **``SourceState/preparing`` と ``SourceState/running`` を名乗るのはこの係だけ**で、すべて錠の内側で名乗る。結果を
/// 入れる側は入れる直前に ``announceRunning()`` を呼ぶので、結果が見えるフレームで状態が preparing のことは無い。
/// ``SourceState/stopped`` は ``HandPose/close()`` が ``stop()`` の後に名乗る (どちらも main actor の上で順に呼ばれ、
/// ``stop()`` が錠を取った後にこの係は状態を変えない)。
nonisolated final class HandPosePreparation: Sendable {
    private struct State {
        var started = false
        var prepared = false
        var stopped = false
    }

    private let estimator: any HandPoseEstimator
    private let output: ExternalInput<HandPoseResult>
    private let state = Mutex(State())
    private let finished = DispatchSemaphore(value: 0)

    init(estimator: any HandPoseEstimator, output: ExternalInput<HandPoseResult>) {
        self.estimator = estimator
        self.output = output
    }

    /// 用意が済んだか。
    var isPrepared: Bool { state.withLock { $0.prepared } }

    /// 開く。済んでいなければ ``SourceState/preparing`` を名乗って用意を始め (始めていなければ)、済んでいれば
    /// ``SourceState/running`` を名乗る。**すぐ返る。**
    func start() {
        let begins = state.withLock { state -> Bool in
            state.stopped = false
            if state.prepared {
                output.setState(.running)
                return false
            }
            output.setState(.preparing)
            guard !state.started else { return false }
            state.started = true
            return true
        }
        guard begins else { return }
        Task.detached(priority: .userInitiated) { [self] in
            await estimator.prepare()
            state.withLock { state in
                state.prepared = true
                if !state.stopped { output.setState(.running) }
            }
            finished.signal()
        }
    }

    /// 止める。この後に用意が済んでも、状態は変えない。
    func stop() {
        state.withLock { $0.stopped = true }
    }

    /// 結果を入れる直前に呼ぶ。推論が結果を出せたので用意は済んだものとし、止めていなければ ``SourceState/running``
    /// を名乗る (用意の終わりより先に結果が出る順でも、preparing のまま結果を見せない)。
    func announceRunning() {
        state.withLock { state in
            state.prepared = true
            if !state.stopped { output.setState(.running) }
        }
    }

    /// 用意が済むまで、この場で待つ。`timeout` を越えたら待たずに `false` を返す。
    func wait(timeout: Duration) -> Bool {
        if isPrepared { return true }
        guard finished.wait(timeout: .now() + timeout.seconds) == .success else { return isPrepared }
        return true
    }
}

extension Duration {
    /// 秒 (`DispatchTime` に足せる形)。
    nonisolated fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// 届いた絵。**まだ読み出していない** — 画素を読む費用は、推論に渡すと決まったときだけ払う (``read``)。
struct ArrivedPicture {
    /// 絵が届いた瞬間の host time。
    let hostTime: UInt64
    /// 絵の写しを作る (画素を読み出す)。
    let read: () -> HandPoseInput
}

/// 推論で回す出どころ。届いた絵を ``HandPoseWorker`` に渡し、結果は worker が入れ物へ入れる。
///
/// 届いた絵 (``ArrivedPicture``) は `pictures` が返す。**新しい絵が届いたときだけ**値を返し、無ければ
/// `nil` を返す — 同じ絵を 2 度推論しない。止めたら `forget` で「見た絵」を忘れ、足し直した後は同じ絵でも
/// 1 度推論する。
///
/// **`waits` が `true` を返す間 (固定の時計) は推論を待つ。** 開くときに用意を、フレームごとに推論を、この場で
/// 待つ (`patience` まで)。結果はその ``Inlet/supply()`` の中で入れ物へ入るので、フレーム N の絵に対する結果が
/// フレーム N の `draw()` に出る。用意か推論の待ちが期限を越えたら、そのフレームは新しい結果なしで進め、1 度だけ名乗り、
/// **以後この出どころは待たない** (固まった推論で書き出しを止め続けない)。越えた後の結果は、どのフレームの絵のものかが
/// フレームと揃わない。`waits` が `false` の間 (実時間の時計) は待たず、worker に渡す。
///
/// **待たないときは、worker が空いているフレームでだけ絵を読み出す。** 推論中に届いた絵は読まずに最新の 1 枚だけを
/// 持ち、worker が空いたフレームで読み出して渡す (捨てる絵の読み出しを払わない)。
final class InferenceSource: HandPoseSource {
    /// 固定の時計で、用意と推論の 1 回をそれぞれ待つ長さの既定。この機械で初めて推論した回の用意 (数秒) が収まる長さ。
    static let defaultPatience: Duration = .seconds(30)

    private let pictures: () -> ArrivedPicture?
    private let forget: () -> Void
    private let estimator: any HandPoseEstimator
    private let dropped: DroppedHands
    private let waits: () -> Bool
    private let patience: Duration
    private let tell: (String) -> Void
    private(set) var worker: HandPoseWorker?
    private var preparation: HandPosePreparation?
    private var stopped = false
    /// 届いて、まだ推論に渡していない最新の絵 (読み出す前)。
    private var deferred: ArrivedPicture?
    /// 期限を越えたことがあるか。越えた後は待たない。
    private(set) var gaveUpWaiting = false

    init(
        estimator: any HandPoseEstimator, dropped: DroppedHands = DroppedHands(),
        waits: @escaping () -> Bool = { false }, patience: Duration = defaultPatience,
        tell: @escaping (String) -> Void = { Diagnostics.warn($0) },
        forget: @escaping () -> Void = {}, pictures: @escaping () -> ArrivedPicture?
    ) {
        self.pictures = pictures
        self.forget = forget
        self.estimator = estimator
        self.dropped = dropped
        self.waits = waits
        self.patience = patience
        self.tell = tell
    }

    /// 写しをそのまま返す組み方 (検査が使う)。`frame` が値を返したときが、新しい絵である。
    convenience init(
        estimator: any HandPoseEstimator, dropped: DroppedHands = DroppedHands(),
        waits: @escaping () -> Bool = { false }, patience: Duration = defaultPatience,
        tell: @escaping (String) -> Void = { Diagnostics.warn($0) },
        forget: @escaping () -> Void = {}, frame: @escaping () -> HandPoseInput?
    ) {
        self.init(
            estimator: estimator, dropped: dropped, waits: waits, patience: patience, tell: tell, forget: forget
        ) {
            frame().map { picture in ArrivedPicture(hostTime: picture.hostTime) { picture } }
        }
    }

    /// 届いて、まだ推論に渡していない絵の host time。**検査が読む。**
    var waiting: UInt64? { deferred?.hostTime }

    /// 推論の用意が済んだか。**検査が読む。**
    var isPrepared: Bool { preparation?.isPrepared ?? false }

    /// 絵の大きさと到着の記録から写しを作る組み方 (画素は持たない)。`arrival` の host time が前と変わったときが、
    /// 新しい絵である。
    convenience init(
        estimator: any HandPoseEstimator, dropped: DroppedHands = DroppedHands(),
        waits: @escaping () -> Bool = { false }, patience: Duration = defaultPatience,
        tell: @escaping (String) -> Void = { Diagnostics.warn($0) },
        size: @escaping () -> (width: Int, height: Int), arrival: @escaping () -> Arrival?
    ) {
        let filter = ArrivalFilter()
        self.init(
            estimator: estimator, dropped: dropped, waits: waits, patience: patience, tell: tell,
            forget: filter.forget
        ) { () -> ArrivedPicture? in
            guard let hostTime = arrival()?.hostTime, filter.isNew(hostTime) else { return nil }
            return ArrivedPicture(hostTime: hostTime) {
                let size = size()
                return HandPoseInput(width: size.width, height: size.height, hostTime: hostTime)
            }
        }
    }

    /// 絵と到着の記録から写しを作る組み方。新しい絵が届き、推論に渡すと決まったフレームで、絵の画素を
    /// ``Image/readPixels()`` で読む。
    ///
    /// **供給の順に注意。** 入り口は足した順に ``Inlet/supply()`` が回る。絵を書き込む入り口 (`Capture`) より
    /// 後に足せば、同じフレームで書かれたばかりの絵を見る。読み出しを後のフレームへ送ったときは、その時点の絵
    /// (届いた中で最新のもの) を読む。
    convenience init(
        estimator: any HandPoseEstimator, dropped: DroppedHands = DroppedHands(), image: Image,
        waits: @escaping () -> Bool = { false }, patience: Duration = defaultPatience,
        tell: @escaping (String) -> Void = { Diagnostics.warn($0) },
        arrival: @escaping () -> Arrival?
    ) {
        let filter = ArrivalFilter()
        self.init(
            estimator: estimator, dropped: dropped, waits: waits, patience: patience, tell: tell,
            forget: filter.forget
        ) { () -> ArrivedPicture? in
            guard let hostTime = arrival()?.hostTime, filter.isNew(hostTime) else { return nil }
            return ArrivedPicture(hostTime: hostTime) { HandPoseInput(pixels: image.readPixels(), hostTime: hostTime) }
        }
    }

    func start(into input: ExternalInput<HandPoseResult>) {
        stopped = false
        if let worker {
            worker.resume()
        } else {
            let preparation = HandPosePreparation(estimator: estimator, output: input)
            self.preparation = preparation
            worker = HandPoseWorker(estimator: estimator, output: input, dropped: dropped, preparation: preparation)
        }
        preparation?.start()
        guard shouldWait, let preparation, !preparation.wait(timeout: patience) else { return }
        giveUp("getting the hand pose estimator ready")
    }

    func pump(into input: ExternalInput<HandPoseResult>) {
        // 止めている間は絵を見ない — 見ると「見た絵」になり、足し直した後に同じ絵が推論されない
        guard !stopped, let worker else { return }
        if let arrived = pictures() { deferred = arrived }
        guard let picture = deferred else { return }
        guard shouldWait else {
            // 推論中なら読まずに持つ。空いたフレームで、届いた中で最新の絵を読んで渡す
            guard worker.isIdle else { return }
            deferred = nil
            worker.submit(picture.read())
            return
        }
        deferred = nil
        let frame = picture.read()
        guard let hands = worker.estimateHere(frame, timeout: patience) else {
            giveUp("estimating the hands in a frame")
            return
        }
        let converted = HandPoseResult.converting(hands, of: frame)
        preparation?.announceRunning()
        input.send(converted.result, hostTime: frame.hostTime)
        dropped.note(converted.dropped)
    }

    func stop() {
        stopped = true
        deferred = nil
        forget()
        worker?.stop()
        preparation?.stop()
    }

    private var shouldWait: Bool { !gaveUpWaiting && waits() }

    private func giveUp(_ what: String) {
        gaveUpWaiting = true
        tell(
            "hand pose: \(what) took longer than \(patience), so the sketch went on without the result. "
                + "From now on this hand pose does not wait for the estimator: in a written movie, the hands no "
                + "longer line up with the frame whose picture they came from")
    }
}
