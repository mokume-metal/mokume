// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 計算が書いた数の並びを置き場所として読み、立体の形を読み戻しなしで置く
/// (`shape(_:at:layout:)`・[#3581])。
///
/// 値の検査は GPU を要さない。絵の検査は、同じ位置の `[Placement]` で置いた絵と画素まで一致することを
/// 比べる (比べる相手の `[Placement]` の道は、区間 1 つの立体なら置き場所を並べるだけの 1 本の道)。
///
/// [#3581]: https://github.com/mokume-metal/mokume/issues/3581
@Suite("数の並びを置き場所として読む (値)")
struct PositionLayoutValueTests {
    @Test("型の名前は Placement.Layout で、この段は .position だけを持つ")
    func layoutHasOnlyPosition() {
        let layout: Placement.Layout = .position
        #expect(layout == .position)
    }
}

@Suite(
    "数の並びを置き場所として読む (絵)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PositionLayoutDrawingTests {
    private func makeCanvas(width: Int = 200, height: Int = 300) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 成分のビットが 1 つでも違う画素の数。
    private func differingPixels(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        guard a.width == b.width, a.height == b.height else { return max(a.width * a.height, 1) }
        var count = 0
        var index = 0
        while index < a.components.count {
            for offset in 0..<4
            where a.components[index + offset].bitPattern != b.components[index + offset].bitPattern {
                count += 1
                break
            }
            index += 4
        }
        return count
    }

    /// 背景でない画素の数。
    private func coveredPixels(_ buffer: PixelBuffer) -> Int {
        var count = 0
        var index = 0
        while index < buffer.components.count {
            if buffer.components[index] > 0 || buffer.components[index + 1] > 0
                || buffer.components[index + 2] > 0
            {
                count += 1
            }
            index += 4
        }
        return count
    }

    private func cube(_ canvas: Canvas, _ size: Float = 20) -> Shape {
        canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
            canvas.box(size)
        }
    }

    /// 格子に位置を並べる計算。`count` 個ぶん、`columns` 列に並べて `turn` だけ右へずらす。
    /// `bad` に挙げた番号は数でない値・無限にする (0: 何もしない・NaN は y・無限は x・負の無限は z)。
    private static let grid = """
        kernel void grid(device float *position [[buffer(0)]],
                         constant Values &values [[buffer(MOKUME_VALUES)]],
                         uint id [[thread_position_in_grid]])
        {
            uint columns = uint(values.columns);
            position[id * 3] = values.originX + values.stepX * float(id % columns) + values.turn;
            position[id * 3 + 1] = values.originY + values.stepY * float(id / columns);
            position[id * 3 + 2] = 0.0;
            if (uint(values.nanAt) == id + 1u) { position[id * 3 + 1] = as_type<float>(0x7fc00000u); }
            if (uint(values.infinityAt) == id + 1u) { position[id * 3] = as_type<float>(0x7f800000u); }
            if (uint(values.negativeInfinityAt) == id + 1u) {
                position[id * 3 + 2] = as_type<float>(0xff800000u);
            }
            if (uint(values.nanAlso) == id + 1u) { position[id * 3] = as_type<float>(0x7fc00000u); }
        }
        """

    private struct Grid {
        var count = 12
        var columns: Float = 6
        var originX: Float = 25
        var originY: Float = 60
        var stepX: Float = 30
        var stepY: Float = 70
        var turn: Float = 0
        /// 数でない値・無限にする番号 (0 起点)。無ければ nil。
        var nanAt: Int?
        var infinityAt: Int?
        var negativeInfinityAt: Int?
        var nanAlso: Int?

        /// 数でない値にしない位置。CPU が `[Placement]` で置くときの元。
        func usable() -> [Placement] {
            let bad = Set([nanAt, infinityAt, negativeInfinityAt, nanAlso].compactMap { $0 })
            var placements: [Placement] = []
            for id in 0..<count where !bad.contains(id) {
                placements.append(
                    Placement(
                        x: originX + stepX * Float(id % Int(columns)) + turn,
                        y: originY + stepY * Float(id / Int(columns))))
            }
            return placements
        }
    }

    private func makeGrid(_ canvas: Canvas) throws -> Computation {
        try canvas.makeComputation(
            Self.grid, name: "grid",
            values: [
                "columns": 6, "originX": 25, "originY": 60, "stepX": 30, "stepY": 70, "turn": 0,
                "nanAt": 0, "infinityAt": 0, "negativeInfinityAt": 0, "nanAlso": 0,
            ])
    }

    private func configure(_ computation: Computation, _ grid: Grid) {
        computation.set("columns", .number(grid.columns))
        computation.set("originX", .number(grid.originX))
        computation.set("originY", .number(grid.originY))
        computation.set("stepX", .number(grid.stepX))
        computation.set("stepY", .number(grid.stepY))
        computation.set("turn", .number(grid.turn))
        computation.set("nanAt", .number(Float((grid.nanAt ?? -1) + 1)))
        computation.set("infinityAt", .number(Float((grid.infinityAt ?? -1) + 1)))
        computation.set("negativeInfinityAt", .number(Float((grid.negativeInfinityAt ?? -1) + 1)))
        computation.set("nanAlso", .number(Float((grid.nanAlso ?? -1) + 1)))
    }

    /// 計算が位置を書き、その並びで置いた絵。
    private func fromNumbers(
        _ grid: Grid, frames: [Grid]? = nil, size: Float = 20, lit: Bool = true,
        setup: (Canvas) -> Void = { _ in }
    ) throws -> (picture: PixelBuffer, canvas: Canvas, positions: Numbers) {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: grid.count * 3)
        let computation = try makeGrid(canvas)
        let cube = cube(canvas, size)
        for frame in frames ?? [grid] {
            try canvas.draw {
                configure(computation, frame)
                canvas.compute(computation, over: frame.count, writes: [positions])
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                if lit { canvas.lights() }
                setup(canvas)
                canvas.shape(cube, at: positions, layout: .position)
            }
        }
        return (try canvas.target.readPixels(), canvas, positions)
    }

    /// 同じ位置を `[Placement]` で置いた絵。
    private func fromPlacements(
        _ placements: [Placement], size: Float = 20, lit: Bool = true,
        setup: (Canvas) -> Void = { _ in }
    ) throws -> PixelBuffer {
        let canvas = try makeCanvas()
        let cube = cube(canvas, size)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            if lit { canvas.lights() }
            setup(canvas)
            canvas.shape(cube, at: placements)
        }
        return try canvas.target.readPixels()
    }

    // MARK: - 条件 1: 同じ位置の [Placement] と画素で一致する

    @Test("計算が書いた位置で置いた絵は、同じ位置の [Placement] で置いた絵と画素で一致する")
    func matchesPlacements() throws {
        let grid = Grid()
        let numbers = try fromNumbers(grid)
        let placed = try fromPlacements(grid.usable())
        let gap = differingPixels(numbers.picture, placed)
        #expect(gap == 0, "数の並びで置いた絵が [Placement] の絵と \(gap) 画素違う")
        #expect(coveredPixels(placed) > 0, "何も描かれていない (検査の前提)")
    }

    @Test("いまの変換 (移動と一様の倍率) も、同じ位置の [Placement] と同じように効く")
    func appliesTheCurrentTransform() throws {
        let grid = Grid(count: 6, columns: 3, originX: 10, originY: 15, stepX: 20, stepY: 30)
        let setup: (Canvas) -> Void = { canvas in
            canvas.translate(20, 40)
            canvas.scale(2, 2, 2)
        }
        let numbers = try fromNumbers(grid, size: 12, setup: setup)
        let placed = try fromPlacements(grid.usable(), size: 12, setup: setup)
        let gap = differingPixels(numbers.picture, placed)
        #expect(gap == 0, "変換を掛けた絵が \(gap) 画素違う")
        #expect(coveredPixels(placed) > 0, "何も描かれていない (検査の前提)")
    }

    @Test("画面の変換が形を鏡映していても、同じ位置の [Placement] と画素で一致する")
    func mirroredTransformMatches() throws {
        let grid = Grid(count: 6, columns: 3, originX: 20, originY: 40, stepX: 25, stepY: 50)
        let setup: (Canvas) -> Void = { canvas in
            canvas.translate(190, 0)
            canvas.scale(-1, 1, 1)
        }
        let numbers = try fromNumbers(grid, size: 14, setup: setup)
        let placed = try fromPlacements(grid.usable(), size: 14, setup: setup)
        let gap = differingPixels(numbers.picture, placed)
        #expect(gap == 0, "鏡映した変換の絵が \(gap) 画素違う")
        #expect(coveredPixels(placed) > 0, "何も描かれていない (検査の前提)")
    }

    @Test("鏡映する変換では列が鏡映の符号を持ち、鏡映しない変換では持たない (巻き方の表が列ごとに 1 つのため)")
    func batchCarriesTheMirrorSign() throws {
        // 画素では見えない: 保持した形は裏面を捨てずに描くので、巻き方の表を取り違えても絵は変わらない。
        // 列が持つ符号そのものを、描き切る前に見る
        for (mirrored, flip) in [(true, Float(-1)), (false, Float(1))] {
            let canvas = try makeCanvas()
            let positions = try canvas.makeNumbers(count: 3)
            positions.set([60, 100, 0])
            let cube = cube(canvas)
            var batch: Canvas.Batch?
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.translate(190, 0)
                canvas.scale(flip, 1, 1)
                canvas.shape(cube, at: positions, layout: .position)
                batch = canvas.batches.last
            }
            let found = try #require(batch, "列が開いていない")
            #expect(found.isMirrored == mirrored)
            // 描く個数は GPU が書いた引数から読む列である
            #expect(found.indirectArguments != nil)
            #expect(found.instances != nil)
        }
    }

    @Test("球 (法線のある形) も、同じ位置の [Placement] と画素で一致する")
    func sphereMatches() throws {
        let canvas = try makeCanvas()
        let sphere = canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 0.5, green: 0.7, blue: 0.9))
            canvas.sphere(14, detail: 12)
        }
        let grid = Grid(count: 6, columns: 3, originX: 40, originY: 60, stepX: 50, stepY: 90)
        let positions = try canvas.makeNumbers(count: grid.count * 3)
        let computation = try makeGrid(canvas)
        try canvas.draw {
            configure(computation, grid)
            canvas.compute(computation, over: grid.count, writes: [positions])
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.shape(sphere, at: positions, layout: .position)
        }
        let numbers = try canvas.target.readPixels()

        let other = try makeCanvas()
        let otherSphere = other.createShape {
            other.noStroke()
            other.fill(.linear(red: 0.5, green: 0.7, blue: 0.9))
            other.sphere(14, detail: 12)
        }
        try other.draw {
            other.background(.linear(red: 0, green: 0, blue: 0))
            other.lights()
            other.shape(otherSphere, at: grid.usable())
        }
        let gap = differingPixels(numbers, try other.target.readPixels())
        #expect(gap == 0, "球を数の並びで置いた絵が \(gap) 画素違う")
    }

    // MARK: - 条件 2: 数でない値・無限を含む 1 つは描かれず、残りは並びの順

    @Test("数でない値・無限を含む位置は描かれず、ほかは同じ位置の [Placement] と画素で一致する")
    func nonFinitePositionsAreSkipped() throws {
        let grid = Grid(count: 12, nanAt: 2, infinityAt: 5, negativeInfinityAt: 7)
        let numbers = try fromNumbers(grid)
        let placed = try fromPlacements(grid.usable())
        #expect(grid.usable().count == 9, "検査の前提: 3 つが外れる")
        let gap = differingPixels(numbers.picture, placed)
        #expect(gap == 0, "数でない位置を外した絵が \(gap) 画素違う")
        #expect(coveredPixels(placed) > 0, "何も描かれていない (検査の前提)")
    }

    @Test("外した後も、残りは並びの順に詰まる (置き場所の先頭から)")
    func remainingPositionsKeepTheirOrder() throws {
        let grid = Grid(count: 12, nanAt: 2, infinityAt: 5, negativeInfinityAt: 7)
        let numbers = try fromNumbers(grid)
        let placer = try #require(numbers.canvas.positionLayouts.existingPlacer(for: numbers.positions))
        let draw = placer.draws[0]
        let instances = numbers.canvas.read(draw.instances)
        let counts = numbers.canvas.read(draw.arguments)
        // 描く引数: [頂点の数, 置いた数, 0, 0]
        #expect(counts[1].bitPattern == 9, "置いた数が 9 ではない: \(counts[1].bitPattern)")
        let expected = grid.usable()
        for (slot, placement) in expected.enumerated() {
            // 置き場所の 32 個の並びの、行列の 4 列目 (12…15) が位置
            let base = slot * 32
            #expect(instances[base + 12] == placement.x, "\(slot) 番目の x が並びの順ではない")
            #expect(instances[base + 13] == placement.y, "\(slot) 番目の y が並びの順ではない")
        }
    }

    @Test("256 を超える並びでも、scan が区画をまたいで数えて、外した位置を除いて詰まる")
    func skipsAcrossScanBlocks() throws {
        // 1000 個 (段が 3 つ) を 36 列に並べる。区画をまたぐ番号 (255・256・600・999) を外す
        let grid = Grid(
            count: 1000, columns: 36, originX: 4, originY: 4, stepX: 5, stepY: 6, nanAt: 255,
            infinityAt: 256, negativeInfinityAt: 600, nanAlso: 999)
        let numbers = try fromNumbers(grid, size: 3, lit: false)
        let placed = try fromPlacements(grid.usable(), size: 3, lit: false)
        let gap = differingPixels(numbers.picture, placed)
        #expect(gap == 0, "1000 個の絵が \(gap) 画素違う")
        let placer = try #require(numbers.canvas.positionLayouts.existingPlacer(for: numbers.positions))
        #expect(placer.scanCount == 2, "段が 3 つになっていない — 検査の前提")
        #expect(coveredPixels(placed) > 0, "何も描かれていない (検査の前提)")
    }

    // MARK: - 条件 3: CPU が待たず、同じフレームの値で置く

    @Test("毎フレーム位置が変わる計算でも読み戻さず、描いた絵はそのフレームの値で置いたものと一致する")
    func followsTheComputationWithoutReadingBack() throws {
        // 4 フレーム回す。位置は 1 フレームごとに右へ 6 動く。絵は最後のフレームの値で置いた絵と一致する
        // (前のフレームの値で置くと、6 ずれて一致しない)
        var frames: [Grid] = []
        for frame in 0..<4 {
            frames.append(Grid(turn: Float(frame) * 6))
        }
        let numbers = try fromNumbers(frames[0], frames: frames)
        let placed = try fromPlacements(frames[3].usable())
        let gap = differingPixels(numbers.picture, placed)
        #expect(gap == 0, "最後のフレームの絵が、そのフレームの値で置いた絵と \(gap) 画素違う")
        #expect(numbers.positions.readbackAllocations == 0, "位置の並びを読み戻している")

        let stale = try fromPlacements(frames[2].usable())
        #expect(differingPixels(numbers.picture, stale) > 0, "前のフレームの値と見分けられない — 検査の前提")
    }

    @Test("CPU が書いた位置の並びも、同じように置ける")
    func placesNumbersWrittenByTheCPU() throws {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([60, 100, 0, 140, 200, 0])
        let cube = cube(canvas)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.shape(cube, at: positions, layout: .position)
        }
        let picture = try canvas.target.readPixels()
        let placed = try fromPlacements([Placement(x: 60, y: 100), Placement(x: 140, y: 200)])
        #expect(differingPixels(picture, placed) == 0)
        #expect(coveredPixels(picture) > 0, "何も描かれていない (検査の前提)")
    }

    // MARK: - 条件 4: 載らない形は描かれず、1 度知らせる

    @Test("載らない形は描かれず、理由つきで 1 度だけ知らせる", arguments: IneligibleShape.allCases)
    func ineligibleShapesAreRefused(_ kind: IneligibleShape) throws {
        let canvas = try makeCanvas()
        let shape = kind.build(canvas)
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([60, 100, 0, 140, 200, 0])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.shape(shape, at: positions, layout: .position)
            canvas.shape(shape, at: positions, layout: .position)
        }
        let picture = try canvas.target.readPixels()
        #expect(coveredPixels(picture) == 0, "\(kind) が描かれた")
        let message = try #require(
            canvas.warnings.message(for: .positionLayoutShape), "\(kind) を断る注意が出ていない")
        #expect(message.contains(kind.reason), "\(kind) の理由 (\(kind.reason)) が文面に無い: \(message)")
    }

    @Test("立体の線を持たない不透明な cone と box は載る")
    func eligibleShapesAreAccepted() throws {
        let canvas = try makeCanvas()
        let cone = canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 0.4, green: 0.8, blue: 0.5))
            canvas.cone(10, 24)
        }
        let box = cube(canvas)
        for shape in [cone, box] {
            guard case .placeable = Canvas.positionLayoutEligibility(of: shape) else {
                Issue.record("載るはずの形が断られた")
                continue
            }
        }
    }

    // MARK: - 条件 5: 3 で割り切れない長さ

    @Test("3 で割り切れない長さは、count / 3 個だけ置き、端数を 1 度知らせる")
    func remainderIsDroppedAndReported() throws {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: 8)
        positions.set([60, 100, 0, 140, 200, 0, 99, 99])
        let cube = cube(canvas)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.shape(cube, at: positions, layout: .position)
            canvas.shape(cube, at: positions, layout: .position)
        }
        let picture = try canvas.target.readPixels()
        let placed = try fromPlacements([Placement(x: 60, y: 100), Placement(x: 140, y: 200)])
        #expect(differingPixels(picture, placed) == 0, "切り捨てた個数で置いた絵と違う")
        #expect(canvas.warnings.hasWarned(.positionLayoutRemainder))
    }

    @Test("3 個に満たない並びは何も置かず、端数を知らせる")
    func fewerThanOnePositionPlacesNothing() throws {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: 2)
        positions.set([60, 100])
        let cube = cube(canvas)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.shape(cube, at: positions, layout: .position)
        }
        #expect(coveredPixels(try canvas.target.readPixels()) == 0)
        #expect(canvas.warnings.hasWarned(.positionLayoutRemainder))
    }

    // MARK: - 条件 6: createShape の中

    @Test("createShape { } の中で呼ぶと、描かれず形にも入らず、1 度知らせる")
    func insideCreateShapeIsRefused() throws {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([60, 100, 0, 140, 200, 0])
        let cube = cube(canvas)
        var built = Shape.empty
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            built = canvas.createShape {
                canvas.shape(cube, at: positions, layout: .position)
                canvas.shape(cube, at: positions, layout: .position)
            }
        }
        #expect(built.isEmpty, "組み立ての中の呼び出しが形に入った")
        #expect(coveredPixels(try canvas.target.readPixels()) == 0, "組み立ての中の呼び出しが描かれた")
        #expect(
            canvas.warnings.message(for: .positionLayoutInsideShape)
                == Canvas.InsideShape.positionLayout.notice)
        #expect(canvas.positionLayouts.placerCount == 0, "断った呼び出しが置き場を作った")
    }

    // MARK: - 組の分離と常駐

    @Test("同じフレームで同じ並びを 2 度置くと、呼び出しごとの置き場所で描かれ、次のフレームは組を使い回す")
    func twoCallsInOneFrameUseSeparateDraws() throws {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([40, 60, 0, 60, 200, 0])
        let cube = cube(canvas)
        for _ in 0..<3 {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.shape(cube, at: positions, layout: .position)
                canvas.push()
                canvas.translate(100, 0)
                canvas.shape(cube, at: positions, layout: .position)
                canvas.pop()
            }
        }
        let picture = try canvas.target.readPixels()
        let placed = try fromPlacements([
            Placement(x: 40, y: 60), Placement(x: 60, y: 200), Placement(x: 140, y: 60),
            Placement(x: 160, y: 200),
        ])
        #expect(differingPixels(picture, placed) == 0, "2 回の呼び出しの絵が 1 回ずつの絵と違う")
        let placer = try #require(canvas.positionLayouts.existingPlacer(for: positions))
        #expect(placer.draws.count == 2, "組が 2 つになっていない: \(placer.draws.count)")
        #expect(canvas.positionLayouts.placerCount == 1)
    }

    @Test("組を足せなかった呼び出しは描かれず、1 度知らせる。先に取れた呼び出しは描かれる")
    func unavailableDrawIsReportedAndSkipped() throws {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([60, 100, 0, 140, 200, 0])
        let cube = cube(canvas)
        // 1 回目で置き場を作り、2 回目が組を足すところで失敗させる
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.shape(cube, at: positions, layout: .position)
            let placer = canvas.positionLayouts.existingPlacer(for: positions)
            placer?.drawAllocationFailureForTesting = .bufferUnavailable(byteCount: 1)
            canvas.push()
            canvas.translate(100, 0)
            canvas.shape(cube, at: positions, layout: .position)
            canvas.pop()
        }
        let picture = try canvas.target.readPixels()
        let placed = try fromPlacements([Placement(x: 60, y: 100), Placement(x: 140, y: 200)])
        #expect(differingPixels(picture, placed) == 0, "失敗した呼び出しが描かれたか、先の呼び出しが消えた")
        #expect(canvas.warnings.hasWarned(.positionLayoutUnavailable))
    }

    @Test("置き場は並びごとに 1 つで、並びを手放すと次に置き場を作るときに畳まれる")
    func placersFollowTheirNumbers() throws {
        let canvas = try makeCanvas()
        let cube = cube(canvas)
        var kept: Numbers? = try canvas.makeNumbers(count: 6)
        kept?.set([60, 100, 0, 140, 200, 0])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            if let kept { canvas.shape(cube, at: kept, layout: .position) }
        }
        #expect(canvas.positionLayouts.placerCount == 1)
        kept = nil
        let next = try canvas.makeNumbers(count: 9)
        next.set([30, 30, 0, 90, 90, 0, 150, 150, 0])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(cube, at: next, layout: .position)
        }
        #expect(canvas.positionLayouts.placerCount == 1, "手放した並びの置き場が残っている")
    }
}

