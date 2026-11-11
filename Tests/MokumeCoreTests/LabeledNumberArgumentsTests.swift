// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 数の計算のラベル付きの形 ([#3785])。自由関数は GPU 無しで回る。
///
/// 約束は、**ラベル付きの形に位置の形と同じ値を渡すと、返る値が 1 ビットも違わない**こと。値は
/// ビット列 (`bitPattern`) で比べるので、`0` と `-0`・`∞` の符号の違いも見分ける。
///
/// **値は引数ごとに違うもの**にして、引数の取り違えが結果に出るようにした (`map(5, 0, 10, 0, 100)` は
/// 先の端を入れ替えても 50 のままなので、それだけでは取り違えを見逃す)。端の値・逆向きの範囲・幅 0・
/// 数でない値と無限の値・途中の差や積が溢れる組 ([#3952]) も混ぜ、位置の形の扱いをそのまま受けることを見る。
///
/// [#3785]: https://github.com/mokume-metal/mokume/issues/3785
/// [#3952]: https://github.com/mokume-metal/mokume/issues/3952
@Suite("数の計算のラベル付きの形")
struct LabeledNumberArgumentsTests {
    nonisolated static let m = Float.greatestFiniteMagnitude
    nonisolated static let tiny = Float.leastNonzeroMagnitude

    /// 2 つの値がビット列で一致すること。
    private func same(
        _ actual: Float, _ expected: Float, _ name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            actual.bitPattern == expected.bitPattern,
            "\(name): ラベル付きの形は \(actual)、位置の形は \(expected)", sourceLocation: sourceLocation)
    }

    // MARK: - map(_:fromLow:fromHigh:toLow:toHigh:)

    nonisolated static var mapCases: [(Float, Float, Float, Float, Float)] {
        [
            (5, 0, 10, 0, 100), (5, 10, 0, 0, 100),  // Issue の例
            (2, 1, 9, -30, 70), (2, 9, 1, -30, 70), (2, 1, 9, 70, -30),  // 引数ごとに違う値・逆向き
            (12, 1, 9, -30, 70), (-4, 1, 9, -30, 70),  // 範囲の外 (締めない)
            (1, 1, 9, -30, 70), (9, 1, 9, -30, 70),  // 端ちょうど
            (5, 3, 3, 100, 200),  // 幅 0
            (.nan, 0, 1, 100, 200), (0.5, 0, .infinity, 100, 200), (0.5, 0, 1, .nan, 200),  // 数でない値・無限
            (0.5, 0, 1, -3e38, 3e38), (m, -m, 0, 0, 1), (m, -m, 0, 10, 0),  // 幅・差が溢れる組
            (m, -m, 0, 0, m), (2, 0, 1, m, 0), (1e30, 0, 1e-30, 0, tiny),  // 外挿が溢れる組
        ]
    }

    @Test("map(_:fromLow:fromHigh:toLow:toHigh:) は map(_:_:_:_:_:) と同じ値を返す", arguments: mapCases)
    func mapMatchesThePositionalForm(_ c: (Float, Float, Float, Float, Float)) {
        same(
            map(c.0, fromLow: c.1, fromHigh: c.2, toLow: c.3, toHigh: c.4), map(c.0, c.1, c.2, c.3, c.4),
            "map\(c)")
    }

    @Test("Issue の例: 逆向きの元の範囲でも、位置の形と同じ 50 を返す")
    func mapIssueExamples() {
        #expect(map(5, fromLow: 0, fromHigh: 10, toLow: 0, toHigh: 100) == 50)
        #expect(map(5, fromLow: 10, fromHigh: 0, toLow: 0, toHigh: 100) == 50)
        // 整数のまま渡しても同じ (引数の型は位置の形と同じ `some ScalarConvertible`)
        #expect(map(2, fromLow: 1, fromHigh: 9, toLow: -30, toHigh: 70) == map(2, 1, 9, -30, 70))
    }

    // MARK: - lerp(_:_:amount:)・lerpAngle(_:_:amount:)

    nonisolated static var lerpCases: [(Float, Float, Float)] {
        [
            (20, 380, 0.25), (380, 20, 0.25), (20, 380, 0), (20, 380, 1),  // 中ほど・逆向き・端
            (20, 380, 2), (20, 380, -1),  // 0…1 の外 (締めない)
            (9.357954e11, 9.357954e11, 0.86),  // 幅 0
            (.nan, 1, 0.5), (0, .infinity, 0.5), (0, 1, .nan),  // 数でない値・無限
            (-3e38, 3e38, 0.5), (m, 0, 2), (1e38, 2e38, 10),  // 幅・積が溢れる組
            (3, -3, 0.5), (3, -3, 1),  // lerpAngle が ±π をまたぐ組
        ]
    }

    @Test("lerp(_:_:amount:) は lerp(_:_:_:) と同じ値を返す", arguments: lerpCases)
    func lerpMatchesThePositionalForm(_ c: (Float, Float, Float)) {
        same(lerp(c.0, c.1, amount: c.2), lerp(c.0, c.1, c.2), "lerp\(c)")
    }

    @Test("lerpAngle(_:_:amount:) は lerpAngle(_:_:_:) と同じ値を返す", arguments: lerpCases)
    func lerpAngleMatchesThePositionalForm(_ c: (Float, Float, Float)) {
        same(lerpAngle(c.0, c.1, amount: c.2), lerpAngle(c.0, c.1, c.2), "lerpAngle\(c)")
    }

    // MARK: - lerpColor(_:_:amount:)

    nonisolated static var lerpColorAmounts: [Float] { [0, 0.3, 1, 2, -1, .nan, .infinity] }

    @Test("lerpColor(_:_:amount:) は lerpColor(_:_:_:) と同じ色を返す", arguments: lerpColorAmounts)
    func lerpColorMatchesThePositionalForm(_ amount: Float) {
        let start = color(255, 170, 60, 200)
        let stop = color(40, 50, 120)
        let labeled = lerpColor(start, stop, amount: amount)
        let positional = lerpColor(start, stop, amount)
        for (name, a, b) in [
            ("red", labeled.red, positional.red), ("green", labeled.green, positional.green),
            ("blue", labeled.blue, positional.blue), ("alpha", labeled.alpha, positional.alpha),
        ] {
            same(a, b, "lerpColor(amount: \(amount)).\(name)")
        }
    }

    // MARK: - smoothstep(_:_:x:)

    nonisolated static var smoothstepCases: [(Float, Float, Float)] {
        [
            (2.4, 5.4, 3), (5.4, 2.4, 3),  // 上り坂・下り坂
            (2, 6, 1), (2, 6, 9), (2, 6, 2), (2, 6, 6),  // 外と縁
            (4, 4, 3), (4, 4, 4),  // 幅 0 は段
            (.nan, 6, 3), (2, .infinity, 3), (2, 6, .nan),  // 数でない値・無限
            (-3e38, 3e38, 0), (-m, 0, m),  // 幅・差が溢れる組
        ]
    }

    @Test("smoothstep(_:_:x:) は smoothstep(_:_:_:) と同じ値を返す", arguments: smoothstepCases)
    func smoothstepMatchesThePositionalForm(_ c: (Float, Float, Float)) {
        same(smoothstep(c.0, c.1, x: c.2), smoothstep(c.0, c.1, c.2), "smoothstep\(c)")
    }

    // MARK: - damp(_:toward:lambda:deltaTime:)

    nonisolated static var dampCases: [(Float, Float, Float, Float)] {
        [
            (200, 340, 6, 1.0 / 60), (340, 200, 6, 1.0 / 60), (0, 10, 4, 1),  // 寄る・逆向き
            (200, 340, 6, 0), (200, 340, 0, 0.5),  // 動かない
            (200, 340, -6, 0.5), (200, 340, 6, -0.5),  // 負の lambda・dt
            (.nan, 340, 6, 0.5), (200, .infinity, 6, 0.5), (200, 340, .nan, 0.5), (200, 340, 6, .infinity),
            (m, -m, 1e30, 1e30), (-3e38, 3e38, 0.7, 0.3),  // 積・幅が溢れる組
        ]
    }

    @Test("damp(_:toward:lambda:deltaTime:) は damp(_:_:_:_:) と同じ値を返す", arguments: dampCases)
    func dampMatchesThePositionalForm(_ c: (Float, Float, Float, Float)) {
        same(damp(c.0, toward: c.1, lambda: c.2, deltaTime: c.3), damp(c.0, c.1, c.2, c.3), "damp\(c)")
    }
}

