// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 入力の合流点。
///
/// **窓からの実操作と、外から送られたものが、同じここへ入る。** 合流が 1 箇所なら、
/// 送られた出来事が実操作と違う扱いを受けることが構造的に起こらない — 外から動かして
/// 確かめたことが、人が触ったときにも同じように成り立つ。
///
/// **例外は、道具の窓の出来事が通る線だけである** ([#2777](https://github.com/mokume-metal/mokume/issues/2777))。
/// 道具の窓の出来事は 1 行にして子へ渡り、その線は有限でない値を 0 にする。窓の値は有限なので
/// 届かない守りで、届けば、ここで捨てる (下の「有限である」) のとは違い (0, 0) として当たる。
///
/// 溜めた出来事はフレームの頭で流し込まれ、**同じフレームの `draw()` から見える**。
///
/// ## 見せる量と配る量は有限である
///
/// 位置 (``x``・``previousX``)・動いた量 (``movedX``)・引きずった量 (``dragX``)・スクロール量
/// (``scrollX``)・ピンチの量 (``pinch``) と、配る量 (引きずり・移動・スクロールの 1 件ぶん) は、数でない値にも無限にも
/// ならない ([#2731](https://github.com/mokume-metal/mokume/issues/2731))。外から送る経路は
/// ±3.4e38 までの極端な値を運べ、その差や和は `Float` に収まらないことがある。差は原点の両側で
/// 約 1.7e38 より遠い位置どうしで溢れ、和はずっと小さい量の繰り返しでも溢れる。``enqueue(_:)`` には
/// 数でない値も渡せる。
///
/// - **移動・スクロール・ピンチ** (`mouseMoved`・`mouseMovedBy`・`scrolled`・`pinched`) は、当てるとそうなるなら、
///   状態にも配りにも入れずに捨て、1 度だけ言う
/// - **押下と解放** (`mouseDown`・`mouseUp`) は、位置が有限でなければ**位置だけを捨てる**。釦の
///   状態は当てて、呼び出しも配る — 位置は前の値のまま。落とすと釦が押されたまま残り
///   (``enqueue(_:)`` の「どの種別も状態だけは残す」・#935 と同じ理由)、押下と解放の組も崩れる
///
/// **範囲の外の位置は丸めない** — 極端でも有限に収まる値は、窓から来る値と同じに当てて配る。
@MainActor
public final class InputState {
    /// 溜める上限。描画が停滞しても際限なく伸びないようにする。
    static let queueLimit = 4096

    /// まだ流し込んでいない出来事。**先頭は ``pendingHead`` 番目** — それより手前は、溢れて当てた
    /// 出来事の抜け殻である ([#2383])。
    ///
    /// [#2383]: https://github.com/mokume-metal/mokume/issues/2383
    private var pending: [InputEvent] = []
    /// ``pending`` の先頭の添字。**溢れるたびに先頭を詰め直さず、添字を進めるだけにする。**
    /// 1 件ごとの詰め直しは上限ぶんの写しを毎回払い、溢れ続ける間は件数 × 上限で効く。
    private var pendingHead = 0
    /// 溜めきれずに捨てた数。
    private(set) var droppedEvents = 0

