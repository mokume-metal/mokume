// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import Testing
import mokume

@testable import MokumeCore

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

    /// 継承される側。**`final` にしない** — 継承を見る検査の基底が継承できないと、
    /// 基底を辿る経路を一度も通らない ([#1389](https://github.com/mokume-metal/mokume/issues/1389))。
    class Base: Sketch {
        @Param(0...1) var mix: Double = 0.5
        required init() {}
    }

    final class Derived: Base {
        @Param(0...10) var extra: Double = 1
    }

    /// 基底と同じ名前を、別のプロパティから宣言する派生。
    ///
    /// 同じ型の中での重なりはビルドが止めるが、基底と派生にまたがる重なりは止められない
    /// (`@Param` の説明の但し書き)。
    final class Overlapping: Base {
        @Param(0...10, name: "mix") var louderMix: Double = 7
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

    @Test("基底と派生で同じ名前を宣言すると、先に宣言した基底が勝ち、名指しで知らせる")
    func overlappingNamesKeepTheFirstAndWarn() {
        // 知らせは標準エラーへ直に出るので、口を差し替えて受け取る。``Sketch/params`` も
        // 窓も面も、この 1 つの集め方を通る
        var warnings: [String] = []
        let entries = ParamCatalog.indexed(from: Overlapping()) { warnings.append($0) }

        #expect(entries.map(\.name) == ["mix"])
        let mix = entries.first?.box.declaration
        #expect(mix?.range == ParamRange(0...1))
        #expect(mix?.value == .float(0.5))
        // 黙って片方を落とすと「書いたのに動かない値」になるので、名指しで 1 度言う
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("\"mix\"") == true)
    }

    @Test("重なりが無ければ、何も知らせない")
    func distinctNamesDoNotWarn() {
        var warnings: [String] = []
        _ = ParamCatalog.indexed(from: Derived()) { warnings.append($0) }
        #expect(warnings.isEmpty)
    }
}
