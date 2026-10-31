// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import ObjectiveC

// 検査のプロセスだけで、並べた窓を透明にする (#3652)。
//
// **何を。** 窓の経路を通す検査 (`SketchApplication.didFinishLaunching()` を呼ぶもの・`SketchViewTests` などが
// 自前で建てるもの・窓に付けるシート) は本物の窓を画面に並べる。窓の大きさは描く大きさ × 0.5 なので、検査の
// 32×16 のスケッチでは 16×8 pt の米粒になり、走らせている人の画面に現れては消えた。検査が確かめているのは
// 窓の経路の振る舞い (キー・ドロップ・× ・第一応答者) で、窓が見えることではない。見えることを頼りにする
// 唯一の判定 (`occlusionState`) は、検査から `windowVisibilityForTesting` で決めている。
//
// **どう。** 窓を並べる口で、元の実装の前に `alphaValue = 0` を当てる。並べるのはやめない — キーの窓・
// 第一応答者・全画面の切り替えは、画面に出た窓にしか効かない。口は 2 つある (2026-10-31 に実験で確かめた):
// 1. `-[NSWindow orderWindow:relativeTo:]`。`orderFront:`・`makeKeyAndOrderFront:`・`orderBack:` が通る
// 2. `-[NSWindow orderFrontRegardless]`。1 を通らない (見張りが起こした入れ替えの経路が使う)
//
// **前面は扱わない。** 検査のプロセスは `run()` を呼ばないので活動の方針が `.prohibited` のままで、
// `NSApp.activate()` を呼んでも前面のアプリは変わらない (#3652 の原因の 3 つ目)。
//
// **製品には入れない。** このファイルは `MokumeCoreTests` にだけ属し、`Sources/` からは見えない。

/// 検査の環境で並べた窓を透明にする。効いているかは `TestWindowConcealmentTests` が見る。
nonisolated enum TestWindowConcealment {
    static func install() {
        let orderWindow = NSSelectorFromString("orderWindow:relativeTo:")
        if let method = class_getInstanceMethod(NSWindow.self, orderWindow) {
            typealias Original = @convention(c) (AnyObject, Selector, Int, Int) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (AnyObject, Int, Int) -> Void = { window, place, relativeTo in
                conceal(window)
                original(window, orderWindow, place, relativeTo)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        let regardless = NSSelectorFromString("orderFrontRegardless")
        if let method = class_getInstanceMethod(NSWindow.self, regardless) {
            typealias Original = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (AnyObject) -> Void = { window in
                conceal(window)
                original(window, regardless)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    /// 窓を並べるのは main thread だけなので、ここも main thread で呼ばれる (違えば `assumeIsolated` が落とす)。
    private static func conceal(_ window: AnyObject) {
        nonisolated(unsafe) let window = window
        MainActor.assumeIsolated { (window as? NSWindow)?.alphaValue = 0 }
    }
}