    /// いまの位置。
    public private(set) var x: Float = 0
    public private(set) var y: Float = 0
    /// 前のフレームでの位置。
    public private(set) var previousX: Float = 0
    public private(set) var previousY: Float = 0
    /// どれかの釦が押されているか。
    public var isMouseDown: Bool { !pressedButtons.isEmpty }
    /// 押されている釦。**釦ごとに持つ** — 1 つの真偽値で持っていた頃は、左を押したまま
    /// 右を押して離すと、左も離した扱いになった
    /// ([#2599](https://github.com/mokume-metal/mokume/issues/2599))。
    private(set) var pressedButtons: Set<MouseButton> = []
    /// 最後に押されたか離された釦。まだ何も来ていなければ `nil`。
    public private(set) var button: MouseButton?
    /// 直近のスクロール量 (このフレームぶん)。
    public private(set) var scrollX: Float = 0
    public private(set) var scrollY: Float = 0
    /// 直近のピンチの量 (このフレームぶん・倍率の差分の合計)。開くと正、閉じると負
    /// ([#2762](https://github.com/mokume-metal/mokume/issues/2762))。
    public private(set) var pinch: Float = 0
    /// このフレームに届いた、左ボタンの 2 回目の押下 (`clickCount == 2`) の数。**フレームの頭で 0 に戻る。**
    /// ``SketchPart/orbitControl(_:_:_:)`` が視点を戻す合図に読む。スケッチ向けの口はまだ無い (作例が来てから)。
    private(set) var leftDoubleClicks = 0
    /// 押したまま引きずった量 (このフレームぶん)。
    ///
    /// **押下は移動ではない。** `mouseX - pmouseX` には、押した瞬間にカーソルが押下
    /// 位置へ飛んだぶんが混ざる — 前のフレームからどこへ動いたかしか分からないので、
    /// 押した場所が前の位置と離れていれば、指を動かしていなくても差が出る。それを
    /// 回す量に使うと**押した瞬間に絵が飛ぶ**。
    ///
    /// ここは**押されている間の移動だけ**を足し込むので、押下では増えない。足し込みで
    /// 数えるので、1 フレームにまとめて届いても取りこぼしも重複も起きない。
    public private(set) var dragX: Float = 0
    public private(set) var dragY: Float = 0
    /// 動いた量 (このフレームぶん)。**押しているかによらず数える。**
    ///
    /// 足すのは移動の出来事だけで、``dragX`` と同じく**押下・解放の飛びは数えない**。位置の
    /// 移動 (`mouseMoved`) は当てる前の位置との差を、相対の移動 (`mouseMovedBy`) はその量を
    /// 足す — 後者は位置を動かさないので、``x`` の差からは読めない
    /// ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
    public private(set) var movedX: Float = 0
    public private(set) var movedY: Float = 0
    /// 押されているキー。
    public private(set) var pressedKeys: Set<Key> = []
    /// 描いたフレームの間に、押されていない状態から押されたキーと、押されている状態から
    /// 離されたキー (``SketchPart/keyboard`` の `justPressed` / `justReleased`)。
    ///
    /// **消すのはフレームの頭ではなく、描いたフレームの終わり (``endFrame()``)。** 止めている間
    /// (`noLoop()`) も、届いた入力はフレームの外で ``beginFrame(dispatch:)`` を通って配られる。
    /// 頭で消すと、止めている間に離したキーが次に描くフレームの `draw()` から見えない。
    ///
    /// 1 フレームに押して離せば、両方に入る (速い連打を落とさない)。
    private(set) var justPressedKeys: Set<Key> = []
    private(set) var justReleasedKeys: Set<Key> = []
    /// 最後に押されたか離されたキー。まだ何も来ていなければ `nil`。
    public private(set) var lastKey: Key?
    /// 最後に入力された文字。
    public private(set) var characters: String = ""

    /// 入力の層が 1 度だけ言う注意の種類。
    enum Warning: Hashable {
        /// 当てると、見せる量か配る量が有限でなくなる移動・スクロールを捨てた (``apply(_:)``・#2731)。
        case nonFiniteEvent
        /// 位置が有限でない押下・解放の、位置だけを捨てた (釦の状態は当てた・``apply(_:)``・#2731)。
        case nonFinitePosition
    }

    /// 1 度だけ言った注意の控え。**検査が読む。**
    private(set) var warnings = WarningLog<Warning>()

    public init() {}