/// 数の並びでは置けない形。
enum IneligibleShape: CaseIterable, CustomTestStringConvertible {
    case outlined
    case twoPieces
    case indexed
    case translucent
    case flat

    var testDescription: String { "\(self)" }

    /// 注意の文面に入るはずの理由の一部。
    var reason: String {
        switch self {
        case .outlined: "3D outlines"
        case .twoPieces: "2 pieces"
        case .indexed: "by index"
        case .translucent: "back faces first"
        case .flat: "not a 3D solid"
        }
    }

    func build(_ canvas: Canvas) -> Shape {
        switch self {
        case .outlined:
            // 線は既定で有効で、箱の縁が形に焼き付く
            canvas.createShape {
                canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
                canvas.box(20)
            }
        case .twoPieces:
            canvas.createShape {
                canvas.noStroke()
                canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
                canvas.box(20)
                canvas.blendMode(.add)
                canvas.translate(14, 0, 0)
                canvas.box(12)
                canvas.blendMode(.blend)
            }
        case .indexed:
            canvas.createShape {
                canvas.noStroke()
                canvas.fill(.linear(red: 0.9, green: 0.4, blue: 0.2))
                canvas.beginShape(.triangles)
                for point in [(-18, -18), (18, -18), (-18, 18), (18, 18)] as [(Float, Float)] {
                    canvas.vertex(point.0, point.1, 0)
                }
                for number in [0, 1, 2, 1, 3, 2] { canvas.index(number) }
                canvas.endShape()
            }
        case .translucent:
            canvas.createShape {
                canvas.noStroke()
                canvas.fill(204, 153, 102, 128)
                canvas.box(20)
            }
        case .flat:
            canvas.createShape {
                canvas.noStroke()
                canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
                canvas.rect(-10, -10, 20, 20)
            }
        }
    }
}
