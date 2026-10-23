// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 種と細かさを値として持つ揺らぎ ``NoiseField`` (#2418)。
///
/// **種の無い `init()` は置かない** — `NoiseField()` はコンパイルが通らない。型の宣言で守っていて、
/// 実行時の検査では書けない。
@Suite("値として持てる揺らぎ")
struct NoiseFieldTests {
    private let points: [(Float, Float, Float, Float)] = [
        (0.3, 0.7, 0, 0), (12.25, -3.5, 0, 0), (0.1, 0.2, 0.3, 0), (5.5, 1.5, 2.5, 0.75), (-40.2, 8.8, -1.1, 3.3),
    ]

    @Test("同じ設定なら、何度引いても同じ値。0…1 に収まる")
    func sameSettingsGiveTheSameValues() {
        let a = NoiseField(seed: 11)
        let b = NoiseField(seed: 11)
        for (x, y, z, w) in points {
            let value = a.value(x, y, z, w)
            #expect(value == b.value(x, y, z, w))
            #expect(value == a.value(x, y, z, w))
            #expect(value >= 0 && value <= 1)
        }
    }

    @Test("種が違えば、同じ座標でも別の模様になる (板ごとの種)")
    func differentSeedsGiveDifferentPatterns() {
        let planks = (0..<4).map { NoiseField(seed: 100 + $0) }
        var rows: [[Float]] = []
        for plank in planks {
            rows.append((0..<32).map { plank.value(Float($0) * 0.37, 1.5) })
        }
        for i in 0..<planks.count {
            for j in (i + 1)..<planks.count {
                #expect(rows[i] != rows[j], "板 \(i) と \(j) が同じ模様")
            }
        }
    }

    @Test("座標は 1〜4 つ。後ろを省くと 0 を渡したのと同じ値で、w が 0 なら 3 つのときと同じ")
    func missingCoordinatesAreZero() {
        let field = NoiseField(seed: 3)
        #expect(field.value(1.7) == field.value(1.7, 0, 0, 0))
        #expect(field.value(1.7, 2.2) == field.value(1.7, 2.2, 0, 0))
        #expect(field.value(1.7, 2.2, 0.9) == field.value(1.7, 2.2, 0.9, 0))
        #expect(field.value(1.7, 2.2, 0.9, 0.4) != field.value(1.7, 2.2, 0.9, 0))
        // 数でない座標・整数の座標も受け取る
        #expect(field.value(Float.nan, 1) == 0)
        #expect(field.value(2, 3) == field.value(Float(2), Float(3)))
    }

    @Test("重ねる枚数と弱まりは値で持ち、範囲の外は端に丸める")
    func detailIsClampedIntoItsRange() {
        let point: (Float, Float, Float) = (1.3, 2.7, 0.4)
        func value(_ field: NoiseField) -> Float { field.value(point.0, point.1, point.2) }
        #expect(value(NoiseField(seed: 1, octaves: 0)) == value(NoiseField(seed: 1, octaves: 1)))
        #expect(value(NoiseField(seed: 1, octaves: 99)) == value(NoiseField(seed: 1, octaves: 16)))
        #expect(value(NoiseField(seed: 1, falloff: -3)) == value(NoiseField(seed: 1, falloff: 0)))
        #expect(value(NoiseField(seed: 1, falloff: 7)) == value(NoiseField(seed: 1, falloff: 1)))
        #expect(value(NoiseField(seed: 1, falloff: Float.nan)) == value(NoiseField(seed: 1, falloff: 0.5)))
        // 枚数が違えば値も違う (細かさが効いている)
        #expect(value(NoiseField(seed: 1, octaves: 1)) != value(NoiseField(seed: 1, octaves: 8)))
        #expect(value(NoiseField(seed: 1, falloff: 0.2)) != value(NoiseField(seed: 1, falloff: 0.8)))
    }
}

/// スケッチの `noise()` との一致と、スケッチの種に触れないこと。走っているランタイムが要るので、GPU を使う。
@Suite(
    "値として持てる揺らぎとスケッチの noise()",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct NoiseFieldSketchTests {
    final class Probe: Sketch {
        var settings = SketchSettings(width: 16, height: 16)
        var script: ((Probe) -> Void)?
        init() {}
        func draw() { script?(self) }
    }

    private func run(_ script: @escaping (Probe) -> Void) throws {
        let probe = Probe()
        probe.script = script
        let runtime = try SketchRuntime(sketch: probe, gpu: try RenderDevice())
        runtime.start()
        try runtime.advance()
    }

    private let points: [(Float, Float, Float, Float)] = [
        (0.3, 0.7, 0, 0), (12.25, -3.5, 0, 0), (0.1, 0.2, 0.3, 0), (5.5, 1.5, 2.5, 0.75), (-40.2, 8.8, -1.1, 3.3),
    ]

    @Test("NoiseField(seed: 11) は noiseSeed(11) の後の noise() と同じ値を返し、スケッチの種を書き換えない")
    func matchesTheSketchNoise() throws {
        var sketchValues: [Float] = []
        var fieldValues: [Float] = []
        var sketchAfter: [Float] = []
        try run { probe in
            probe.noiseSeed(11)
            sketchValues = self.points.map { probe.noise($0.0, $0.1, $0.2, $0.3) }
            // 別の種の値を引いても、スケッチの種は 11 のまま
            let other = NoiseField(seed: 99)
            _ = self.points.map { other.value($0.0, $0.1, $0.2, $0.3) }
            fieldValues = self.points.map { NoiseField(seed: 11).value($0.0, $0.1, $0.2, $0.3) }
            sketchAfter = self.points.map { probe.noise($0.0, $0.1, $0.2, $0.3) }
        }
        #expect(sketchValues == fieldValues)
        #expect(sketchAfter == sketchValues, "別の種の NoiseField を引いたらスケッチの揺らぎが変わった")
    }

    @Test("細かさ (枚数・弱まり) も noiseDetail と同じ値になる")
    func matchesTheSketchDetail() throws {
        var sketchValues: [Float] = []
        try run { probe in
            probe.noiseSeed(5)
            probe.noiseDetail(7, 0.35)
            sketchValues = self.points.map { probe.noise($0.0, $0.1, $0.2, $0.3) }
        }
        let field = NoiseField(seed: 5, octaves: 7, falloff: 0.35)
        #expect(sketchValues == points.map { field.value($0.0, $0.1, $0.2, $0.3) })
    }
}
