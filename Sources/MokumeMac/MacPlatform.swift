// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeCore

/// MokumeCore が OS の UI 部品に頼る口へ、macOS の部品を差し込む (#3804)。
///
/// **MokumeCore は AppKit を知らない。** 画面の一覧 (``Display``) とメニューバーの名乗り (``SketchPresence``) は
/// OS の UI 部品で読む・出すもので、Core は口 (`Display.screenReader`・`SketchRuntime.makePresence`) だけを持つ。
/// スケッチの実体を作る前・ランタイムを組む前に、ここで一度差し込む。差し込む前に読んだ画面の一覧は空で、差し込む
/// 前に組んだランタイムも、差し込んだ後には名乗る。
///
/// 呼ぶのは、スケッチの実体を作る・ランタイムを組む入口: ウィンドウの経路 (``SketchApplication``・``Sketch/main()``・
/// `SketchView`) と、ウィンドウを出さない口 (`MokumeHost` の `HeadlessRun`)・参照スケッチ・`frame-rate-probe`。
/// **何度呼んでもよい。**
@MainActor
package enum MacPlatform {
    /// 差し込む画面の読み手。既定は `NSScreen` を読む。**検査が差し替える** — 画面の無い実行環境でも、
    /// 差し込まれた読み手で読んだことを見分けられるようにする。
    package static var screenReadings: () -> [Display.Reading] = { Display.readings() }

    package static func install() {
        Display.screenReader = screenReadings
        SketchRuntime.makePresence = { SketchPresence(source: $0) }
    }
}
