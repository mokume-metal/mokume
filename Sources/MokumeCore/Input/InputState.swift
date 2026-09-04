// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 入力の合流点。
///
/// **窓からの実操作と、外から送られたものが、同じここへ入る。** 合流が 1 箇所なら、
/// 送られた出来事が実操作と違う扱いを受けることが構造的に起こらない — 外から動かして
/// 確かめたことが、人が触ったときにも同じように成り立つ。
///
/// 溜めた出来事はフレームの頭で流し込まれ、**同じフレームの `draw()` から見える**。
@MainActor
public final class InputState {
    /// 溜める上限。描画が停滞しても際限なく伸びないようにする。
    static let queueLimit = 4096

    /// まだ流し込んでいない出来事。
    private var pending: [InputEvent] = []
    /// 溜めきれずに捨てた数。
    private(set) var droppedEvents = 0

    /// いまの位置。
    public private(set) var x: Float = 0
    public private(set) var y: Float = 0
    /// 前のフレームでの位置。
    public private(set) var previousX: Float = 0
    public private(set) var previousY: Float = 0
    /// 押されているか。
    public private(set) var isMouseDown = false
    /// 最後に押された釦。
    public private(set) var button: Int = 0
    /// 直近のスクロール量 (このフレームぶん)。
    public private(set) var scrollX: Float = 0
    public private(set) var scrollY: Float = 0
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
    /// 押されているキー。
    public private(set) var pressedKeys: Set<Key> = []
    /// 最後に押されたか離されたキー。まだ何も来ていなければ `nil`。
    public private(set) var lastKey: Key?
    /// 最後に入力された文字。
    public private(set) var characters: String = ""

    public init() {}

    /// 出来事を溜める。**窓からも外からも、入口はここ 1 つ。**
    public func enqueue(_ event: InputEvent) {
        if pending.count >= Self.queueLimit {
            pending.removeFirst()
            droppedEvents += 1
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
        dragX = 0
        dragY = 0
        let events = pending
        pending.removeAll(keepingCapacity: true)
        for event in events {
            // 判定に要る「適用する前」を控えてから状態を進め、**進めた後の値で**配る
            let wasMouseDown = isMouseDown
            apply(event)
            dispatchCallbacks(for: event, wasMouseDown: wasMouseDown, to: dispatch)
        }
    }

    /// その 1 件が生む呼び出しを、生む順に配る。**写し方の正本はここ 1 つ。**
    private func dispatchCallbacks(
        for event: InputEvent, wasMouseDown: Bool, to dispatch: (InputCallback) -> Void
    ) {
        switch event {
        case .mouseDown:
            dispatch(.mousePressed)
        case .mouseUp:
            dispatch(.mouseReleased)
            // **押下を伴う解放だけがクリックになる。** 押していないところで離しても
            // 解放は起きる (窓の外で押して中で離す・上限で押下が捨てられた、など)
            if wasMouseDown { dispatch(.mouseClicked) }
        case .mouseMoved, .scrolled, .keyDown, .keyUp:
            break
        }
    }

    private func apply(_ event: InputEvent) {
        switch event {
        case .mouseDown(let x, let y, let button):
            self.x = x
            self.y = y
            self.button = button
            isMouseDown = true
        case .mouseUp(let x, let y, let button):
            self.x = x
            self.y = y
            self.button = button
            isMouseDown = false
        case .mouseMoved(let x, let y):
            // 押されている間の移動だけを引きずった量へ足す (押下では増やさない)
            if isMouseDown {
                dragX += x - self.x
                dragY += y - self.y
            }
            self.x = x
            self.y = y
        case .scrolled(let dx, let dy):
            scrollX += dx
            scrollY += dy
        case .keyDown(let code, let characters, _):
            pressedKeys.insert(code)
            lastKey = code
            if !characters.isEmpty { self.characters = characters }
        case .keyUp(let code):
            pressedKeys.remove(code)
            lastKey = code
        }
    }
}
