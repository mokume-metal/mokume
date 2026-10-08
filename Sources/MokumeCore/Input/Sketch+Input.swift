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
    /// 最後に押されたか離された釦。まだ何も押していなければ `nil`。
    ///
    /// <!-- example: 文脈 var marks: [Float] = [] -->
    /// ```swift
    /// func mouseReleased() {
    ///     if mouseButton == .right { marks.removeAll() }
    /// }
    /// ```
    ///
    /// **押しても離しても入れ替わる。** ``mouseReleased()`` の中から「どの釦が離されたか」
    /// を知る口はここしかない (``keyCode`` と同じ)。押していない間も最後に離した釦を指した
    /// ままなので、いま押されているかは ``isMousePressed`` で見る。
    ///
    /// **手本と綴りは同じだが、数ではない** ([ADR-0034] 決定 1)。手本の `LEFT` / `RIGHT` /
    /// `CENTER` は ``MouseButton/left`` / ``MouseButton/right`` / ``MouseButton/center`` と
    /// 書く。Processing の定数は 37 / 39 / 3、ブラウザの番号は 0 / 2 / 1 で、どちらも
    /// mokume が運ぶ macOS の番号 (0 = 左・1 = 右・2 = 中) とは合わない。**型が違うので、
    /// 写した数の比較はコンパイルの時点で止まる** — 黙って別の釦になるより、そこで気付ける
    /// ほうがよい。
    ///
    /// `switch` で分けるときも `case .left:` と書ける。まだ何も押していないときの `nil` は
    /// `default` の枝へ落ちる。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    public var mouseButton: MouseButton? { Self.input.button }
    /// このフレームのスクロール量 (横)。
    ///
    /// **これはフレームの合計で、`draw()` から読むためのもの。** 出来事 1 件ぶんの量が
    /// 要るなら ``Sketch/mouseWheel(deltaX:deltaY:)`` が引数で受け取る。あちらの中から
    /// ここを読むと、その出来事までの部分累計を何度も足し込む形になる ([ADR-0034] 決定 5)。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    public var scrollX: Float { Self.input.scrollX }
    /// このフレームのスクロール量 (縦)。
    public var scrollY: Float { Self.input.scrollY }
    /// このフレームに、押したまま引きずった量 (横)。
    ///
    /// **押した瞬間には増えない。** `mouseX - pmouseX` を回す量に使うと、押した場所が
    /// 前のフレームの位置と離れているときに絵が飛ぶ — 押下は移動ではないのに、位置の
    /// 差としては現れてしまうためである。引きずって動かす道具はこちらを使う。
    ///
    /// **これはフレームの合計で、`draw()` から読むためのもの。** 出来事 1 件ぶんの量が
    /// 要るなら ``Sketch/mouseDragged(deltaX:deltaY:)`` が引数で受け取る — 1 フレーム
    /// ぶんを足し合わせればここと一致する。
    public var dragX: Float { Self.input.dragX }
    /// このフレームに、押したまま引きずった量 (縦)。
    public var dragY: Float { Self.input.dragY }
    /// このフレームに動いた量 (横)。**押しているかによらず数える。**
    ///
    /// カーソルを捕まえている間 (``requestPointerLock()``) は ``mouseX`` が動かないので、
    /// 手を動かした量はここで読む。単位は描く解像度の画素で、縦軸は下向きである
    /// (``mouseY`` と同じ約束)。
    ///
    /// ```swift
    /// var yaw: Float = 0
    ///
    /// func draw() {
    ///     yaw += movedX * 0.005
    /// }
    /// ```
    ///
    /// **押下・解放で位置が飛んだぶんは数えない** (``dragX`` と同じ約束)。捕まえていないときは
    /// 移動の出来事ごとの位置の差を、捕まえているときは手を動かした量そのものを足す。
    ///
    /// **これはフレームの合計で、`draw()` から読むためのもの。** 出来事 1 件ぶんの量は
    /// ``Sketch/mouseMoved(deltaX:deltaY:)`` と ``Sketch/mouseDragged(deltaX:deltaY:)`` が引数で
    /// 受け取り、両方を足すとここと一致する。あちらの中からここを読むと、その出来事までの部分
    /// 累計を何度も足し込む形になる ([ADR-0034] 決定 5)。
    ///
    /// **手本 (p5.js) とは数え方が違う。** 名前は手本の `movedX` だが、p5.js 1.11 は最新の
    /// 1 件で上書きするので、手本で `mouseMoved()` の中から `movedX` を読む書き方は 1 件ぶんに
    /// なる。ここはフレームの合計なので、その行をそのまま写すと回りすぎる — 1 件ぶんは
    /// ``Sketch/mouseMoved(deltaX:deltaY:)`` の引数で受け取る。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    public var movedX: Float { Self.input.movedX }
    /// このフレームに動いた量 (縦)。**縦軸は下向き**で、手前へ引くと正になる。
    public var movedY: Float { Self.input.movedY }
    /// そのキーが押されているか。
    public func isKeyDown(_ key: Key) -> Bool { Self.input.pressedKeys.contains(key) }
    /// 最後に入力された文字。
    ///
    /// **文字を生むキーでだけ変わる。** 矢印・ファンクションキー・Escape・Delete では
    /// 更新されない — AppKit がそれらへ返すのは私用領域や制御文字なので、そのまま
    /// 入れると画面に見えない文字が出る。打鍵そのものを受け取る口は
    /// ``Sketch/keyTyped()``。
    public var key: String { Self.input.characters }
    /// 最後に押されたか離されたキー。まだ何も来ていなければ `nil`。
    ///
    /// **どの文字が打たれたかではなく、どのキーが動いたか**を表す。配列や修飾キーに
    /// よらないので、「W で前へ進む」のような操作の割り当てはこちらで書く。打たれた
    /// 文字が要るなら ``key`` を読む。
    ///
    /// ```swift
    /// if keyCode == .space { background(240, 240, 240) }
    /// ```
    ///
    /// **手本と綴りは同じだが、数ではない** ([ADR-0034] 決定 1)。p5.js の `keyCode` は
    /// ブラウザの符号を返すので `keyCode == 32` のように数と比べる書き方があるが、
    /// mokume が運んでいるのは macOS の仮想キーコードで、同じ数が別のキーを指す。
    /// **型が違うので、写した数の比較はコンパイルの時点で止まる** — 黙って別のキーに
    /// なるより、そこで気付けるほうがよい。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    public var keyCode: Key? { Self.input.lastKey }

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
