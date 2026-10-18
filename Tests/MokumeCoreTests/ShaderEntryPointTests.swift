// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 入口を書き違えた断片の理由の言い直し (#2782)。**GPU を使わない** — Metal の理由の文面の例を
/// 入れて、言い直しの照合だけを見る (実際の断片で言い直しが出ることは `ShaderErrorLineTests` が
/// GPU で見る)。
///
/// 例の文面は 2026-10-18 に手元の GPU で実測したもの (#2782 の着手時のプラン)。前置きの
/// `unused function` の警告は省いた。
@Suite("入口の言い直し")
struct ShaderEntryPointTests {
    /// リンクの段で入口の記号が未定義と出た理由。
    private static func undefined(_ symbol: String, from referrer: String = "mokume_effectMain") -> String {
        """
        Undefined symbol(s) for architecture 'air64':
          '\(symbol)', referenced from:
              \(referrer) in program_object_0
        error: symbol(s) not found for target 'air64-apple-macosx27.0.0'
        """
    }

    @Test(
        "入口の記号が未定義と出たら、先頭に期待する入口の形を 1 行で足し、Metal の文面は下に残す",
        arguments: [
            (false, "_Z5paint8Fragment6Values", "float4 paint(Fragment in, Values values)"),
            (true, "_Z5paint8Fragment6Values8Surfaces",
             "float4 paint(Fragment in, Values values, Surfaces surfaces)"),
        ])
    func aMissingPaintIsRestated(_ surfaces: Bool, _ symbol: String, _ signature: String) throws {
        let reason = Self.undefined(symbol, from: "_ZL17mokume_shapeColor15ShapeFragmentIn")
        let restated = ShaderEntryPoint.paint(surfaces: surfaces).restating(reason, in: "shader")
        let lines = restated.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("shader: error: ") == true, "\(restated)")
        #expect(lines.first?.contains(signature) == true, "\(restated)")
        #expect(restated.hasSuffix("\n" + reason), "Metal の文面がそのまま下に残らない:\n\(restated)")
    }

    @Test("面を渡した塗りの言い直しは、面を渡したので 3 引数が要ると言う")
    func theSurfacesFormSaysWhy() throws {
        let restated = ShaderEntryPoint.paint(surfaces: true)
            .restating(Self.undefined("_Z5paint8Fragment6Values8Surfaces"), in: "waves.metal")
        let first = try #require(restated.components(separatedBy: "\n").first)
        #expect(first.hasPrefix("waves.metal: error: "), "\(first)")
        #expect(first.contains("surfaces:"), "\(first)")
    }

    @Test("効果の入口の記号が未定義と出たら、effect の形を言う")
    func aMissingEffectIsRestated() throws {
        let restated = ShaderEntryPoint.effect.restating(Self.undefined("_Z6effect5Pixel6Values"), in: "effect")
        let first = try #require(restated.components(separatedBy: "\n").first)
        #expect(first.hasPrefix("effect: error: "), "\(first)")
        #expect(first.contains("float4 effect(Pixel in, Values values)"), "\(first)")
    }

    /// 面を渡さずに 3 引数の `paint` を書くと、`Surfaces` の型が無いのでリンクの前の組み立てで落ちる。
    @Test("面を渡さない塗りで Surfaces が無いと出たら、2 引数が要ると言う")
    func surfacesWithoutSurfacesIsRestated() throws {
        let reason = """
            shader:1:42: error: unknown type name 'Surfaces'
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                                                     ^
            """
        let restated = ShaderEntryPoint.paint(surfaces: false).restating(reason, in: "shader")
        let first = try #require(restated.components(separatedBy: "\n").first)
        #expect(first.hasPrefix("shader: error: "), "\(first)")
        #expect(first.contains("float4 paint(Fragment in, Values values)"), "\(first)")
        #expect(first.contains("surfaces:"), "\(first)")
        #expect(restated.hasSuffix("\n" + reason))
        // 面を渡した塗りでは Surfaces は在るので、この形の言い直しはしない
        #expect(ShaderEntryPoint.paint(surfaces: true).restating(reason, in: "shader") == reason)
    }

    /// 入口以外の記号が未定義のリンクの失敗は言い直さない。`referenced from:` の下に入口の記号が
    /// 引用符なしで並ぶ (入口から呼んだ) ので、引用符つきの記号だけを照合する。
    @Test("入口以外の記号が未定義なら、言い直さずにそのまま返す")
    func otherUndefinedSymbolsAreLeftAlone() {
        let reason = """
            Undefined symbol(s) for architecture 'air64':
              '_Z6helperf', referenced from:
                  mokume_fragmentMain in program_object_0
                  _Z5paint8Fragment6Values in program_object_0
            error: symbol(s) not found for target 'air64-apple-macosx27.0.0'
            """
        #expect(ShaderEntryPoint.paint(surfaces: false).restating(reason, in: "shader") == reason)
        #expect(ShaderEntryPoint.paint(surfaces: true).restating(reason, in: "shader") == reason)
        #expect(ShaderEntryPoint.effect.restating(reason, in: "effect") == reason)
    }

    /// 2 引数の記号は 3 引数の記号の頭と同じ綴りなので、引用符まで含めて照合しないと取り違える。
    @Test("2 引数の入口の照合は、3 引数の記号の未定義を拾わない")
    func theShortSymbolDoesNotMatchTheLongOne() {
        let reason = Self.undefined("_Z5paint8Fragment6Values8Surfaces")
        #expect(ShaderEntryPoint.paint(surfaces: false).restating(reason, in: "shader") == reason)
    }

    @Test("断片の名前に改行があっても、入口の言い直しは 1 行に収まる")
    func aFragmentNameWithANewlineStaysOnOneLine() {
        let restated = ShaderEntryPoint.effect.restating(Self.undefined("_Z6effect5Pixel6Values"), in: "my\neffect")
        #expect(restated.components(separatedBy: "\n").first?.hasPrefix("my effect: error: ") == true, "\(restated)")
        #expect(!ShaderEntryPoint.missingKernel(named: "probe", in: "my\nprobe").contains("\n"))
    }

    @Test("組み立ての誤りは言い直さない")
    func compileErrorsAreLeftAlone() {
        let reason = "shader:2:12: error: use of undeclared identifier 'foo'"
        #expect(ShaderEntryPoint.paint(surfaces: false).restating(reason, in: "shader") == reason)
        #expect(ShaderEntryPoint.effect.restating(reason, in: "effect") == reason)
    }
}

