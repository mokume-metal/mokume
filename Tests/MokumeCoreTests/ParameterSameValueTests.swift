// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Observation
import Testing

@testable import MokumeCore
@testable import mokume

/// 値が同じ再代入では、公開も保存もしないこと
/// ([#2382](https://github.com/mokume-metal/mokume/issues/2382))。
///
/// `size = min(size, 100)` のように値を保つ書き方も、これまでは毎回「変わった」と知らせ、
/// `mokume watch` の下では毎フレーム応答 (`report.json`) を書き直していた。ADR-0030 決定 2 は改訂番号を
/// 「値が変わるたびに進む」と決めているので、**値が変わらなければ進まない**のが文言どおりである。
/// 値が変わるときの通知・改訂番号の意味は変えない。
@Suite("同じ値の再代入では公開も保存もしない")
@MainActor
struct ParameterSameValueTests {
    final class Knobbed: Sketch {
        @Param(0...200) var radius: Double = 80
        @Param(1...8) var count: Int = 3
        @Param var tint: LinearRGBA = LinearRGBA(straightRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    }

    /// 面に出る表現より多くを持つ自作の型 (`note` は応答にも保存にも載らない)。
    struct Tagged: ParamRepresentable, Equatable {
        var length: Double
        var note: String
        var paramValue: ParamValue { .float(length) }
        init(_ length: Double, note: String) {
            self.length = length
            self.note = note
        }
        init?(paramValue: ParamValue) {
            guard case .float(let value) = paramValue else { return nil }
            length = value
            note = ""
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = try TestScratch.directory("mokume-same-value")
        return directory
    }

    /// 観測が呼ばれたかを数える。`withObservationTracking` は 1 度きりなので、読んだ値が変わったかだけを返す。
    private func notifies<Value>(_ box: ParamBox<Value>, _ change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking {
            _ = box.value
        } onChange: {
            flag.raise()
        }
        change()
        return flag.isRaised
    }

    /// 観測の閉包 (Sendable) から立てる印。
    private nonisolated final class Flag: @unchecked Sendable {
        nonisolated(unsafe) private(set) var isRaised = false
        func raise() { isRaised = true }
    }

    // MARK: - 通知

    @Test("同じ値の代入は観測へ知らせず、違う値は今までどおり知らせる")
    func observationFiresOnlyWhenTheValueChanges() {
        let box = ParamBox<Double>(name: "x", value: 5, range: ParamRange(0...10))
        #expect(!notifies(box) { box.value = 5 })
        #expect(box.value == 5)
        #expect(notifies(box) { box.value = 6 })
        #expect(box.value == 6)
    }

    @Test("`+= 0` のように、その場で変える書き方も同じ")
    func modifyInPlaceFollowsTheSameRule() {
        let box = ParamBox<Double>(name: "x", value: 5)
        #expect(!notifies(box) { box.value += 0 })
        #expect(notifies(box) { box.value += 1 })
        #expect(box.value == 6)
    }

    @Test("組・色・文字・真偽・整数も、成分が同じなら知らせない")
    func everyTypeComparesByWhatItShows() {
        let pair = ParamBox<Vector2>(name: "p", value: Vector2(1, 2))
        #expect(!notifies(pair) { pair.value = Vector2(1, 2) })
        #expect(notifies(pair) { pair.value = Vector2(1, 3) })
        let text = ParamBox<String>(name: "t", value: "a")
        #expect(!notifies(text) { text.value = "a" })
        #expect(notifies(text) { text.value = "b" })
        let flag = ParamBox<Bool>(name: "f", value: true)
        #expect(!notifies(flag) { flag.value = true })
        #expect(notifies(flag) { flag.value = false })
        let count = ParamBox<Int>(name: "c", value: 3)
        #expect(!notifies(count) { count.value = 3 })
        #expect(notifies(count) { count.value = 4 })
        let ink = LinearRGBA(straightRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let tint = ParamBox<LinearRGBA>(name: "k", value: ink)
        #expect(!notifies(tint) { tint.value = ink })
        #expect(notifies(tint) { tint.value = LinearRGBA(straightRed: 0.1, green: 0.2, blue: 0.4, alpha: 1) })
    }

    /// 通知しないだけで、値は置く。面に出ない部分 (`note`) や符号 (`-0.0`) を落とさない。
    @Test("通知しなくても値は置く。面に出ない部分と零の符号を落とさない")
    func theValueIsStillStoredWithoutNotifying() {
        let tagged = ParamBox<Tagged>(name: "a", value: Tagged(2, note: "first"))
        #expect(!notifies(tagged) { tagged.value = Tagged(2, note: "second") })
        #expect(tagged.value.note == "second", "同じに見える値で、面に出ない部分を捨てた")

        let zero = ParamBox<Double>(name: "z", value: 0)
        #expect(!notifies(zero) { zero.value = -0.0 })
        #expect(zero.value.sign == .minus)
    }

    @Test("非有限の拒みは変わらない (前の値を保ち、知らせない)")
    func theNonFiniteGateIsUnchanged() {
        let box = ParamBox<Double>(name: "x", value: 5)
        #expect(!notifies(box) { box.value = .nan })
        #expect(box.value == 5)
    }

    // MARK: - 応答と保存

    @Test("同じ値を書き直しても応答の改訂番号は進まず、違う値では進む")
    func theReportRevisionAdvancesOnlyOnChange() throws {
        let sketch = Knobbed()
        let surface = ParamSurface(directory: try makeDirectory(), registry: ParamRegistry(of: sketch))
        surface.start()
        let first = try #require(surface.revision)

        sketch.radius = sketch.radius
        sketch.count = sketch.count
        sketch.tint = sketch.tint
        #expect(surface.drain() == nil, "同じ値の書き直しで公開した")
        #expect(surface.revision == first)

        sketch.radius = min(sketch.radius, 100)  // 値を保つ書き方
        #expect(surface.drain() == nil)
        #expect(surface.revision == first)

        sketch.radius = 90
        let report = try #require(surface.drain(), "変わったのに公開しなかった")
        #expect(report.revision == first + 1)
        #expect(surface.revision == first + 1)
    }

    @Test("外からの書き込みは、同じ値でも応答を書く (届いたと分かる形のまま)")
    func anExternalWriteIsAnsweredEvenIfTheValueIsTheSame() throws {
        let facet = try makeDirectory()
        let sketch = Knobbed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()
        let first = try #require(surface.revision)
        try #"{"id":"s1","values":[{"name":"radius","type":"float","value":80}]}"#.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)

        let report = try #require(surface.drain(), "同じ値の要求に応えなかった")
        #expect(report.id == "s1")
        #expect(report.revision == first + 1)
        #expect(sketch.radius == 80)
    }

    @Test("同じ値の書き直しでは保存を書かない。違う値なら静まってから書く")
    func savingIsNotTriggeredByTheSameValue() async throws {
        let sketch = Knobbed()
        let directory = try makeDirectory()
        let store = ParamStore(
            registry: ParamRegistry(of: sketch), at: directory.appendingPathComponent("params.json"))
        store.restore()  // 見張りはここで張る
        await Task.yield()
        for _ in 0...ParamStore.quietFrames { store.tick() }
        #expect(store.writeCount == 0)

        sketch.radius = sketch.radius
        await Task.yield()
        for _ in 0...ParamStore.quietFrames { store.tick() }
        #expect(store.writeCount == 0, "同じ値の書き直しで保存した")

        sketch.radius = 90
        await Task.yield()
        for _ in 0...ParamStore.quietFrames { store.tick() }
        #expect(store.writeCount == 1)
    }
}
