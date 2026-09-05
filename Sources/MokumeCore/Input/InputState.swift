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
            let before = Before(isMouseDown: isMouseDown, x: x, y: y)
            apply(event)
            dispatchCallbacks(for: event, before: before, to: dispatch)
        }
    }

    /// 出来事を当てる前の姿。**呼び出しを決めるのに要るぶんだけ持つ。**
    ///
    /// 配るのは当てた後だが、「押下を伴う解放か」も「1 件で何画素動いたか」も、当てる
    /// 前の値がないと決まらない。
    private struct Before {
        let isMouseDown: Bool
        let x: Float
        let y: Float
    }

    /// その 1 件が生む呼び出しを、生む順に配る。**写し方の正本はここ 1 つ。**
    private func dispatchCallbacks(
        for event: InputEvent, before: Before, to dispatch: (InputCallback) -> Void
    ) {
        switch event {
        case .mouseDown:
            dispatch(.mousePressed)
        case .mouseUp:
            dispatch(.mouseReleased)
            // **押下を伴う解放だけがクリックになる。** 押していないところで離しても
            // 解放は起きる (窓の外で押して中で離す・上限で押下が捨てられた、など)
            if before.isMouseDown { dispatch(.mouseClicked) }
        case .mouseMoved(let x, let y):
            // **窓にしか無い情報を使わずに、押下状態から導く。** 窓は押している間の
            // 移動を `mouseDragged` として拾うが、合流点へは 6 種別しか流れないので
            // (`SketchSurface` が `.mouseMoved` へ写す)、外から送れるものと同じ材料で
            // 分けられる。移動は押下状態を変えないので、当てる前と後で同じ
            //
            // **引きずった量は当てる前との差**。dragX はフレームの頭から足し込むので、
            // ここから読むとその出来事までの部分累計になる ([ADR-0034] 決定 5)
            dispatch(
                before.isMouseDown
                    ? .mouseDragged(deltaX: x - before.x, deltaY: y - before.y)
                    : .mouseMoved)
        case .keyDown(_, let characters, _):
            dispatch(.keyPressed)
            // **文字を生むキーだけが打鍵になる。** 矢印やファンクションキーでは呼ばない
            if Self.producesText(characters) { dispatch(.keyTyped) }
        case .keyUp:
            dispatch(.keyReleased)
        case .scrolled(let dx, let dy):
            // 1 件ぶんが出来事にそのまま載っているので、控えずに渡せる
            dispatch(.mouseWheel(deltaX: dx, deltaY: dy))
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
    /// ``characters`` (``Sketch/key``) の更新が同じここを見る — 割れていた頃は、矢印を
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
            // **打鍵と同じ判定を使う。** 空でないことで見ていた頃は、矢印を押すと
            // ここが私用領域の文字になっていた (#805)
            if Self.producesText(characters) { self.characters = characters }
        case .keyUp(let code):
            pressedKeys.remove(code)
            lastKey = code
        }
    }
}
