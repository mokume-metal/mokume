// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Testing

/// 検査のプロセスのウィンドウのアニメーション停止 (#3286)。止め方は `TestWindowAnimations.swift` にある。
///
/// 専用機では、止めていないウィンドウのアニメーションが GCD のワーカーを `NSAnimation` の中で止めたまま残し、
/// グローバルキューが走れなくなった。**この検査が赤なら、その連鎖が戻る。**
@Suite("検査のプロセスではウィンドウのアニメーションを止める")
struct TestWindowAnimationsTests {
    @Test("アプリ全体の既定が false になっている")
    func theAppWideDefaultIsOff() {
        let defaults = UserDefaults.standard
        #expect(defaults.object(forKey: TestWindowAnimations.defaultsKey) != nil)
        #expect(!defaults.bool(forKey: TestWindowAnimations.defaultsKey))
    }

    /// 作ったウィンドウの読み出しが `.none` になる。何も当てていない素のウィンドウと、`.default` を明示したウィンドウの
    /// 両方で見る (後者は、ウィンドウの側の設定を上書きして読み出しを固定していることの確かめ)。
    @Test("作ったウィンドウの animationBehavior は .none")
    func aNewWindowHasNoAnimation() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.titled],
            backing: .buffered, defer: true)
        // 素の `NSWindow` は閉じたら自分を解放する。こちらが強い参照を持ったまま閉じると過剰に解放される (#705)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(window.animationBehavior == .none)
        window.animationBehavior = .default
        #expect(window.animationBehavior == .none)
    }
}
