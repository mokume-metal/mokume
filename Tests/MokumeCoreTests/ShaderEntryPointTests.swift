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
        var caught: ShaderFailure?
        do {
            try ShaderSource.checkNames(values: ["tint color": 1, "ok": 2], path: "shader")
        } catch {
            caught = error
        }
        guard case .notCompilable(let path, let reason) = try #require(caught) else {
            Issue.record("notCompilable で断らない: \(String(describing: caught))")
            return
        }
        #expect(path == "shader")
        #expect(reason.contains("\"tint color\""), "\(reason)")
        #expect(reason.contains("values:"), "\(reason)")
        #expect(!reason.contains("\"ok\""), "受ける名前まで名指しした:\n\(reason)")
        #expect(!reason.contains("mokume/"), "\(reason)")
    }

    @Test("識別子の名前だけなら断らない")
    func usableNamesPass() throws {
        try ShaderSource.checkNames(values: ["tint": 1, "_k1": 2, "波": 3], path: "shader")
    }
}