/// `values:`・`surfaces:` の名前の検め (#2783)。**GPU を使わない** — 判定と断り方だけを見る
/// (6 つの口が実際に断ることは `ShaderErrorLineTests` が見る)。
@Suite("値と面の名前")
struct ShaderValueNameTests {
    @Test("断片の中で書ける名前は受ける", arguments: ["tint", "_k1", "波", "Tint2", "_", "ä"])
    func usableNames(_ name: String) {
        #expect(ShaderSource.isUsableName(name))
    }

    @Test(
        "空・数字で始まる・空白や記号を含む名前は断る",
        arguments: ["", "1x", "a b", "a;b", "a; float b", "a.b", "tint color", "$x", "a-b", "a\nb"])
    func unusableNames(_ name: String) {
        #expect(!ShaderSource.isUsableName(name))
    }

    @Test("断るときは、渡した口 (values: か surfaces:) と名前を名指しし、本体の前置きの名を出さない")
    func theFailureNamesTheArgument() throws {
        let reason = try #require(
            ShaderSource.unusableNames(values: ["tint color": 1, "ok": 2], in: "shader"))
        #expect(reason.hasPrefix("shader: error: "), "\(reason)")
        #expect(reason.contains("\"tint color\""), "\(reason)")
        #expect(reason.contains("values:"), "\(reason)")
        #expect(!reason.contains("\"ok\""), "受ける名前まで名指しした:\n\(reason)")
        #expect(!reason.contains("mokume/"), "\(reason)")
    }

    @Test("識別子の名前だけなら断らない")
    func usableNamesPass() {
        #expect(ShaderSource.unusableNames(values: ["tint": 1, "_k1": 2, "波": 3], in: "shader") == nil)
    }
}

/// 字の並びは通っても Metal で使えない名前の言い直し (#2783 の反証)。**GPU を使わない** — 実測した
/// Metal の理由の文面の例 (2026-10-18・手元の GPU) を入れて、宣言の行から名前を引く照合だけを見る。
/// 実際の断片で出ることは `ShaderErrorLineTests` が GPU で見る。
@Suite("Metal で使えない名前の言い直し")
struct ShaderDeclaredNameTests {
    /// 値の宣言の行は、4 成分のものが先で、同じ成分の数なら名前の降順 (``ShaderSource/pack(_:)`` と同じ)。
    /// `c` (色) が 2 行目、`half` が 3 行目、`a` が 4 行目。
    private static let values: [String: ShaderValue] = [
        "a": 1, "half": 2, "c": .color(LinearRGBA(straightRed: 1, green: 1, blue: 1)),
    ]

