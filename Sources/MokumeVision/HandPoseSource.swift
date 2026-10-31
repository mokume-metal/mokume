// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
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
    /// 推論の結果を、利用者へ見せる形へ写す。
    ///
    /// Vision の座標 (0〜1・左下が原点) を、入力の絵の画素の座標 (左上が原点・y は下向き) にする
    /// ([ADR-0014] の改訂 (2026-10-23)・[ADR-0020] 決定 6)。**左右は入れ替えない** — 入力の絵が既に
    /// 入れ替えた後のもの (カメラの `mirrored`) なら、点はその絵の上に重なる。関節が 21 に満たない手は
    /// 捨てる。
    ///
    /// [ADR-0014]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0014-machine-learning-role.md
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    init(raw hands: [RawHand], of frame: HandPoseInput) {
        let width = Float(frame.width)
        let height = Float(frame.height)
        self.init(
            hostTime: frame.hostTime,
            hands: hands.compactMap { hand in
                Hand(
                    handedness: hand.handedness,
                    joints: hand.joints.map {
                        HandJoint(
                            position: Vector2($0.x * width, (1 - $0.y) * height),
                            confidence: $0.confidence)
                    })
            })
    }
}

/// 推論を main actor の外で走らせ、最新の絵だけを渡す係。**溜めない。**
///
/// 推論中に届いた絵は最新の 1 枚だけを持ち、古いものは捨てる ([ADR-0028] 決定 2)。重い推論でも、
/// 描くほう (``submit(_:)`` を呼ぶフレーム) は止まらない。結果は元の絵の host time を持って入れ物へ入る。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
nonisolated final class HandPoseWorker: Sendable {
    private struct State {
        /// 推論待ちの最新の 1 枚。
        var pending: HandPoseInput?
        /// 推論の列が走っているか。
        var running = false
        /// 止められているか。止めた後に終わった推論の結果は入れない。
        var stopped = false
        /// 止められた回数。止める前に始めた推論は、足し直された後に終わっても結果を入れない。
        var stops = 0
    }

    private let estimator: any HandPoseEstimator
    private let output: ExternalInput<HandPoseResult>
    private let state = Mutex(State())

    init(estimator: any HandPoseEstimator, output: ExternalInput<HandPoseResult>) {
        self.estimator = estimator
        self.output = output
    }

    /// 次に推論する絵を渡す。待っていた絵があれば置き換える。**すぐ返る。**
    func submit(_ frame: HandPoseInput) {
        let begins = state.withLock { state -> Bool in
            // 止められている間に届いた絵は捨てる (足し直した最初の推論に、外していた間の絵を当てない)
            guard !state.stopped else { return false }
            state.pending = frame
            guard !state.running else { return false }
            state.running = true
            return true
        }
        guard begins else { return }
        Task.detached(priority: .userInitiated) { [self] in await drain() }
    }

    /// 開く。止めた後に足し直されたときも呼ばれる。
    func resume() {
        state.withLock { $0.stopped = false }
    }

    /// 止める。待っている絵は捨て、走っている推論の結果は入れない。
    func stop() {
        state.withLock {
            $0.stopped = true
            $0.stops += 1
            $0.pending = nil
        }
    }

    /// 待っている絵がなくなるまで、1 枚ずつ推論する。
    private func drain() async {
        while true {
            let next = state.withLock { state -> (frame: HandPoseInput, stops: Int)? in
                if !state.stopped, let frame = state.pending {
                    state.pending = nil
                    return (frame, state.stops)
                }
                state.running = false
                return nil
            }
            guard let (frame, stops) = next else { return }
            let result = HandPoseResult(raw: await estimator.estimate(frame), of: frame)
            // 推論を始めた後に止められていなければ入れる。確かめてから入れるまでの間に止められないよう、錠の内側で入れる
            state.withLock { state in
                if !state.stopped, state.stops == stops { output.send(result, hostTime: frame.hostTime) }
            }
        }
    }
}

/// 推論で回す出どころ。届いた絵を ``HandPoseWorker`` に渡し、結果は worker が入れ物へ入れる。
///
/// 絵の写し (``HandPoseInput``) は `frame` が作る。**新しい絵が届いたときだけ**値を返し、無ければ
/// `nil` を返す — 同じ絵を 2 度推論しない。
final class InferenceSource: HandPoseSource {
    private let frame: () -> HandPoseInput?
    private let estimator: any HandPoseEstimator
    private var worker: HandPoseWorker?

    init(estimator: any HandPoseEstimator, frame: @escaping () -> HandPoseInput?) {
        self.estimator = estimator
        self.frame = frame
    }

    /// 絵と到着の記録から写しを作る組み方。`arrival` の host time が前と変わったときが、新しい絵である。
    ///
    /// **供給の順に注意。** 入り口は足した順に ``Inlet/supply()`` が回る。絵を書き込む入り口 (`Capture`) より
    /// 後に足せば、同じフレームで書かれたばかりの絵を見る。
    convenience init(
        estimator: any HandPoseEstimator, image: Image, arrival: @escaping () -> Arrival?
    ) {
        var last: UInt64?
        self.init(estimator: estimator) {
            guard let hostTime = arrival()?.hostTime, hostTime != last else { return nil }
            last = hostTime
            return HandPoseInput(width: image.width, height: image.height, hostTime: hostTime)
        }
    }

    func start(into input: ExternalInput<HandPoseResult>) {
        if let worker {
            worker.resume()
        } else {
            worker = HandPoseWorker(estimator: estimator, output: input)
        }
        // 用意の状態は、実物の推論が用意に時間を使う段 (#3587) で名乗る
        input.setState(.running)
    }

    func pump(into input: ExternalInput<HandPoseResult>) {
        guard let picture = frame() else { return }
        worker?.submit(picture)
    }

    func stop() {
        worker?.stop()
    }
}
