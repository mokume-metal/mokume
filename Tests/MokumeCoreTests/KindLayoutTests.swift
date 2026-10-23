// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 断片が種別として読む番号が、Swift と Metal で一致しているか。
///
/// 番号がずれても例外は出ない。**別の種別として効くだけ**なので、ずれは絵にしか
/// 現れず、しかも絵に出ない番号がある — 力の attract / wander / swirl、効果の
/// invert / monochrome / adjust / 縮め段、光の spot、折れ目の bevel / round は
/// 台帳のどのシーンも通らない ([#802])。
///
/// 両側に手で書いた表を突き合わせる形では、両方が同時にずれたときに黙って通る。
/// ここは GPU 自身に自分の見ている表を書かせ、CPU が並びとして読み比べる。
///
/// [#802]: https://github.com/mokume-metal/mokume/issues/802
@Suite(
    "種別の番号",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct KindLayoutTests {
    /// 区画の境に置く印。`Shaders/Kinds.metal` の `kKindSection` と同じ数。
    ///
    /// **ここが割れても黙って通らない** — 印が合わなければ並び全体が食い違う。
    static let section: UInt32 = 9000

    /// Swift 側が持っている番号を、`mokume_kindLayout` が書く順に並べたもの。
    static var expected: [UInt32] {
        var numbers: [UInt32] = []

        numbers.append(section + 0)
        numbers += [Light.Kind.ambient, .directional, .point, .spot].map(\.rawValue)

        numbers.append(section + 1)
        numbers += BlendMode.allCases.map(\.rawIndex)

        numbers.append(section + 2)
        numbers += [FormInstance.Kind.rect, .ellipse, .arc, .line].map(\.rawValue)

        numbers.append(section + 3)
        numbers += [StrokeCap.round, .square, .project].map(FormInstance.code(of:))

        numbers.append(section + 4)
        numbers += [StrokeJoin.miter, .bevel, .round].map(FormInstance.code(of:))

        numbers.append(section + 5)
        numbers += [FormInstance.fillsFlag, FormInstance.strokesFlag]

        numbers.append(section + 6)
        numbers += BuiltinEffectKind.allCases.map(\.rawValue)

        numbers.append(section + 7)
        numbers += ForceKind.allCases.map(\.rawValue)

        numbers.append(section + 8)
        numbers += [
            FormInstance.EdgeClass.straight, .curved, .rounded, .joined, .roundLine, .point,
        ].map(\.rawValue)
        numbers += [
            FormInstance.CoverageMode.area, .linear, .linearExceptCorners, .linearExceptCaps,
        ].map(\.rawValue)

        numbers.append(section + 99)
        return numbers
    }

    @Test("種別の番号が、CPU と GPU で一致する")
    func agreesOnTheKindsWithTheGPU() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        let canvas = try Canvas(target: target, gpu: gpu)
        // 断片の中身は要らない — `mokume_kindLayout` は前置き (`Kinds.metal`) にあり、
        // どの計算のライブラリにも入っている
        let probe = try canvas.makeComputation("", name: "mokume_kindLayout")
        let slots = try canvas.makeNumbers(count: Self.expected.count)

        var written: [Float] = []
        try canvas.draw {
            canvas.compute(probe, over: 1, writes: [slots])
            written = canvas.read(slots)
        }

        // 書き出しは `uint` なので、置き場から読んだ数はそのビットで読み直す
        #expect(written.map(\.bitPattern) == Self.expected)
    }

    /// 番号を足したら両側へ足す、が守られているか。
    ///
    /// 上の検査は**並びが同じ長さである限り**値を見るが、片方だけに 1 つ足すと
    /// 末尾の印の位置がずれるので、そこでも落ちる。この検査は「いくつあるか」を
    /// 人が読める形で残しておくためのもの。
    @Test("種別の総数が、区画の印を含めて 64 のまま")
    func keepsTheNumberOfKinds() {
        #expect(Self.expected.count == 64)
    }

    /// **基本図形の縁の分類 (境目の幅・被覆の数え方) が、CPU と GPU で一致する** ([#2991])。
    ///
    /// 境目 (細い枝との境の測り方) と被覆 (縁を線形の渡しか面積で数えるか) は、`Kinds.metal` の
    /// `mokume_formEdgeClass` ほかの 1 つの表を読む。CPU の `FormInstance.EdgeClass` も同じ表で、割れると
    /// 「境目では直線・被覆では曲線」のように、同じ形の扱いが食い違う。ここは GPU 自身にその関数を
    /// 標本ごとに評価させ、CPU が読み比べる (標本は種別・長さ・角の半径・輪郭・端・折れ目・太さの組み合わせ)。
    ///
    /// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
    @Test("基本図形の縁の分類が、CPU と GPU で一致する")
    func agreesOnTheEdgeClassesWithTheGPU() throws {
        struct Sample {
            var kind: FormInstance.Kind
            var halfLength: Float
            var cornerRadius: Float
            var halfWeight: Float
            var strokes: Bool
            var cap: StrokeCap
            var join: StrokeJoin
        }
        var samples: [Sample] = []
        for kind in [FormInstance.Kind.rect, .ellipse, .arc, .line] {
            for halfLength in [Float(0), 0.3, 5] {
                for cornerRadius in [Float(0), 0.5, 3] {
                    for halfWeight in [Float(0.5), 2] {
                        for strokes in [true, false] {
                            for cap in [StrokeCap.round, .square, .project] {
                                for join in [StrokeJoin.miter, .bevel, .round] {
                                    samples.append(
                                        Sample(
                                            kind: kind, halfLength: halfLength, cornerRadius: cornerRadius,
                                            halfWeight: strokes ? halfWeight : 0, strokes: strokes, cap: cap, join: join))
                                }
                            }
                        }
                    }
                }
            }
        }
        func literal(_ value: Float) -> String { String(format: "%.6f", value) }
        let rows = samples.map { sample in
            "float4(\(literal(sample.halfLength)), \(literal(sample.cornerRadius)), \(literal(sample.halfWeight)), \(sample.kind.rawValue))"
        }
        let flags = samples.map { sample in
            "uint4(\(sample.strokes ? 1 : 0), \(FormInstance.code(of: sample.cap)), \(FormInstance.code(of: sample.join)), 0)"
        }
        // 1 標本につき 5 つ書く: 分類・塗りと線の境目の行ノルムの割合 (65536 倍)・穴の境目が曲線か・
        // 軸に沿うときの被覆の数え方・回したときの被覆の数え方
        let source = """
            constant float4 samples[\(samples.count)] = { \(rows.joined(separator: ", ")) };
            constant uint4 flags[\(samples.count)] = { \(flags.joined(separator: ", ")) };
            kernel void probeEdgeClasses(device uint *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
                float4 s = samples[id];
                uint4 f = flags[id];
                uint kind = uint(s.w);
                uint edge = mokume_formEdgeClass(kind, s.x, s.y, f.x != 0, f.y, f.z);
                out[id * 5 + 0] = edge;
                out[id * 5 + 1] = uint(round(mokume_formReachCurved(edge, s.x, s.z) * 65536.0));
                out[id * 5 + 2] = mokume_formHoleCurved(edge, s.y, s.z) ? 1u : 0u;
                out[id * 5 + 3] = mokume_formCoverageMode(edge, true);
                out[id * 5 + 4] = mokume_formCoverageMode(edge, false);
            }
            """
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        let canvas = try Canvas(target: target, gpu: gpu)
        let probe = try canvas.makeComputation(source, name: "probeEdgeClasses")
        let slots = try canvas.makeNumbers(count: samples.count * 5)
        var written: [Float] = []
        try canvas.draw {
            canvas.compute(probe, over: samples.count, writes: [slots])
            written = canvas.read(slots)
        }
        let words = written.map(\.bitPattern)
        var mismatches: [String] = []
        for (index, sample) in samples.enumerated() {
            // 輪郭を持たない形は、半分の太さが 0 になる (`FormInstance.init`・標本もそう作ってある)
            let instance = FormInstance(
                kind: sample.kind, linear: SIMD4(1, 0, 0, 1), offset: .zero,
                half: SIMD2(sample.halfLength, 1), halfWeight: sample.halfWeight,
                cornerRadius: sample.cornerRadius, fill: .zero, stroke: .zero, fills: !sample.strokes,
                strokes: sample.strokes, cap: sample.cap, join: sample.join)
            let expectedReach = UInt32((instance.reachCurved * 65536).rounded())
            let expected: [UInt32] = [
                instance.edgeClass.rawValue, expectedReach, instance.holeReachIsCurved ? 1 : 0,
                instance.coverageMode(aligned: true).rawValue, instance.coverageMode(aligned: false).rawValue,
            ]
            let actual = Array(words[(index * 5)..<(index * 5 + 5)])
            if actual != expected { mismatches.append("\(sample): GPU \(actual) ・CPU \(expected)") }
        }
        #expect(mismatches.isEmpty, "分類が食い違った標本 \(mismatches.count) 件: \(mismatches.prefix(5))")
    }
}
