// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Carbon.HIToolbox
import Foundation
import Testing

@testable import MokumeCore

/// キーの符号が名乗る体系 ([ADR-0034] 決定 1)。
///
/// **写像表を手で書いている以上、正典と突き合わせないと嘘に気付けない。** 綴りが 1 つ
/// ずれても絵は出るし検査も通り、症状は「そのキーだけ効かない」としか出ない。だから
/// macOS 自身が持つ定数 (`Carbon.HIToolbox` の `kVK_*`) と 1 つずつ比べる。
///
/// この検査だけが Carbon を引く。**面には出さない** — 型を面に出さない限り、正典の
/// 在処を知っているのはここだけで済む ([ADR-0020] 決定 6)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
@Suite("キーの符号")
struct KeyTests {
    @Test(
        "名前の付いたキーの符号は、macOS の正典と一致する",
        arguments: [
            (Key.a, kVK_ANSI_A), (.b, kVK_ANSI_B), (.c, kVK_ANSI_C), (.d, kVK_ANSI_D),
            (.e, kVK_ANSI_E), (.f, kVK_ANSI_F), (.g, kVK_ANSI_G), (.h, kVK_ANSI_H),
            (.i, kVK_ANSI_I), (.j, kVK_ANSI_J), (.k, kVK_ANSI_K), (.l, kVK_ANSI_L),
            (.m, kVK_ANSI_M), (.n, kVK_ANSI_N), (.o, kVK_ANSI_O), (.p, kVK_ANSI_P),
            (.q, kVK_ANSI_Q), (.r, kVK_ANSI_R), (.s, kVK_ANSI_S), (.t, kVK_ANSI_T),
            (.u, kVK_ANSI_U), (.v, kVK_ANSI_V), (.w, kVK_ANSI_W), (.x, kVK_ANSI_X),
            (.y, kVK_ANSI_Y), (.z, kVK_ANSI_Z),
            (.digit0, kVK_ANSI_0), (.digit1, kVK_ANSI_1), (.digit2, kVK_ANSI_2),
            (.digit3, kVK_ANSI_3), (.digit4, kVK_ANSI_4), (.digit5, kVK_ANSI_5),
            (.digit6, kVK_ANSI_6), (.digit7, kVK_ANSI_7), (.digit8, kVK_ANSI_8),
            (.digit9, kVK_ANSI_9),
            (.space, kVK_Space), (.enter, kVK_Return), (.escape, kVK_Escape),
            (.tab, kVK_Tab), (.backspace, kVK_Delete),
            (.arrowLeft, kVK_LeftArrow), (.arrowRight, kVK_RightArrow),
            (.arrowDown, kVK_DownArrow), (.arrowUp, kVK_UpArrow),
        ])
    func matchesTheSystemVirtualKeyCodes(key: Key, expected: Int) {
        #expect(key.rawValue == expected)
    }

    /// **並べた綴りが全部違うキーを指していること。** 写し間違えて 2 つが同じ符号に
    /// なっても、片方を使っている限り気付けない。
    @Test("名前の付いたキーは、どれも別のキーを指している")
    func namesTheKeysWithoutOverlap() {
        let named: [Key] = [
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
            .digit0, .digit1, .digit2, .digit3, .digit4,
            .digit5, .digit6, .digit7, .digit8, .digit9,
            .space, .enter, .escape, .tab, .backspace,
            .arrowLeft, .arrowRight, .arrowDown, .arrowUp,
        ]
        #expect(Set(named).count == named.count)
    }

    /// 外からは任意の符号が送られてくる ([ADR-0018] 決定 1)。名前の付いたものしか
    /// 表せない形にすると、**知らないキーを押しただけで出来事が消える**。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    @Test("名前の無い符号も、そのまま表せる")
    func carriesUnnamedCodes() {
        let unnamed = Key(rawValue: 4242)
        #expect(unnamed.rawValue == 4242)
        #expect(unnamed != .space)
    }
}

@Suite("キーを読む面")
@MainActor
struct KeySurfaceTests {
    /// **外から送った符号が、面では綴りとして読める。** 線は macOS の仮想キーコードの
    /// ままで据え置いたので ([ADR-0034] 決定 1)、送り手を変えずに書き味だけが変わる。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    @Test("外から送った符号は、面では名前の付いたキーになる")
    func readsTheSentCodeAsANamedKey() throws {
        let raw = try JSONDecoder().decode(
            RawInputEvent.self,
            from: Data(#"{"type":"keyDown","code":49,"characters":" "}"#.utf8))
        let state = InputState()
        state.enqueue(try #require(raw.event))
        state.beginFrame()

        #expect(state.lastKey == .space)
        #expect(state.pressedKeys.contains(.space))
    }

    @Test("最後に動いたキーは、押しても離しても入れ替わる")
    func remembersTheKeyThatMovedLast() {
        let state = InputState()
        // まだ何も来ていなければ、指しているキーは無い
        #expect(state.lastKey == nil)

        state.enqueue(.keyDown(code: .arrowUp, characters: "", isRepeat: false))
        state.beginFrame()
        #expect(state.lastKey == .arrowUp)

        state.enqueue(.keyUp(code: .arrowUp))
        state.beginFrame()
        // 離したキーも「最後に動いたキー」— 離された側を知る口がここしかない
        #expect(state.lastKey == .arrowUp)
        #expect(!state.pressedKeys.contains(.arrowUp))
    }

    /// 矢印キーは文字を打たない。**打った文字と、動いたキーは別の問いである。**
    @Test("文字を打たないキーでも、どのキーかは読める")
    func namesTheKeyEvenWhenNothingIsTyped() {
        let state = InputState()
        state.enqueue(.keyDown(code: .arrowLeft, characters: "", isRepeat: false))
        state.beginFrame()

        #expect(state.lastKey == .arrowLeft)
        #expect(state.characters.isEmpty)
    }
}
