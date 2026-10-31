// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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

/// 推論に渡す、1 枚の絵の写し。**画素は持たない。**
///
/// ``Image`` は main actor の持ち物で `Sendable` ではないので、推論 (main actor の外) へは渡せない。
/// 渡すのは大きさと届いた host time だけにして、画素を CPU へ読み出して持たせるのは実物の推論の段
/// (#3587) で足す。
nonisolated struct HandPoseInput: Sendable, Equatable {
    /// 絵の幅 (画素)。
    let width: Int
    /// 絵の高さ (画素)。
    let height: Int
    /// 絵が届いた瞬間の host time。
    let hostTime: UInt64
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
    func estimate(_ frame: HandPoseInput) async -> [RawHand]
}

nonisolated extension HandPoseResult {
    /// 推論の結果を、利用者へ見せる形へ写す。捨てた手の数は ``converting(_:of:)`` が数える。
    init(raw hands: [RawHand], of frame: HandPoseInput) {
        self = Self.converting(hands, of: frame).result
    }

    /// 推論の結果を、利用者へ見せる形へ写し、**捨てた手の数**を添える。
    ///
    /// Vision の座標 (0〜1・左下が原点) を、入力の絵の画素の座標 (左上が原点・y は下向き) にする
    /// ([ADR-0014] の改訂 (2026-10-23)・[ADR-0020] 決定 6)。**左右は入れ替えない** — 入力の絵が既に
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
    }

    private let estimator: any HandPoseEstimator
    private let output: ExternalInput<HandPoseResult>
    private let dropped: DroppedHands
    private let state = Mutex(State())

    init(
        estimator: any HandPoseEstimator, output: ExternalInput<HandPoseResult>,
        dropped: DroppedHands = DroppedHands()
    ) {
        self.estimator = estimator
        self.output = output
        self.dropped = dropped
    }

    /// 推論待ちの絵。**検査が読む。**
    var waiting: HandPoseInput? { state.withLock { $0.pending } }

    /// 次に推論する絵を渡す。待っていた絵があれば置き換える。**すぐ返る。**
    func submit(_ frame: HandPoseInput) {
        let generation = state.withLock { state -> Int? in
            // 止められている間に届いた絵は捨てる (足し直した最初の推論に、外していた間の絵を当てない)
            guard !state.stopped else { return nil }
            state.pending = frame
            guard !state.running else { return nil }
            state.running = true
            return state.stops
        }
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
                output.send(converted.result, hostTime: frame.hostTime)
                return true
            }
            if accepted { dropped.note(converted.dropped) }
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

/// 推論で回す出どころ。届いた絵を ``HandPoseWorker`` に渡し、結果は worker が入れ物へ入れる。
///
/// 絵の写し (``HandPoseInput``) は `frame` が作る。**新しい絵が届いたときだけ**値を返し、無ければ
/// `nil` を返す — 同じ絵を 2 度推論しない。止めたら `forget` で「見た絵」を忘れ、足し直した後は同じ絵でも
/// 1 度推論する。
final class InferenceSource: HandPoseSource {
    private let frame: () -> HandPoseInput?
    private let forget: () -> Void
    private let estimator: any HandPoseEstimator
    private let dropped: DroppedHands
    private(set) var worker: HandPoseWorker?
    private var stopped = false

    init(
        estimator: any HandPoseEstimator, dropped: DroppedHands = DroppedHands(),
        forget: @escaping () -> Void = {}, frame: @escaping () -> HandPoseInput?
    ) {
        self.frame = frame
        self.forget = forget
        self.estimator = estimator
        self.dropped = dropped
    }

    /// 絵の大きさと到着の記録から写しを作る組み方。`arrival` の host time が前と変わったときが、新しい絵である。
    convenience init(
        estimator: any HandPoseEstimator, dropped: DroppedHands = DroppedHands(),
        size: @escaping () -> (width: Int, height: Int), arrival: @escaping () -> Arrival?
    ) {
        let filter = ArrivalFilter()
        self.init(estimator: estimator, dropped: dropped, forget: filter.forget) {
            guard let hostTime = arrival()?.hostTime, filter.isNew(hostTime) else { return nil }
            let size = size()
            return HandPoseInput(width: size.width, height: size.height, hostTime: hostTime)
        }
    }

    /// 絵と到着の記録から写しを作る組み方。
    ///
    /// **供給の順に注意。** 入り口は足した順に ``Inlet/supply()`` が回る。絵を書き込む入り口 (`Capture`) より
    /// 後に足せば、同じフレームで書かれたばかりの絵を見る。
    convenience init(
        estimator: any HandPoseEstimator, image: Image, arrival: @escaping () -> Arrival?
    ) {
        self.init(estimator: estimator, size: { (image.width, image.height) }, arrival: arrival)
    }

    func start(into input: ExternalInput<HandPoseResult>) {
        stopped = false
        if let worker {
            worker.resume()
        } else {
            worker = HandPoseWorker(estimator: estimator, output: input, dropped: dropped)
        }
        // 用意の状態は、実物の推論が用意に時間を使う段 (#3587) で名乗る
        input.setState(.running)
    }

    func pump(into input: ExternalInput<HandPoseResult>) {
        // 止めている間は絵を見ない — 見ると「見た絵」になり、足し直した後に同じ絵が推論されない
        guard !stopped, let picture = frame() else { return }
        worker?.submit(picture)
    }

    func stop() {
        stopped = true
        forget()
        worker?.stop()
    }
}
