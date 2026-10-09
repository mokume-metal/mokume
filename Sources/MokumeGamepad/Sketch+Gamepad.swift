// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

// ゲームパッド。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0041] の地図の「mokume の仕事 (標準)」)。`plugins` には
// 何も書かない — 一覧を返す口が、走っているスケッチへパッドごとの入り口を足す
// (``Sketch/attach(_:)-(Inlet)``)。
//
// 手本 (Processing / p5.js) の本体にゲームパッドは無いので、名前は Issue の作例の綴りに合わせ、
// Swift の慣行に従う ([ADR-0020] 決定 1)。記録を流す口の `create…` は、手本の作る口
// (`createCapture`) と揃える。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0041]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md
extension Sketch {

    /// 繋がったゲームパッドの一覧。走り始めてから初めて繋がった順に並ぶ。
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
    /// - **抜いたパッドも列に残る。** ``Gamepad/state`` が ``SourceState/disconnected`` を名乗り、
    ///   挿し直せば同じ ``Gamepad`` が ``SourceState/running`` に戻る。抜いたものを列から外すと
    ///   後ろの台が前へ詰まり、上の例では円の持ち主が入れ替わる。いま繋がっているものだけが
    ///   要るなら `state == .running` で絞る
    /// - **毎フレーム呼んでよい。** 同じパッドには同じ ``Gamepad`` を返す。後から挿したパッドは、
    ///   OS が繋がったと知らせた後に呼んだときから列の後ろに並ぶ
    /// - 1 台を識別子 (``Gamepad/id``) で選ぶなら、列から探す:
    ///   `gamepads().first { $0.id == "Xbox Wireless Controller #1" }`
    /// - **呼んだときだけ見張り始める。** `import mokume` しただけでは、GameController に触れない
    /// - 許可は要らない。入力が届くのは、スケッチの窓が前面にある間だけである
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。外で呼ぶと、返るパッドは走っている
    /// スケッチに足されず、値が入らない。
    public func gamepads() -> [Gamepad] {
        GamepadRoster.roster(for: self).gamepads(for: self, from: .shared)
    }

    /// 記録した入力の列を、ゲームパッドの代わりに流す。**機材を使わない。**
    ///
    /// `inputs[i]` が、作ってから i 番目のフレームの入力になる。`nil` のフレームは抜かれている
    /// (``Gamepad/state`` が ``SourceState/disconnected`` になり、押していた釦は離したことになる)。
    /// 最後まで行けば最初に戻る。どの入力が入るかはフレームの数え方だけで決まるので、同じ列からは
    /// 何度回しても同じ動きになる — パッドで動かすスケッチを機材の無い場所で確かめるときや、展示の
    /// 前に空回しするときに使う ([ADR-0028] 決定 6・7)。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var pad: Gamepad?
    ///     var x: Float = 100
    ///     func setup() {
    ///         // 60 フレーム右へ倒し、続く 30 フレームは A を押したまま止まる
    ///         let right = Array(repeating: GamepadInput(leftStick: [1, 0]), count: 60)
    ///         let held = Array(repeating: GamepadInput(pressed: [.a]), count: 30)
    ///         pad = createGamepad(inputs: right + held)
    ///     }
    ///     func draw() {
    ///         guard let pad else { return }
    ///         background(0)
    ///         x += pad.leftStick.x * 4
    ///         circle(x, height / 2, pad.isPressed(.a) ? 120 : 60)
    ///     }
    /// }
    /// ```
    ///
    /// 実機のパッドと同じ入れ物を通る — スティックは最新の 1 つ、釦は前のフレームとの差が
    /// 押し離しの出来事として落とさない列に入る。識別子は `"recorded #1"` の形になる。
    ///
    /// - Parameter inputs: フレームごとの入力。抜かれているフレームは `nil`。空なら
    ///   ``Gamepad/state`` が ``SourceState/unavailable`` のまま何も入らない。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createGamepad(inputs: [GamepadInput?]) -> Gamepad {
        GamepadRoster.roster(for: self).recorded(inputs, for: self)
    }
}

/// 1 つのスケッチに足したパッド。``Sketch/gamepads()`` が同じパッドに同じ物を返すためにある。
///
/// スケッチごとに 1 つで、**持ち主を弱く持つ** (``SynthStage`` と同じ形)。手放された後の同じ番地の
/// 別のスケッチが、前のパッドを引き継がないよう、持ち主も照らし合わせる。パッドも弱く持つ —
/// パッドを持つのは走っているスケッチ (入り口の並び) で、ここではない。
final class GamepadRoster {
    private static var rosters: [GamepadRoster] = []

    private weak var owner: (any Sketch)?
    private var pads: [String: WeakPad] = [:]
    private var recordedCount = 0

    private struct WeakPad {
        weak var pad: Gamepad?
    }

    private init(owner: any Sketch) {
        self.owner = owner
    }

    /// `sketch` の一覧。まだ無ければ作る。
    static func roster(for sketch: any Sketch) -> GamepadRoster {
        rosters.removeAll { $0.owner == nil }
        if let found = rosters.first(where: { $0.owner === sketch }) { return found }
        let roster = GamepadRoster(owner: sketch)
        rosters.append(roster)
        return roster
    }

    /// 係が振った識別子ごとのパッド。まだ無い・外されたものは作り、走っているスケッチへ足す。
    func gamepads(for sketch: any Sketch, from hub: GamepadHub) -> [Gamepad] {
        hub.start()
        return hub.slots.known.map { id in
            if let pad = pads[id]?.pad, !pad.isClosed { return pad }
            let pad = Gamepad(
                id: id, name: "gamepad: \(id)", source: ControllerSource(id: id, hub: hub))
            // 走っていなければ足せない (足す口が診断に出す)。次に呼ばれたとき作り直す
            if sketch.attach(pad) { pads[id] = WeakPad(pad: pad) }
            return pad
        }
    }

    /// 記録した入力を流すパッドを作り、走っているスケッチへ足す。
    func recorded(_ inputs: [GamepadInput?], for sketch: any Sketch) -> Gamepad {
        recordedCount += 1
        let id = "recorded #\(recordedCount)"
        let pad = Gamepad(id: id, name: "gamepad (\(id))", source: RecordedGamepadSource(inputs: inputs))
        sketch.attach(pad)
        return pad
    }
}
