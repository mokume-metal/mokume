// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 釦の押し離し 1 件。落とさない列 (``ExternalQueue``) に届いた順で入る。
nonisolated enum GamepadChange: Sendable, Equatable {
    case pressed(GamepadButton)
    case released(GamepadButton)
    /// 抜かれた。押していた釦をすべて離したことにする。
    ///
    /// **列に入れて順に当てる。** 抜いた瞬間の状態をフレームの側で消すと、抜いて挿し直すまでが
    /// 1 フレームに収まったとき、抜く前に押していた釦が押されたまま残る。
    case releasedAll
}

/// パッド 1 台ぶんの入れ物。**届き方の違う 2 つを分けて持つ** ([ADR-0028] 決定 2)。
///
/// - スティックの傾きは最新の 1 つ (``ExternalInput``)。1 台で毎秒数百件届き、要るのは
///   フレームの頭のいまの値だけである。列に溜めると、読まない間に上限で捨てた知らせが意味の
///   無いところで出る
/// - 釦の押し離しは落とさない列 (``ExternalQueue``)。1 フレームに押して離したものも、届いた順に
///   全部当てる
///
/// 状態は 2 つに同じものを置く。読むのは列の側である。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
nonisolated final class GamepadInbox: Sendable {
    let name: String
    let stick: ExternalInput<SIMD2<Float>>
    let changes: ExternalQueue<GamepadChange>

    init(name: String, state: SourceState) {
        self.name = name
        stick = ExternalInput(name: name, state: state)
        changes = ExternalQueue(name: name, state: state)
    }

    /// 出どころの状態を変える。
    func setState(_ state: SourceState) {
        stick.setState(state)
        changes.setState(state)
    }

    /// 出どころの状態。
    var state: SourceState { changes.state }

    /// 抜かれた。傾きを 0 に戻し、押していた釦を離したことにして、抜かれたと名乗る。
    /// 実機の係 (``GamepadHub``) も記録の再生も、抜かれたときはこの形で入れる。
    func unplug() {
        stick.send(.zero)
        changes.send(.releasedAll)
        setState(.disconnected)
    }

    /// 観測の応答に載せる名乗り。最後に届いたのは、2 つの入れ物のうち後に取り出したほう。
    var report: SourceReport {
        let arrivals = [stick.lastArrival, changes.lastArrival].compactMap { $0 }
        let latest = arrivals.max { ($0.frame, $0.hostTime) < ($1.frame, $1.hostTime) }
        return SourceReport(name: name, state: state, lastArrival: latest)
    }
}

/// パッドの入力の出どころ。**実機も記録の再生も、同じ入れ物 (``GamepadInbox``) へ入れる**
/// ([ADR-0028] 決定 6・[ADR-0042] 決定 4 の「供給元を差し替えられる」)。
///
/// 入れ物から先 (``Gamepad``) は出どころを知らない。だから記録の再生で回した検査が、実機の
/// ときの受け取りの正しさをそのまま固定する。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
protocol GamepadSource: AnyObject {
    /// 始める。届いた入力と状態は `inbox` へ入れる。
    func start(into inbox: GamepadInbox)
    /// フレームごと、取り出す前に呼ばれる。**実機は何もしない** (入力は向こうの都合で届く)。
    func pump(into inbox: GamepadInbox)
    /// 止める。
    func stop()
}

/// 記録した入力の列を、フレームごとに 1 つずつ入れる出どころ。**機材を使わない。**
///
/// どの入力が入るかはフレームの数え方だけで決まる (始めてから何回目の取り出しか) ので、
/// 同じ列からは何度回しても同じ入力が同じフレームに出る ([ADR-0028] 決定 7)。
///
/// 実機と同じ入れ物を通すため、釦は前のフレームとの差を押し離しの出来事にして列へ入れ、
/// `nil` (抜かれている) は実機が抜かれたときと同じ形で入れる。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class RecordedGamepadSource: GamepadSource {
    private let inputs: [GamepadInput?]
    private var next = 0
    /// 前のフレームで押されていた釦。抜かれていれば空。
    private var held: Set<GamepadButton> = []
    private var stopped = false

    init(inputs: [GamepadInput?]) {
        self.inputs = inputs
    }

    func start(into inbox: GamepadInbox) {
        inbox.setState(inputs.isEmpty ? .unavailable : .running)
    }

    func pump(into inbox: GamepadInbox) {
        guard !inputs.isEmpty, !stopped else { return }
        let input = inputs[next % inputs.count]
        next += 1
        guard let input else {
            if inbox.state != .disconnected { inbox.unplug() }
            held = []
            return
        }
        inbox.setState(.running)
        inbox.stick.send(input.leftStick)
        // 並べる順を名前で固定する。集合の順は回ごとに変わりうる
        for button in held.subtracting(input.pressed).sorted(by: Self.byName) {
            inbox.changes.send(.released(button))
        }
        for button in input.pressed.subtracting(held).sorted(by: Self.byName) {
            inbox.changes.send(.pressed(button))
        }
        held = input.pressed
    }

    func stop() {
        stopped = true
    }

    private static func byName(_ lhs: GamepadButton, _ rhs: GamepadButton) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
