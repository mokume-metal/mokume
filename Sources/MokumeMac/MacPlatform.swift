// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeCore

/// MokumeCore が OS の UI 部品に頼る口へ、macOS の部品を差し込む (#3804)。
///
/// **MokumeCore は AppKit を知らない。** 画面の一覧 (``Display``) とメニューバーの名乗り (``SketchPresence``) は
/// OS の UI 部品で読む・出すもので、Core は口 (`Display.screenReader`・`SketchRuntime.makePresence`) だけを持つ。
/// ランタイムを組む前に、ここで一度差し込む。差し込む前に組んだランタイムは、画面の一覧を空と読み、名乗らない。
///
/// 呼ぶのは、ランタイムを組む入口: ウィンドウの経路 (``SketchApplication``・``Sketch/main()``・`SketchView`) と、
/// ウィンドウを出さない口 (`MokumeHost` の `HeadlessRun`)・参照スケッチの書き出し。**何度呼んでもよい。**
@MainActor
package enum MacPlatform {
    package static func install() {
        Display.screenReader = { Display.readings() }
        SketchRuntime.makePresence = { SketchPresence(source: $0) }
    }
}
