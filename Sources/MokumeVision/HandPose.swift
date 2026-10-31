// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 手の関節点の入り口。``Sketch/createHandPose(results:)`` が作り、走っているスケッチへ足す。
///
/// 毎フレーム呼ぶ口は無い。`draw()` の前に、**最新の 1 つ**の結果が ``hands`` に入る ([ADR-0028] 決定 2 の
/// 「最新の 1 つ」)。新しい結果が無いフレームは、前の結果のまま — 溜まらない。
///
/// <!-- example: 文脈 var hands: HandPose? -->
/// ```swift
/// // 見つけた手の関節に円を置く
/// for hand in hands?.hands ?? [] {
///     for joint in hand.joints { circle(joint.position.x, joint.position.y, 8) }
/// }
/// ```
///
/// ## 点は入力の絵の画素の座標
///
/// 返る点は、手を探した**絵の画素の座標**である (左上が原点、y は下向き)。0〜1・左下が原点という
/// Vision の座標は見えない。左右を入れ替えた絵 (`mirrored: true` のカメラの絵) を探したときは、入れ替えた後の
/// 絵の画素の座標で返るので、その絵を描いた上に円を置けば手に重なる。
///
/// ## 結果は元の絵の時刻を持つ
///
/// ``hostTime`` は、結果を出した元の絵が届いた瞬間の host time である。**推論が終わった時刻ではない**。
/// 結果は絵より遅れて届くことがあり、絵の host time (``Arrival/hostTime``) と比べれば遅れが分かる。
/// ``lastArrival`` は、結果を取り出したフレームを答える。
///
/// ## 入り口は足した順に供給される
///
/// 入り口は、足した順に `draw()` の直前に供給される ([ADR-0024] 決定 6)。**絵を書き込む入り口 (`Capture`) より
/// 後に作った手の入り口は、同じフレームで書かれたばかりの絵を見る。** 手を探す入り口を先に作ると、絵は
/// 1 フレーム遅れて渡る。
///
/// ## 状態
///
/// | 状態 | いつ |
/// | --- | --- |
/// | ``SourceState/running`` | 受けている |
/// | ``SourceState/unavailable`` | 記録した結果の列が空 |
/// | ``SourceState/stopped`` | スケッチから外した (``SketchPart/detach(_:)-(Inlet)``)。足し直せば戻る |
///
/// 手が写っていない絵の結果は、``hands`` が空になる。落ちない。許可は要らない。
///
/// 観測の応答の `inputs` にも、同じ状態が載る ([ADR-0028] 決定 4)。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class HandPose: Inlet {
    /// 最新の結果に写っていた手。写っていなければ、また結果がまだ 1 つも届いていなければ空。
    public private(set) var hands: [Hand] = []
    /// 最新の結果の元の絵が届いた瞬間の host time。まだ結果が 1 つも届いていなければ `nil`。
    public private(set) var hostTime: UInt64?

    let input: ExternalInput<HandPoseResult>
    private let source: any HandPoseSource

    init(name: String, source: any HandPoseSource) {
        self.source = source
        input = ExternalInput(name: name, state: .unavailable)
    }

    /// 出どころの状態。
    public var state: SourceState { input.state }
    /// 最新の結果を取り出したフレーム。まだ 1 つも届いていなければ `nil`。
    public var lastArrival: Arrival? { input.lastArrival }

    // MARK: - Inlet

    public func open() throws {
        source.start(into: input)
    }

    public func supply() {
        source.pump(into: input)
        if let result = input.take() {
            hands = result.hands
            hostTime = result.hostTime
        }
    }

    public func close() {
        source.stop()
        input.setState(.stopped)
        // 届いて読まれなかった結果は捨てる。足し直した最初の `supply()` に、外す前のものを当てない
        input.discardWaiting()
        hands = []
        hostTime = nil
    }

    public var report: SourceReport? { input.report }
}
