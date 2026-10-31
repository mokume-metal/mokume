// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import ObjectiveC

// 検査のプロセスだけで、窓のアニメーションを止める (#3286)。
//
// **何を。** 専用機 (`mokume-m4`) で全部の検査を続けて走らせると、窓を使う検査のたびに GCD のワーカーが
// `-[NSAnimation _runBlocking]` (窓の開閉・サイズ変更のアニメーション) の中で止まったまま残り、スレッドが
// 16 本から 77 本まで積み上がる (診断 1・2: #3284・#3285)。上限に当たるとグローバルキューに積んだ仕事
// (動画の書き手の閉じ・裏の組み立て) が走れず、「30 秒待って届かない」赤が連鎖した (#3263 の queue)。
// 始めるのは AppKit が窓の出し入れ (`makeKeyAndOrderFront:`・`close`) に自動で付ける
// `_NSWindowTransformAnimation` で、mokume のコードは `NSAnimation` を直に使っていない (診断 4: #3288)。
// 診断 3 (#3287) で下の 2 つを立てたところ、専用機の `render-pr` が緑・スレッドの最大 21 本・
// 止まり 0 回・`NSAnimation` の開始 0 回になった。
//
// **どう。** テストバンドルが読み込まれた時点 (どの検査よりも前) に、次の 2 つを入れる。
// 診断 4 では 1 だけで積み上がりが消えた。2 は、1 を見ずに窓ごとの振る舞いでアニメーションを
// 始める経路が残っても止まるように重ねている。
// 1. `NSAutomaticWindowAnimationsEnabled` を false にする (アプリ全体の窓のアニメーションの既定)
// 2. `-[NSWindow animationBehavior]` の読み出しを常に `.none` にする。窓は `SketchApplication`・
//    `WindowPlacement`・検査自身が作るので、窓ごとに `.none` を当てる形では作る所を 1 つに絞れない
//
// **製品には入れない。** 利用者の Mac の窓の振る舞い (開閉・全画面のアニメーション) は変えない。
// このファイルは `MokumeCoreTests` にだけ属し、`Sources/` からは見えない。

/// 検査の環境で窓のアニメーションを止める。効いているかは `TestWindowAnimationsTests` が見る。
nonisolated enum TestWindowAnimations {
    static let defaultsKey = "NSAutomaticWindowAnimationsEnabled"

    static func install() {
        // **置き場に書かず、このプロセスの登録の層にだけ置く。** `set` は検査の道具
        // (`swiftpm-testing-helper`) の設定の置き場に残り、別の走り・同時に走る別のプロセスにまで効く。
        // 終わるときに消す形にすると、先に終わったプロセスの消しが、まだ走っているプロセスの値まで消した
        // (#3289 の CI で、この値を見る検査が赤になった)。登録の層はプロセスの中だけで消える
        UserDefaults.standard.register(defaults: [defaultsKey: false])
        guard
            let method = class_getInstanceMethod(
                NSWindow.self, NSSelectorFromString("animationBehavior"))
        else { return }
        let block: @convention(block) (AnyObject) -> Int = { _ in
            NSWindow.AnimationBehavior.none.rawValue
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

/// テストバンドルの読み込み時 (どの検査よりも前) に 1 度だけ走る。窓のアニメーションを止め (#3286)、
/// 並べた窓を透明にする (`TestWindowConcealment`・#3652)。
@section("__DATA,__mod_init_func")
@used
private let testWindowsConstructor: @convention(c) () -> Void = {
    TestWindowAnimations.install()
    TestWindowConcealment.install()
}
