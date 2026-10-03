// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 外から届くものの出どころが、いまどうなっているか。
///
/// カメラ・マイク・機材・通信のどれでも同じ型で名乗る ([ADR-0042] 決定 4)。領域ごとに
/// 失敗の伝え方が分かれると (投げる・旗・コールバック)、利用者は領域の数だけ作法を覚える
/// ことになる。
///
/// **値が来ないことの理由を区別するためにある** ([ADR-0028] 決定 4)。許可を待っている
/// 間も、拒まれた後も、機材が無いときも、見た目はどれも「何も届かない」になる。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
public nonisolated enum SourceState: String, Sendable, Equatable, Encodable {
    /// OS の許可を待っている。まだ誰も答えていない。
    case waitingForPermission
    /// OS の許可が拒まれている。
    case denied
    /// 動いている。値が届きうる。
    case running
    /// 使える機材が無い。**挿されたら始まる** — 投げて外さないのはこのためである。
    case unavailable
    /// 使っていた機材が抜かれた・向こうが終わった。
    case disconnected
    /// 止めた (止めるよう頼まれた)。
    case stopped
}

/// 届いた値が、どのフレームに割り当てられたか。
///
/// **時刻は 1 本にする** ([ADR-0042] 決定 4)。届いた瞬間の時刻 (``hostTime``) と、その値を
/// 取り出したフレーム (``frame`` / ``time``) を組で持つ。スケッチが読むのは後者で、
/// 書き出しと揃うのもこちらである。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
public nonisolated struct Arrival: Sendable, Equatable {
    /// 取り出したフレームの番号。
    public let frame: Int
    /// 取り出したフレームの時刻 (秒)。``Sketch/time`` と同じ時計。
    public let time: Float
    /// 届いた瞬間の host time (`mach_absolute_time` の単位)。
    public let hostTime: UInt64

    public init(frame: Int, time: Float, hostTime: UInt64) {
        self.frame = frame
        self.time = time
        self.hostTime = hostTime
    }
}

/// 入り口 1 つの名乗り。観測の応答の `inputs` に 1 行として載る ([ADR-0028] 決定 4)。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public nonisolated struct SourceReport: Sendable, Equatable, Encodable {
    /// 何の入り口か (読み手が見分けるための名前)。
    public let name: String
    /// 出どころの状態。
    public let state: SourceState
    /// 最後に値が届いたフレーム。まだ 1 つも届いていなければ `nil`。
    public let lastArrival: Arrival?

    public init(name: String, state: SourceState, lastArrival: Arrival?) {
        self.name = name
        self.state = state
        self.lastArrival = lastArrival
    }

    private enum CodingKeys: String, CodingKey {
        case name, state, lastFrame, lastTime
    }

    /// 応答では届いた瞬間の host time を出さない。機械ごとの起点に依る数で、読み手が
    /// 比べられるのはフレームの番号と時刻のほうである。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(lastArrival?.frame, forKey: .lastFrame)
        try container.encodeIfPresent(lastArrival.map { Double($0.time) }, forKey: .lastTime)
    }
}
