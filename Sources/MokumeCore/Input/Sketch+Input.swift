// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// いまの位置 (横)。
    public var mouseX: Float { Self.input.x }
    /// いまの位置 (縦)。
    public var mouseY: Float { Self.input.y }
    /// 前のフレームでの位置 (横)。
    public var pmouseX: Float { Self.input.previousX }
    /// 前のフレームでの位置 (縦)。
    public var pmouseY: Float { Self.input.previousY }
    /// 押されているか。
    public var isMousePressed: Bool { Self.input.isMouseDown }
    /// 最後に押された釦 (0 = 主釦)。
    public var mouseButton: Int { Self.input.button }
    /// このフレームのスクロール量 (横)。
    public var scrollX: Float { Self.input.scrollX }
    /// このフレームのスクロール量 (縦)。
    public var scrollY: Float { Self.input.scrollY }
    /// そのキーが押されているか。
    public func isKeyDown(_ code: Int) -> Bool { Self.input.pressedKeys.contains(code) }
    /// 最後に入力された文字。
    public var key: String { Self.input.characters }

    /// 走っているランタイムの合流点。走っていなければ**空の状態**を返す。
    ///
    /// 描画と違って止めない — 入力を読むだけで落ちると、`draw()` の外 (初期化など) で
    /// 位置を参照しただけのスケッチが動かなくなる。走っていないなら入力は無い、が
    /// 素直な答えである。
    @MainActor
    private static var input: InputState {
        runningSketch?.input ?? InputState.empty
    }
}

extension InputState {
    /// 走っていないときに返す、何も起きていない状態。
    @MainActor
    static let empty = InputState()
}
