// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore
@testable import mokume

/// 宣言からつまみを決める規則。
///
/// **ウィンドウを立てずに検められる形にしてある** ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 8)。
/// 対応を SwiftUI の中に埋めると、規則が正しいかどうかは画面を見るまで分からなくなる。
@Suite("型ごとのつまみ")
struct KnobKindTests {
    private func kind(_ value: ParamValue, range: ParamRange? = nil, choices: [String]? = nil)
        -> KnobKind
    {
        KnobKind.forDeclaration(
            ParamDeclaration(name: "x", value: value, range: range, choices: choices))
    }

    @Test("数はスライダー。整数は刻みつき")
    func numbersBecomeSliders() {
        let range = ParamRange(0...10)
        #expect(kind(.float(1), range: range) == .slider(range))
        #expect(kind(.int(1), range: range) == .steppedSlider(range))
    }

    /// **範囲を書かなかった数値には、つまみを出さない** (ADR-0030 決定 8)。値から範囲を
    /// 推すと、引いている最中に範囲そのものが動いてつまみが指の下から逃げる。
    @Test("範囲を書かなかった数値には、つまみを出さない")
    func numbersWithoutRangeGetNoKnob() {
        #expect(kind(.float(1)) == .none(.rangeNotDeclared))
        #expect(kind(.int(1)) == .none(.rangeNotDeclared))
        #expect(kind(.vector2(Vector2(1, 2))) == .none(.rangeNotDeclared))
        #expect(kind(.vector3(Vector3(1, 2, 3))) == .none(.rangeNotDeclared))
    }

    @Test("真偽はトグル、色は色の選択")
    func flagsAndColors() {
        #expect(kind(.bool(true)) == .toggle)
        #expect(kind(.color(.transparent)) == .color)
    }

    @Test("組は成分ごとのスライダー")
    func vectorsBecomeComponentSliders() {
        let range = ParamRange(-1...1)
        #expect(kind(.vector2(Vector2(0, 0)), range: range) == .components(count: 2, range: range))
        #expect(kind(.vector3(Vector3(0, 0, 0)), range: range) == .components(count: 3, range: range))
    }

    @Test("文字は候補から選ぶ。候補が無ければつまみを出さない")
    func stringsNeedChoices() {
        #expect(kind(.string("a"), choices: ["a", "b"]) == .choice(["a", "b"]))
        #expect(kind(.string("a")) == .none(.choicesNotDeclared))
        #expect(kind(.string("a"), choices: []) == .none(.choicesNotDeclared))
    }

    /// つまみが出ない値を並びから消すと、**書いたのに効かない**のか**出していないだけ**なのか
    /// がウィンドウからは区別できない。理由は次に何を書けばよいかまで言う。
    @Test("つまみを出さない理由は、次に何を書けばよいかまで言う")
    func reasonsSayWhatToWrite() {
        #expect(KnobKind.Reason.rangeNotDeclared.note.contains("declare a range"))
        #expect(KnobKind.Reason.choicesNotDeclared.note.contains("declare the choices"))
    }
}

/// つまみの脇に出る値の表記。
@Suite("つまみの脇の数字")
struct KnobTextTests {
    @Test("実数は小数 2 桁で、桁が伸び縮みしない")
    func floatsKeepTheirWidth() {
        #expect(KnobText.value(of: .float(1)) == "1.00")
        #expect(KnobText.value(of: .float(1.005)) == "1.00" || KnobText.value(of: .float(1.005)) == "1.01")
        #expect(KnobText.value(of: .int(7)) == "7")
    }

    @Test("色は 16 進で出る")
    func colorsShowAsHex() {
        #expect(KnobText.value(of: .color(.linear(red: 1, green: 0, blue: 0))) == "#FF0000")
    }

    @Test("ウィンドウの 16 進は、書いた色の綴りと一致する")
    func hexMatchesTheColorAsWritten() {
        // **1.0 と 0.0 は線形でもエンコード値でも同じ**なので、上の検査だけでは
        // 転送関数を通し忘れても気付けなかった (#746)。中間調で見る
        #expect(KnobText.value(of: .color(.display(red: 0.5, green: 0.5, blue: 0.5))) == "#808080")
        #expect(KnobText.value(of: .color(color(hex: 0xFF_CC00))) == "#FFCC00")
    }

    @Test("半透明の色も、書いた綴りのまま出る")
    func hexIgnoresTheAlphaMultiplication() {
        // 作業空間はアルファ乗算済み (ADR-0011 決定 4) なので、掛け戻さないと
        // 薄い色ほど暗い綴りになる
        #expect(KnobText.value(of: .color(color(255, 204, 0, 128))) == "#FFCC00")
    }

    @Test("色域の外の色は、綴れる範囲へ寄せて出す")
    func hexClampsWhatItCannotSpell() {
        // 24 bit の綴りに範囲外は書けない。**丸めるのはウィンドウだけ**で、値は保たれている
        #expect(KnobText.value(of: .color(color(510, -20, 0))) == "#FF0000")
    }

    @Test("組は成分を並べる")
    func vectorsShowComponents() {
        #expect(KnobText.value(of: .vector2(Vector2(1, 2))) == "1.00, 2.00")
    }
}
