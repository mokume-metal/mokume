// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 同じフレームの出口どうしが、**どんな入力でも** 同じバイトを出す (#1762)。
///
/// 出口は 2 本に集まっている — CPU で変換する ``RenderTarget/encodeForDisplay(scale:)``
/// (PNG・同期の読み出し) と、GPU で変換する ``RenderTarget/encodeToImage()`` (録画・観測・
/// 出力の口)。描いた絵だけで比べると、量子化の境目のほぼ真上に落ちる値を踏まず、1 段の
/// ずれが隠れる。ここでは half の全ビット列と乱数を画素へ直に置いて比べる。
///
/// 比べる前に、置いた値が面に載ったことを読み戻して確かめる (#1761 — 載らなかった入力で
/// 比較が通らないため)。
@Suite(
    "出力段: 出口どうしが全入力で一致する",
    .serialized,
    .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct OutputAgreementTests {
    /// 明るさを写す設定。露出の 3 通り × 丸め方 2 通り。
    static let settings: [(exposure: Float, toneMapping: ToneMapping)] = [
        (1, .clip), (2, .clip), (0.5, .clip), (1, .roll), (2, .roll), (0.5, .roll),
    ]

    /// 総当たりで振る不透明度。0・最小の正規数・1 段・半透明・1・範囲の外・値でないもの。
    static let alphas: [Float16] = [
        0, .leastNormalMagnitude, Float16(1.0 / 255), 0.1, 0.5, 0.75, 0.9, 1, -1, .nan, .infinity,
    ]

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 256, height: 256)
    }

    /// 置いた値が面に載ったことを確かめる。有限の値は半精度に丸めた値と、値でないものは
    /// 値でないことで見る。
    private func expectStored(_ canvas: Canvas, _ expected: [SIMD4<Float>]) throws {
        let stored = try canvas.output.readPixels()
        var wrong = 0
        for index in expected.indices {
            let actual = stored[index % 256, index / 256]
            let got = SIMD4(actual.red, actual.green, actual.blue, actual.alpha)
            for lane in 0..<4 {
                let want = Float(Float16(expected[index][lane]))
                if want.isNaN ? !got[lane].isNaN : got[lane] != want { wrong += 1 }
            }
        }
        #expect(wrong == 0, "\(wrong) 成分が置いた値と違う — 比べる前提が崩れている")
    }

    /// 全設定で 2 本の出口を比べ、食い違った設定ごとの報告を返す。
    private func mismatches(_ canvas: Canvas, label: String) throws -> [String] {
        var reports: [String] = []
        for setting in Self.settings {
            canvas.exposure(setting.exposure)
            canvas.toneMapping(setting.toneMapping)
            let cpu = try canvas.output.encodeForDisplay().bytes
            let gpu = try canvas.output.encodeToImage().read().bytes
            var differing = 0
            var first: String?
            for index in stride(from: 0, to: cpu.count, by: 4)
            where cpu[index..<(index + 4)] != gpu[index..<(index + 4)] {
                differing += 1
                if first == nil {
                    first = "画素 \(index / 4): CPU \(Array(cpu[index..<(index + 4)])) / GPU \(Array(gpu[index..<(index + 4)]))"
                }
            }
            if differing > 0 {
                reports.append(
                    "\(label) 露出 \(setting.exposure) \(setting.toneMapping): \(differing) 画素 (\(first ?? "-"))")
            }
        }
        return reports
    }

    @Test("half の全ビット列を 1 成分に置いても、2 本の出口が同じバイトを出す", arguments: [0, 1, 2])
    func everyHalfAgrees(channel: Int) throws {
        let canvas = try makeCanvas()
        var reports: [String] = []
        for alpha in Self.alphas {
            var placed: [SIMD4<Float>] = []
            placed.reserveCapacity(65_536)
            for bits in 0..<65_536 {
                // 残りの 2 成分には、起票時の 0.25 / 0.75 を前から順に置く
                var color = SIMD4<Float>(0, 0, 0, Float(alpha))
                var others: [Float] = [0.25, 0.75]
                for lane in 0..<3 {
                    color[lane] =
                        lane == channel
                        ? Float(Float16(bitPattern: UInt16(bits))) : others.removeFirst()
                }
                placed.append(color)
            }
            try canvas.draw {
                for (index, color) in placed.enumerated() {
                    canvas.set(
                        index % 256, index / 256,
                        LinearRGBA(
                            premultipliedRed: color.x, green: color.y, blue: color.z, alpha: color.w))
                }
            }
            try expectStored(canvas, placed)
            reports += try mismatches(canvas, label: "α \(alpha)")
        }
        #expect(reports.isEmpty, "\(reports.joined(separator: "\n"))")
    }

    @Test("4 成分とも乱数の画素でも、2 本の出口が同じバイトを出す")
    func randomPixelsAgree() throws {
        let canvas = try makeCanvas()
        var random = SplitMix(seed: 1762)
        var reports: [String] = []
        for round in 0..<6 {
            var placed: [SIMD4<Float>] = []
            placed.reserveCapacity(65_536)
            for _ in 0..<65_536 {
                placed.append(
                    SIMD4(
                        random.component(), random.component(), random.component(), random.alpha()))
            }
            try canvas.draw {
                for (index, color) in placed.enumerated() {
                    canvas.set(
                        index % 256, index / 256,
                        LinearRGBA(
                            premultipliedRed: color.x, green: color.y, blue: color.z, alpha: color.w))
                }
            }
            try expectStored(canvas, placed)
            reports += try mismatches(canvas, label: "乱数 \(round)")
        }
        #expect(reports.isEmpty, "\(reports.joined(separator: "\n"))")
    }

    @Test("起票の 3 例が、2 本の出口で同じバイトになる")
    func reportedExamplesAgree() throws {
        let red = Float(Float16(bitPattern: 0x377e))
        let cases: [(alpha: Float, exposure: Float)] = [(0.5, 1), (1, 2), (.infinity, 2)]
        for example in cases {
            let canvas = try makeCanvas()
            canvas.exposure(example.exposure)
            canvas.toneMapping(.roll)
            try canvas.draw {
                canvas.set(
                    0, 0, LinearRGBA(premultipliedRed: red, green: 0.25, blue: 0.75, alpha: example.alpha))
            }
            let cpu = try canvas.output.encodeForDisplay()[0, 0]
            let gpu = try canvas.output.encodeToImage().read()[0, 0]
            #expect(cpu == gpu, "α \(example.alpha) 露出 \(example.exposure): CPU \(cpu) / GPU \(gpu)")
        }
    }
}

