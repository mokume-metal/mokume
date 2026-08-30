// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import Testing
import mokume

/// 変更が伝わったかを覚えておくだけの入れ物。
///
/// `withObservationTracking` の知らせは隔離の外から届くので、素の変数を書き換える
/// 形では受け取れない。
nonisolated final class Notice: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var fired: Bool {
        lock.withLock { value }
    }

    func fire() {
        lock.withLock { value = true }
    }
}

@Suite("宣言した値が面から見える")
struct ParameterDeclarationTests {
    final class Knobbed: Sketch {
        @Param(0...200) var radius: Double = 80
        @Param(1...8) var count: Int = 3
        @Param var spinning: Bool = true
        @Param(choices: ["circle", "square"]) var shape: String = "circle"
        @Param(name: "ink") var color: LinearRGBA = .display(red: 1, green: 0, blue: 0)
        @Param var offset: SIMD2<Float> = .init(1, 2)
    }

    @Test("宣言した順に、名前・型・範囲・候補が引ける")
    func lists() {
        let sketch = Knobbed()
        let params = sketch.params
        #expect(params.map(\.name) == ["radius", "count", "spinning", "shape", "ink", "offset"])
        #expect(params.map(\.typeName) == ["float", "int", "bool", "string", "color", "vec2"])
        #expect(params[0].range == ParamRange(0...200))
        #expect(params[1].range == ParamRange(1...8))
        #expect(params[2].range == nil)
        #expect(params[3].choices == ["circle", "square"])
        #expect(params[0].value == .float(80))
        #expect(params[1].value == .int(3))
    }

    @Test("読み書きは普通のプロパティと変わらない")
    func readsAndWrites() {
        let sketch = Knobbed()
        #expect(sketch.radius == 80)
        sketch.radius = 120
        #expect(sketch.radius == 120)
        #expect(sketch.params[0].value == .float(120))
    }

    @Test("範囲はコードからの代入を素通しする")
    func codeAssignmentIsNotClamped() {
        // 範囲は面のための宣言であって、値の不変条件ではない (ADR-0030 決定 3)
        let sketch = Knobbed()
        sketch.radius = 999
        #expect(sketch.radius == 999)
    }

    final class Base: Sketch {
        @Param(0...1) var mix: Double = 0.5
    }

    final class Derived: Sketch {
        @Param(0...1) var mix: Double = 0.5
        @Param(0...10) var extra: Double = 1
    }

    @Test("値が変わったことが、登録も通知も書かずに伝わる")
    func observes() {
        // 変更追跡は Observation に載せ、自前の通知機構を持たない (ADR-0013 決定 1)。
        // 窓の更新はこの経路で成立するので、ここが切れると窓が動かなくなる。
        let sketch = Knobbed()
        let notified = Notice()
        withObservationTracking {
            _ = sketch.radius
        } onChange: {
            notified.fire()
        }
        #expect(!notified.fired)
        sketch.radius = 10
        #expect(notified.fired)
    }

    @Test("触っていない値を書いても、見ている値には伝わらない")
    func doesNotOverNotify() {
        let sketch = Knobbed()
        let notified = Notice()
        withObservationTracking {
            _ = sketch.radius
        } onChange: {
            notified.fire()
        }
        sketch.shape = "square"
        #expect(!notified.fired)
    }

    @Test("宣言していないスケッチの一覧は空")
    func emptyWhenUndeclared() {
        final class Plain: Sketch {}
        #expect(Plain().params.isEmpty)
    }

    @Test("継承していても、書いた順に並ぶ")
    func inherited() {
        #expect(Derived().params.map(\.name) == ["mix", "extra"])
        #expect(Base().params.map(\.name) == ["mix"])
    }
}
