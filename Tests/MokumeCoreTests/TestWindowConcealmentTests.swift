// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Testing

/// 検査のプロセスで並べた窓を透明にする (#3652)。透明にし方は `TestWindowConcealment.swift` にある。
///
/// **この検査が赤なら、検査を走らせるたびに米粒ほどの窓が画面に現れる。** 窓を並べる口ごとに見る —
/// 口は 1 つではなく、`orderFrontRegardless` は他の口と別の道を通る。
@MainActor
@Suite("検査のプロセスでは並べた窓を透明にする")
struct TestWindowConcealmentTests {
    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.titled],
            backing: .buffered, defer: false)
        // 素の `NSWindow` は閉じたら自分を解放する。こちらが強い参照を持ったまま閉じると過剰に解放される (#705)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test(
        "窓を並べる口のどれを通っても、窓は画面に出たまま透明になる",
        arguments: ["orderFront", "makeKeyAndOrderFront", "orderFrontRegardless", "orderBack"])
    func everyWayOfOrderingInConcealsTheWindow(_ way: String) {
        let window = window()
        defer { window.close() }
        switch way {
        case "orderFront": window.orderFront(nil)
        case "makeKeyAndOrderFront": window.makeKeyAndOrderFront(nil)
        case "orderFrontRegardless": window.orderFrontRegardless()
        default: window.orderBack(nil)
        }
        #expect(window.isVisible, "窓が並んでいない — 並べることまで止めている")
        #expect(window.alphaValue == 0, "\(way) で並べた窓が見えている")
    }

    /// 窓に付けるシートは別の窓 (`NSPanel`) で、`SketchApplicationTests`・`SharedFrameStageTests` が本物を出す。
    @Test("窓に付けたシートも透明になる")
    func anAttachedSheetIsConcealed() {
        let window = window()
        window.orderFront(nil)
        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 20), styleMask: [.titled],
            backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer {
            window.endSheet(sheet)
            sheet.close()
            window.close()
        }
        window.beginSheet(sheet, completionHandler: nil)
        #expect(window.attachedSheet === sheet)
        #expect(sheet.alphaValue == 0, "シートが見えている")
    }
}
