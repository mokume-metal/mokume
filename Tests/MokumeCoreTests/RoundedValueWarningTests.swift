// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 範囲の外の値を丸める受け口が、丸めたことを 1 度知らせるかの検査 ([#1698])。GPU を要する。
///
/// 約束は [ADR-0020] 決定 5 の 1 行目 — フレームごとに呼ばれる口は投げずに、受け口で値を
/// 検め、**警告を出して**安全な既定へ倒す。直す前は、ここに並べた口が丸めるだけで黙っていた。
/// **使う値 (丸め先) は直す前のまま**で、足したのは知らせだけである — 絵は変わらない。
///
/// 範囲は、丸める受け口の全体を並べて回す。探し方は #1698 の本文 (`max(` / `min(` /
/// `clamp` の族) に残してある。文面は実装とは別に、ここへ原文を写して突き合わせる。
///
/// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
@Suite(
    "範囲の外を丸めた受け口の注意",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RoundedValueWarningTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 32, height: 32)
    }

    /// 丸める口の 1 回ぶん。渡す値は範囲の外でも中でもよい。
    nonisolated enum Call: Sendable, CustomTestStringConvertible {
        case strokeWeight(Float)
        case textSize(Float)
        case textLeading(Float)
        case curveDetail(Int)
        case solidDetail(Solid, Int)
        case spotLightAngle(Float)

        /// 形のうち、`detail` を取る 5 つ。
        enum Solid: String, Sendable, CaseIterable {
            case sphere, ellipsoid, cylinder, cone, torus
        }

        var testDescription: String {
            switch self {
            case .strokeWeight(let value): "strokeWeight(\(value))"
            case .textSize(let value): "textSize(\(value))"
            case .textLeading(let value): "textLeading(\(value))"
            case .curveDetail(let value): "curveDetail(\(value))"
            case .solidDetail(let solid, let value): "\(solid.rawValue)(detail: \(value))"
            case .spotLightAngle(let value): "spotLight(angle: \(value))"
            }
        }

        /// この口が言う注意の鍵。
        var key: Canvas.Warning {
            switch self {
            case .strokeWeight: .badStrokeWeight
            case .textSize: .negativeTextSize
            case .textLeading: .negativeTextLeading
            case .curveDetail: .badCurveDetail
            case .solidDetail: .badSolidDetail
            case .spotLightAngle: .badSpotLightAngle
            }
        }

        /// 同じ口へ、もう 1 つ別の範囲の外の値を渡す呼び方。
        var another: Call {
            switch self {
            case .strokeWeight: .strokeWeight(-100)
            case .textSize: .textSize(-100)
            case .textLeading: .textLeading(-100)
            case .curveDetail: .curveDetail(-100)
            case .solidDetail(let solid, let value): .solidDetail(solid, value > 128 ? 1 : 100_000)
            case .spotLightAngle: .spotLightAngle(-1)
            }
        }
    }

    /// 丸めた口と、初回の文面の原文。
    nonisolated struct Rounded: Sendable, CustomTestStringConvertible {
        var call: Call
        var notice: String
        var testDescription: String { call.testDescription }
    }

    nonisolated static let rounded: [Rounded] = [
        Rounded(
            call: .strokeWeight(-3),
            notice: "strokeWeight(): the weight takes 0 or more, but -3.0 was passed, so 0 was used"),
        Rounded(
            call: .strokeWeight(.nan),
            notice: "strokeWeight(): the weight takes 0 or more, but nan was passed, so 0 was used"),
        Rounded(
            call: .textSize(-4),
            notice: "textSize(): the size takes 0 or more, but -4.0 was passed, so 0 was used"),
        Rounded(
            call: .textLeading(-5),
            notice: "textLeading(): the leading takes 0 or more, but -5.0 was passed, so 0 was used"),
        Rounded(
            call: .curveDetail(0),
            notice: "curveDetail(): the number of steps takes 1 or more, but 0 was passed, so 1 was used"),
        Rounded(
            call: .curveDetail(-2),
            notice: "curveDetail(): the number of steps takes 1 or more, but -2 was passed, so 1 was used"),
        Rounded(
            call: .spotLightAngle(-0.5),
            notice: "spotLight(): angle takes 0 to pi / 2 (1.5707963), but -0.5 was passed, so 0.0 was used"),
        Rounded(
            call: .spotLightAngle(2),
            notice: "spotLight(): angle takes 0 to pi / 2 (1.5707963), but 2.0 was passed, so 1.5707963 was used"),
        Rounded(
            call: .spotLightAngle(.nan),
            notice: "spotLight(): angle takes 0 to pi / 2 (1.5707963), but nan was passed, so 0.0 was used"),
    ] + Call.Solid.allCases.flatMap { solid in
        [(1, 3), (1000, 128)].map { passed, used in
            Rounded(
                call: .solidDetail(solid, passed),
                notice: "\(solid.rawValue)(): detail takes 3 to 128, but \(passed) was passed, so \(used) was used")
        }
    }

    /// 範囲の中 (端を含む) の呼び方。どれも注意を言わない。
    nonisolated static let admitted: [Call] = [
        .strokeWeight(0), .strokeWeight(3), .textSize(0), .textSize(24), .textLeading(0),
        .textLeading(30), .curveDetail(1), .curveDetail(20), .spotLightAngle(0),
        .spotLightAngle(.pi / 2), .spotLightAngle(.pi / 6),
    ] + Call.Solid.allCases.flatMap { solid in
        [3, 24, 128].map { Call.solidDetail(solid, $0) }
    }

    /// 呼んで、口が効かせた値を返す。形は保持した形の頂点の数で、光は円錐の余弦で見る。
    private func apply(_ call: Call, on canvas: Canvas) throws -> Float {
        switch call {
        case .strokeWeight(let value):
            canvas.strokeWeight(value)
            return canvas.style.strokeWeight
        case .textSize(let value):
            canvas.textSize(value)
            return canvas.style.textSize
        case .textLeading(let value):
            canvas.textLeading(value)
            return try #require(canvas.style.textLeading)
        case .curveDetail(let value):
            canvas.curveDetail(value)
            return Float(canvas.currentCurveDetail)
        case .solidDetail(let solid, let value):
            var count = 0
            try canvas.draw {
                count = canvas.createShape {
                    switch solid {
                    case .sphere: canvas.sphere(10, detail: value)
                    case .ellipsoid: canvas.ellipsoid(10, 8, 6, detail: value)
                    case .cylinder: canvas.cylinder(10, 20, detail: value)
                    case .cone: canvas.cone(10, 20, detail: value)
                    case .torus: canvas.torus(10, 3, detail: value)
                    }
                }.vertexCount
            }
            return Float(count)
        case .spotLightAngle(let value):
            var cone: Float?
            try canvas.draw {
                canvas.spotLight(.linear(red: 1, green: 1, blue: 1), 0, 0, 100, 0, 0, -1, angle: value)
                cone = canvas.activeLights.last?.directionAndCone.w
            }
            return try #require(cone)
        }
    }

    /// 丸めた先の値で直に呼んだときに効く値。
    private func expected(for rounded: Rounded) throws -> Float {
        let reference = try makeCanvas()
        let call: Call =
            switch rounded.call {
            case .strokeWeight: .strokeWeight(0)
            case .textSize: .textSize(0)
            case .textLeading: .textLeading(0)
            case .curveDetail: .curveDetail(1)
            case .solidDetail(let solid, let value): .solidDetail(solid, value < 3 ? 3 : 128)
            case .spotLightAngle(let value): .spotLightAngle(value > 1 ? .pi / 2 : 0)
            }
        let value = try apply(call, on: reference)
        #expect(!reference.warnings.hasWarned(call.key), "丸めた先の \(call) で注意した")
        return value
    }

    @Test("範囲の外の値は今までどおり丸めて効かせ、口の名前と範囲を名乗って 1 度だけ注意する", arguments: rounded)
    func roundsAndWarnsOnce(_ rounded: Rounded) throws {
        let canvas = try makeCanvas()
        let used = try apply(rounded.call, on: canvas)
        #expect(used == (try expected(for: rounded)), "丸めた先と違う値が効いた")
        #expect(canvas.warnings.message(for: rounded.call.key) == rounded.notice)

        // 同じ口へ別の範囲の外の値を渡しても、控えは初回の文面のまま
        _ = try apply(rounded.call.another, on: canvas)
        #expect(canvas.warnings.message(for: rounded.call.key) == rounded.notice, "2 度目を言った")

        // 鍵は口ごとに分かれている。この口の知らせが、他の口の知らせを黙らせない
        let others = Set(Self.rounded.map(\.call.key)).subtracting([rounded.call.key])
        for key in others {
            #expect(!canvas.warnings.hasWarned(key), "\(rounded.call) で \(key) を言った")
        }
    }

    @Test("範囲の中の値 (端を含む) では注意しない", arguments: admitted)
    func saysNothingInsideTheRange(_ call: Call) throws {
        let canvas = try makeCanvas()
        _ = try apply(call, on: canvas)
        for key in Set(Self.rounded.map(\.call.key)) {
            #expect(!canvas.warnings.hasWarned(key), "\(call) で \(key) を言った")
        }
    }

    // MARK: - 粒

    /// `emit` の 1 回ぶん。どれも有限で、1 フレームで粒が出る (`rate` が負でなければ)。
    nonisolated struct Emission: Sendable, CustomTestStringConvertible {
        var rate: Float = 120
        var life: ClosedRange<Float> = 1...1
        var size: ClosedRange<Float> = 2...2
        var testDescription: String { "rate: \(rate), life: \(life), size: \(size)" }
    }

    /// 1 フレームで出して、出た数と、出た粒の寿命 (`span`) と大きさを返す。
    private func emitted(_ emission: Emission) throws -> (count: Int, spans: [Float], sizes: [Float], dust: Particles) {
        let canvas = try makeCanvas()
        canvas.deltaTime = 1.0 / 30
        var randomness = Randomness(seed: 1698)
        let dust = try canvas.makeParticles(count: 8)
        try canvas.draw {
            canvas.emit(
                dust, from: .point(16, 16), rate: emission.rate, speed: 0...0, angle: 0...0,
                life: emission.life, size: emission.size, color: .linear(red: 1, green: 1, blue: 1),
                using: &randomness)
        }
        let count = min(dust.cursor, 8)
        let particles = canvas.read(dust.state).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Particle.self).prefix(count))
        }
        return (dust.cursor, particles.map(\.span), particles.map(\.size), dust)
    }

    nonisolated static let negativeEmissions: [(Emission, String)] = [
        (
            Emission(rate: -5),
            "emit(): rate takes 0 or more, but -5.0 was passed, so 0 was used"
        ),
        (
            Emission(life: -2 ... -1),
            "emit(): life takes 0 or more, but -2.0...-1.0 was passed, so the part below 0 was used as 0"
        ),
        (
            Emission(size: -3 ... -1),
            "emit(): size takes 0 or more, but -3.0...-1.0 was passed, so the part below 0 was used as 0"
        ),
    ]

    @Test("emit の負の rate・life・size は今までどおり 0 として扱い、引数を名乗って 1 度だけ注意する", arguments: negativeEmissions)
    func negativeEmissionIsRoundedAndWarned(_ emission: Emission, notice: String) throws {
        let (count, spans, sizes, dust) = try emitted(emission)
        if emission.rate < 0 {
            #expect(count == 0, "負の rate で粒が出た")
        } else {
            #expect(count > 0, "粒が出ていない (検査の前提)")
        }
        if emission.life.lowerBound < 0 { #expect(spans.allSatisfy { $0 == 0 }, "寿命 \(spans)") }
        if emission.size.lowerBound < 0 { #expect(sizes.allSatisfy { $0 == 0 }, "大きさ \(sizes)") }
        #expect(dust.warnings.message(for: .negativeEmission) == notice)
        #expect(!dust.warnings.hasWarned(.unacceptableEmission), "数でない値の注意を言った")
    }

    @Test(
        "emit の範囲の中の値 (0 を含む) では注意しない",
        arguments: [Emission(rate: 0), Emission(life: 0...1), Emission(size: 0...1), Emission()])
    func saysNothingForAdmittedEmission(_ emission: Emission) throws {
        let (_, _, _, dust) = try emitted(emission)
        #expect(!dust.warnings.hasWarned(.negativeEmission))
    }
}
