// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import mokume

@testable import MokumeCore
@testable import reference_sketches

/// 参照スケッチ `scenes-and-looks` (#4133)。シーンの値の束が、遷移の途中で別のシーンを指定しても跳ばずに移る。
/// フレームの時計で 1 枚ずつ進め、キーは押した枚の次に効くのではなく、押した枚の頭で効く。
///
/// 描く経路を通すので GPU を使う (台帳の検査と同じ)。
@Suite(
    "参照スケッチ scenes-and-looks",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ScenesAndLooksTests {
    typealias Look = ScenesAndLooks.Look

    /// 1 枚ずつ進めて、そのフレームの値を残す。
    @MainActor
    final class Driver {
        let sketch = ScenesAndLooks()
        let runtime: SketchRuntime
        /// 描いたフレームごとの、表示した値の束と遷移の進み具合。
        var shots: [(look: Look, progress: Float)] = []

        init() throws {
            runtime = try SketchRuntime(
                sketch: sketch, gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60), persistsParams: false)
        }

        func frame() throws {
            try runtime.advance()
            shots.append((sketch.shown, sketch.progress))
        }

        func frames(_ count: Int) throws {
            for _ in 0..<count { try frame() }
        }

        /// `key` を押した枚を進め、離す (離すのは次の枚の頭)。
        func tap(_ key: Key) throws {
            runtime.input.enqueue(.keyDown(code: key, characters: "", isRepeat: false))
            try frame()
            runtime.input.enqueue(.keyUp(code: key))
        }
    }

    /// 向きの差 (度)。0° をまたぐ組は短いほうの弧で測る。
    private static func angleStep(_ a: Float, _ b: Float) -> Float {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        return abs(delta)
    }

    /// 1 フレームに動いてよい量の上限。`smoothstep` の傾きは最大 1.5 / 遷移の長さ (フレーム数) で、
    /// 出発点から目的地までの距離にかかる。距離の上限を 3 つのシーンと途中の値から見積もって、少し余裕を持たせる。
    private static let framesPerTransition = Float(ScenesAndLooks.duration) * 60
    private static let slope = 1.5 / framesPerTransition

    @Test("1 から 2 へ移ると、針は 350° から 10° へ 20° だけ回り、遠回りしない")
    @MainActor
    func headingTakesTheShortArc() throws {
        let driver = try Driver()
        try driver.frames(2)
        try driver.tap(.digit2)
        try driver.frames(Int(Self.framesPerTransition) + 5)

        let headings = driver.shots.map(\.look.heading)
        // 350° から 370° (= 10°) までを、止まらず増える向きだけで進む。350° を下回らず、370° を越えない
        #expect(headings.min()! >= 350 - 0.001)
        #expect(headings.max()! <= 370 + 0.001)
        #expect(Self.angleStep(headings.last!, 10) < 0.001)
        for (before, after) in zip(headings, headings.dropFirst()) {
            #expect(after >= before - 0.0001, "回る向きは途中で変わらない")
        }
    }

    @Test("遷移の途中で 3 を指定しても、そのときの値から移り、どの値も 1 フレームで跳ばない")
    @MainActor
    func switchingMidTransitionDoesNotJump() throws {
        let driver = try Driver()
        try driver.frames(2)
        try driver.tap(.digit2)
        // 遷移の半分手前 (進み具合が 0.5 に届く前) で 3 を指定する
        try driver.frames(40)
        let atSwitch = driver.shots.count
        try driver.tap(.digit3)
        try driver.frames(Int(Self.framesPerTransition) + 5)

        let looks = driver.shots.map(\.look)
        let radiusLimit = Self.slope * 65 + 0.001
        let headingLimit = Self.slope * 180 + 0.001
        let redLimit = Self.slope * 1 + 0.001
        for index in 1..<looks.count {
            let (before, after) = (looks[index - 1], looks[index])
            #expect(abs(after.radius - before.radius) <= radiusLimit, "radius \(index)")
            #expect(Self.angleStep(before.heading, after.heading) <= headingLimit, "heading \(index)")
            #expect(abs(after.tint.red - before.tint.red) <= redLimit, "red \(index)")
        }

        // 切り替えた枚そのもの (3 を押した枚) は、前の枚と同じ値から始まる
        #expect(looks[atSwitch] == looks[atSwitch - 1])
        // 遷移の途中の値から出発している (シーン 2 の値でも、シーン 1 の値でもない)
        #expect(driver.sketch.from != driver.sketch.looks[1] && driver.sketch.from != driver.sketch.looks[0])
        // 最後は 3 の値に着く
        let last = looks.last!
        let three = driver.sketch.looks[2]
        #expect(abs(last.radius - three.radius) < 0.001)
        #expect(Self.angleStep(last.heading, three.heading) < 0.001)
        #expect(last.filled == three.filled)
    }

    @Test("真偽の値は、遷移の進み具合が 0.5 を越えたフレームで 1 度だけ切り替わる")
    @MainActor
    func booleanFlipsOnceAfterHalfway() throws {
        let driver = try Driver()
        try driver.frames(2)
        try driver.tap(.digit2)
        try driver.frames(Int(Self.framesPerTransition) + 5)

        let flips = zip(driver.shots, driver.shots.dropFirst()).filter { $0.0.look.filled != $0.1.look.filled }
        #expect(flips.count == 1)
        let flipped = try #require(flips.first)
        #expect(flipped.0.progress <= 0.5 && flipped.1.progress > 0.5)
    }
}
