// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 断片が名前で読む数の並び (`numbers:`・#3576)。GPU を要する。
///
/// 渡す側は作る口の `numbers:` と ``Shader/set(_:_:)-(_,Numbers)``、断片の側は入口の `Numbers numbers`
/// から `numbers.<名前>[i]` で読む (面の `surfaces:` と同じ形・#2458 の Q-D6)。名前の付かない 1 本
/// (`numbers()`・`in.numbers`) は残す。
@Suite(
    "名前で読む数の並び",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ShaderNumbersTests {
    private func makeCanvas(width: Int = 16, height: Int = 16) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private func numbers(_ values: [Float], on canvas: Canvas) throws -> Numbers {
        let numbers = try canvas.makeNumbers(count: values.count)
        numbers.set(values)
        return numbers
    }

    /// 全面を 1 枚の四角で塗り、真ん中の色を返す。
    private func paintedColor(on canvas: Canvas, with shader: Shader) throws -> LinearRGBA {
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
            canvas.resetShader()
        }
        return canvas.get(8, 8)
    }

    @Test("名前で渡した 2 本の並びが、それぞれの名前で断片に届く")
    func namedArraysReachTheFragment() throws {
        let canvas = try makeCanvas()
        // **名前は渡した順と名前順が逆になるように選ぶ。** 口の割り当て (名前順) と原稿の宣言の
        // 並びが食い違えば、赤と青が入れ替わる
        let zeta = try numbers([0, 1], on: canvas)
        let alpha = try numbers([1, 0], on: canvas)
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values, Numbers numbers) {
                return float4(numbers.alpha[0], numbers.zeta[0], numbers.zeta[1], 1.0);
            }
            """,
            numbers: ["zeta": zeta, "alpha": alpha])

        #expect(try paintedColor(on: canvas, with: shader) == .linear(red: 1, green: 0, blue: 1))
    }

    @Test("面と並びの両方を宣言した断片は、面・並びの順に 4 引数で受け取る")
    func surfacesAndNumbersTogether() throws {
        let canvas = try makeCanvas()
        let tone = try canvas.createImage(4, 4)
        tone.fill(.linear(red: 0, green: 1, blue: 0))
        let gain = try numbers([1], on: canvas)
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values, Surfaces surfaces, Numbers numbers) {
                return float4(numbers.gain[0], mokume_sample(surfaces.tone, in.place).g, 0.0, 1.0);
            }
            """,
            surfaces: ["tone": .image(tone)], numbers: ["gain": gain])

        #expect(try paintedColor(on: canvas, with: shader) == .linear(red: 1, green: 1, blue: 0))
    }

    /// 完了条件 3 (#3576)。名前の付かない 1 本 (`numbers()`・`in.numbers`) は、名前で渡した並びと
    /// 同じ断片の中でも読める。
    @Test("名前で渡した並びと、numbers() で渡した 1 本を、同じ断片で読める")
    func theUnnamedArrayStillWorksAlongside() throws {
        let canvas = try makeCanvas()
        let named = try numbers([1], on: canvas)
        let unnamed = try numbers([1], on: canvas)
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values, Numbers numbers) {
                return float4(numbers.named[0], in.numbers[0], 0.0, 1.0);
            }
            """,
            numbers: ["named": named])

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 8, 16)
            canvas.numbers(unnamed)
            canvas.rect(8, 0, 8, 16)
            canvas.resetNumbers()
            canvas.resetShader()
        }
        // 左は 1 本を渡す前なので、in.numbers は 1 個の 0 を読む
        #expect(canvas.get(4, 8) == .linear(red: 1, green: 0, blue: 0))
        #expect(canvas.get(12, 8) == .linear(red: 1, green: 1, blue: 0))
    }

    @Test("並びを差し替える前に置いた図形は前の並びを、後に置いた図形は新しい並びを読む")
    func setSwapsTheArrayForLaterPlacements() throws {
        let canvas = try makeCanvas()
        let first = try numbers([1], on: canvas)
        let second = try numbers([0], on: canvas)
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values, Numbers numbers) {
                return float4(numbers.level[0], 0.0, 0.0, 1.0);
            }
            """,
            numbers: ["level": first])

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 1))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 8, 16)
            shader.set("level", second)
            canvas.rect(8, 0, 8, 16)
            canvas.resetShader()
        }
        #expect(canvas.get(4, 8) == .linear(red: 1, green: 0, blue: 0))
        #expect(canvas.get(12, 8) == .linear(red: 0, green: 0, blue: 0))
    }

    @Test("宣言していない名前の並びは受け付けない")
    func undeclaredNamesAreRefused() throws {
        let canvas = try makeCanvas()
        let declared = try numbers([1], on: canvas)
        let stranger = try numbers([0], on: canvas)
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values, Numbers numbers) {
                return float4(numbers.level[0], 0.0, 0.0, 1.0);
            }
            """,
            numbers: ["level": declared])
        // **名前は宣言済みの名前より前に並ぶものを選ぶ。** 受け付けてしまえば口の割り当てが
        // 1 つずれるので、無視されたかどうかが絵に出る
        shader.set("astray", stranger)

        #expect(try paintedColor(on: canvas, with: shader) == .linear(red: 1, green: 0, blue: 0))
    }

    @Test("並びは口の数まで渡せ、超える宣言は読み込みの時点で断られる")
    func moreArraysThanThereArePortsAreRefusedAtLoad() throws {
        let canvas = try makeCanvas()
        let one = try numbers([1], on: canvas)
        let body = "float4 paint(Fragment in, Values values, Numbers numbers) { return in.color; }"

        var full: [String: Numbers] = [:]
        for index in 0..<ShapePipeline.namedNumbersCapacity { full["n\(index)"] = one }
        _ = try canvas.makeShader(body, name: "full", numbers: full)

        var crowded = full
        crowded["extra"] = one
        #expect(
            throws: ShaderFailure.tooManyNumbers(
                path: "crowded", count: ShapePipeline.namedNumbersCapacity + 1,
                capacity: ShapePipeline.namedNumbersCapacity)
        ) {
            try canvas.makeShader(body, name: "crowded", numbers: crowded)
        }

        // 在処から読む経路も同じ
        let directory = TestScratch.path("mokume-shader-numbers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("crowded.metal")
        try body.write(to: url, atomically: true, encoding: .utf8)
        #expect(
            throws: ShaderFailure.tooManyNumbers(
                path: url.path, count: ShapePipeline.namedNumbersCapacity + 1,
                capacity: ShapePipeline.namedNumbersCapacity)
        ) {
            try canvas.loadShader(url.path, numbers: crowded)
        }
    }

    @Test("並びの名前が断片の中で書けなければ、numbers: の名前として名指しで断られる")
    func unusableNamesAreNamedAsNumbers() throws {
        let canvas = try makeCanvas()
        let one = try numbers([1], on: canvas)
        do {
            _ = try canvas.makeShader(
                "float4 paint(Fragment in, Values values, Numbers numbers) { return in.color; }",
                numbers: ["two words": one])
            Issue.record("書けない名前が通った")
        } catch {
            let text = "\(error)"
            #expect(text.contains("the name \"two words\" in numbers:"), "\(text)")
        }
    }

    @Test("並びを渡したのに 2 引数の入口を書くと、並びを受け取る形を言う")
    func aMissingNumbersEntryIsRestated() throws {
        let canvas = try makeCanvas()
        let one = try numbers([1], on: canvas)
        do {
            _ = try canvas.makeShader(
                "float4 paint(Fragment in, Values values) { return in.color; }",
                numbers: ["level": one])
            Issue.record("入口の書き違えが通った")
        } catch {
            let text = "\(error)"
            #expect(
                text.contains(
                    "shader: error: the fragment does not define its entry point "
                        + "float4 paint(Fragment in, Values values, Numbers numbers)"),
                "\(text)")
        }
    }
}

/// 名前で読む並びの原稿 (#3576)。**GPU を使わない。**
@Suite("名前で読む数の並びの原稿")
struct ShaderNumbersSourceTests {
    @Test("並びを宣言しなければ、前置きは 1 バイトも増えない")
    func noNumbersAddsNothing() {
        #expect(ShaderSource.declaration(ofNumbers: []).isEmpty)
        let body = "float4 paint(Fragment in, Values values) { return in.color; }"
        let plain = ShaderSource.assemble(
            prelude: [.init(name: "mokume/Common.metal", text: "COMMON")], values: [:],
            body: .init(name: "shader", text: body))
        let withEmpty = ShaderSource.assemble(
            prelude: [.init(name: "mokume/Common.metal", text: "COMMON")], values: [:],
            numbers: [], body: .init(name: "shader", text: body))
        #expect(plain == withEmpty)
        #expect(!plain.contains("mokume/Numbers"))
    }

    @Test("並びの宣言は名前順に並び、口の数だけ受け取り、区切りの名前を名乗る")
    func theDeclarationIsOrderedByName() throws {
        let declaration = ShaderSource.declaration(ofNumbers: ["zeta", "alpha"])
        #expect(declaration.contains("#define MOKUME_NUMBERS 2"))
        let alpha = try #require(declaration.range(of: "numbers.alpha = n0;"))
        let zeta = try #require(declaration.range(of: "numbers.zeta = n1;"))
        #expect(alpha.lowerBound < zeta.lowerBound)
        #expect(declaration.contains("device const float *n\(ShapePipeline.namedNumbersCapacity - 1)"))

        let assembled = ShaderSource.assemble(
            prelude: [], values: [:], numbers: ["alpha"], body: .init(name: "shader", text: ""))
        #expect(assembled.contains("#line 1 \"mokume/Numbers\"\n" + ShaderSource.declaration(ofNumbers: ["alpha"])))
    }

    @Test("組み立ての誤りが並びの宣言の行を指したら、numbers: の名前として名指す")
    func aDeclarationErrorIsNamedAsNumbers() {
        let names = ShaderSource.declaredNames(values: [:], numbers: ["half"])
        // 3 行目が `device const float *half;` (1 行目は #define、2 行目は struct)
        let restated = names.restating(
            "mokume/Numbers:3:25: error: expected member name or ';'", in: "shader")
        #expect(restated.hasPrefix("shader: error: the name \"half\" in numbers: "), "\(restated)")
    }

    @Test(
        "並びを渡した塗りの入口の記号が未定義と出たら、並びを受け取る形を言う",
        arguments: [
            (false, "_Z5paint8Fragment6Values7Numbers",
             "float4 paint(Fragment in, Values values, Numbers numbers)"),
            (true, "_Z5paint8Fragment6Values8Surfaces7Numbers",
             "float4 paint(Fragment in, Values values, Surfaces surfaces, Numbers numbers)"),
        ])
    func aMissingPaintWithNumbersIsRestated(_ surfaces: Bool, _ symbol: String, _ signature: String) throws {
        let reason = """
            Undefined symbol(s) for architecture 'air64':
              '\(symbol)', referenced from:
                  _ZL17mokume_shapeColor15ShapeFragmentIn in program_object_0
            """
        let restated = ShaderEntryPoint.paint(surfaces: surfaces, numbers: true)
            .restating(reason, in: "shader")
        let first = try #require(restated.components(separatedBy: "\n").first)
        #expect(first.hasPrefix("shader: error: "), "\(first)")
        #expect(first.contains(signature), "\(first)")
        #expect(first.contains("numbers:"), "\(first)")
    }

    @Test("並びを渡さない塗りで Numbers が無いと出たら、並びを渡していない入口の形を言う")
    func numbersWithoutNumbersIsRestated() throws {
        let reason = """
            shader:1:42: error: unknown type name 'Numbers'
            float4 paint(Fragment in, Values values, Numbers numbers) {
                                                     ^
            """
        let restated = ShaderEntryPoint.paint(surfaces: false).restating(reason, in: "shader")
        let first = try #require(restated.components(separatedBy: "\n").first)
        #expect(first.hasPrefix("shader: error: Numbers exists only"), "\(first)")
        #expect(first.contains("float4 paint(Fragment in, Values values)"), "\(first)")
        // 並びを渡した塗りでは Numbers は在るので、この形の言い直しはしない
        #expect(ShaderEntryPoint.paint(surfaces: false, numbers: true).restating(reason, in: "shader") == reason)
    }
}
