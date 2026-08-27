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
    /// 押されているキーの符号。
    public private(set) var pressedKeys: Set<Int> = []
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
    func beginFrame() {
        previousX = x
        previousY = y
        scrollX = 0
        scrollY = 0
        let events = pending
        pending.removeAll(keepingCapacity: true)
        for event in events { apply(event) }
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
            self.x = x
            self.y = y
        case .scrolled(let dx, let dy):
            scrollX += dx
            scrollY += dy
        case .keyDown(let code, let characters, _):
            pressedKeys.insert(code)
            if !characters.isEmpty { self.characters = characters }
        case .keyUp(let code):
            pressedKeys.remove(code)
        }
    }
}
