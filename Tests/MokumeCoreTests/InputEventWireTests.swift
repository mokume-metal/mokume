// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 道具の窓から子へ運ぶ 1 行。
///
/// **書く側と読む側が同じ綴りを使っているかを見る。** 割れると症状は「触っても効かない」
/// としか出ない — 道具は書けたと思い、子は知らない鍵として捨てるので、どちらも何も
/// 言わない ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 4)。
@Suite("窓から子へ運ぶ 1 行")
struct InputEventWireTests {
    private func roundTrip(_ event: InputEvent) throws -> InputEvent? {
        let line = event.wireLine
        #expect(line.hasSuffix("\n"), "1 行 1 件なので、改行で閉じる")
        let raw = try JSONDecoder().decode(
            RawInputEvent.self, from: Data(line.utf8))
        return raw.event
    }

    @Test(
        "どの種別も、書いて読み戻すと同じ出来事になる",
        arguments: [
            InputEvent.mouseDown(x: 12.5, y: 30, button: 1),
            .mouseUp(x: 0, y: 0, button: 0),
            .mouseMoved(x: -4.25, y: 719.5),
            .scrolled(dx: 1.5, dy: -2.25),
            .keyDown(code: .enter, characters: "a", isRepeat: true),
            .keyUp(code: .escape),
        ])
    func survivesTheRoundTrip(event: InputEvent) throws {
        #expect(try roundTrip(event) == event)
    }

    /// **入力された文字がそのまま入る。** 逃がさないと、`"` を 1 つ打っただけで行が壊れ、
    /// その 1 件どころか後続の解釈まで崩れる。
    @Test(
        "囲みを壊す文字が入っていても、行は壊れない",
        arguments: ["\"", "\\", "改\n行", "\t", "\u{01}", "あ"])
    func escapesTroublesomeCharacters(characters: String) throws {
        let event = InputEvent.keyDown(code: .s, characters: characters, isRepeat: false)
        #expect(try roundTrip(event) == event)
    }

    /// JSON に `nan` も `inf` も無い。そのまま書くと**行ごと**解けなくなる — 1 件が
    /// 丸ごと消えるのは、位置が 0 になるより分かりにくい。
    @Test("有限でない数は 0 にして、行を壊さない")
    func replacesNonFiniteNumbers() throws {
        let event = InputEvent.mouseMoved(x: .nan, y: .infinity)
        #expect(try roundTrip(event) == .mouseMoved(x: 0, y: 0))
    }
}