    /// 出来事を溜める。**窓からも外からも、入口はここ 1 つ。**
    ///
    /// **溢れたら、捨てる前にその 1 件を状態へ当てる。** 落とすのは呼び出し
    /// (`mouseReleased` などの配り) であって状態ではない — そのまま捨てていた頃は、
    /// 解放が押し出されると**離したキーが押されたまま残り**、次に同じキーを押して
    /// 離すまで直らなかった ([#935])。
    ///
    /// 種別ごとに捨て方を分けはしない。失ってよいものは種別で違う (位置は最新だけ
    /// 効けばよく、押下と解放は落とすと状態が壊れる) が、**どの種別も状態だけは
    /// 残す**なら、上限に達したときだけ通る経路を種別の数だけ持たなくて済む。
    /// 引きずりとスクロールはフレームの頭で 0 に戻る量なので、捨てた分は失われる —
    /// 捨てた以上それが正しい。
    ///
    /// **溜めた移動とスクロールでも、当てると位置・差・和が有限でなくなるなら捨てる** ([#2731])。
    /// 数でない値や無限を載せたものと、極端な位置や量で差や和が `Float` に収まらなくなるものである。
    /// 捨てた出来事は状態を動かさず、コールバックも呼ばない。**押下と解放は捨てない** — 位置が有限で
    /// なければ位置だけを捨て、釦の状態は当てて配る (上の「どの種別も状態だけは残す」)。どちらも、
    /// 最初の 1 件だけ警告で言う。決まるのは当てるとき (フレームの頭か、溢れて当てるとき) の状態なので、
    /// 溜めた時点では分からない。
    ///
    /// **溢れて当てる 1 件は、フレームの頭で 0 に戻る前の和に足して検める。** だから 1e38 級の量では、
    /// フレームの頭で当てれば収まった移動・スクロールを捨てうる。溢れたときだけ通る経路で、そこで
    /// 足し込んだ引きずり・スクロールは、どのみちフレームの頭で 0 に戻って失われる量である。
    ///
    /// [#935]: https://github.com/mokume-metal/mokume/issues/935
    /// [#2731]: https://github.com/mokume-metal/mokume/issues/2731
    public func enqueue(_ event: InputEvent) {
        if pending.count - pendingHead >= Self.queueLimit {
            apply(pending[pendingHead])
            pendingHead += 1
            droppedEvents += 1
            // 抜け殻が上限ぶん溜まったら 1 回で詰める。1 件ごとに詰めると溢れ続ける間 O(上限) を
            // 毎回払うが、これなら上限件に 1 回の O(上限) なので 1 件あたりは一定で、置き場も
            // 上限の 2 倍までしか伸びない
            if pendingHead >= Self.queueLimit {
                pending.removeSubrange(0..<pendingHead)
                pendingHead = 0
            }
        }
        pending.append(event)
    }

    /// 溜めたものを流し込む。フレームの頭で 1 回呼ぶ。
    ///
    /// **畳みながら配る。** 1 件適用するごとに、その 1 件が生む呼び出しを `dispatch` へ
    /// 渡す。畳むだけにすると、1 フレームに `mouseDown` → `mouseUp` が収まったとき
    /// 押されたことがどこにも残らない — 窓を人が触るぶんには押下と解放の間に数フレーム
    /// 入るので滅多に踏まないが、外から送る経路では 1 回の要求がまとめて 1 フレームへ
    /// 入るので、**クリックを 1 件送るという最も素直な使い方が常に消える**
    /// ([#723](https://github.com/mokume-metal/mokume/issues/723))。
    ///
    /// 規則は 1 つ — **状態はその出来事まで適用した値**。配られた側から読む位置や押下
    /// 状態は、その出来事を当てた直後の姿になっている。`draw()` から見える最終状態は
    /// 畳んだときと変わらない。
    ///
    /// - Parameter dispatch: 呼び出しの配り先。既定では何もしない (状態を進めるだけ)。
    func beginFrame(dispatch: (InputCallback) -> Void = { _ in }) {
        previousX = x
        previousY = y
        scrollX = 0
        scrollY = 0
        pinch = 0
        leftDoubleClicks = 0
        dragX = 0
        dragY = 0
        movedX = 0
        movedY = 0
        let events = pending[pendingHead...]
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
        for event in events {
            // 判定に要る「適用する前」を控えてから状態を進め、**進めた後の値で**配る
            let before = Before(
                pressedButtons: pressedButtons, keyWasPressed: wasPressed(event), x: x, y: y)
            // **捨てた出来事は配らない** (#2731)。状態に入らなかった量を配ると、配った量の和と
            // 足し込んだ和 (``dragX`` ほか) が食い違う。配るのは当てた形 (位置を捨てた押下・解放は、
            // 前の位置のまま)
            guard let applied = apply(event) else { continue }
            dispatchCallbacks(for: applied, before: before, to: dispatch)
        }
    }

