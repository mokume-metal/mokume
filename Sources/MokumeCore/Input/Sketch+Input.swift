// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// いまの位置 (横)。
    ///
    /// **単位は描く解像度の画素で、窓の大きさによらない。** 窓を大きくしても縮めても、
    /// 同じ場所は同じ数で読める。
    ///
    /// **面の外を指すこともある。** 窓と縦横比が合わないときに出る帯の上へカーソルを
    /// 出すと、負や幅超えの値になる — 丸めていないので、面の外を面の外として扱える
    /// (外から送る経路も範囲外を送れるので、丸めると 2 つの経路で範囲が食い違う)。
    /// 面の中だけを相手にしたいなら、読む側で挟む。
    public var mouseX: Float { Self.input.x }
    /// いまの位置 (縦)。**縦軸は下向き**で、面の上端が 0 (``mouseX`` と同じ約束)。
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
    /// このフレームに、押したまま引きずった量 (横)。
    ///
    /// **押した瞬間には増えない。** `mouseX - pmouseX` を回す量に使うと、押した場所が
    /// 前のフレームの位置と離れているときに絵が飛ぶ — 押下は移動ではないのに、位置の
    /// 差としては現れてしまうためである。引きずって動かす道具はこちらを使う。
    ///
    /// **これはフレームの累計であって、1 件ぶんではない。** ``Sketch/mouseDragged()``
    /// の中から読むと、1 フレームに移動が 3 件届いたときそれぞれの時点までの部分累計に
    /// なる (呼び出しも 3 回)。フレームぶんをまとめて食う道具 —
    /// ``orbitControl(_:_:_:)`` — は `draw()` の中から呼ぶ。
    public var dragX: Float { Self.input.dragX }
    /// このフレームに、押したまま引きずった量 (縦)。
    public var dragY: Float { Self.input.dragY }
    /// そのキーが押されているか。
    public func isKeyDown(_ code: Int) -> Bool { Self.input.pressedKeys.contains(code) }
    /// 最後に入力された文字。
    ///
    /// **文字を生むキーでだけ変わる。** 矢印・ファンクションキー・Escape・Delete では
    /// 更新されない — AppKit がそれらへ返すのは私用領域や制御文字なので、そのまま
    /// 入れると画面に見えない文字が出る。打鍵そのものを受け取る口は
    /// ``Sketch/keyTyped()``。
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
