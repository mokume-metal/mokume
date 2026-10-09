// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// ゲームパッド 2 台で、2 人が円を 1 つずつ動かす (展示で 2 人が遊ぶ形・#1965 の作例)。
///
/// **見どころは、抜かれたパッドの円が灰色で残ること。** 左スティックで円が動き、A を押している
/// 間は円が大きくなる。右の円のパッドは途中で抜かれて灰色の小さな円になって止まり、挿し直すと
/// 白に戻って、同じ円がまた動き出す。抜いたパッドも一覧の同じ位置に残るので、左の円の持ち主は
/// 入れ替わらない。
///
/// パッドはここでは実機ではなく、`setup()` で作った 2 台ぶんの記録した入力を
/// `createGamepad(inputs:)` で流している。**どの入力が入るかはフレームの数え方だけで決まる**
/// ので、書き出すたびに同じ絵になる ([ADR-0028] 決定 7)。実機で動かすなら、`draw()` の
/// `players` を `gamepads()` に替えるだけでよい。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class GamepadAndPlayers: Sketch {
    var settings = SketchSettings(width: 1200, height: 600, title: "gamepad and players")

    /// 記録した入力の長さ (フレーム)。最後まで行けば最初に戻る。
    private static let length = 240
    /// 右のパッドが抜かれているフレーム。
    private static let unplugged = 36..<100

    private var players: [Gamepad] = []
    private var pos: [SIMD2<Float>] = [[300, 300], [900, 300]]

    func setup() {
        players = [createGamepad(inputs: Self.left()), createGamepad(inputs: Self.right())]
    }

    func draw() {
        background(0)
        noStroke()
        for (i, pad) in players.prefix(2).enumerated() {
            pos[i] += pad.leftStick * 8
            fill(pad.state == .running ? 255 : 80)
            circle(pos[i].x, pos[i].y, pad.isPressed(.a) ? 120 : 60)
        }
    }

    /// 左の円のパッド。8 の字に倒し続け、1 秒ごとに A を押す。
    ///
    /// 傾きは周期の整数倍で 1 巡するので、列が最初に戻っても円は同じところを回る。
    private static func left() -> [GamepadInput?] {
        (0..<length).map { frame in
            let turn = Float(frame) / 120 * 2 * .pi
            return GamepadInput(
                leftStick: [0.8 * cos(turn), 0.8 * cos(2 * turn)],
                pressed: (30..<55).contains(frame % 60) ? [.a] : [])
        }
    }

    /// 右の円のパッド。縦長の 8 の字に倒し、途中で抜かれて、挿し直される。
    ///
    /// 傾きは繋がっている間だけ進め、繋がっているフレームの中で 2 巡させる。抜けている間は
    /// 動かないので、列が最初に戻っても円はずれていかない。
    private static func right() -> [GamepadInput?] {
        let connected = length - unplugged.count
        var step = 0
        return (0..<length).map { frame in
            guard !unplugged.contains(frame) else { return nil }
            let turn = Float(step) / Float(connected / 2) * 2 * .pi
            step += 1
            return GamepadInput(
                leftStick: [-0.9 * cos(2 * turn), 0.9 * cos(turn)],
                pressed: (10..<30).contains(frame % 80) ? [.a] : [])
        }
    }
}