    /// 描いたフレームを終える。**このフレームの押した・離したを消す** (``justPressedKeys``)。
    ///
    /// ランタイムが `draw()` の後に呼ぶ。止めている間に配った分は、ここを通らないので
    /// 次に描くフレームまで残る。
    func endFrame() {
        justPressedKeys.removeAll(keepingCapacity: true)
        justReleasedKeys.removeAll(keepingCapacity: true)
    }

    /// 出来事を当てる前の姿。**呼び出しを決めるのに要るぶんだけ持つ。**
    ///
    /// 配るのは当てた後だが、「押下を伴う解放か」も「1 件で何画素動いたか」も「押されて
    /// いないキーが押されたか」も、当てる前の値がないと決まらない。
    private struct Before {
        let pressedButtons: Set<MouseButton>
        /// キーの出来事なら、そのキーが当てる前に押されていたか。ほかの出来事では `false`。
        let keyWasPressed: Bool
        let x: Float
        let y: Float

        var isMouseDown: Bool { !pressedButtons.isEmpty }
    }

    /// キーの出来事なら、そのキーがいま押されているか。
    private func wasPressed(_ event: InputEvent) -> Bool {
        switch event {
        case .keyDown(let code, _, _), .keyUp(let code): pressedKeys.contains(code)
        default: false
        }
    }

    /// その 1 件が生む呼び出しを、生む順に配る。**写し方の正本はここ 1 つ。**
    private func dispatchCallbacks(
        for event: InputEvent, before: Before, to dispatch: (InputCallback) -> Void
    ) {
        switch event {
        case .mouseDown:
            dispatch(.mousePressed)
        case .mouseUp(_, _, let button):
            dispatch(.mouseReleased)
            // **押下を伴う解放だけがクリックになる。** 押していないところで離しても
            // 解放は起きる (窓の外で押して中で離す・上限で押下が捨てられた、など)。
            // 見るのは**その釦が**押されていたかで、ほかの釦の押下では数えない
            if before.pressedButtons.contains(button) { dispatch(.mouseClicked) }
        case .mouseMoved(let x, let y):
            // **窓にしか無い情報を使わずに、押下状態から導く。** 窓は押している間の
            // 移動を `mouseDragged` として拾うが、合流点へは窓の出来事の区別が流れないので
            // (`SketchSurface` が `.mouseMoved` へ写す)、外から送れるものと同じ材料で
            // 分けられる。移動は押下状態を変えないので、当てる前と後で同じ
            //
            // **動いた量は当てる前との差**。dragX / movedX はフレームの頭から足し込むので、
            // ここから読むとその出来事までの部分累計になる ([ADR-0034] 決定 5)
            dispatchMotion(deltaX: x - before.x, deltaY: y - before.y, before: before, to: dispatch)
        case .mouseMovedBy(let dx, let dy):
            // **位置を持たない移動も、同じ分け方で配る** (#1144)。差を作らずに量そのものを
            // 渡す — 位置は動かないので、当てる前との差は常に 0 になる
            dispatchMotion(deltaX: dx, deltaY: dy, before: before, to: dispatch)
        case .keyDown(let code, let characters, let isRepeat):
            // **修飾キーは押下の状態だけを変える** (``Key/isModifier``)
            guard !code.isModifier else { return }
            // **押されていないキーが押されたとき、またはリピートでない押下が届いたときに呼ぶ**
            // (``isFreshPress(wasPressed:isRepeat:)``)。押しっぱなしのキーリピートは打鍵
            // (`keyTyped()`) にだけ流す — 連射していた頃は、「1 回だけ切り替える」に押したままかの
            // 印を作者が持つ必要があった ([#2400](https://github.com/mokume-metal/mokume/issues/2400))
            if Self.isFreshPress(wasPressed: before.keyWasPressed, isRepeat: isRepeat) {
                dispatch(.keyPressed)
            }
            // **文字を生むキーだけが打鍵になる。** 矢印やファンクションキーでは呼ばない
            if Self.producesText(characters) { dispatch(.keyTyped) }
        case .keyUp(let code):
            // **押されているキーが離されたときだけ呼ぶ。** 窓が退いて離した扱いにした後で
            // 本物の解放が届いても、2 度は呼ばない
            guard !code.isModifier, before.keyWasPressed else { return }
            dispatch(.keyReleased)
        case .scrolled(let dx, let dy):
            // 1 件ぶんが出来事にそのまま載っているので、控えずに渡せる
            dispatch(.mouseWheel(deltaX: dx, deltaY: dy))
        case .pinched:
            // 読むのはフレームの合計 (``pinch``) だけ。1 件ぶんを配る口は、作例が来てから
            // ([#2762](https://github.com/mokume-metal/mokume/issues/2762))
            break
        }
    }

