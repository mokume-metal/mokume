// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 性能レビュー (親 #1744) 群 G4Media のうち、音 (#2379) の計測の下書き。**コンパイルされない置き場にある。**
//
// 置き場の想定: Tests/MokumeAudioTests/PerfReviewG4Audio.swift
// GPU を要さない。出力は PERF<TAB>Issue<TAB>場面<TAB>指標<TAB>値<TAB>単位。release で採る。

import Accelerate
import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

nonisolated private enum G4A {
    static func ms(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1e3 + Double(parts.attoseconds) / 1e15
    }

    static func sample(warmup: Int = 3, runs: Int = 30, _ body: () throws -> Void) rethrows -> [Double] {
        let clock = ContinuousClock()
        for _ in 0..<warmup { try body() }
        var values: [Double] = []
        for _ in 0..<runs { values.append(ms(try clock.measure { try body() })) }
        return values
    }

    /// `repeats` 回の和を測って 1 回あたりに割る (1 回が数十 µs のもの)。
    static func perCall(repeats: Int, runs: Int = 20, _ body: () -> Void) -> [Double] {
        sample(runs: runs) { for _ in 0..<repeats { body() } }.map { $0 * 1000 / Double(repeats) }
    }

    static func report(_ scene: String, _ metric: String, _ values: [Double], unit: String) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return }
        let p90 = sorted[max(0, min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1))]
        for (name, value) in [("median", sorted[sorted.count / 2]), ("p90", p90), ("min", sorted[0]),
                              ("max", sorted[sorted.count - 1])] {
            print("PERF\t2379\t\(scene)\t\(metric).\(name)\t\(String(format: "%.4f", value))\t\(unit)")
        }
    }
}

nonisolated(unsafe) private var g4aSink: Float = 0

@Suite("PerfReview G4Audio", .serialized)
struct PerfReviewG4Audio {

    /// 1000 Hz の正弦波を鳴らした 1024 標本の窓。
    private static let window: [Float] = (0..<AudioAnalysis.windowSize).map {
        0.4 * sin(2 * Float.pi * 1000 * Float($0) / 48_000)
    }

    /// 解析 1 回と、その内訳。いまの `analyze` が 1 回で払うものを分けて見る。
    @Test("2379 AudioAnalysis.analyze の 1 回と内訳 (setup の作成・変換・振幅のループ・dB の写し)")
    func analyzeBreakdown() throws {
        let window = Self.window
        let size = AudioAnalysis.windowSize
        G4A.report("analyze", "total", G4A.perCall(repeats: 200) {
            g4aSink += AudioAnalysis.analyze(window).level
        }, unit: "us")

        // setup の作成だけ (いまは呼ぶたびに作る)
        G4A.report("analyze", "dftSetupCreation", G4A.perCall(repeats: 200) {
            let transform = try? vDSP.DiscreteFourierTransform(
                count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
            if transform == nil { g4aSink += 1 }
        }, unit: "us")

        // 作り置いた setup で変換だけ (複素 → 複素、虚部は 0 の配列)
        let transform = try vDSP.DiscreteFourierTransform(
            count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        let zeros = [Float](repeating: 0, count: size)
        G4A.report("analyze", "dftTransformOnly", G4A.perCall(repeats: 200) {
            let output = transform.transform(real: window, imaginary: zeros)
            g4aSink += output.real[1]
        }, unit: "us")

        // 振幅のスカラーのループ (512 帯域の平方根)
        let output = transform.transform(real: window, imaginary: zeros)
        G4A.report("analyze", "magnitudeScalarLoop", G4A.perCall(repeats: 200) {
            var spectrum = [Float](repeating: 0, count: size / 2)
            for band in 0..<(size / 2) {
                spectrum[band] = (output.real[band] * output.real[band]
                    + output.imaginary[band] * output.imaginary[band]).squareRoot()
            }
            g4aSink += spectrum[3]
        }, unit: "us")

        // 帯域ごとの dB → 0〜1 (512 回の log10)
        let spectrum = (0..<(size / 2)).map { Float($0) / 512 }
        G4A.report("analyze", "spectrumLevelsMap", G4A.perCall(repeats: 200) {
            let levels = spectrum.map { AudioAnalysis.level(AudioAnalysis.decibels($0)) }
            g4aSink += levels[7]
        }, unit: "us")

        // 窓の切り出し (`SampleRing.latest` と同じ形: 1024 回の剰余と添字)
        let ring = SynthRack(sampleRate: 48_000)
        let node = try #require(ring.addSource(.wave(.sine)))
        _ = ring.post(SynthCommand(op: .play, node: UInt8(node.id)))
        ring.advance(frames: 4096)
        G4A.report("analyze", "meterLatest1024", G4A.perCall(repeats: 200) {
            g4aSink += node.meter.latest(AudioAnalysis.windowSize)[5]
        }, unit: "us")
    }

    /// 合成音を `count` 個鳴らし、1 フレーム (60 fps・48 kHz = 800 標本) ぶん進めてから、
    /// `SynthSound.refresh()` と同じ `analyze(meter.latest(1024))` を全部に掛ける。
    ///
    /// **`SynthStage.supply()` の main の時間に相当する** (鳴らさない書き出しの経路で、ラックを進めるのも main)。
    /// 進める (`rack.advance`) と解析を分けて出す。
    @Test("2379 合成音 1 / 10 / 50 / 64 個の 1 フレームぶん: ラックを進める・全部を解析する", arguments: [1, 10, 50, 64])
    func framePerSounds(count: Int) throws {
        let rack = SynthRack(sampleRate: 48_000)
        var nodes: [RackNode] = []
        for index in 0..<count {
            let node = try #require(rack.addSource(.wave(index.isMultiple(of: 2) ? .sine : .saw)))
            _ = rack.set(node.id, .frequency, 110 + Float(index) * 37)
            _ = rack.set(node.id, .amplitude, 0.5)
            _ = rack.post(SynthCommand(op: .play, node: UInt8(node.id)))
            nodes.append(node)
        }
        rack.advance(frames: 4096)
        let scene = "sounds\(count)"
        G4A.report(scene, "rackAdvance800", G4A.sample { rack.advance(frames: 800) }, unit: "ms")
        G4A.report(scene, "analyzeAll", G4A.sample {
            for node in nodes { g4aSink += AudioAnalysis.analyze(node.meter.latest(AudioAnalysis.windowSize)).level }
        }, unit: "ms")
        G4A.report(scene, "advanceAndAnalyzeAll", G4A.sample {
            rack.advance(frames: 800)
            for node in nodes { g4aSink += AudioAnalysis.analyze(node.meter.latest(AudioAnalysis.windowSize)).level }
        }, unit: "ms")
    }
}
