// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 形の組み立て (`createShape { }`) の中で書いた乱数の種は、組み立ての外へ残らない ([#1936])。
///
/// 乱数の列は `Canvas` ではなくランタイムが持つので、`Canvas` の格納を写して戻す出口
/// (``Canvas/Manner``・#1684) には載らなかった。約束は 1 つで、**組み立ての中で書いた種は外へ
/// 残らず、種を書かずに引いた値は、外で引いたのと同じく 1 本の列を進める。**
///
/// 組み立ての入口は 2 つある。スケッチの `createShape` と、描き場所 (`createGraphics` が返す
/// ``Canvas``) の `createShape` で、後者は ``SketchRuntime`` を経ない。描き場所は本体から作る 1 段目
/// だけでなく、**描き場所から作る描き場所** (通知先が 2 段で引き継がれる) もあるので、入れて数える。
/// どれも `setup()` と `draw()` の両方で確かめる。期待する値は、実行の外で ``Randomness`` を直に
/// 引いて作る — 検査の対象と同じ口から期待を作らない。
///
/// [#1936]: https://github.com/mokume-metal/mokume/issues/1936
@Suite(
    "形の組み立ての中の乱数の種",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShapeSeedExitTests {
    /// 形を組み立てる入口。
    nonisolated enum Entrance: CaseIterable, CustomTestStringConvertible, Sendable {
        /// スケッチの `createShape` (``Sketch/createShape(_:)``)
        case sketch
        /// 描き場所の `createShape` (``Canvas/createShape(_:)``)。ランタイムを経ない
        case graphics
        /// **描き場所から作った描き場所**の `createShape`。通知先は本体の面から 2 段で引き継がれる
        /// (``Canvas/createGraphics(_:_:)`` が作った面へ写す 1 行が、親の側でも効いていること)
        case childGraphics

        var testDescription: String {
            switch self {
            case .sketch: "スケッチの createShape"
            case .graphics: "描き場所の createShape"
            case .childGraphics: "描き場所から作った描き場所の createShape"
            }
        }
    }

    /// 組み立てを呼ぶコールバック。
    enum Phase: CaseIterable, CustomTestStringConvertible {
        case setup
        case draw

        var testDescription: String { self == .setup ? "setup()" : "draw()" }
    }

    /// 入れ子の組み立ての、外側と内側の入口の組。
    nonisolated struct Nesting: CustomTestStringConvertible, Sendable {
        let outer: Entrance
        let inner: Entrance

        nonisolated static let all = Entrance.allCases.flatMap { outer in
            Entrance.allCases.map { Nesting(outer: outer, inner: $0) }
        }

        var testDescription: String { "外側 \(outer.testDescription) の中に \(inner.testDescription)" }
    }

    /// 台本を `setup()` か `draw()` の中で 1 度だけ走らせるスケッチ。
    final class Probe: Sketch {
        var settings = SketchSettings(width: 16, height: 16)
        /// 描き場所。`setup()` で作る
        var layer: Canvas?
        /// `layer` から作った描き場所。`setup()` で作る
        var childLayer: Canvas?
        var phase = Phase.draw
        var script: ((Probe) -> Void)?
        /// 走らせているランタイム。ランタイムの状態を読む台本のために、`run` が差す
        weak var runtime: SketchRuntime?

        init() {}

        func setup() {
            layer = try? createGraphics(16, 16)
            childLayer = try? layer?.createGraphics(16, 16)
            if phase == .setup { script?(self) }
        }
        func draw() {
            if phase == .draw { script?(self) }
        }

        /// `entrance` から形を組み立てる。本体は、その入口が描く面を受け取る。
        func build(_ entrance: Entrance, _ body: (Canvas) -> Void) -> Shape {
            switch entrance {
            case .sketch:
                let surface = canvas
                return createShape { body(surface) }
            case .graphics:
                guard let layer else { return .empty }
                return layer.createShape { body(layer) }
            case .childGraphics:
                guard let childLayer else { return .empty }
                return childLayer.createShape { body(childLayer) }
            }
        }
    }

    /// 台本を走らせる。`setup()` と最初の `draw()` が済んだところで返る。
    private func run(_ phase: Phase, _ script: @escaping (Probe) -> Void) throws {
        let probe = Probe()
        probe.phase = phase
        probe.script = script
        let runtime = try SketchRuntime(sketch: probe, gpu: try RenderDevice())
        probe.runtime = runtime
        runtime.start()
        try runtime.advance()
        #expect(probe.layer != nil && probe.childLayer != nil, "描き場所を作れていない")
    }

    /// 種 `seed` の列の `count` 番目 (1 から数える)。実行の外で直に引く。
    private func value(seed: Int, at count: Int) -> Float {
        var line = Randomness(seed: seed)
        var last: Float = 0
        for _ in 0..<count { last = line.unitValue() }
        return last
    }

    /// 形の中身の綴り。位置が違えば綴りも違う。
    private func fingerprint(_ shape: Shape) -> String {
        String(describing: shape.vertices) + String(describing: shape.forms)
    }

    @Test(
        "中で種を書いても、抜けた後の列は書く直前の種から続く (例 1)",
        arguments: Entrance.allCases, Phase.allCases)
    func aSeedWrittenInsideDoesNotLeak(entrance: Entrance, phase: Phase) throws {
        var next: Float = -1
        var shape = Shape.empty
        try run(phase) { probe in
            probe.randomSeed(1)
            shape = probe.build(entrance) { surface in
                probe.randomSeed(42)
                surface.circle(probe.random(100), 50, 10)
            }
            next = probe.random()
        }
        #expect(!shape.isEmpty, "形が組み立てられていない")
        #expect(next == value(seed: 1, at: 1), "外の列が、中で書いた種 42 の列から続いている")
    }

    @Test(
        "種を書かずに中で引いた分は、外の列を進める (例 2)",
        arguments: Entrance.allCases, Phase.allCases)
    func drawingWithoutASeedAdvancesTheOuterLine(entrance: Entrance, phase: Phase) throws {
        var first = Shape.empty
        var second = Shape.empty
        var next: Float = -1
        try run(phase) { probe in
            probe.randomSeed(1)
            first = probe.build(entrance) { $0.circle(probe.random(100), 50, 10) }
            second = probe.build(entrance) { $0.circle(probe.random(100), 50, 10) }
            next = probe.random()
        }
        #expect(!first.isEmpty && !second.isEmpty, "形が組み立てられていない")
        #expect(fingerprint(first) != fingerprint(second), "2 つの形が同じ位置になった (列を戻している)")
        #expect(next == value(seed: 1, at: 3), "中で引いた 2 つぶんが、外の列に数えられていない")
    }

    @Test(
        "種を書く前に中で引いた分は、外の列に数える (例 3)",
        arguments: Entrance.allCases, Phase.allCases)
    func drawsBeforeTheSeedCountInTheOuterLine(entrance: Entrance, phase: Phase) throws {
        var next: Float = -1
        try run(phase) { probe in
            probe.randomSeed(1)
            _ = probe.build(entrance) { _ in
                _ = probe.random()
                probe.randomSeed(42)
                _ = probe.random()
            }
            next = probe.random()
        }
        #expect(next == value(seed: 1, at: 2), "種より前に引いた 1 つぶんが、外の列に数えられていない")
    }

    @Test(
        "中で何度書いても、戻る先は最初に書く直前の列である",
        arguments: Entrance.allCases, Phase.allCases)
    func theLineGoesBackToBeforeTheFirstWrite(entrance: Entrance, phase: Phase) throws {
        var next: Float = -1
        try run(phase) { probe in
            probe.randomSeed(1)
            _ = probe.build(entrance) { _ in
                probe.randomSeed(42)
                _ = probe.random()
                probe.randomSeed(43)
                _ = probe.random()
            }
            next = probe.random()
        }
        #expect(next == value(seed: 1, at: 1), "2 度目に書いた種の途中へ戻っている")
    }

    @Test(
        "入れ子の組み立てで、内側を抜けた直後の列は外側の組み立ての種の続きである",
        arguments: Nesting.all, Phase.allCases)
    func aNestedBuildReturnsToTheOuterBuildsLine(nesting: Nesting, phase: Phase) throws {
        let (outer, inner) = (nesting.outer, nesting.inner)
        var afterInner: Float = -1
        var afterOuter: Float = -1
        try run(phase) { probe in
            probe.randomSeed(1)
            _ = probe.build(outer) { _ in
                probe.randomSeed(7)
                _ = probe.build(inner) { _ in
                    probe.randomSeed(42)
                    _ = probe.random()
                }
                afterInner = probe.random()
            }
            afterOuter = probe.random()
        }
        #expect(afterInner == value(seed: 7, at: 1), "内側を抜けた後が、外側の組み立ての種 7 の列から続いていない")
        #expect(afterOuter == value(seed: 1, at: 1), "外側を抜けた後が、組み立ての前の種 1 の列から続いていない")
    }

    /// ランタイムの「戻す」に分けた状態を**全部汚してから抜け、全部が戻ったかを見る** — `Canvas` の側の
    /// ``ShapeExitTests/everyRestoredStateIsBackAfterTheBuild(insideAFrame:)`` と同じ形で、表
    /// (``ShapeExit/runtimeTable``) に足した状態の戻し落としが黙らない。
    @Test(
        "組み立ての中で汚したランタイムの状態は、出口の直後に組み立て前の値へ戻る (#1936)",
        arguments: Entrance.allCases, Phase.allCases)
    func everyRestoredRuntimeStateIsBackAfterTheBuild(entrance: Entrance, phase: Phase) throws {
        typealias Restored = (name: String, dirty: (any Sketch) -> Void, read: (SketchRuntime) -> String)
        var before: [String: String] = [:]
        var inside: [String: String] = [:]
        var after: [String: String] = [:]
        try run(phase) { probe in
            guard let runtime = probe.runtime else { return }
            let restored = ShapeExit.runtimeTable.compactMap { entry -> Restored? in
                guard case .restore(let dirty, let read) = entry.exit else { return nil }
                return (entry.name, dirty, read)
            }
            func readAll() -> [String: String] {
                Dictionary(uniqueKeysWithValues: restored.map { ($0.name, $0.read(runtime)) })
            }
            probe.randomSeed(1)
            before = readAll()
            _ = probe.build(entrance) { _ in
                for entry in restored { entry.dirty(probe) }
                inside = readAll()
            }
            after = readAll()
        }
        #expect(!before.isEmpty, "戻す状態が表に 1 つも無い")
        for name in before.keys.sorted() {
            #expect(inside[name] != before[name], "\(name) を汚す手順が汚していない (既定のままでは戻ったかを見分けられない)")
            #expect(after[name] == before[name], "\(name) が組み立ての後に組み立て前の値へ戻っていない")
        }
    }

    /// 組み立ての中で描き場所を閉じると形は空になり、出口は途中で抜ける (#1588)。その経路でも
    /// 控えは戻る。戻らないと、積んだ段が残って後の組み立てが入れ子に見える。
    @Test("組み立ての中でフレームが閉じて形が空になっても、列は書く直前へ戻る")
    func theLineIsBackWhenTheBuildIsDrawnOut() throws {
        var next: Float = -1
        var later: Float = -1
        var shape = Shape.empty
        try run(.draw) { probe in
            guard let layer = probe.layer else { return }
            probe.randomSeed(1)
            layer.beginDraw()
            layer.rect(0, 0, 4, 4)
            shape = layer.createShape {
                probe.randomSeed(42)
                layer.rect(0, 0, 4, 4)
                layer.endDraw()
            }
            next = probe.random()
            // 続けて組み立てても、前の組み立ての控えを引きずらない
            _ = probe.createShape { probe.randomSeed(9) }
            later = probe.random()
        }
        #expect(shape.isEmpty, "形が空にならなかった (この検査は出口の途中の抜け道を通っていない)")
        #expect(next == value(seed: 1, at: 1), "空の形を返す経路で、書いた種が外へ残った")
        #expect(later == value(seed: 1, at: 2), "続く組み立ての後で、列が戻っていない")
    }
}
