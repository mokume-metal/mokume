// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 面の座標と空間の座標を行き来する。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {

    // MARK: - 空間 → 画面

    /// 点が、いまの変換でどこへ移るか (横)。
    ///
    /// ```swift
    /// translate(100, 50)
    /// rotate(.pi / 4)
    /// let x = screenX(0, 0)   // 変換を積んだ後の原点が、面のどこにあるか
    /// ```
    ///
    /// **奥行きを渡さない形は視点を通さない。** 平面の図形が通る道と同じで、
    /// ``camera()`` をどう動かしてもこの値は変わらない。視点を通した位置が要るときは
    /// 奥行きまで渡す ``screenX(_:_:_:)`` を使う。
    public func screenX(_ x: Float, _ y: Float) -> Float {
        Self.drawingCanvas?.screenX(x, y) ?? 0
    }

    /// 点が、いまの変換でどこへ移るか (縦)。
    public func screenY(_ x: Float, _ y: Float) -> Float {
        Self.drawingCanvas?.screenY(x, y) ?? 0
    }

    /// 奥行きを持つ点が、いまの変換といまの視点でどこへ移るか (横)。
    ///
    /// ```swift
    /// push()
    /// translate(width / 2, height / 2, 0)
    /// box(120)
    /// let x = screenX(0, 0, 60)   // 箱の手前の面の中心が、面のどこにあるか
    /// pop()
    /// ```
    ///
    /// 変換を積んだ状態でも視点を変えた状態でも、**実際に描かれる画素の位置**が返る。
    /// 立体に文字や印を重ねる、当たり判定を面の座標で書く、といった用途のためにある。
    public func screenX(_ x: Float, _ y: Float, _ z: Float) -> Float {
        Self.drawingCanvas?.screenX(x, y, z) ?? 0
    }

    /// 奥行きを持つ点が、いまの変換といまの視点でどこへ移るか (縦)。
    public func screenY(_ x: Float, _ y: Float, _ z: Float) -> Float {
        Self.drawingCanvas?.screenY(x, y, z) ?? 0
    }

    /// 奥行きを持つ点が、いまの視点でどれだけ奥にあるか。
    ///
    /// **0 が手前の面、1 が奥の面。** 面の上の位置ではなく、奥行きの面に書かれる値
    /// なので、大小を比べれば前後が分かる。
    ///
    /// この値がそのまま ``spacePosition(screenX:screenY:depth:)`` の `depth` になる —
    /// 前向きの 3 本が、後ろ向きの入力を過不足なく作る。
    public func screenZ(_ x: Float, _ y: Float, _ z: Float) -> Float {
        Self.drawingCanvas?.screenZ(x, y, z) ?? 0
    }

    // MARK: - 画面 → 空間

    /// 面の位置が、いまの視点で空間のどこを指すか。
    ///
    /// 返るのは**いまの変換の中の座標**で、``screenX(_:_:_:)`` に渡す座標と同じ意味。
    /// だから前向きと後ろ向きは、変換を積んだ状態でも往復して元へ戻る。
    ///
    /// `depth` は**どの奥行きの面へ戻すか**を決める (0 が手前の面、1 が奥の面)。
    /// 面 1 枚ぶんの位置からは空間の 1 点は決まらないので、戻し先を渡す側が選ぶ。
    /// 掴む・置くはたいてい「掴んだ物と同じ奥行き」なので、その物の
    /// ``screenZ(_:_:_:)`` を取って渡す:
    ///
    /// ```swift
    /// // 箱を掴んで、画面に沿って引きずる
    /// let depth = screenZ(box.x, box.y, box.z)
    /// let pointed = spacePosition(screenX: mouseX, screenY: mouseY, depth: depth)
    /// if isMousePressed { box = pointed }
    /// ```
    ///
    /// 平行投影でも透視投影でも同じように使える (式の違いは視点の側が持つ)。
    public func spacePosition(screenX: Float, screenY: Float, depth: Float) -> SIMD3<Float> {
        Self.drawingCanvas?.spacePosition(screenX: screenX, screenY: screenY, depth: depth)
            ?? .zero
    }

    /// いま描いている面。走っていなければ `nil`。
    ///
    /// 座標を読むのに ``canvas`` を通さないのは、あちらが**走っていなければ止める**
    /// ためである。座標は読み取りなので決して落ちてはならず ([ADR-0020] 決定 5)、
    /// 初期化の中や後片付けの後から呼ばれうる — 入力を読む道 (``mouseX``) が
    /// 「走っていなければ空の状態」を返すのと同じ扱いにする。
    @MainActor
    private static var drawingCanvas: Canvas? { runningSketch?.canvas }
}
