// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// どちらの手か。
///
/// 絵に写った向きのまま答える。左右を入れ替えた絵 (`mirrored: true` のカメラの絵) を渡したときは、
/// 入れ替えた後の絵で見て左右が決まる。
public nonisolated enum Handedness: String, Sendable, Hashable, Codable {
    /// 左手。
    case left
    /// 右手。
    case right
    /// 見分けられなかった。
    case unknown
}

/// 手の関節の名前。1 つの手に 21 あり、`rawValue` が ``Hand/joints`` の並びの番号になる。
///
/// 手首が 1 つ、各指が 4 つ (付け根に近いほうから 3 つの関節と指先)。名前は解剖学の呼び名で、`MCP` は
/// 付け根の関節、`PIP` は指の真ん中の関節、`DIP` は指先に近い関節、親指だけは `CMC`・`MCP`・`IP` と
/// 呼ぶ。
public nonisolated enum HandJointName: Int, Sendable, CaseIterable, Hashable, Codable {
    case wrist
    case thumbCMC, thumbMCP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

/// 手の関節 1 つの位置と信頼度。
public nonisolated struct HandJoint: Sendable, Hashable, Codable {
    /// 位置。**入力の絵の画素の座標**で、左上が原点、y は下向き。描いた絵の上にそのまま重なる。
    public let position: Vector2
    /// 信頼度 (0〜1)。1 に近いほど確か。
    public let confidence: Float

    public init(position: Vector2, confidence: Float) {
        self.position = position
        self.confidence = confidence
    }
}

/// 絵に写った手 1 つの関節点。
///
/// 21 の関節が ``HandJointName`` の順に並ぶ。
public nonisolated struct Hand: Sendable, Hashable, Codable {
    /// どちらの手か。
    public let handedness: Handedness
    /// 21 の関節。``HandJointName`` の `rawValue` が番号になる。``subscript(_:)`` で名前から引ける。
    public let joints: [HandJoint]

    /// 関節の並びから手を作る。**ちょうど 21 の関節が要る** — 数が合わなければ `nil` を返す。
    public init?(handedness: Handedness, joints: [HandJoint]) {
        guard joints.count == HandJointName.allCases.count else { return nil }
        self.handedness = handedness
        self.joints = joints
    }

    /// 名前で引いた関節。
    public subscript(name: HandJointName) -> HandJoint {
        joints[name.rawValue]
    }

    private enum CodingKeys: String, CodingKey {
        case handedness, joints
    }

    /// 関節が 21 でなければ読めない。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let handedness = try container.decode(Handedness.self, forKey: .handedness)
        let joints = try container.decode([HandJoint].self, forKey: .joints)
        guard let hand = Hand(handedness: handedness, joints: joints) else {
            throw DecodingError.dataCorruptedError(
                forKey: .joints, in: container,
                debugDescription: "A hand needs exactly 21 joints, but it had \(joints.count)")
        }
        self = hand
    }
}

/// 1 枚の絵に対する、手の関節点の結果。
///
/// 手が写っていなければ ``hands`` が空の結果になる (落ちない)。`Codable` なので、結果の列を書き出して
/// 読み戻せ、``Sketch/createHandPose(results:)`` で流し直せる。
public nonisolated struct HandPoseResult: Sendable, Hashable, Codable {
    /// 結果を出した元の絵が届いた瞬間の host time (`mach_absolute_time` の単位)。
    ///
    /// **推論が終わった時刻ではない。** 結果は絵より遅れて届くので、この値と絵の host time
    /// (``Arrival/hostTime``) を比べれば、遅れが分かる。
    public let hostTime: UInt64
    /// 写っていた手。写っていなければ空。
    public let hands: [Hand]

    public init(hostTime: UInt64, hands: [Hand]) {
        self.hostTime = hostTime
        self.hands = hands
    }
}