    @Test("誤りが値の宣言の行を指したら、その行の名前を values: の名前として名指す")
    func anErrorOnAValueLineNamesThatValue() throws {
        let reason = """
            mokume/Values:3:11: error: cannot combine with previous 'float' declaration specifier
                float half;
            mokume/Values:3:5: warning: declaration does not declare anything [-Wmissing-declarations]
            """
        let names = ShaderSource.declaredNames(values: Self.values)
        let restated = names.restating(reason, in: "shader")
        let first = try #require(restated.components(separatedBy: "\n").first)
        #expect(first.hasPrefix("shader: error: the name \"half\" in values: "), "\(restated)")
        #expect(restated.components(separatedBy: "\n").count == reason.components(separatedBy: "\n").count + 1)
        #expect(restated.hasSuffix("\n" + reason), "Metal の文面がそのまま下に残らない")
    }

    @Test("宣言の行が並びのとおりに名前へ対応する")
    func declarationRowsFollowTheDeclaration() {
        let names = ShaderSource.declaredNames(values: Self.values)
        #expect(names.valueLines == [2: "c", 3: "half", 4: "a"])
        let lines = ShaderSource.declaration(of: Self.values).components(separatedBy: "\n")
        #expect(lines[1] == "    float4 c;")
        #expect(lines[2] == "    float half;")
        #expect(lines[3] == "    float a;")
    }

    @Test("誤りが面の宣言の行を指したら、その行の名前を surfaces: の名前として名指す")
    func anErrorOnASurfaceLineNamesThatSurface() throws {
        let reason = """
            mokume/Surfaces:3:29: error: expected member name or ';' after declaration specifiers
                metal::texture2d<float> MOKUME_SURFACES;
            mokume/Surfaces:1:25: note: expanded from macro 'MOKUME_SURFACES'
            mokume/Surfaces:7:14: error: expected unqualified-id
                surfaces.MOKUME_SURFACES = s0;
            """
        let names = ShaderSource.DeclaredNames(
            valueLines: [:], surfaceLines: [3: "MOKUME_SURFACES", 7: "MOKUME_SURFACES"],
            values: [], surfaces: ["MOKUME_SURFACES"])
        let restated = names.restating(reason, in: "waves.metal")
        let lines = restated.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("waves.metal: error: the name \"MOKUME_SURFACES\" in surfaces: "), "\(restated)")
        // 同じ名前を 2 度名指さない
        #expect(lines[1] == reason.components(separatedBy: "\n")[0], "\(restated)")
    }

    /// 前置きのマクロと同じ名前の値を断片で読むと、誤りは書いた断片の行に出て、マクロの知らせが添う。
    @Test("渡した名前のマクロが展開されたと出たら、その名前を名指す")
    func anExpandedMacroWithAPassedNameIsNamed() throws {
        let reason = """
            probe:1:159: error: expected unqualified-id
            kernel void probe(…) { out[id] = values.MOKUME_VALUES; }
            mokume/Compute.metal:19:23: note: expanded from macro 'MOKUME_VALUES'
            #define MOKUME_VALUES 15
            """
        let names = ShaderSource.declaredNames(values: ["MOKUME_VALUES": 1])
        let first = try #require(names.restating(reason, in: "probe").components(separatedBy: "\n").first)
        #expect(first.hasPrefix("probe: error: the name \"MOKUME_VALUES\" in values: "), "\(first)")
        // 渡していない名前のマクロは名指さない
        #expect(ShaderSource.declaredNames(values: ["tint": 1]).restating(reason, in: "probe") == reason)
    }

    @Test("宣言を指さない誤り・宣言の行への警告だけなら、言い直さない")
    func otherReasonsAreLeftAlone() {
        let names = ShaderSource.declaredNames(values: Self.values)
        let inTheFragment = "shader:2:12: error: use of undeclared identifier 'foo'"
        #expect(names.restating(inTheFragment, in: "shader") == inTheFragment)
        let warningOnly = "mokume/Values:3:5: warning: declaration does not declare anything"
        #expect(names.restating(warningOnly, in: "shader") == warningOnly)
    }

    @Test("断片の名前に改行があっても、言い直しは 1 行に収まる")
    func aNameWithANewlineStaysOnOneLine() {
        let reason = "mokume/Values:3:11: error: cannot combine with previous 'float' declaration specifier"
        let restated = ShaderSource.declaredNames(values: Self.values).restating(reason, in: "my\nshader")
        #expect(restated.components(separatedBy: "\n").first?.hasPrefix("my shader: error: ") == true, "\(restated)")
        let unusable = ShaderSource.unusableNames(values: ["a b": 1], in: "my\nshader") ?? ""
        #expect(!unusable.contains("\n"), "\(unusable)")
    }
}
