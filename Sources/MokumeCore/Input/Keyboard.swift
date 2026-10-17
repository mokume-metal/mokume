// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// キーボードへの問い合わせ。``SketchPart/keyboard`` から読む。
///
/// 意味の説明は ``SketchPart/keyboard`` が正本である ([ADR-0020] 決定 4)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public struct Keyboard {
    /// 読む先の合流点。
    let state: InputState

    /// そのキーを押している間 `true`。
    ///
    /// <!-- example: 文脈 var x: Float = 0 -->
    /// ```swift
    /// if keyboard.isPressed(.arrowLeft) { x -= 4 }
    /// ```
    ///
    /// 修飾キー (``Key/shift`` など) は、左右どちらを押していても `true` になる。
    public func isPressed(_ key: Key) -> Bool {
        key.sides.contains(where: state.pressedKeys.contains)
    }

    /// そのキーが、このフレームで押されたら `true`。**押しっぱなしでは、押した 1 フレームだけ。**
    ///
    /// <!-- example: 文脈 var jumps = 0 -->
    /// ```swift
    /// if keyboard.justPressed(.space) { jumps += 1 }
    /// ```
    ///
    /// 1 フレームの中で押して離すと、``justReleased(_:)`` と両方 `true` になり、
    /// ``isPressed(_:)`` は `false` になる。速い連打を落とさない。
    public func justPressed(_ key: Key) -> Bool {
        key.sides.contains(where: state.justPressedKeys.contains)
    }

    /// そのキーが、このフレームで離されたら `true`。
    ///
    /// <!-- example: 文脈 var charging = false -->
    /// ```swift
    /// if keyboard.justReleased(.space) { charging = false }
    /// ```
    ///
    /// **窓が前から退いたときも、押していたキーは離された扱いになる** (``SketchPart/keyboard``)。
    public func justReleased(_ key: Key) -> Bool {
        key.sides.contains(where: state.justReleasedKeys.contains)
    }
}