    /// 移動 1 件が生む呼び出し。押していれば引きずり、押していなければ移動とその量が続く。
    ///
    /// **`mouseMoved` の直後に量を続ける** (``InputCallback/mouseMovedBy(deltaX:deltaY:)``)。
    /// 引数なしの `mouseMoved()` は残し、量の要る書き手は引数のある口を書く — 置き換えると、
    /// 引数なしで書いた作品が黙って呼ばれなくなる (ADR-0034 決定 5 の追補 (2026-10-07))。
    private func dispatchMotion(
        deltaX: Float, deltaY: Float, before: Before, to dispatch: (InputCallback) -> Void
    ) {
        if before.isMouseDown {
            dispatch(.mouseDragged(deltaX: deltaX, deltaY: deltaY))
        } else {
            dispatch(.mouseMoved)
            dispatch(.mouseMovedBy(deltaX: deltaX, deltaY: deltaY))
        }
    }

    /// 文字を生むキーか。**「`characters` が空でない」では判定できない。**
    ///
    /// AppKit の `NSEvent.characters` は矢印やファンクションキーに Unicode の私用領域
    /// (`NSUpArrowFunctionKey` = U+F700 など) を返し、Escape には U+001B、Delete には
    /// U+007F を返す。どれも `isEmpty` は `false` なので、空でないことを打鍵の合図に
    /// すると**手本 (p5 / Processing) では呼ばれないキーで発火する**
    /// ([#805](https://github.com/mokume-metal/mokume/issues/805))。
    ///
    /// 判定は「制御文字でも私用領域でもないスカラを 1 つ以上含むこと」。打鍵の合図と、
    /// ``characters`` (``SketchPart/key``) の更新が同じここを見る — 割れていた頃は、矢印を
    /// 押すと `key` が見えない文字になっていた。
    static func producesText(_ characters: String) -> Bool {
        characters.unicodeScalars.contains { scalar in
            let value = scalar.value
            // 制御文字 (Escape・Delete・Tab・改行など)
            if value < 0x20 || value == 0x7F { return false }
            // AppKit が矢印・ファンクションキー・Home などへ返す私用領域
            if (0xF700...0xF8FF).contains(value) { return false }
            return true
        }
    }

    /// 押下 1 件が、新しく押したことになるか。**押されていなかったキーか、リピートでない押下。**
    ///
    /// 押されていなかったキーなら、リピートでも新しい押下として入る — 窓が退いて離した扱いに
    /// した後で、押し続けていたキーのリピートが戻ってきた形である。
    ///
    /// 押されているはずのキーにリピートでない押下が届いたら、**解放を取りこぼした印**として
    /// 新しい押下に数える。集合に古い押下が残ったままだと、次に本当に押したときに
    /// `keyPressed()` も `justPressed` も起きず、押下が 1 回無視される (窓が key のまま解放だけが
    /// 届かない経路は、すべては塞げない)。
    static func isFreshPress(wasPressed: Bool, isRepeat: Bool) -> Bool {
        !wasPressed || !isRepeat
    }

