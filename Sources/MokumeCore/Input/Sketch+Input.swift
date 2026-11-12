// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension SketchPart {
    /// いまの位置 (横)。
    ///
    /// **単位は描く解像度の画素で、ウィンドウの大きさによらない。** ウィンドウを大きくしても縮めても、
    /// 同じ場所は同じ数で読める。
    ///
    /// **面の外を指すこともある。** ウィンドウと縦横比が合わないときに出る帯の上へカーソルを
    /// 出すと、負や幅超えの値になる — 丸めていないので、面の外を面の外として扱える
    /// (外から送る経路も範囲外を送れるので、丸めると 2 つの経路で範囲が食い違う)。
    /// 面の中だけを相手にしたいなら、読む側で挟む。
    public var mouseX: Float { liveInput.x }
    /// いまの位置 (縦)。**縦軸は下向き**で、面の上端が 0 (``mouseX`` と同じ約束)。
    public var mouseY: Float { liveInput.y }
    /// 前のフレームでの位置 (横)。
    public var pmouseX: Float { liveInput.previousX }
    /// 前のフレームでの位置 (縦)。
    public var pmouseY: Float { liveInput.previousY }
    /// どれかのボタンが押されているか。
    ///
    /// **ボタンごとに数える** — 左を押したまま右を押して離しても、`true` のまま。ウィンドウが前から退くと、
    /// 押していたボタンは離された扱いになる (``Sketch/mouseReleased()``)。
    public var isMousePressed: Bool { liveInput.isMouseDown }
    /// 最後に押されたか離されたボタン。まだ何も押していなければ `nil`。
    ///
    /// <!-- example: 文脈 var marks: [Float] = [] -->
    /// ```swift
    /// func mouseReleased() {
    ///     if mouseButton == .right { marks.removeAll() }
    /// }
    /// ```
    ///
    /// **押しても離しても入れ替わる。** ``Sketch/mouseReleased()`` の中から「どのボタンが離されたか」
    /// を知る口はここしかない (``keyCode`` と同じ)。押していない間も最後に離したボタンを指した
    /// ままなので、いま押されているかは ``isMousePressed`` で見る。
    ///
    /// **手本と綴りは同じだが、数ではない** ([ADR-0034] 決定 1)。手本の `LEFT` / `RIGHT` /
    /// `CENTER` は ``MouseButton/left`` / ``MouseButton/right`` / ``MouseButton/center`` と
    /// 書く。Processing の定数は 37 / 39 / 3、ブラウザの番号は 0 / 2 / 1 で、どちらも
    /// mokume が運ぶ macOS の番号 (0 = 左・1 = 右・2 = 中) とは合わない。**型が違うので、
    /// 写した数の比較はコンパイルの時点で止まる** — 黙って別のボタンになるより、そこで気付ける
    /// ほうがよい。
    ///
    /// `switch` で分けるときも `case .left:` と書ける。まだ何も押していないときの `nil` は
    /// `default` の分岐へ落ちる。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    public var mouseButton: MouseButton? { liveInput.button }
    /// このフレームのスクロール量 (横)。**単位は点** (トラックパッドは指の動いた点、ふつうのホイールは
    /// 1 行 = 10 点に換算した量)。指を離した後の慣性の続きも足し込まれる ([ADR-0034] 決定 8)。
    ///
    /// **これはフレームの合計で、`draw()` から読むためのもの。** 出来事 1 件ぶんの量が
    /// 要るなら ``Sketch/mouseWheel(deltaX:deltaY:)`` が引数で受け取る。あちらの中から
    /// ここを読むと、その出来事までの部分累計を何度も足し込む形になる ([ADR-0034] 決定 5)。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    public var scrollX: Float { liveInput.scrollX }
    /// このフレームのスクロール量 (縦)。単位と慣性は ``scrollX`` と同じ。
    public var scrollY: Float { liveInput.scrollY }
    /// このフレームのピンチの量 (トラックパッドで指を開くと正、閉じると負)。
    ///
    /// **倍率の差分のフレーム合計** — 0.1 は「1.1 倍に開いた」である。AppKit の `magnification` と
    /// 同じ量なので、拡大率を持つスケッチは `zoom *= 1 + pinch` と書ける。1 フレームに届かなければ 0。
    ///
    /// **これはフレームの合計で、`draw()` から読むためのもの** (``scrollY`` と同じ)。ウィンドウの外から送るときは
    /// `{"type": "pinched", "amount": 0.1}` で、同じフレームに 2 件届けば合計になる。
    /// ``orbitControl(_:_:_:)`` の寄りは、この合計ではなく**件ごとの倍率の積**で決まる (倍率は掛け算で重なるので、
    /// 閉じる件が溜まった合計が −1 以下になっても、閉じる操作は効く)。
    public var pinch: Float { liveInput.pinch }
    /// このフレームに、押したまま引きずった量 (横)。
    ///
    /// **押した瞬間には増えない。** `mouseX - pmouseX` を回す量に使うと、押した場所が
    /// 前のフレームの位置と離れているときに絵が飛ぶ — 押下は移動ではないのに、位置の
    /// 差としては現れてしまうためである。引きずって動かす道具はこちらを使う。
    ///
    /// **これはフレームの合計で、`draw()` から読むためのもの。** 出来事 1 件ぶんの量が
    /// 要るなら ``Sketch/mouseDragged(deltaX:deltaY:)`` が引数で受け取る — 1 フレーム
    /// ぶんを足し合わせればここと一致する。**``Sketch/mouseDragged()`` の中でここを読むと、
    /// 1 フレームに複数件届いたとき、その出来事までの部分累計になる** (`3a + 2b + c` を足し込む形)。
    /// 1 件ぶんは ``Sketch/mouseDragged(deltaX:deltaY:)`` の引数で受け取る ([ADR-0034] 決定 5 の
    /// 改訂 (2026-10-28))。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    public var dragX: Float { liveInput.dragX }
    /// このフレームに、押したまま引きずった量 (縦)。
    public var dragY: Float { liveInput.dragY }
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
    /// 受け取り、両方を足すとここと一致する。あちらの中と、引数なしの ``Sketch/mouseMoved()`` /
    /// ``Sketch/mouseDragged()`` の中からここを読むと、その出来事までの部分累計を何度も足し込む形に
    /// なる ([ADR-0034] 決定 5)。
    ///
    /// **手本 (p5.js) とは数え方が違う。** 名前は手本の `movedX` だが、p5.js 1.11 は最新の
    /// 1 件で上書きするので、手本で `mouseMoved()` の中から `movedX` を読む書き方は 1 件ぶんに
    /// なる。ここはフレームの合計なので、その行をそのまま写すと回りすぎる — 1 件ぶんは
    /// ``Sketch/mouseMoved(deltaX:deltaY:)`` の引数で受け取る。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    public var movedX: Float { liveInput.movedX }
    /// このフレームに動いた量 (縦)。**縦軸は下向き**で、手前へ引くと正になる。
    public var movedY: Float { liveInput.movedY }
    /// キーボードへの問い合わせ。押している間・押した瞬間・離した瞬間を、キーごとに問う。
    ///
    /// <!-- example: 文脈 var x: Float = 0 -->
    /// <!-- example: 文脈 var jumps = 0 -->
    /// ```swift
    /// if keyboard.isPressed(.arrowLeft) { x -= 4 }   // 押している間
    /// if keyboard.justPressed(.space) { jumps += 1 } // 押したフレームだけ
    /// ```
    ///
    /// | 語 | 意味 |
    /// | --- | --- |
    /// | ``Keyboard/isPressed(_:)`` | 押している間 |
    /// | ``Keyboard/justPressed(_:)`` | このフレームで押された |
    /// | ``Keyboard/justReleased(_:)`` | このフレームで離された |
    ///
    /// **判定はフレームごとの入力の状態から決まる。** ウィンドウで触っても、外から送っても
    /// (`mokume input`・MCP の `input`)、同じ出来事の並びは同じ答えになる。
    ///
    /// - **1 フレームの中で押して離すと**、`justPressed` と `justReleased` が両方 `true` で、
    ///   `isPressed` は `false` になる
    /// - **止めている間 (``noLoop()``) に押した・離した分は、次に描くフレームで `true` になる。**
    ///   ``pauseTime()`` の間はフレームが回るので、そのまま次のフレームで読める
    /// - **ウィンドウが前から退くと (⌘Tab・ほかのウィンドウを触る・メニューを開く)、押していたキーとボタンはすべて
    ///   離された扱いになる。** 次のフレームで `justReleased` が `true` になり、``Sketch/keyReleased()`` も
    ///   呼ばれる。離していないのに離した扱いになるのが代償で、戻ってきたときに押し続けて
    ///   いれば、キーリピートが届いたところで押下として入り直す。退いている間に離したキーが
    ///   押されたまま残り、物が走り続けるのを避けるためである
    ///   ([#2443](https://github.com/mokume-metal/mokume/issues/2443))
    /// - **修飾キー** (``Key/shift``・``Key/control``・``Key/option``・``Key/command``) も
    ///   問える。左右どちらでも `true` になる
    ///
    /// **手本の `keyIsDown(code)` は `keyboard.isPressed(_:)` と書く。** 問い合わせを入力の種類
    /// ごとに分けるのは、トップレベルの `justPressed(.left)` だと `.left` がマウスのボタンに
    /// 解決され、矢印キー (``Key/arrowLeft``) のつもりでも黙ってマウスとして動くためである
    /// ([ADR-0034] 決定 7)。
    ///
    /// **コールバックの `keyPressed()` と、問い合わせの `isPressed` は意味が違う。** 前者は押した
    /// 瞬間に 1 回、後者は押している間ずっとである。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    public var keyboard: Keyboard { Keyboard(state: liveInput) }
    /// 最後に入力された文字。
    ///
    /// **文字を生むキーでだけ変わる。** 矢印・ファンクションキー・Escape・Delete では
    /// 更新されない — AppKit がそれらへ返すのは私用領域や制御文字なので、そのまま
    /// 入れると画面に見えない文字が出る。打鍵そのものを受け取る口は
    /// ``Sketch/keyTyped()``。
    public var key: String { liveInput.characters }
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
    public var keyCode: Key? { liveInput.lastKey }
    /// ウィンドウが前にあるか (キーを受け取るウィンドウか)。Processing の `focused` に当たる。
    ///
    /// ```swift
    /// func draw() {
    ///     // ほかのアプリへ移ったら止める。戻ってきたら keyPressed() などで loop() を呼ぶ
    ///     if !focused { noLoop() }
    ///     background(20)
    ///     circle(mouseX, mouseY, 40)
    /// }
    /// ```
    ///
    /// ⌘Tab などでウィンドウが前から退くと `false` になり、戻ると `true` になる。**変わるのは、知らせが届いたフレームの頭**
    /// — 入力と同じ合流点を通るので、同じフレームの中では読むたびに同じ値を返す。退いたときは、ウィンドウで押していた
    /// キーとボタンが離された扱いになり (``Sketch/keyReleased()``・``Sketch/mouseReleased()``)、その呼び出しの中から
    /// 読んでも既に `false` である。
    ///
    /// **退いても、外から注入した押下は離さない** — 入力の線・MCP の `input` で送った `keyDown`・`mouseDown` は、注入した
    /// 側が解放を送るまで押されたまま残る。だから `focused` が `false` の間も、``keyboard`` や ``isMousePressed`` が
    /// 押されていると答えることがある (自動操作の最中に人がウィンドウを切り替えても、結果が変わらない)。
    ///
    /// ## ウィンドウを持つ所ごとの答え
    ///
    /// - **直に走らせたウィンドウ** (`mokume run`・束ねた `.app`): そのウィンドウが key か
    /// - **`mokume watch` の下**: ウィンドウは道具が持つので、道具のウィンドウ (作品のウィンドウかプレビュー) が key か。
    ///   道具が入力と同じ線で子へ運ぶ。子を起こし直した直後は、次に道具のウィンドウが key の出入りをするまで `true`
    /// - **``SketchView``**: ビューを載せたホストのウィンドウが key か。ウィンドウに載っていない間は `true`
    /// - **ウィンドウの無い実行** (`mokume render`・参照スケッチの `--render`): いつも `true`。`if !focused { noLoop() }`
    ///   は書き出しを止めない
    /// - **走っていないとき** (`init` の中など): `true` (警告は出さない)
    ///
    /// Processing は初めて前に出るまで `false` だが、mokume は `true` から始める。
    ///
    /// ## 外から送る
    ///
    /// 入力の線 (`.mokume/input`・MCP の `input`) で `{"type": "focusChanged", "focused": false}` を送ると、`focused` が
    /// `false` になる。機材も人の操作も無しに確かめられる。送った知らせは押下を離さない (ウィンドウの押下を離すのは
    /// ウィンドウ自身で、注入した押下は注入した側の解放で離れる)。
    public var focused: Bool { liveInput.focused }

    /// 走っているランタイムの合流点。走っていなければ**空の状態**を返す。
    ///
    /// 描画と違って止めない — 入力を読むだけで落ちると、`draw()` の外 (初期化など) で
    /// 位置を参照しただけのスケッチが動かなくなる。走っていないなら入力は無い、が
    /// 素直な答えである。
    @MainActor
    private var liveInput: InputState {
        activeRun(for: .read, from: self)?.input ?? InputState.empty
    }
}

extension InputState {
    /// 走っていないときに返す、何も起きていない状態。
    @MainActor
    static let empty = InputState()
}
