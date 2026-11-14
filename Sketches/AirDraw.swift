// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 手の関節に円を置き、人差し指の先が通った跡を線で残す (ml5.js の handPose の作例)。
/// **既定は記録した結果を流し、キーを押したときだけ実機のカメラと推論 (Vision) へ切り替える参照スケッチ** ([#3587])。
///
/// 手の推論はカメラ・許可・OS のモデルに依り、同じ絵にならない。そこで**既定は `createHandPose(results:)` に、
/// `setup()` で作った手 (21 の関節) が 8 の字を描いて動く結果の列を流す**。カメラも推論も使わず、同じフレームは
/// 同じ絵になるので、台帳に載るのはこの注入の 1 枚である。実機は C を押したときだけ開く。
///
/// **注入の確認は、実機の確認の代わりにならない。** 推論の用意の間の表示・手の写った映像との重なり
/// (`mirrored: true` で指先と円が重なるか)・推論の遅れは、C で切り替えてウィンドウで確かめる。
///
/// ## 起動方法
///
/// ウィンドウを開いて走らせる (`swift run reference-sketches air-draw`)。何も押さない間は、カメラの許可を使わない。
///
/// ## 操作
///
/// - C — 実機のカメラ (`createCapture(_:_:mirrored:)` の `mirrored: true`) と、その画像から手を探す推論
///   (`createHandPose(_:arrival:)`) へ切り替える。もう一度押すと止めて記録へ戻る
/// - Space — 跡を消す
///
/// ## 正しい見え方 (記録)
///
/// 21 の白い円が手の形 (手首と 5 本の指) に並び、8 の字を描いて動く。人差し指の先の円だけ橙で、通った跡が
/// 橙の線で残る (古い跡から消える)。
///
/// ## 正しい見え方 (実機・C)
///
/// 鏡のように左右を入れ替えたカメラの映像が出る。手をかざすと、関節の上に円が重なり、人差し指の先を動かすと
/// 跡が残る。右手を上げると画面の右側で動く (鏡と同じ)。下に推論の状態 (`state`) が出る:
///
/// - 用意している — 推論のモデルを読み込んでいる (この Mac で初めて使うときは数秒)。描画は止まらない
/// - 動いている — 推論している。手が写っていなくてもこの状態で、円は出ない
/// - 止めた — C で止めた
///
/// ## 異常の兆候
///
/// - 何も押していないのに、カメラの許可を求められる・カメラが開く
/// - 実機で、円が手から左右にずれる (反転した映像と点の座標が食い違っている)
/// - 用意している、のまま動いているにならない
///
/// [#3587]: https://github.com/mokume-metal/mokume/issues/3587
final class AirDraw: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 640, height: 480, title: "air draw")
    }

    /// 記録した結果の列の長さ (8 の字を 1 周するフレームの数)。
    private static let loop = 240
    /// 残す跡の点の数。
    private static let trailLength = 90

    /// 記録した結果を流す入り口。
    var recorded: HandPose?
    /// 実機。C で切り替えている間だけ持つ。
    var camera: Capture?
    /// 実機の画像から手を探す入り口。C で切り替えている間だけ持つ。
    var live: HandPose?
    /// 実機を開こうとして投げられた理由。
    var failure = ""
    /// 人差し指の先が通った跡。
    var trail: [Vector2] = []

    func setup() {
        recorded = createHandPose(results: (0..<Self.loop).map { Self.result(frame: $0) })
    }

    func keyPressed() {
        if keyCode == .space { trail = [] }
        guard keyCode == .c else { return }
        trail = []
        if let camera {
            camera.stop()
            if let live { detach(live) }
            self.camera = nil
            live = nil
            if let recorded { attach(recorded) }
        } else {
            do {
                let camera = try createCapture(640, 480, mirrored: true)
                self.camera = camera
                // カメラより後に作る: 同じフレームで書かれたばかりの画像を探す
                live = createHandPose(camera.image, arrival: { camera.lastArrival })
                failure = ""
                if let recorded { detach(recorded) }
            } catch {
                failure = "\(error)"
            }
        }
    }

    func draw() {
        background(18, 18, 24)
        // 点は画像のピクセル座標なので、画像を拡大せずに原点へ描けば重なる
        if let camera { image(camera.image, 0, 0) }
        guard let hands = live ?? recorded else { return }

        // 新しい結果が届いたフレームだけ、跡に足す
        if hands.lastArrival?.frame == frameCount, let hand = hands.hands.first {
            trail.append(hand[.indexTip].position)
            if trail.count > Self.trailLength { trail.removeFirst(trail.count - Self.trailLength) }
        }

        noFill()
        stroke(255, 170, 40)
        strokeWeight(4)
        beginShape()
        for point in trail { vertex(point.x, point.y) }
        endShape()

        noStroke()
        for hand in hands.hands {
            for (index, joint) in hand.joints.enumerated() {
                if index == HandJointName.indexTip.rawValue { fill(255, 170, 40) } else { fill(240, 240, 255) }
                circle(joint.position.x, joint.position.y, index == HandJointName.indexTip.rawValue ? 14 : 9)
            }
        }

        fill(230, 237, 255)
        textSize(18)
        text(live == nil ? "記録した手を流している (カメラも推論も使わない)。C で実機へ" : "実機のカメラと推論。C で記録へ戻る", 16, 28)
        if live != nil { stateLine(hands) }
        if !failure.isEmpty {
            fill(242, 140, 64)
            textSize(14)
            text("実機を開けなかった: \(failure)", 16, 420, 608, 48)
        }
    }

    /// 推論の状態。
    private func stateLine(_ hands: HandPose) {
        let label: String
        switch hands.state {
        case .preparing: label = "用意している (モデルを読み込んでいる)"
        case .running: label = hands.hands.isEmpty ? "動いている (手が写っていない)" : "動いている (手 \(hands.hands.count) つ)"
        case .stopped: label = "止めた"
        case .waitingForPermission, .denied, .unavailable, .disconnected: label = "\(hands.state)"
        }
        fill(hands.state == .running ? color(120, 230, 160) : color(242, 217, 89))
        textSize(16)
        text("推論 \(label)   カメラ \(camera.map { "\($0.state)" } ?? "—")", 16, 460)
    }

    // MARK: - 記録する手

    /// `frame` 番目の結果。手 1 つが 8 の字を描いて動き、少し傾く。
    private static func result(frame: Int) -> HandPoseResult {
        let t = Float(frame) / Float(loop) * 2 * Float.pi
        let center = Vector2(320 + 170 * sin(t), 250 + 80 * sin(2 * t))
        let tilt = 0.25 * sin(t)
        let hands = hand(wrist: center, tilt: tilt).map { [$0] } ?? []
        return HandPoseResult(hostTime: UInt64(frame + 1), hands: hands)
    }

    /// 手首を `wrist` に置き、指を上へ扇に開いた右手。`tilt` だけ時計回りに傾ける。
    private static func hand(wrist: Vector2, tilt: Float) -> Hand? {
        // 指ごとの向き (上が 0・ラジアン) と、付け根から先への 4 つの距離
        let fingers: [(angle: Float, reach: [Float])] = [
            (-1.1, [24, 48, 70, 90]),  // 親指 (CMC・MCP・IP・先)
            (-0.42, [62, 92, 114, 134]),  // 人差し指 (MCP・PIP・DIP・先)
            (-0.12, [64, 98, 122, 144]),  // 中指
            (0.17, [60, 92, 114, 134]),  // 薬指
            (0.46, [54, 80, 98, 114]),  // 小指
        ]
        var joints = [HandJoint(position: wrist, confidence: 1)]
        for finger in fingers {
            let angle = finger.angle + tilt
            for distance in finger.reach {
                let position = Vector2(wrist.x + distance * sin(angle), wrist.y - distance * cos(angle))
                joints.append(HandJoint(position: position, confidence: 1))
            }
        }
        return Hand(handedness: .right, joints: joints.compactMap { $0 })
    }
}
