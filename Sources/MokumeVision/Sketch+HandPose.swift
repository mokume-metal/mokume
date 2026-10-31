// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

// 手の関節点の入り口。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0014] の改訂 (2026-10-23)・[ADR-0041] の地図)。`plugins` には何も
// 書かない — 作る口が、走っているスケッチへ自分で入り口を足す (``Sketch/attach(_:)-(Inlet)``)。
//
// 名前 ([ADR-0020] 決定 1): 手本 (ml5.js の `handPose`) の語に揃え、作る口は他の入り口 (`createMIDI`・
// `createGamepad`) の `create` に揃える。記録を流す口の引数ラベルは、MIDI の `messages:`・ゲームパッドの
// `inputs:` と同じく、流すものの名前 (`results:`) にする。
//
// 段 2 (#3586) は結果の型・座標の写し・最新の 1 つの入り口・注入の口までで、実物の推論 (Vision) は段 3
// (#3587) で、絵を受けて手を探す口 (`createHandPose(_:arrival:)`) と一緒に足す。
//
// [ADR-0014]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0014-machine-learning-role.md
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0041]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md
extension Sketch {

    /// 記録した手の関節点の結果の列を、手を探した結果として流す。**カメラも Vision も使わない。**
    ///
    /// `results[i]` が、作ってから i 番目のフレームで ``HandPose/hands`` に入る。最後まで行けば最初に戻る。
    /// どの結果が入るかはフレームの数え方だけで決まるので、同じ列からは何度回しても同じ点が同じフレームに出る。
    /// 手を探した結果だけで描くスケッチは、このリプレイで決定論の水準 2 を名乗れる ([ADR-0025]・[ADR-0028] 決定 7)。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var hands: HandPose?
    ///     func setup() {
    ///         // 手首から指先まで 21 の関節が、1 秒かけて右へ動く手を流す
    ///         hands = createHandPose(results: (0..<60).map { frame in
    ///             let joints = HandJointName.allCases.map { name in
    ///                 let x = 100 + Float(frame) * 3 + Float(name.rawValue) * 8
    ///                 return HandJoint(position: Vector2(x, 100 + Float(name.rawValue) * 6), confidence: 1)
    ///             }
    ///             return HandPoseResult(hostTime: UInt64(frame), hands: Hand(handedness: .right, joints: joints).map { [$0] } ?? [])
    ///         })
    ///     }
    ///     func draw() {
    ///         background(0)
    ///         for hand in hands?.hands ?? [] {
    ///             for joint in hand.joints { circle(joint.position.x, joint.position.y, 8) }
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// - **`nil` のフレームは、新しい結果がまだ届いていない。** 前の結果が最新のまま残る (実物では、結果は絵より
    ///   遅れて届き、毎フレーム新しいとは限らない)
    /// - 結果は ``HandPoseResult`` が持つ host time を、そのまま元の絵の host time として入れる
    /// - 結果の列は `Codable` なので、書き出して読み戻した列からも同じ点が出る
    /// - 外して足し直しても、i 番目のフレームには `results[i]` が入る (外していた間の分は届かない・[#3152](https://github.com/mokume-metal/mokume/issues/3152))
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、走っている
    /// スケッチに足されず何も入らない ``HandPose`` を返し、この口の名前で 1 度だけ警告する。
    ///
    /// - Parameter results: フレームごとの結果。新しい結果がまだ届いていないフレームは `nil`。空の列なら
    ///   ``HandPose/state`` が ``SourceState/unavailable`` のまま何も入らない。
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createHandPose(results: [HandPoseResult?]) -> HandPose {
        let pose = HandPose(
            name: "hand pose (recorded)", source: RecordedHandPoseSource(frames: results, owner: self))
        attach(pose, calledAs: #function, returning: "a hand pose that never receives anything")
        return pose
    }
}
