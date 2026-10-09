// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// ゲームパッド 1 台の入り口。``Sketch/gamepads()`` が繋がったパッドごとに作り、走っている
/// スケッチへ足す。
///
/// 毎フレーム呼ぶ口は無い。`draw()` の前に、そのときのスティックの傾きが ``leftStick`` に入り、
/// 前のフレームの後に届いた釦の押し離しが**全部、届いた順に**当てられている ([ADR-0028] 決定 2 の
/// 「落とさない列」)。
///
/// ```swift
/// final class TwoPlayers: Sketch {
///     var pos: [SIMD2<Float>] = [[300, 300], [900, 300]]
///     func draw() {
///         background(0)
///         for (i, pad) in gamepads().prefix(2).enumerated() {
///             pos[i] += pad.leftStick * 8
///             fill(pad.state == .running ? 255 : 80)
///             circle(pos[i].x, pos[i].y, pad.isPressed(.a) ? 120 : 60)
///         }
///     }
/// }
/// ```
///
/// ## 抜かれたことが読める
///
/// 抜かれると ``state`` が ``SourceState/disconnected`` になり、``leftStick`` は 0 に、押していた
/// 釦は離したことになる。挿し直せば同じ物が ``SourceState/running`` に戻る。観測の応答の
/// `inputs` にも、パッドごとに同じものが載る ([ADR-0028] 決定 4)。
///
/// | 状態 | いつ |
/// | --- | --- |
/// | ``SourceState/running`` | 繋がっている |
/// | ``SourceState/disconnected`` | 抜かれた。挿し直せば戻る |
/// | ``SourceState/unavailable`` | 走っていないスケッチから作った・記録した列が空 |
/// | ``SourceState/stopped`` | スケッチから外した (``Sketch/detach(_:)-(Inlet)``) |
///
/// 許可は要らない。**入力が届くのは、スケッチの窓が前面にある間だけ**である (GameController の
/// 既定。窓のキーやマウスと同じ)。
///
/// 振動・ライト・傾きの検出は持たない。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class Gamepad: Inlet {
    /// 識別子。``Sketch/gamepads()`` が「機種名 #番号」の形で振る (`"Xbox Wireless Controller #1"`)。
    ///
    /// **抜いて挿し直しても同じ値になる。** 挿し直したパッドは、同じ機種名で抜かれている番号の
    /// 小さいものへ戻る。番号は、同じ機種名のパッドが初めて繋がった順に 1 から振る。
    ///
    /// **同じ機種の 2 台を両方抜いて、逆の順に挿すと入れ替わる。** GameController が機材ごとの
    /// 識別子を持たないためで、1 台ずつの抜き差しや、機種の違う台どうしでは入れ替わらない。
    ///
    /// 記録した入力の列を流すパッド (``Sketch/createGamepad(inputs:)``) は `"recorded #1"` の形になる。
    public let id: String

    /// 左スティックの傾き。各軸 -1〜1 で、倒していなければ 0。
    ///
    /// **縦軸は下向き**で、手前に倒すと正になる (``Sketch/mouseY`` と同じ約束)。だから
    /// `pos += pad.leftStick * 8` で、倒した向きへ画面の上の点が動く。
    public private(set) var leftStick: SIMD2<Float> = .zero

    let inbox: GamepadInbox
    private let source: any GamepadSource
    private var pressed: Set<GamepadButton> = []
    /// 外された。``Sketch/gamepads()`` は外されたものを返さず、作り直す。
    private(set) var isClosed = false

    init(id: String, name: String, source: any GamepadSource) {
        self.id = id
        self.source = source
        inbox = GamepadInbox(name: name, state: .unavailable)
    }

    /// 出どころの状態。
    public var state: SourceState { inbox.state }

    /// その釦が押されているか。
    ///
    /// <!-- example: 文脈 var pad: Gamepad! -->
    /// ```swift
    /// circle(width / 2, height / 2, pad.isPressed(.a) ? 120 : 60)
    /// ```
    ///
    /// フレームの頭の状態で答える。前のフレームの後に押して離した釦は、離した後なので偽になる。
    /// 抜かれている間は、どの釦も偽。
    public func isPressed(_ button: GamepadButton) -> Bool {
        pressed.contains(button)
    }

    // MARK: - Inlet

    public func open() throws {
        source.start(into: inbox)
    }

    public func supply() {
        source.pump(into: inbox)
        if let tilt = inbox.stick.take() { leftStick = tilt }
        for change in inbox.changes.take() {
            switch change {
            case .pressed(let button): pressed.insert(button)
            case .released(let button): pressed.remove(button)
            case .releasedAll: pressed.removeAll()
            }
        }
    }

    public func close() {
        isClosed = true
        source.stop()
        inbox.setState(.stopped)
        leftStick = .zero
        pressed.removeAll()
    }

    public var report: SourceReport? { inbox.report }
}
