// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 範囲の外の値を丸める受け口が、丸めたことを 1 度知らせるかの検査 ([#1698])。GPU を要する。
///
/// 約束は [ADR-0020] 決定 5 の 1 行目 — フレームごとに呼ばれる口は投げずに、受け口で値を
/// 検め、**警告を出して**安全な既定へ倒す。直す前は、ここに並べた口が丸めるだけで黙っていた。
/// #1698 で知らせを足した口は、**使う値 (丸め先) が直す前のまま**で、足したのは知らせだけ
/// である — 絵は変わらない。
///
/// **例外は `curveDetail` の上の端 ([#1692]) で、ここは丸めそのものを新しく足した。** 直す前は
/// 上の端が無く、渡した数だけ刻んでいた。いまは 1024 を越える値を 1024 として刻むので、その
/// 3 行 (`1025`・`100_000`・`Int.max`) だけは直す前と効く値も絵も違う。`Int.max` はここで描かずに
/// 受け口の値だけを見る — 描くと、上限が外れる退行で検査ごと固まる (`ShapeFormulaTests` の
/// 刻みの上限の節)。
///
/// 範囲は、丸める受け口の全体を並べて回す。探し方は #1698 の本文 (`max(` / `min(` /
/// `clamp` の族) に残してある。文面は実装とは別に、ここへ原文を写して突き合わせる。
///
/// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
/// [#1692]: https://github.com/mokume-metal/mokume/issues/1692
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
        /// `Double` のまま渡す半頂角。`asFloat` を通る道を見る (#1698 の反証 8)。
        case spotLightAngleInDouble(Double)

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
            case .spotLightAngleInDouble(let value): "spotLight(angle: \(value) as Double)"
            }
        }

        /// この口が言う注意の鍵。
        var key: Canvas.Warning {
            switch self {
            case .strokeWeight: .badStrokeWeight
            case .textSize: .negativeTextSize
            case .textLeading: .negativeTextLeading
            case .curveDetail: .badCurveDetail
            case .solidDetail(.sphere, _): .badSphereDetail
            case .solidDetail(.ellipsoid, _): .badEllipsoidDetail
            case .solidDetail(.cylinder, _): .badCylinderDetail
            case .solidDetail(.cone, _): .badConeDetail
            case .solidDetail(.torus, _): .badTorusDetail
            case .spotLightAngle, .spotLightAngleInDouble: .badSpotLightAngle
            }
        }

        /// 同じ口へ、もう 1 つ別の範囲の外の値を渡す呼び方。
        var another: Call {
            switch self {
            case .strokeWeight: .strokeWeight(-100)
            case .textSize: .textSize(-100)
            case .textLeading: .textLeading(-100)
            case .curveDetail(let value): .curveDetail(value > 1024 ? -100 : 100_000)
            case .solidDetail(let solid, let value): .solidDetail(solid, value > 128 ? 1 : 100_000)
            case .spotLightAngle, .spotLightAngleInDouble: .spotLightAngle(-1)
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
            notice: "strokeWeight(): the weight takes a finite value of 0 or more, but -3.0 was passed, so 0 was used"),
        Rounded(
            call: .strokeWeight(.nan),
            notice: "strokeWeight(): the weight takes a finite value of 0 or more, but nan was passed, so 0 was used"),
        Rounded(
            call: .strokeWeight(.infinity),
            notice: "strokeWeight(): the weight takes a finite value of 0 or more, but inf was passed, so 0 was used"),
        Rounded(
            call: .textSize(-4),
            notice: "textSize(): the size takes 0 or more, but -4.0 was passed, so 0 was used"),
        Rounded(
            call: .textLeading(-5),
            notice: "textLeading(): the leading takes 0 or more, but -5.0 was passed, so 0 was used"),
        Rounded(
            call: .curveDetail(0),
            notice: "curveDetail(): the number of steps takes 1 to 1024, but 0 was passed, so 1 was used"),
        Rounded(
            call: .curveDetail(-2),
            notice: "curveDetail(): the number of steps takes 1 to 1024, but -2 was passed, so 1 was used"),
        Rounded(
            call: .curveDetail(1025),
            notice: "curveDetail(): the number of steps takes 1 to 1024, but 1025 was passed, so 1024 was used"),
        Rounded(
            call: .curveDetail(100_000),
            notice: "curveDetail(): the number of steps takes 1 to 1024, but 100000 was passed, so 1024 was used"),
        Rounded(
            call: .curveDetail(.max),
            notice: "curveDetail(): the number of steps takes 1 to 1024, but 9223372036854775807 was passed, so 1024 was used"),
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
        .textLeading(30), .curveDetail(1), .curveDetail(20), .curveDetail(1024), .spotLightAngle(0),
        .spotLightAngle(.pi / 2), .spotLightAngle(.pi / 6), .spotLightAngleInDouble(.pi / 2),
        .spotLightAngleInDouble(0),
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
            return try spotLightCone(on: canvas, angle: value)
        case .spotLightAngleInDouble(let value):
            return try spotLightCone(on: canvas, angle: value)
        }
    }

    private func spotLightCone(on canvas: Canvas, angle: some ScalarConvertible) throws -> Float {
        var cone: Float?
        try canvas.draw {
            canvas.spotLight(.linear(red: 1, green: 1, blue: 1), 0, 0, 100, 0, 0, -1, angle: angle)
            cone = canvas.activeLights.last?.directionAndCone.w
        }
        return try #require(cone)
    }

    /// 丸めた先の値で直に呼んだときに効く値。
    private func expected(for rounded: Rounded) throws -> Float {
        let reference = try makeCanvas()
        let call: Call =
            switch rounded.call {
            case .strokeWeight: .strokeWeight(0)
            case .textSize: .textSize(0)
            case .textLeading: .textLeading(0)
            case .curveDetail(let value): .curveDetail(value > 1024 ? 1024 : 1)
            case .solidDetail(let solid, let value): .solidDetail(solid, value < 3 ? 3 : 128)
            case .spotLightAngle(let value): .spotLightAngle(value > 1 ? .pi / 2 : 0)
            case .spotLightAngleInDouble(let value): .spotLightAngle(value > 1 ? .pi / 2 : 0)
            }
        let value = try apply(call, on: reference)
        #expect(!reference.warnings.hasWarned(call.key), "丸めた先の \(call) で注意した")
        return value
    }

    @Test("範囲の外の値は範囲の端へ丸めて効かせ、口の名前と範囲を名乗って 1 度だけ注意する", arguments: rounded)
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

    /// `Double` で書いた π/2 は、`Float` の π/2 と同じ光になる (#1698 の反証 8)。`Float.pi` は
    /// 0 の側へ丸めてあるので、`Double.pi / 2` を移した値は 1 ulp 大きい。
    @Test("Double で書いた π/2 の半頂角は、Float の π/2 と同じ円錐になり、注意しない")
    func aDoubleHalfPiIsTheFloatHalfPi() throws {
        try #require(Float(Double.pi / 2) == (Float.pi / 2).nextUp, "検査の前提: 1 ulp の差が無い")
        let canvas = try makeCanvas()
        let fromDouble = try spotLightCone(on: canvas, angle: Double.pi / 2)
        let fromFloat = try spotLightCone(on: canvas, angle: Float.pi / 2)
        #expect(fromDouble == fromFloat)
        #expect(!canvas.warnings.hasWarned(.badSpotLightAngle))
    }

    /// 立体ごとに鍵を分けたので、先に言った立体が後の立体を黙らせない (#1698 の反証 9)。
    @Test("sphere の分け方を丸めた後でも、torus の分け方の丸めを言う")
    func eachSolidKeepsItsOwnKey() throws {
        let canvas = try makeCanvas()
        _ = try apply(.solidDetail(.sphere, 2), on: canvas)
        _ = try apply(.solidDetail(.torus, 1000), on: canvas)
        #expect(canvas.warnings.hasWarned(.badSphereDetail))
        #expect(
            canvas.warnings.message(for: .badTorusDetail)
                == "torus(): detail takes 3 to 128, but 1000 was passed, so 128 was used")
    }

    /// フレームの外では光も形も置かないので、丸めの注意は言わず、1 度きりの鍵を残す
    /// (#1698 の反証 10)。言うのは「フレームの外」だけである。
    @Test("フレームの外では丸めの注意を言わず、フレームの外の注意だけを言う")
    func saysOnlyOutsideFrameOutsideTheFrame() throws {
        let canvas = try makeCanvas()
        canvas.spotLight(.linear(red: 1, green: 1, blue: 1), 0, 0, 100, 0, 0, -1, angle: 2)
        canvas.sphere(10, detail: 1000)
        #expect(canvas.warnings.hasWarned(.lightOutsideFrame))
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
        #expect(!canvas.warnings.hasWarned(.badSpotLightAngle), "置かない光のために丸めを言った")
        #expect(!canvas.warnings.hasWarned(.badSphereDetail), "置かない形のために丸めを言った")

        // 鍵は残っているので、フレームの中の書き間違いはまだ言える
        _ = try apply(.spotLightAngle(2), on: canvas)
        _ = try apply(.solidDetail(.sphere, 1000), on: canvas)
        #expect(canvas.warnings.hasWarned(.badSpotLightAngle))
        #expect(canvas.warnings.hasWarned(.badSphereDetail))
    }

    /// 無限の太さは 0 として扱うので、塗りは出て線は出ない (#1698 の反証 5)。直す前は太さが
    /// 無限のまま形の経路へ届き、形ごと黙って捨てられて塗りも出なかった。
    @Test("無限の太さの矩形は、太さ 0 と同じく塗りだけが出る")
    func anInfiniteWeightDrawsTheFill() throws {
        func center(weight: Float) throws -> Float {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.fill(.linear(red: 1, green: 1, blue: 1))
                canvas.stroke(.linear(red: 1, green: 0, blue: 0))
                canvas.strokeWeight(weight)
                canvas.rect(8, 8, 16, 16)
            }
            let pixels = try canvas.target.readPixels()
            let index: Int = (16 * 32 + 16) * 4 + 1
            return Float(pixels.components[index])
        }
        let infinite = try center(weight: .infinity)
        let zero = try center(weight: 0)
        #expect(infinite == zero)
        #expect(infinite > 0.5, "無限の太さで塗りが出ない")
    }

    // MARK: - 粒

    /// `emit` の引数のうち、0 より小さくならない量。
    nonisolated enum Argument: String, Sendable {
        case rate, life, size, radius

        var key: Particles.Warning {
            switch self {
            case .rate: .negativeRate
            case .life: .negativeLife
            case .size: .negativeSize
            case .radius: .negativeRadius
            }
        }
    }

    /// `emit` の 1 回ぶん。どれも有限で、1 フレームで粒が出る (`rate` が負でなければ)。
    nonisolated struct Emission: Sendable, CustomTestStringConvertible {
        var rate: Float = 120
        var from: Emitter = .point(16, 16)
        var life: ClosedRange<Float> = 1...1
        var size: ClosedRange<Float> = 2...2
        var testDescription: String { "rate: \(rate), from: \(from), life: \(life), size: \(size)" }
    }

    /// 1 フレームで出して、出た数と、出た粒の寿命 (`span`)・大きさ・中心からの距離を返す。
    private func emitted(_ emission: Emission) throws -> (
        count: Int, spans: [Float], sizes: [Float], distances: [Float], dust: Particles
    ) {
        let canvas = try makeCanvas()
        canvas.deltaTime = 1.0 / 30
        var randomness = Randomness(seed: 1698)
        let dust = try canvas.makeParticles(count: 8)
        try canvas.draw {
            canvas.emit(
                dust, from: emission.from, toward: .plane(0...0), rate: emission.rate, speed: 0...0,
                life: emission.life, size: emission.size, color: .linear(red: 1, green: 1, blue: 1),
                using: &randomness)
        }
        let count = min(dust.cursor, 8)
        let particles = canvas.read(dust.state).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Particle.self).prefix(count))
        }
        let distances = particles.map { simd_distance(SIMD3($0.x, $0.y, $0.z), SIMD3(16, 16, 0)) }
        return (dust.cursor, particles.map(\.span), particles.map(\.size), distances, dust)
    }

    nonisolated struct NegativeEmission: Sendable, CustomTestStringConvertible {
        var emission: Emission
        var argument: Argument
        var notice: String
        var testDescription: String { emission.testDescription }
    }

    nonisolated static let negativeEmissions: [NegativeEmission] = [
        NegativeEmission(
            emission: Emission(rate: -5), argument: .rate,
            notice: "emit(): rate takes 0 or more, but -5.0 was passed, so 0 was used"),
        NegativeEmission(
            emission: Emission(life: -2 ... -1), argument: .life,
            notice: "emit(): life takes 0 or more, but -2.0...-1.0 was passed, so the part below 0 was used as 0"),
        NegativeEmission(
            emission: Emission(size: -3 ... -1), argument: .size,
            notice: "emit(): size takes 0 or more, but -3.0...-1.0 was passed, so the part below 0 was used as 0"),
        NegativeEmission(
            emission: Emission(from: .circle(16, 16, radius: -4)), argument: .radius,
            notice: "emit(): the radius of from takes 0 or more, but circle(16.0, 16.0, radius: -4.0) was passed, so 4.0 was used"),
        NegativeEmission(
            emission: Emission(from: .sphere(16, 16, 0, radius: -4)), argument: .radius,
            notice: "emit(): the radius of from takes 0 or more, but sphere(16.0, 16.0, 0.0, radius: -4.0) was passed, so 4.0 was used"),
    ]

    @Test("emit の負の rate・life・size・半径は今までどおりに扱い、引数を名乗って 1 度だけ注意する", arguments: negativeEmissions)
    func negativeEmissionIsRoundedAndWarned(_ negative: NegativeEmission) throws {
        let emission = negative.emission
        let (count, spans, sizes, distances, dust) = try emitted(emission)
        switch negative.argument {
        case .rate: #expect(count == 0, "負の rate で粒が出た")
        case .life: #expect(spans.allSatisfy { $0 == 0 }, "寿命 \(spans)")
        case .size: #expect(sizes.allSatisfy { $0 == 0 }, "大きさ \(sizes)")
        case .radius:
            // 負の半径は絶対値で読む。出た粒は中心から半径 4 の内側にあり、中心に固まらない
            #expect(distances.allSatisfy { $0 <= 4.0001 }, "距離 \(distances)")
            #expect(distances.contains { $0 > 0.01 }, "負の半径で中心から動かない")
        }
        if negative.argument != .rate { #expect(count > 0, "粒が出ていない (検査の前提)") }
        #expect(dust.warnings.message(for: negative.argument.key) == negative.notice)
        for other in [Argument.rate, .life, .size, .radius] where other != negative.argument {
            #expect(!dust.warnings.hasWarned(other.key), "\(negative.argument) で \(other) を言った")
        }
        #expect(!dust.warnings.hasWarned(.unacceptableEmission), "数でない値の注意を言った")
    }

    /// 引数ごとに鍵を分けたので、先に言った引数が後の引数を黙らせない (#1698 の反証 9)。
    @Test("負の rate を踏んだ後でも、負の size を言う")
    func eachArgumentKeepsItsOwnKey() throws {
        let canvas = try makeCanvas()
        var randomness = Randomness(seed: 1698)
        let dust = try canvas.makeParticles(count: 8)
        try canvas.draw {
            for (rate, size) in [(Float(-5), Float(2)...2), (120, -3 ... -1)] {
                canvas.emit(
                    dust, from: .point(16, 16), toward: .plane(0...0), rate: rate, speed: 0...0,
                    life: 1...1, size: size, color: .linear(red: 1, green: 1, blue: 1),
                    using: &randomness)
            }
        }
        #expect(dust.warnings.hasWarned(.negativeRate))
        #expect(dust.warnings.hasWarned(.negativeSize))
    }

    @Test(
        "emit の範囲の中の値 (0 を含む) では注意しない",
        arguments: [
            Emission(rate: 0), Emission(life: 0...1), Emission(size: 0...1), Emission(),
            Emission(from: .circle(16, 16, radius: 0)), Emission(from: .sphere(16, 16, 0, radius: 4)),
        ])
    func saysNothingForAdmittedEmission(_ emission: Emission) throws {
        let (_, _, _, _, dust) = try emitted(emission)
        for argument in [Argument.rate, .life, .size, .radius] {
            #expect(!dust.warnings.hasWarned(argument.key), "\(emission) で \(argument) を言った")
        }
    }
}