    /// 出来事を状態へ当て、**当てた形を返す** (#2731)。当てると有限でなくなる移動・スクロールは
    /// 当てずに `nil` を返す。位置が有限でない押下・解放は、位置を前の値に替えて当てる。
    ///
    /// 検めるのは当てる直前のここ 1 か所である。フレームの頭 (``beginFrame(dispatch:)``) も、溢れた
    /// 1 件を当てる ``enqueue(_:)`` も、ここを通る。読み手 (``dragX``・``scrollY``・3 つの配り) ごとに
    /// 検めると、読み手が増えるたびに漏れうる。
    ///
    /// **押下と解放は捨てない。** 捨てると、押下中に届いた解放なら釦が押されたまま残って後の移動が
    /// 引きずりとして足し込まれ続け、押下なら後の解放が `mousePressed` も `mouseClicked` も伴わずに
    /// 配られる。#935 が溢れの経路で守った「落とすのは呼び出しであって状態ではない」と同じ向きで、
    /// ここでは呼び出しも落とさない (位置を捨てても、押した・離したことは本当に起きている)。
    @discardableResult
    private func apply(_ event: InputEvent) -> InputEvent? {
        let applied: InputEvent
        switch event {
        case .mouseDown(let x, let y, let button, let clickCount) where !(x.isFinite && y.isFinite):
            warnPositionKept(event)
            applied = .mouseDown(x: self.x, y: self.y, button: button, clickCount: clickCount)
        case .mouseUp(let x, let y, let button) where !(x.isFinite && y.isFinite):
            warnPositionKept(event)
            applied = .mouseUp(x: self.x, y: self.y, button: button)
        default:
            guard keepsQuantitiesFinite(event) else {
                warnings.warnOnce(
                    .nonFiniteEvent,
                    "Dropped the input event \(Self.spelled(event)): applying it would make the "
                        + "mouse position, a movement, a drag or a scroll amount infinite or not a "
                        + "number (later events like this are dropped without saying so again)")
                return nil
            }
            applied = event
        }
        update(by: applied)
        return applied
    }

    /// 位置が有限でない押下・解放の位置だけを捨てたことを、1 度だけ言う。
    private func warnPositionKept(_ event: InputEvent) {
        warnings.warnOnce(
            .nonFinitePosition,
            "The input event \(Self.spelled(event)) has a position that is not a finite number, "
                + "so its button change was applied and the mouse position was left where it was "
                + "(later events like this are handled the same way without saying so again)")
    }

    /// 注意に載せる出来事の綴り。**釦は名前で書く** — ``MouseButton`` は綴りを持たないので、
    /// 出来事をそのまま埋めると `MouseButton(rawValue: 0)` と出る。名前の無い番号は番号で書く。
    static func spelled(_ event: InputEvent) -> String {
        switch event {
        case .mouseDown(let x, let y, let button, let clickCount):
            "mouseDown(x: \(x), y: \(y), button: \(spelled(button)), clickCount: \(clickCount))"
        case .mouseUp(let x, let y, let button):
            "mouseUp(x: \(x), y: \(y), button: \(spelled(button)))"
        default:
            "\(event)"
        }
    }

    /// 釦の綴り (`.left`・`.right`・`.center`。ほかは番号)。
    static func spelled(_ button: MouseButton) -> String {
        switch button {
        case .left: ".left"
        case .right: ".right"
        case .center: ".center"
        default: "\(button.rawValue)"
        }
    }

