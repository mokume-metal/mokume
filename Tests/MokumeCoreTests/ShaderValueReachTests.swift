// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 足した型 (`float3`・`bool`・`int`・`float4x4`) の値が、塗り・効果・計算の断片に**そのまま届く**ことの検査
/// (#3568)。宣言と詰め方が Metal の配置とずれると、断片は隣の値の一部を読む。宣言そのものは
/// ``ShaderValueConvertibleTests`` が GPU なしで見る。
///
/// 計算は受けた値を浮動小数の並びに書き出して**ビットまで**比べ、塗りと効果は色に書いて読む。
/// `set(_:_:)` は Swift の値を包まずに渡す。
@Suite(
    "足した型の値が断片に届く",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShaderValueReachTests {
    private static var placement: Transform {
        var placement = Transform.identity
        placement.translate(x: 2, y: 3, z: 4)
        placement.rotate(by: 0.5)
        placement.scale(x: 2, y: 4)
        return placement
    }

    /// 型を 1 つずつ。名前は `v`、書き出す成分の数と、`out[i] = …` の式。
    private struct Single: Sendable {
        let label: String
        let value: ShaderValue
        let expected: [Float]
        let lines: String
    }

    private static let singles: [Single] = [
        Single(
            label: "float3", value: .vector3(Vector3(0.25, -2, 7)), expected: [0.25, -2, 7],
            lines: "out[0] = values.v.x; out[1] = values.v.y; out[2] = values.v.z;"),
        Single(
            label: "bool (true)", value: .bool(true), expected: [1],
            lines: "out[0] = values.v ? 1.0 : 0.0;"),
        Single(
            label: "bool (false)", value: .bool(false), expected: [0],
            lines: "out[0] = values.v ? 1.0 : 0.0;"),
        Single(
            label: "int", value: .int(-12345), expected: [-12345],
            lines: "out[0] = float(values.v);"),
        Single(
            label: "int (Float で表せない大きさ)", value: .int(16_777_217), expected: [1],
            // 2^24 + 1 は float では 2^24 に丸まる。整数のまま 2 で割った余りを見る
            lines: "out[0] = float(values.v % 2);"),
        Single(
            label: "float4x4", value: .transform(placement),
            expected: {
                let m = placement.matrix
                return [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
            }(),
            lines: """
                for (uint c = 0; c < 4; c++) { for (uint r = 0; r < 4; r++) { out[c * 4 + r] = values.v[c][r]; } }
                """),
        Single(
            label: "float2 (既存)", value: .pair(3, 4), expected: [3, 4],
            lines: "out[0] = values.v.x; out[1] = values.v.y;"),
        Single(
            label: "float4 (既存)", value: .color(LinearRGBA(premultipliedRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)),
            expected: [0.1, 0.2, 0.3, 0.4],
            lines: "out[0] = values.v.r; out[1] = values.v.g; out[2] = values.v.b; out[3] = values.v.a;"),
        Single(
            label: "float (既存)", value: .number(0.625), expected: [0.625],
            lines: "out[0] = values.v;"),
    ]

    private static func kernel(_ lines: String) -> String {
        """
        kernel void probe(device float *out [[buffer(0)]],
                          constant Values &values [[buffer(MOKUME_VALUES)]],
                          uint id [[thread_position_in_grid]])
        {
            \(lines)
        }
        """
    }

    @Test("計算: 型を 1 つずつ渡すと、断片が同じ値を受ける")
    func eachTypeReachesAComputation() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        let out = try canvas.makeNumbers(count: 16)
        for single in Self.singles {
            let probe = try canvas.makeComputation(
                Self.kernel(single.lines), name: "probe", values: ["v": single.value])
            try canvas.draw { canvas.compute(probe, over: 1, writes: [out]) }
            let got = canvas.read(out).prefix(single.expected.count).map(\.bitPattern)
            #expect(got == single.expected.map(\.bitPattern), "\(single.label) の値が届いていない")
        }
    }

    @Test("計算: 値を書き換えると、次の頼みから新しい値が届く (足した型)")
    func rewrittenValuesReachTheNextRequest() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        let first = try canvas.makeNumbers(count: 4)
        let second = try canvas.makeNumbers(count: 4)
        let probe = try canvas.makeComputation(
            Self.kernel("out[0] = values.dir.x; out[1] = values.dir.z; out[2] = values.on ? 1.0 : 0.0; out[3] = float(values.n);"),
            name: "probe", values: ["dir": .vector3(Vector3(1, 2, 3)), "on": .bool(false), "n": .int(5)])
        try canvas.draw {
            canvas.compute(probe, over: 1, writes: [first])
            // Swift の値を包まずに渡す
            probe.set("dir", Vector3(10, 20, 30))
            probe.set("on", true)
            probe.set("n", ShaderValue.int(-6))
            canvas.compute(probe, over: 1, writes: [second])
        }
        #expect(canvas.read(first) == [1, 3, 0, 5])
        #expect(canvas.read(second) == [10, 30, 1, -6])
    }

    /// 混ぜた組。`float3`・`float4x4`・`bool` を `float`・`int`・`float2`・`float4` と一緒に宣言し、
    /// 隣の値の一部を読む詰め違いがあれば、どれかが崩れる。
    private static let mixed: [String: ShaderValue] = [
        "placement": .transform(placement),
        "dir": .vector3(Vector3(0.25, 0.5, 0.75)),
        "tint": .color(LinearRGBA(premultipliedRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)),
        "offset": .pair(7, 8),
        "count": .int(-3),
        "amount": .number(0.125),
        "other": .bool(false),
        "flag": .bool(true),
        "third": .bool(true),
    ]

    private static let mixedExpected: [Float] = {
        let m = placement.matrix
        let matrix = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        return [0.25, 0.5, 0.75, 1, 0, 1, -3, 0.125, 0.1, 0.2, 0.3, 0.4, 7, 8] + matrix
    }()

    private static let mixedLines = """
        out[0] = values.dir.x; out[1] = values.dir.y; out[2] = values.dir.z;
        out[3] = values.flag ? 1.0 : 0.0; out[4] = values.other ? 1.0 : 0.0; out[5] = values.third ? 1.0 : 0.0;
        out[6] = float(values.count); out[7] = values.amount;
        out[8] = values.tint.r; out[9] = values.tint.g; out[10] = values.tint.b; out[11] = values.tint.a;
        out[12] = values.offset.x; out[13] = values.offset.y;
        for (uint c = 0; c < 4; c++) { for (uint r = 0; r < 4; r++) { out[14 + c * 4 + r] = values.placement[c][r]; } }
        """

    @Test("計算: float3・float4x4・bool・int を混ぜた組が、どれも崩れずに届く")
    func aMixedSetReachesAComputation() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        let out = try canvas.makeNumbers(count: 30)
        let probe = try canvas.makeComputation(Self.kernel(Self.mixedLines), name: "probe", values: Self.mixed)
        try canvas.draw { canvas.compute(probe, over: 1, writes: [out]) }
        #expect(canvas.read(out).map(\.bitPattern) == Self.mixedExpected.map(\.bitPattern))
    }

    /// 混ぜた組から色を作る。各成分は半精度でも表せる 2 進の分数にしてある。
    ///
    /// 赤は `float3` の z (+ 取り違えの検算)、緑は 2 つの `bool`、青は `int`。`check` は、残りの値
    /// (`float4x4` の平行移動・`float4`・`float2`・`float`) が宣言どおりなら 0 で、どれかが隣の値の
    /// 一部を読んでいれば 0 から離れる。
    private static let paintBody = """
        float4 paint(Fragment in, Values values) {
            float check = abs(values.placement[3][0] - 2.0) + abs(values.placement[3][1] - 3.0)
                + abs(values.offset.y - 8.0) + abs(values.tint.g - 0.2) + abs(values.amount - 0.125);
            float r = values.dir.z * (values.third ? 1.0 : 0.0) + check;
            float g = values.flag ? (values.other ? 0.0 : 0.5) : 0.0;
            float b = float(values.count + 5) * 0.125;
            return float4(r, g, b, 1.0);
        }
        """

    private func channels(_ canvas: Canvas) throws -> [Float] {
        let pixels = try canvas.target.readPixels().components
        let base = (4 * 8 + 4) * 4
        return (0..<3).map { Float(pixels[base + $0]) }
    }

    private func expect(_ got: [Float], _ expected: [Float], _ note: String) {
        for channel in 0..<3 {
            #expect(abs(got[channel] - expected[channel]) < 0.01, "\(note): チャンネル \(channel) が \(got[channel]) (期待 \(expected[channel]))")
        }
    }

    @Test("塗り: 混ぜた組を断片が受けた値が、色に出る。Swift の値を包まずに set できる")
    func aMixedSetReachesAShader() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        let shader = try canvas.makeShader(Self.paintBody, values: Self.mixed)
        func paint() throws -> [Float] {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.shader(shader)
                canvas.rect(0, 0, 8, 8)
            }
            return try channels(canvas)
        }
        expect(try paint(), [0.75, 0.5, 0.25], "作ったときの値")

        // 包まずに書き換える: 真偽を落とし、整数を変え、3 つ組を変える
        shader.set("flag", false)
        shader.set("count", ShaderValue.int(-1))
        shader.set("dir", Vector3(0, 0, 0.5))
        expect(try paint(), [0.5, 0.0, 0.5], "書き換えた後")
    }

    @Test("効果: 混ぜた組を断片が受けた値が、色に出る")
    func aMixedSetReachesAnEffect() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        let body = Self.paintBody.replacingOccurrences(of: "paint(Fragment in", with: "effect(Pixel in")
        let effect = try canvas.makeEffect(body, values: Self.mixed)
        try canvas.draw {
            canvas.background(.linear(red: 0.2, green: 0.2, blue: 0.2))
            canvas.effects([.custom(effect)])
        }
        expect(try channels(canvas), [0.75, 0.5, 0.25], "作ったときの値")
    }

    @Test("Float・Int・Double の変数は float として届き、整数のリテラルも float のまま")
    func plainNumbersStayFloats() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        let out = try canvas.makeNumbers(count: 4)
        let probe = try canvas.makeComputation(
            Self.kernel("out[0] = values.time; out[1] = values.bands; out[2] = values.ratio; out[3] = values.speed;"),
            name: "probe", values: ["time": 0, "bands": 0, "ratio": 0, "speed": 6])
        let time: Float = 1.5
        let bands = 4
        let ratio = 0.25
        try canvas.draw {
            probe.set("time", time)
            probe.set("bands", bands)
            probe.set("ratio", ratio)
            probe.set("speed", 9)
            canvas.compute(probe, over: 1, writes: [out])
        }
        #expect(canvas.read(out) == [1.5, 4, 0.25, 9])
        #expect(!probe.values.values.contains { $0.metalType == "int" }, "整数が int の宣言に変わっている")
    }

    @Test("効果の上限は詰めた長さで数える: float4x4 を 3 つで区画がいっぱい、もう 1 つ足すと断る")
    func anEffectCountsATransformAsSixteen() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        let body = "float4 effect(Pixel in, Values values) { return float4(values.a[0][0]); }"
        var values: [String: ShaderValue] = [
            "a": .transform(.identity), "b": .transform(.identity), "c": .transform(.identity),
        ]
        // 48 個ちょうど (区画の大きさ) は通る
        _ = try canvas.makeEffect(body, values: values)
        // 値の数は 4 つで、数 × 4 なら収まるが、詰めた長さは区画を越える
        values["d"] = 1
        do {
            _ = try canvas.makeEffect(body, values: values)
            Issue.record("区画を越える値の組が断られなかった")
        } catch {
            #expect("\(error)".contains("Too many values"), "\(error)")
        }
    }
}