/// 乱数と揺らぎのラベル付きの形 ([#3785])。作者の口はランタイムを通るので GPU を要する。
///
/// `randomGaussian(mean:standardDeviation:)` は、同じ種から同じ回数引いた値の列と、引いた後の列 (続けて
/// 引く ``SketchPart/random()``) が位置の形と 1 ビットも違わないこと。`noiseDetail(octaves:falloff:)` は、
/// 決まった細かさ (``Canvas/noiseSettings``) と注意が位置の形と同じであることを、`Sketch` の中継と
/// `Canvas` の直の呼び出しの両方で見る。
///
/// [#3785]: https://github.com/mokume-metal/mokume/issues/3785
@Suite(
    "乱数と揺らぎのラベル付きの形",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LabeledRandomArgumentsTests {
    final class Blank: Sketch {
        var settings = SketchSettings(width: 8, height: 8)
        init() {}
        func draw() {}
    }

    /// 製品と同じ口 (`withActiveRuntime`) で差してから呼ぶ (``RandomPickSketchTests`` と同じ作法)。
    private func run<T>(_ body: (Blank) -> T) throws -> T {
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        var result: T?
        runtime.withActiveRuntime { result = body(sketch) }
        return try #require(result)
    }

    // MARK: - randomGaussian(mean:standardDeviation:)

    /// 種 3 から、平均と標準偏差を 1 組ずつ変えて引いた列と、引いた後の `random()`。
    private func drawn(_ gaussian: @escaping (Blank, Float, Float) -> Float) throws -> [UInt32] {
        try run { sketch in
            sketch.randomSeed(3)
            let pairs: [(Float, Float)] = [(200, 30), (-7, 0.5), (0, 0), (5, -2), (.nan, 1), (1, .infinity), (3e38, 3e38)]
            let values = pairs.map { gaussian(sketch, $0.0, $0.1) } + [sketch.random()]
            return values.map(\.bitPattern)
        }
    }

    @Test("randomGaussian(mean:standardDeviation:) は randomGaussian(_:_:) と同じ値を引き、列を同じだけ進める")
    func gaussianMatchesThePositionalForm() throws {
        let labeled = try drawn { $0.randomGaussian(mean: $1, standardDeviation: $2) }
        let positional = try drawn { $0.randomGaussian($1, $2) }
        #expect(labeled == positional)
    }

    // MARK: - noiseDetail(octaves:falloff:)

    /// 受け取る組と受け取れない組。受け取れない組は、細かさが変わらず注意が出る (位置の形と同じ)。
    nonisolated static var details: [(octaves: Int, falloff: Float)] {
        [(6, 0.25), (1, 0), (16, 1), (0, 0.5), (17, 0.5), (4, 1.5), (4, .nan), (4, .infinity)]
    }

    private func settings(_ canvas: Canvas) -> (ValueNoise, Bool) {
        (canvas.noiseSettings, canvas.warnings.hasWarned(.badNoise))
    }

    @Test("noiseDetail(octaves:falloff:) は noiseDetail(_:_:) と同じ細かさを決める", arguments: details)
    func noiseDetailMatchesThePositionalForm(_ detail: (octaves: Int, falloff: Float)) throws {
        // Sketch の中継。既定と違う細かさにしておき、「変わらなかった」と「既定へ戻った」を見分ける
        let throughSketch: ((Blank) -> Void) throws -> (ValueNoise, Bool) = { body in
            try self.run { sketch in
                sketch.noiseDetail(3, 0.75)
                body(sketch)
                return self.settings(sketch.canvas)
            }
        }
        let labeled = try throughSketch { $0.noiseDetail(octaves: detail.octaves, falloff: detail.falloff) }
        let positional = try throughSketch { $0.noiseDetail(detail.octaves, detail.falloff) }
        #expect(labeled.0 == positional.0, "Sketch: \(detail)")
        #expect(labeled.1 == positional.1, "Sketch の注意: \(detail)")

        // Canvas の直の呼び出し
        let onCanvas: ((Canvas) -> Void) throws -> (ValueNoise, Bool) = { body in
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
            canvas.noiseDetail(3, 0.75)
            body(canvas)
            return self.settings(canvas)
        }
        let labeledCanvas = try onCanvas { $0.noiseDetail(octaves: detail.octaves, falloff: detail.falloff) }
        let positionalCanvas = try onCanvas { $0.noiseDetail(detail.octaves, detail.falloff) }
        #expect(labeledCanvas.0 == positionalCanvas.0, "Canvas: \(detail)")
        #expect(labeledCanvas.1 == positionalCanvas.1, "Canvas の注意: \(detail)")

        // 両方とも何もしない口でも上は緑になるので、位置の形が実際に決めた (または断った) ことを先に見る
        let accepted = ValueNoise.octaveRange.contains(detail.octaves) && (0...1).contains(detail.falloff)
        for (layer, seen) in [("Sketch", positional), ("Canvas", positionalCanvas)] {
            if accepted {
                #expect(seen.0.octaves == detail.octaves && seen.0.falloff == detail.falloff, "\(layer): \(detail)")
                #expect(!seen.1, "\(layer): 受け取れる値で注意が出た \(detail)")
            } else {
                #expect(seen.0.octaves == 3 && seen.0.falloff == 0.75, "\(layer): \(detail)")
                #expect(seen.1, "\(layer): 受け取れない値で注意が出ない \(detail)")
            }
        }
    }

    @Test("falloff: を省いた noiseDetail(octaves:) は、falloff 0.5 を渡したときと同じ細かさを決める")
    func noiseDetailDefaultFalloffIsOneHalf() throws {
        let (labeled, positional) = try run { sketch in
            sketch.noiseDetail(3, 0.75)
            sketch.noiseDetail(octaves: 5)
            let labeled = sketch.canvas.noiseSettings
            sketch.noiseDetail(3, 0.75)
            sketch.noiseDetail(5, 0.5)
            return (labeled, sketch.canvas.noiseSettings)
        }
        #expect(labeled == positional)
        #expect(labeled.falloff == 0.5)

        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        canvas.noiseDetail(3, 0.75)
        canvas.noiseDetail(octaves: 5)
        #expect(canvas.noiseSettings.octaves == 5)
        #expect(canvas.noiseSettings.falloff == 0.5)
    }
}
