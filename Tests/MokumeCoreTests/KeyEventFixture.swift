// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
@testable import MokumeMac

/// 検査からウィンドウへ送れるキーの出来事。
///
/// **面の `keyDown` を直に呼ぶのでは覆えない区間がある** — ウィンドウ → 第一応答者 → 面という
/// 配送そのものが、いちばん無音で落ちるところである
/// (`SketchSurface.acceptsFirstResponder` が理由を持つ)。ウィンドウへ本物の `NSEvent` を送るには
/// 引数が 11 個要るので、組み方をここに 1 つ置く ([#963])。
///
/// [#963]: https://github.com/mokume-metal/mokume/issues/963
enum KeyEventFixture {
    /// このウィンドウへ送れる keyDown を 1 件。
    ///
    /// - Parameters:
    ///   - window: 送り先。**ウィンドウの番号を載せる** — 載せないと `sendEvent(_:)` が配れない。
    ///   - characters: 押して出る文字。
    ///   - keyCode: キーの符号 (`0` は `a`)。
    static func keyDown(in window: NSWindow, characters: String, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }
}
