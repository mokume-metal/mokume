// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// ゲームパッド 1 台の、1 フレームぶんの入力。``Sketch/createGamepad(inputs:)`` に配列で渡し、
/// 実機のパッドの代わりに再生する。
///
/// <!-- example: 文脈 var pad: Gamepad? -->
/// ```swift
/// // 右へ倒しながら A を押している 1 フレーム
/// let held = GamepadInput(leftStick: [1, 0], pressed: [.a])
/// pad = createGamepad(inputs: [held])
/// ```
public nonisolated struct GamepadInput: Sendable, Equatable {
    /// 左スティックの傾き。各軸 -1〜1 で、**縦軸は下向き** (``Gamepad/leftStick`` と同じ座標系)。
    /// 渡した値をそのまま使う。
    public var leftStick: Vector2
    /// 押されているボタン。
    public var pressed: Set<GamepadButton>

    /// - Parameters:
    ///   - leftStick: 左スティックの傾き。省略すると倒していない状態。
    ///   - pressed: 押されているボタン。省略すると何も押していない状態。
    public init(leftStick: Vector2 = Vector2(0, 0), pressed: Set<GamepadButton> = []) {
        self.leftStick = leftStick
        self.pressed = pressed
    }
}
