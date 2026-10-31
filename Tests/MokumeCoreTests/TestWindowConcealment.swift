// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import ObjectiveC

// 検査のプロセスだけで、並べた窓を透明にする (#3652)。
//
// **何を。** 窓の経路を通す検査 (`SketchApplication.didFinishLaunching()` を呼ぶもの・`SketchViewTests` などが
// 自前で建てるもの・窓に付けるシート) は本物の窓を画面に並べる。窓の大きさは描く大きさ × 0.5 なので、検査の
// 32×16 のスケッチでは 16×8 pt の米粒になり、走らせている人の画面に現れては消えた。検査が確かめているのは
// 窓の経路の振る舞い (キー・ドロップ・× ・第一応答者) で、窓が見えることではない。
//
// **透明にしても、窓の見え方を読む口は残る。** 本体には、窓が見えているかを読む口が 3 つある。
// (1) 差し出すかどうか: `occlusionState` を読むが、検査からは `windowVisibilityForTesting` で決める。
// (2) 名乗りの待ち: `SketchPresence` が `occlusionState` を待つ。検査からは起こさない (#473)。
// (3) 矢印を隠す判定: `windowNumber(at:)` で読み、検査は判定を差し替えている。
// 見え方を読む検査を新しく書くときは、窓は並んでいても透明で、`occlusionState` は当てにならない前提で書く。
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

    /// 窓を並べるのは main thread のはずだが、外から並べた誤りを**検査のプロセスごと落とす形にはしない**。
    /// 落ちると要約の無い「消えた回」になり、どの検査かが読めない。外なら透明にせず、AppKit の警告に任せる。
    private static func conceal(_ window: AnyObject) {
        guard Thread.isMainThread else { return }
        nonisolated(unsafe) let window = window
        MainActor.assumeIsolated { (window as? NSWindow)?.alphaValue = 0 }
    }
}
