// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// ゲームパッド 1 台の、1 フレームぶんの入力。``Sketch/createGamepad(inputs:)`` に列で渡し、
/// パッドの代わりに流す。
///
/// <!-- example: 文脈 var pad: Gamepad? -->
/// ```swift
/// // 右へ倒しながら A を押している 1 フレーム
/// let held = GamepadInput(leftStick: [1, 0], pressed: [.a])
/// pad = createGamepad(inputs: [held])
/// ```
public nonisolated struct GamepadInput: Sendable, Equatable {
    /// 左スティックの傾き。各軸 -1〜1 で、**縦軸は下向き** (``Gamepad/leftStick`` と同じ約束)。
    /// 渡した値をそのまま流す。
    public var leftStick: SIMD2<Float>
    /// 押されている釦。
    public var pressed: Set<GamepadButton>

    /// - Parameters:
    ///   - leftStick: 左スティックの傾き。省けば倒していない。
    ///   - pressed: 押されている釦。省けば何も押していない。
    public init(leftStick: SIMD2<Float> = .zero, pressed: Set<GamepadButton> = []) {
        self.leftStick = leftStick
        self.pressed = pressed
    }
}
