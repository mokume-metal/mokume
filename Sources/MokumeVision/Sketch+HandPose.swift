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
// [ADR-0014]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0014-machine-learning-role.md
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0041]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md
extension Sketch {

    /// 画像に写った手を探し、手ごとに 21 の関節点を返す入力ソースを作る。OS の Vision の手の姿勢推定
    /// (`VNDetectHumanHandPoseRequest`) を使う。
    ///
    /// カメラに手をかざすと、関節に円が置かれ、人差し指の先が通った跡が線として残る:
    ///
    /// ```swift
    /// final class AirDraw: Sketch {
    ///     var camera: Capture?
    ///     var hands: HandPose?
    ///     var trail: [Vector2] = []
    ///
    ///     func setup() throws {
    ///         let camera = try createCapture(640, 480, mirrored: true)
    ///         self.camera = camera
    ///         // カメラより後に作る: 同じフレームで書かれたばかりの画像を探す
    ///         hands = createHandPose(camera.image, arrival: { camera.lastArrival })
    ///     }
    ///
    ///     func draw() {
    ///         background(0)
    ///         guard let camera, let hands else { return }
    ///         image(camera.image, 0, 0)
    ///         if hands.state == .preparing { text("準備中", 10, 20) }
    ///         noStroke()
    ///         for hand in hands.hands {
    ///             for joint in hand.joints { circle(joint.position.x, joint.position.y, 8) }
    ///             trail.append(hand[.indexTip].position)
    ///         }
    ///         if trail.count > 300 { trail.removeFirst(trail.count - 300) }
    ///         noFill()
    ///         stroke(255, 200, 0)
    ///         beginShape()
    ///         for point in trail { vertex(point.x, point.y) }
    ///         endShape()
    ///     }
    /// }
    /// ```
    ///
    /// - **点は渡した画像のピクセル座標で返る** (左上が原点・y は下向き)。`mirrored: true` のカメラの画像を渡せば、
    ///   左右を入れ替えた後の画像の座標で返るので、その画像を描いた上に円を置けば手に重なる
    /// - **新しい画像が届いたときだけ探す。** `arrival` が返す到着の記録 (``Arrival``) の host time が前と変わった
    ///   フレームで、画像のピクセルを読んで推論に渡す。結果は元の画像の host time を持つ (``HandPose/hostTime``)。
    ///   `arrival` を省くと、画像を 1 度だけ探す (`loadImage` で読んだ写真など)。そのときの host time は 0
    /// - **推論は main actor の外で走り、描画は止まらない。** 結果は画像より遅れて届き、届くまでは前の結果のまま。
    ///   推論中に届いた画像は最新の 1 枚だけを持ち、溜めない
    /// - **作った時点でモデルの用意を始める。** 用意が済むまで ``HandPose/state`` は ``SourceState/preparing``
    ///   で、描画は続く。済めば、手が写っていなくても ``SourceState/running`` になる (この Mac で初めて
    ///   使うときは数秒かかる)
    /// - **固定の時計 (``SketchPart/clock`` が ``Clock/frameIndex(frameRate:)``) では推論を待つ。** 書き出し
    ///   (`mokume render`) では、作るときに用意を、画像が届いたフレームごとに推論を待つので、フレーム N に届いた
    ///   画像の結果がフレーム N の `draw()` に出る。実時間の時計では待たない。1 回の待ちが 30 秒を越えたら、
    ///   その結果なしで進め、警告し、以後は待たない
    /// - 手が写っていない画像では ``HandPose/hands`` が空になる。許可は要らない (カメラの許可は `Capture` が持つ)
    ///
    /// ピクセルは ``Image/readPixels()`` で読み、乗算済みのアルファを外し sRGB の転送関数を掛けて Vision に渡す。
    /// 1 枚ごとに画像の大きさに比例する費用がかかる。
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・終了処理の後・`Task` の中) で呼ぶと、実行中の
    /// スケッチに追加されず何も入らない ``HandPose`` を返し、この API の名前で 1 度だけ警告する。
    ///
    /// - Parameters:
    ///   - image: 手を探す画像。カメラ (`Capture/image`)・動画 (`Movie/image`)・読み込んだ画像など。
    ///   - arrival: 画像が届いたことを知らせる到着の記録。カメラなら `{ camera.lastArrival }`。省けば 1 度だけ探す。
    // shot: 撮れない 手の写った映像と実物の推論 (Vision) を要する。作例の絵は参照スケッチ (air-draw) が記録した結果で撮る
    public func createHandPose(_ image: Image, arrival: (() -> Arrival?)? = nil) -> HandPose {
        createHandPose(image, arrival: arrival, estimator: VisionHandPoseEstimator(), calledAs: #function)
    }

    /// 推論を差し替えて作る (検査が偽の推論を差す)。固定の時計かどうかは、このスケッチの ``SketchPart/clock`` で見る。
    func createHandPose(
        _ image: Image, arrival: (() -> Arrival?)?, estimator: any HandPoseEstimator,
        patience: Duration = InferenceSource.defaultPatience, calledAs call: String = #function
    ) -> HandPose {
        let arrival = arrival ?? { Arrival(frame: 0, time: 0, hostTime: 0) }
        let source = InferenceSource(
            estimator: estimator, image: image,
            waits: { [weak self] in self.map { $0.clock != .wallClock } ?? false }, patience: patience,
            arrival: arrival)
        let pose = HandPose(name: "hand pose", source: source)
        attach(pose, calledAs: call, returning: "a hand pose that never receives anything")
        return pose
    }

    /// 記録した手の関節点の結果の列を、手を探した結果として流す。**カメラも Vision も使わない。**
    ///
    /// `results[i]` が、作ってから i 番目のフレームで ``HandPose/hands`` に入る。最後まで行けば最初に戻る。
    /// どの結果が入るかはフレームの数え方だけで決まるので、同じ列からは何度回しても同じ点が同じフレームに出る。
    /// 手を探した結果だけで描くスケッチは、このリプレイで決定論の水準 2 を満たせる ([ADR-0025]・[ADR-0028] 決定 7)。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var hands: HandPose?
    ///     func setup() {
    ///         // 手首から指先まで 21 の関節が、1 秒かけて右へ動く手を流す
    ///         hands = createHandPose(results: (0..<60).map { frame in
    ///             let joints = HandJointName.allCases.compactMap { name in
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
    /// - **`nil` のフレームは、新しい結果がまだ届いていない。** 前の結果が最新のまま残る (実物では、結果は画像より
    ///   遅れて届き、毎フレーム新しいとは限らない)
    /// - 結果は ``HandPoseResult`` が持つ host time を、そのまま元の画像の host time として入れる
    /// - 結果の列は `Codable` なので、書き出して読み戻した列からも同じ点が出る。読み戻すときは、位置が有限でない関節・信頼度が 0〜1 を外れた関節を読めないものとして拒否する
    /// - 取り外して追加し直しても、i 番目のフレームには `results[i]` が入る (取り外していた間の分は届かない・[#3152](https://github.com/mokume-metal/mokume/issues/3152))
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・終了処理の後・`Task` の中) で呼ぶと、実行中の
    /// スケッチに追加されず何も入らない ``HandPose`` を返し、この API の名前で 1 度だけ警告する。
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