    /// 出来事 1 件ぶん、状態を進める。**検めは済んでいる** (``apply(_:)`` からだけ呼ぶ)。
    private func update(by event: InputEvent) {
        switch event {
        case .mouseDown(let x, let y, let button, let clickCount):
            self.x = x
            self.y = y
            self.button = button
            pressedButtons.insert(button)
            if button == .left, clickCount == 2 { leftDoubleClicks += 1 }
        case .mouseUp(let x, let y, let button):
            self.x = x
            self.y = y
            self.button = button
            pressedButtons.remove(button)
        case .mouseMoved(let x, let y):
            accumulateMotion(deltaX: x - self.x, deltaY: y - self.y)
            self.x = x
            self.y = y
        case .mouseMovedBy(let dx, let dy):
            // **位置は動かさない** (#1144)。捕まえている間の窓は位置を名乗らないので、
            // ここで足し込むと mouseX が捕まえた点から離れていく
            accumulateMotion(deltaX: dx, deltaY: dy)
        case .scrolled(let dx, let dy):
            scrollX += dx
            scrollY += dy
        case .pinched(let amount):
            pinch += amount
        case .keyDown(let code, let characters, let isRepeat):
            let wasPressed = !pressedKeys.insert(code).inserted
            if Self.isFreshPress(wasPressed: wasPressed, isRepeat: isRepeat) {
                justPressedKeys.insert(code)
            }
            // **修飾キーは `keyCode` も `key` も動かさない。** 大文字を打った後に `keyCode` が
            // `.shift` のまま残らないようにする (#2435)
            guard !code.isModifier else { return }
            lastKey = code
            // **打鍵と同じ判定を使う。** 空でないことで見ていた頃は、矢印を押すと
            // ここが私用領域の文字になっていた (#805)
            if Self.producesText(characters) { self.characters = characters }
        case .keyUp(let code):
            // 押されていないキーの解放は、呼び出しを生まないので `keyCode` も動かさない
            guard pressedKeys.remove(code) != nil else { return }
            justReleasedKeys.insert(code)
            if !code.isModifier { lastKey = code }
        }
    }

    /// 当てた後も、見せる量と配る量がどれも有限か ([#2731])。
    ///
    /// **状態はいつも有限である** (有限でなくなる出来事は当てないので)。だから足した後の和が有限
    /// なら、足した差も有限で、配る量 (差と、スクロールの 1 件ぶん) も有限になる。見るのは:
    ///
    /// - 押下と解放: 位置そのもの。有限でなければ ``apply(_:)`` が先に位置だけを捨てるので、
    ///   ここへは有限の位置しか来ない
    /// - 位置の移動: 位置と、当てる前との差を足した後の ``movedX`` (押していれば ``dragX`` も)
    /// - 相対の移動: 足した後の ``movedX`` (押していれば ``dragX`` も)
    /// - スクロール: 足した後の ``scrollX``・``scrollY``
    ///
    /// **範囲の外の位置は丸めない** (`SurfaceMapping` の「帯の上は丸めない」)。極端でも有限に
    /// 収まる値は、今までどおり当てる。
    ///
    /// [#2731]: https://github.com/mokume-metal/mokume/issues/2731
    private func keepsQuantitiesFinite(_ event: InputEvent) -> Bool {
        switch event {
        case .mouseDown(let x, let y, _, _), .mouseUp(let x, let y, _):
            x.isFinite && y.isFinite
        case .mouseMoved(let x, let y):
            x.isFinite && y.isFinite && keepsMotionFinite(deltaX: x - self.x, deltaY: y - self.y)
        case .mouseMovedBy(let dx, let dy):
            keepsMotionFinite(deltaX: dx, deltaY: dy)
        case .scrolled(let dx, let dy):
            (scrollX + dx).isFinite && (scrollY + dy).isFinite
        case .pinched(let amount):
            amount.isFinite && (pinch + amount).isFinite
        case .keyDown, .keyUp:
            true
        }
    }

    /// 移動 1 件の量を足し込んでも、和が有限か (``accumulateMotion(deltaX:deltaY:)`` と同じ足し方)。
    private func keepsMotionFinite(deltaX: Float, deltaY: Float) -> Bool {
        guard (movedX + deltaX).isFinite, (movedY + deltaY).isFinite else { return false }
        return !isMouseDown || ((dragX + deltaX).isFinite && (dragY + deltaY).isFinite)
    }

    /// 移動 1 件の量を足し込む。動いた量はいつも、引きずった量は押されている間だけ
    /// (押下では増やさない)。**配る量 (``dispatchMotion(deltaX:deltaY:before:to:)``) と同じ値を
    /// 同じ順で足す**ので、1 件ぶんの和はフレーム合計と食い違わない。
    private func accumulateMotion(deltaX: Float, deltaY: Float) {
        movedX += deltaX
        movedY += deltaY
        if isMouseDown {
            dragX += deltaX
            dragY += deltaY
        }
    }
}