/// 決まった列を返す乱数。検査が落ちたときに同じ入力で調べ直せるように、種から決める。
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0…1 の外まで広げた一様な値。たまに負・範囲の外・値でないもの・無限を混ぜる。
    mutating func component() -> Float {
        let roll = next() % 64
        switch roll {
        case 0: return .nan
        case 1: return .infinity
        case 2: return -Float(next() % 1000) / 500
        default: return Float(next() % 1_000_000) / 1_000_000 * 3
        }
    }

    /// 不透明度。0 と 1 を多めに、残りは 0…1 の一様な値。
    mutating func alpha() -> Float {
        switch next() % 16 {
        case 0: return 0
        case 1, 2, 3: return 1
        default: return Float(next() % 1_000_000) / 1_000_000
        }
    }
}

/// 断片の関数を、**本番と同じ原文と組み方で** GPU 上で評価し、CPU の正本とビット単位で比べる (#1762)。
///
/// 絵を通した比較 (``OutputAgreementTests``) は、1 ulp の違いが量子化の境目の真上に重なった
/// 画素でしか赤にならない。`exp` の 1 ulp の違いは 1,000 万バイトに数個しか表に出ず、数十万
/// 画素では踏めない。ここでは関数の答えそのものを 100 万点で比べる。
@Suite(
    "出力段: 断片の関数が CPU とビットで一致する",
    .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct OutputFunctionAgreementTests {
    /// 断片の関数を呼ぶだけの入口。`Present.metal` の原文の後ろに足して組む。
    private static let probes = """
        kernel void rollProbe(device const float *peaks [[buffer(0)]],
                              device float *out [[buffer(1)]],
                              uint id [[thread_position_in_grid]])
        {
            out[id] = mokumeRolled(peaks[id], 0.8f);
        }

        kernel void quantizeProbe(device const float *linear [[buffer(0)]],
                                  constant float *thresholds [[buffer(1)]],
                                  device float *out [[buffer(2)]],
                                  uint id [[thread_position_in_grid]])
        {
            out[id] = mokumeQuantizeLinear(linear[id], thresholds) * 255.0f;
        }
        """

    /// `Present` の原文と入口を、本番と同じ組み方で組んだ計算。入口は原文の末尾 (safe math の範囲) に入る。
    private func probe(_ name: String, on canvas: Canvas) throws -> Computation {
        let gpu = canvas.gpu
        let body = try gpu.shaders.bundledShaderSource(named: "Present") + "\n" + Self.probes
        let source = ShaderSource.assemble(
            common: try gpu.shaders.preludedShaderSource(named: "Compute"), values: [:], body: body)
        // 組み方は本番と同じ既定のまま。safe math は原文の中の指定 (`#pragma`) が効かせる
        let library = try gpu.device.makeLibrary(source: source, options: nil)
        return try Computation(
            name: name, url: nil, body: body, values: [:], library: library, gpu: gpu,
            pipeline: canvas.computePipeline())
    }

    /// `inputs` を渡して入口を走らせ、書かれた値を返す。
    private func run(
        _ name: String, _ inputs: [Float], extra: [Float]? = nil
    ) throws -> [Float] {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        let computation = try probe(name, on: canvas)
        let input = try canvas.makeNumbers(count: inputs.count)
        input.set(inputs)
        var reads = [input]
        if let extra {
            let table = try canvas.makeNumbers(count: extra.count)
            table.set(extra)
            reads.append(table)
        }
        let output = try canvas.makeNumbers(count: inputs.count)
        try canvas.draw {
            canvas.compute(computation, over: inputs.count, reads: reads, writes: [output])
        }
        return canvas.read(output)
    }

    @Test("寄せた明るさが、100 万点で CPU とビットまで一致する")
    func rolledMatchesBitForBit() throws {
        #expect(Brightness.knee == 0.8, "入口が knee を 0.8 と書いている")
        // 寄せ幅 0…20 (明るさ 0.8…4.8) を、明るい側ほど粗く舐める
        var peaks: [Float] = []
        var peak = Brightness.knee.nextUp
        while peaks.count < 1 << 20, peak < 4.8 {
            peaks.append(peak)
            peak = Float(bitPattern: peak.bitPattern + (peak < 1 ? 3 : 29))
        }
        let gpu = try run("rollProbe", peaks)
        var differing: [(Float, Float, Float)] = []
        for (index, peak) in peaks.enumerated() {
            let cpu = Brightness.rolled(peak)
            if cpu.bitPattern != gpu[index].bitPattern { differing.append((peak, cpu, gpu[index])) }
        }
        #expect(peaks.count > 500_000)
        #expect(
            differing.isEmpty,
            "\(differing.count) 点で違う。最初は \(differing.prefix(4).map { "明るさ \($0.0): CPU \($0.1) / GPU \($0.2)" })")
    }

    @Test("しきい値の表で決めた段が、100 万点で CPU の式と一致する")
    func quantizedStepsMatch() throws {
        var linear: [Float] = [.nan, .infinity, -.infinity, -1, -0.0, 0, 1, 1.5]
        for threshold in OutputStage.quantizeThresholds {
            for offset in -2...2 {
                linear.append(Float(bitPattern: UInt32(Int64(threshold.bitPattern) + Int64(offset))))
            }
        }
        var state: UInt64 = 1762
        while linear.count < 1 << 20 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            linear.append(Float(bitPattern: UInt32(state >> 33) % (Float(1).bitPattern + 1)))
        }
        let gpu = try run("quantizeProbe", linear, extra: OutputStage.quantizeThresholds)
        var differing: [Float] = []
        for (index, value) in linear.enumerated()
        where Float(OutputStage.quantize(OutputStage.encodeForDisplay(value))) != gpu[index] {
            differing.append(value)
        }
        #expect(differing.isEmpty, "\(differing.count) 点で段が違う。最初は \(differing.prefix(4))")
    }
}
