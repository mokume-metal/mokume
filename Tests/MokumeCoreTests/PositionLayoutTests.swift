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

    @Test("失敗の記憶は、間隔を 1・2・4…と倍にし、上限 600 フレームで止める")
    func rememberedFailureBacksOffUpToTheLimit() {
        let failure = RenderFailure.bufferUnavailable(byteCount: 1)
        var remembered = RememberedFailure(failure, at: 100)
        #expect(remembered.interval == 1)
        #expect(remembered.retryFrame == 101)
        #expect(!remembered.allows(at: 100), "失敗したフレームの中では試さない")
        #expect(remembered.allows(at: 101))
        var intervals = [remembered.interval]
        var frame = remembered.retryFrame
        for _ in 0..<14 {
            remembered = RememberedFailure(failure, at: frame, after: remembered)
            intervals.append(remembered.interval)
            frame = remembered.retryFrame
        }
        #expect(
            intervals == [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 600, 600, 600, 600, 600],
            Comment(rawValue: "\(intervals)"))
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
            position[id * 3 + 2] = values.originZ + values.stepZ * float(id % columns);
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
        /// 奥行き。列ごとに stepZ ずつ奥へずらす (0 なら全部 z = originZ)。
        var originZ: Float = 0
        var stepZ: Float = 0
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
                        y: originY + stepY * Float(id / Int(columns)),
                        z: originZ + stepZ * Float(id % Int(columns))))
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
                "originZ": 0, "stepZ": 0,
            ])
    }

    private func configure(_ computation: Computation, _ grid: Grid) {
        computation.set("columns", .number(grid.columns))
        computation.set("originX", .number(grid.originX))
        computation.set("originY", .number(grid.originY))
        computation.set("stepX", .number(grid.stepX))
        computation.set("stepY", .number(grid.stepY))
        computation.set("turn", .number(grid.turn))
        computation.set("originZ", .number(grid.originZ))
        computation.set("stepZ", .number(grid.stepZ))
        computation.set("nanAt", .number(Float((grid.nanAt ?? -1) + 1)))
        computation.set("infinityAt", .number(Float((grid.infinityAt ?? -1) + 1)))
        computation.set("negativeInfinityAt", .number(Float((grid.negativeInfinityAt ?? -1) + 1)))
        computation.set("nanAlso", .number(Float((grid.nanAlso ?? -1) + 1)))
    }

    /// 計算が位置を書き、その並びで置いた絵。
    private func fromNumbers(
        _ grid: Grid, frames: [Grid]? = nil, size: Float = 20, lit: Bool = true,
        width: Int = 200, height: Int = 300, setup: (Canvas) -> Void = { _ in }
    ) throws -> (picture: PixelBuffer, canvas: Canvas, positions: Numbers) {
        let canvas = try makeCanvas(width: width, height: height)
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
        width: Int = 200, height: Int = 300, setup: (Canvas) -> Void = { _ in }
    ) throws -> PixelBuffer {
        let canvas = try makeCanvas(width: width, height: height)
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
        // **手放す前に次の並びを作る。** 手放した後に作ると、同じ番地を使い回して、畳まなくても置き場が
        // 入れ替わって見える
        let next = try canvas.makeNumbers(count: 9)
        next.set([30, 30, 0, 90, 90, 0, 150, 150, 0])
        kept = nil
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(cube, at: next, layout: .position)
        }
        #expect(canvas.positionLayouts.placerCount == 1, "手放した並びの置き場が残っている")
    }

    // MARK: - 画素の一致を、奥行き・回転・遠近・影・描き場所へ広げる (「同じ位置の [Placement] と画素まで一致」の範囲)

    /// 回して、軸ごとに違う倍率を掛け、遠近のある視点で見る。**GPU の `world * float4(位置, 1)` と
    /// CPU の `transform.matrix * 置き場所.matrix` は演算の順が違う**ので、回転の入った変換で食い違わないかを見る。
    private static let tiltedScene: (Canvas) -> Void = { canvas in
        canvas.perspective(Float.pi / 3, 200.0 / 300.0, 10, 3000)
        canvas.translate(100, 150, 0)
        canvas.rotateY(0.6)
        canvas.rotateX(0.35)
        canvas.rotateZ(0.2)
        canvas.scale(1.5, 0.8, 1.2)
    }

    @Test("奥行き (z) のある位置も、回した変換と遠近のある視点の下で、同じ位置の [Placement] と画素で一致する")
    func depthRotationAndPerspectiveMatch() throws {
        let grid = Grid(
            count: 12, columns: 6, originX: -75, originY: -35, stepX: 30, stepY: 70, originZ: -60,
            stepZ: 25)
        let numbers = try fromNumbers(grid, setup: Self.tiltedScene)
        let placed = try fromPlacements(grid.usable(), setup: Self.tiltedScene)
        let gap = differingPixels(numbers.picture, placed)
        #expect(gap == 0, "奥行きと回転のある絵が \(gap) 画素違う")
        #expect(coveredPixels(placed) > 0, "何も描かれていない (検査の前提)")
        // 検査の前提: 遠近のある視点では、z が絵に効いている
        let flat = try fromPlacements(
            grid.usable().map { Placement(x: $0.x, y: $0.y, z: 0) }, setup: Self.tiltedScene)
        #expect(differingPixels(placed, flat) > 0, "奥行きが絵に効いていない — 検査の前提")
    }

    @Test("球 (法線のある形) も、軸ごとに違う倍率で回した変換の下で、同じ位置の [Placement] と画素で一致する")
    func normalsFollowTheTiltedTransform() throws {
        let grid = Grid(
            count: 6, columns: 3, originX: -50, originY: -30, stepX: 50, stepY: 60, originZ: -30,
            stepZ: 30)
        let canvas = try makeCanvas()
        let sphere = canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 0.5, green: 0.7, blue: 0.9))
            canvas.sphere(18, detail: 12)
        }
        let positions = try canvas.makeNumbers(count: grid.count * 3)
        let computation = try makeGrid(canvas)
        try canvas.draw {
            configure(computation, grid)
            canvas.compute(computation, over: grid.count, writes: [positions])
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            Self.tiltedScene(canvas)
            canvas.shape(sphere, at: positions, layout: .position)
        }
        let numbers = try canvas.target.readPixels()

        let other = try makeCanvas()
        let otherSphere = other.createShape {
            other.noStroke()
            other.fill(.linear(red: 0.5, green: 0.7, blue: 0.9))
            other.sphere(18, detail: 12)
        }
        try other.draw {
            other.background(.linear(red: 0, green: 0, blue: 0))
            other.lights()
            Self.tiltedScene(other)
            other.shape(otherSphere, at: grid.usable())
        }
        let gap = differingPixels(numbers, try other.target.readPixels())
        #expect(gap == 0, "回した変換の下の球が \(gap) 画素違う")
        #expect(coveredPixels(numbers) > 0, "何も描かれていない (検査の前提)")
    }

    /// 影を落とす光と、影を受ける床のある場面。床は落とす側から外す。
    private static let shadowedScene: (Canvas) -> Void = { canvas in
        canvas.camera(64, -24, 170, 64, 14, 0, 0, 1, 0)
        canvas.perspective(Float.pi / 3, 1, 1, 500)
        canvas.ambientLight(.linear(red: 0.15, green: 0.15, blue: 0.15))
        canvas.directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.6, 0.6, -0.5)
        canvas.shadows(true)
        canvas.noStroke()
        canvas.castShadow(false)
        canvas.fill(.linear(red: 0.7, green: 0.7, blue: 0.7))
        canvas.push()
        canvas.translate(64, 40, -20)
        canvas.box(190, 8, 190)
        canvas.pop()
        canvas.castShadow(true)
    }

    @Test("影を落とす・受ける場面でも、同じ位置の [Placement] と画素で一致する")
    func shadowsMatch() throws {
        let grid = Grid(
            count: 3, columns: 3, originX: 34, originY: 8, stepX: 30, stepY: 0, originZ: 0, stepZ: 12)
        let numbers = try fromNumbers(
            grid, lit: false, width: 128, height: 128, setup: Self.shadowedScene)
        let placed = try fromPlacements(
            grid.usable(), lit: false, width: 128, height: 128, setup: Self.shadowedScene)
        let gap = differingPixels(numbers.picture, placed)
        #expect(gap == 0, "影のある絵が \(gap) 画素違う")
        // 検査の前提: 影が絵に効いている (影を切った絵と違う)
        let unshadowed = try fromPlacements(
            grid.usable(), lit: false, width: 128, height: 128,
            setup: { canvas in
                Self.shadowedScene(canvas)
                canvas.shadows(false)
            })
        #expect(differingPixels(placed, unshadowed) > 0, "影が絵に効いていない — 検査の前提")
    }

    @Test("描き場所 (createGraphics) の面でも、同じ位置の [Placement] と画素で一致する")
    func graphicsSurfaceMatches() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(120, 160)
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([30, 40, 0, 80, 110, 10])
        let cube = layer.createShape {
            layer.noStroke()
            layer.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
            layer.box(20)
        }
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            layer.beginDraw()
            layer.background(.linear(red: 0, green: 0, blue: 0))
            layer.lights()
            layer.shape(cube, at: positions, layout: .position)
            layer.endDraw()
        }
        let numbers = try layer.target.readPixels()

        let other = try makeCanvas()
        let flat = try other.createGraphics(120, 160)
        let otherCube = flat.createShape {
            flat.noStroke()
            flat.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
            flat.box(20)
        }
        try other.draw {
            other.background(.linear(red: 0, green: 0, blue: 0))
            flat.beginDraw()
            flat.background(.linear(red: 0, green: 0, blue: 0))
            flat.lights()
            flat.shape(otherCube, at: [Placement(x: 30, y: 40), Placement(x: 80, y: 110, z: 10)])
            flat.endDraw()
        }
        let gap = differingPixels(numbers, try flat.target.readPixels())
        #expect(gap == 0, "描き場所の絵が \(gap) 画素違う")
        #expect(coveredPixels(numbers) > 0, "何も描かれていない (検査の前提)")
        #expect(!layer.warnings.hasWarned(.positionLayoutOutsideFrame))
    }

    // MARK: - 個数 (引数) を、区画をまたぐ数・容量 1・全部が数でない値・段 3 以上で読む

    /// x に番号を書いた `count` 個の位置の並びで置き、描く引数の置いた数と、置き場所の x を読む。
    /// `isBad` が真の番号は x を数でない値にする。
    private func placedCount(
        of count: Int, bad isBad: (Int) -> Bool
    ) throws -> (placed: Int, xs: [Float], expected: [Float], scanCount: Int) {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: count * 3)
        var values = [Float](repeating: 0, count: count * 3)
        var expected: [Float] = []
        for index in 0..<count {
            if isBad(index) {
                values[index * 3] = .nan
            } else {
                values[index * 3] = Float(index)
                expected.append(Float(index))
            }
        }
        positions.set(values)
        let cube = cube(canvas, 1)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(cube, at: positions, layout: .position)
        }
        let placer = try #require(canvas.positionLayouts.existingPlacer(for: positions))
        let draw = placer.draws[0]
        let arguments = canvas.read(draw.arguments)
        let placed = Int(arguments[1].bitPattern)
        let instances = canvas.read(draw.instances)
        let xs = (0..<min(placed, count)).map { instances[$0 * 32 + 12] }
        return (placed, xs, expected, placer.scanCount)
    }

    @Test(
        "置いた数と並びの順が、区画の境・容量 1・段が 3 以上・全部が数でない値でも合う",
        arguments: [
            (1, "none"), (1, "all"), (2, "all"), (255, "fifth"), (256, "fifth"), (257, "fifth"),
            (513, "third"), (1000, "all"), (65_536, "seventh"), (65_537, "seventh"),
            (65_537, "last"),
        ] as [(Int, String)])
    func placedCountAndOrderAcrossScanLevels(count: Int, rule: String) throws {
        let isBad: (Int) -> Bool
        switch rule {
        case "none": isBad = { _ in false }
        case "all": isBad = { _ in true }
        case "fifth": isBad = { $0 % 5 == 2 }
        case "third": isBad = { $0 % 3 == 0 }
        case "seventh": isBad = { $0 % 7 == 5 }
        default: isBad = { $0 == count - 1 }
        }
        let result = try placedCount(of: count, bad: isBad)
        #expect(
            result.placed == result.expected.count,
            "置いた数 \(result.placed) が \(result.expected.count) と違う")
        #expect(result.xs == result.expected, "置き場所が並びの順に詰まっていない")
        let levels = Particles.levelLengths(capacity: count).count - 1
        #expect(result.scanCount == levels)
    }

    // MARK: - 呼んだ順

    @Test("置いた後に同じフレームで並びへ書いても、置いた絵は書く前の値で描かれる")
    func writesAfterPlacingDoNotReachTheEarlierCall() throws {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([60, 100, 0, 140, 200, 0])
        let cube = cube(canvas)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.shape(cube, at: positions, layout: .position)
            positions.set([160, 40, 0, 30, 260, 0])
        }
        let picture = try canvas.target.readPixels()
        let placedBefore = try fromPlacements([Placement(x: 60, y: 100), Placement(x: 140, y: 200)])
        let placedAfter = try fromPlacements([Placement(x: 160, y: 40), Placement(x: 30, y: 260)])
        #expect(differingPixels(picture, placedBefore) == 0, "書く前の値で置かれていない")
        #expect(differingPixels(picture, placedAfter) > 0, "書いた後の値と見分けられない — 検査の前提")
    }

    @Test("置く前に同じフレームで書いた値で置かれる")
    func writesBeforePlacingAreRead() throws {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([60, 100, 0, 140, 200, 0])
        let cube = cube(canvas)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            positions.set([160, 40, 0, 30, 260, 0])
            canvas.shape(cube, at: positions, layout: .position)
        }
        let placed = try fromPlacements([Placement(x: 160, y: 40), Placement(x: 30, y: 260)])
        #expect(differingPixels(try canvas.target.readPixels(), placed) == 0)
    }

    // MARK: - 同じフレームの 2 回の呼び出しが、旗の段と指定を取り違えない

    @Test("同じフレームで、並びを書き換えて数でない値の位置が違う 2 回を置いても、互いの旗を読まない")
    func twoCallsWithDifferentNonFinitePositionsDoNotShareFlags() throws {
        let canvas = try makeCanvas()
        let positions = try canvas.makeNumbers(count: 12)
        let cube = cube(canvas)
        let nan = Float.nan
        // 1 回目: 2 つ目が数でない値。2 回目 (書き換えた後): 3 つ目が数でない値で、段の頭も旗の並びも違う
        let first: [Float] = [30, 50, 0, 60, nan, 0, 90, 50, 0, 150, 50, 0]
        let second: [Float] = [30, 150, 0, 60, 150, 0, nan, 150, 0, 150, 150, 0]
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            positions.set(first)
            canvas.shape(cube, at: positions, layout: .position)
            positions.set(second)
            canvas.shape(cube, at: positions, layout: .position)
        }
        let placed = try fromPlacements([
            Placement(x: 30, y: 50), Placement(x: 90, y: 50), Placement(x: 150, y: 50),
            Placement(x: 30, y: 150), Placement(x: 60, y: 150), Placement(x: 150, y: 150),
        ])
        let picture = try canvas.target.readPixels()
        let gap = differingPixels(picture, placed)
        #expect(gap == 0, "2 回の置きが互いの旗を読んだ (\(gap) 画素違う)")
        #expect(coveredPixels(placed) > 0, "何も描かれていない (検査の前提)")
    }

    // MARK: - 途中の描き切り (#1656) を挟んでも、影が組を読む

    /// 影を落とす立方体を同じ並びで 2 回置く。**途中の描き切りを 2 回の間に挟めば、1 回目の影の焼き付けは
    /// 描き切りの後も 1 回目の組の置き場所を読む** — 2 回目が組を使い回すと、その置き場所を上書きする。
    private func shadowedFrame(cut: Bool, shadows: Bool) throws -> DisplayImage {
        let canvas = try makeCanvas(width: 96, height: 96)
        let cube = cube(canvas, 16)
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([24, 36, 0, 44, 36, 0])
        // 2 枚目を見る (描き切りで落とす側を控えるのは、影を有効にした面だけ)
        for _ in 0..<2 {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.camera(48, -36, 120, 48, 48, 0, 0, 1, 0)
                canvas.lights()
                canvas.shadows(shadows)
                canvas.shape(cube, at: positions, layout: .position)
                if cut { _ = canvas.get(40, 40) }
                // 後の呼び出しは横へずらす。組を使い回すと、前の呼び出しの置き場所がこれで上書きされる
                canvas.push()
                canvas.translate(30, 0, 0)
                canvas.shape(cube, at: positions, layout: .position)
                canvas.pop()
                canvas.castShadow(false)
                canvas.noStroke()
                canvas.fill(.linear(red: 0.8, green: 0.8, blue: 0.8))
                canvas.push()
                canvas.translate(48, 72, 0)
                canvas.box(96, 4, 96)
                canvas.pop()
            }
        }
        return try canvas.output.encodeForDisplay()
    }

    /// 成分の差が表示の 1 段 (1/255) を越える画素の数。
    private func displayDifference(_ a: DisplayImage, _ b: DisplayImage) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let left = a[x, y]
                let right = b[x, y]
                if abs(Int(left.red) - Int(right.red)) > 1 || abs(Int(left.green) - Int(right.green)) > 1
                    || abs(Int(left.blue) - Int(right.blue)) > 1
                {
                    count += 1
                }
            }
        }
        return count
    }

    @Test("途中の描き切りを挟んでも、置き場所の道の影は、分けずに描いた絵と一致する (#1656)")
    func aMidFrameCutKeepsTheShadowsOfThePositionPath() throws {
        let plain = try shadowedFrame(cut: false, shadows: true)
        let cut = try shadowedFrame(cut: true, shadows: true)
        let gap = displayDifference(plain, cut)
        #expect(gap == 0, "描き切りを挟むと影の絵が \(gap) 画素違う")

        // 比べる側が影を持つ: 影を切った絵と比べて、床が暗い
        let unshadowed = try shadowedFrame(cut: false, shadows: false)
        var darker = 0
        for y in 0..<plain.height {
            for x in 0..<plain.width where Int(unshadowed[x, y].red) - Int(plain[x, y].red) > 20 {
                darker += 1
            }
        }
        #expect(darker > 50, "床に影が落ちていない (\(darker) 画素)")
    }

    // MARK: - 置き場を畳む・組み立ての失敗を覚える

    @Test("手放した並びの置き場は、フレームの頭で畳まれる。呼び出しのたびには畳まない")
    func releasedPlacersAreFoldedAtTheFrameStart() throws {
        let canvas = try makeCanvas()
        let cube = cube(canvas)
        var gone: Numbers? = try canvas.makeNumbers(count: 6)
        gone?.set([60, 100, 0, 140, 200, 0])
        let stays = try canvas.makeNumbers(count: 6)
        stays.set([30, 30, 0, 90, 90, 0])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            if let gone { canvas.shape(cube, at: gone, layout: .position) }
            canvas.shape(cube, at: stays, layout: .position)
        }
        #expect(canvas.positionLayouts.placerCount == 2)
        // 手放したフレームの中では、残った並びを置く呼び出しがあっても畳まない
        // (呼び出しごとに置き場の数だけ走査しない)。畳むのは次のフレームの頭
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(cube, at: stays, layout: .position)
            gone = nil
            canvas.shape(cube, at: stays, layout: .position)
            #expect(canvas.positionLayouts.placerCount == 2, "呼び出しが畳んだ")
        }
        try canvas.draw {
            #expect(canvas.positionLayouts.placerCount == 1, "フレームの頭で畳まれていない")
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(cube, at: stays, layout: .position)
        }
        #expect(canvas.positionLayouts.placerCount == 1)
    }

    @Test("最後の呼び出しの後に並びを手放すと、何も置かないフレームを 1 枚描くだけで置き場が畳まれる")
    func releasedPlacerIsFoldedByAFrameThatPlacesNothing() throws {
        let canvas = try makeCanvas()
        let cube = cube(canvas)
        var gone: Numbers? = try canvas.makeNumbers(count: 6)
        gone?.set([60, 100, 0, 140, 200, 0])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            if let gone { canvas.shape(cube, at: gone, layout: .position) }
        }
        #expect(canvas.positionLayouts.placerCount == 1)
        gone = nil
        #expect(canvas.positionLayouts.placerCount == 1, "検査の前提: 手放しただけでは畳まれない")
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
        }
        #expect(canvas.positionLayouts.placerCount == 0, "呼び出しの無いフレームで畳まれていない")
    }

    @Test("置き場を用意できなかった並びを手放すと、失敗の記憶も次のフレームの頭で畳まれる")
    func releasedFailureIsFoldedAtTheFrameStart() throws {
        let canvas = try makeCanvas()
        let cube = cube(canvas)
        var broken: Numbers? = try canvas.makeNumbers(count: 6)
        broken?.set([60, 100, 0, 140, 200, 0])
        canvas.positionLayouts.placerFailureForTesting = .bufferUnavailable(byteCount: 1)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            if let broken { canvas.shape(cube, at: broken, layout: .position) }
        }
        #expect(canvas.positionLayouts.placerFailureCount == 1)
        broken = nil
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
        }
        #expect(canvas.positionLayouts.placerFailureCount == 0, "手放した並びの失敗の記憶が残っている")
    }

    @Test("置き場を用意できなかった並びの失敗は並びごとで、別の並びは置ける")
    func placerFailureIsPerSequence() throws {
        let canvas = try makeCanvas()
        let cube = cube(canvas)
        let broken = try canvas.makeNumbers(count: 6)
        broken.set([60, 100, 0, 140, 200, 0])
        canvas.positionLayouts.placerFailureForTesting = .bufferUnavailable(byteCount: 1)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(cube, at: broken, layout: .position)
        }
        #expect(canvas.positionLayouts.placerBuildAttempts == 1)
        #expect(canvas.warnings.hasWarned(.positionLayoutUnavailable))
        #expect(canvas.positionLayouts.placerCount == 0)

        // 失敗は並びごと: 別の並びは、失敗の差し替えを外せば置ける
        canvas.positionLayouts.placerFailureForTesting = nil
        let other = try canvas.makeNumbers(count: 6)
        other.set([60, 100, 0, 140, 200, 0])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.shape(cube, at: other, layout: .position)
        }
        #expect(canvas.positionLayouts.placerBuildAttempts == 2)
        #expect(canvas.positionLayouts.placerCount == 1)
        #expect(coveredPixels(try canvas.target.readPixels()) > 0)
    }

    /// 組み立ての失敗の種類。
    enum BuildFailure: CaseIterable, CustomTestStringConvertible {
        /// 計算の入口を組めない。
        case kernel
        /// 置き場を確保できない。
        case placer
        /// 組を足せない (同じフレームの 2 回目以降の呼び出し)。
        case drawAllocation

        var testDescription: String { "\(self)" }
    }

    @Test(
        "組み立ての失敗は、間隔を 1・2・4…フレームと延ばしながら試し直し、同じフレームでは試さない。直れば置ける",
        arguments: BuildFailure.allCases)
    func buildFailuresAreRetriedWithGrowingIntervals(kind: BuildFailure) throws {
        let canvas = try makeCanvas(width: 96, height: 96)
        let cube = cube(canvas)
        let positions = try canvas.makeNumbers(count: 6)
        positions.set([30, 30, 0, 60, 60, 0])
        let layouts = canvas.positionLayouts

        // 組を足す失敗は、置き場と最初の組ができてから差し替える
        if kind == .drawAllocation {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.shape(cube, at: positions, layout: .position)
            }
        }
        func attempts() -> Int {
            switch kind {
            case .kernel: layouts.kernelBuildAttempts
            case .placer: layouts.placerBuildAttempts
            case .drawAllocation: layouts.existingPlacer(for: positions)?.drawAllocationAttempts ?? 0
            }
        }
        func inject(_ failure: RenderFailure?) {
            switch kind {
            case .kernel: layouts.kernelFailureForTesting = failure
            case .placer: layouts.placerFailureForTesting = failure
            case .drawAllocation:
                layouts.existingPlacer(for: positions)?.drawAllocationFailureForTesting = failure
            }
        }
        /// 1 フレームに 3 回呼ぶ (同じフレームの 2 回目以降は、試さずに断られる)。試みが増えたフレームを返す。
        func drawFrame(limit: Int) throws -> Int? {
            let frame = canvas.framesDrawn
            let before = attempts()
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                for index in 0..<3 {
                    canvas.push()
                    canvas.translate(Float(index) * 2, 0)
                    canvas.shape(cube, at: positions, layout: .position)
                    canvas.pop()
                }
            }
            let grown = attempts() - before
            #expect(grown <= limit, "同じフレームで \(grown) 回試した")
            return grown > 0 ? frame : nil
        }

        inject(.bufferUnavailable(byteCount: 1))
        var attemptFrames: [Int] = []
        for _ in 0..<20 { if let frame = try drawFrame(limit: 1) { attemptFrames.append(frame) } }
        let gaps = zip(attemptFrames.dropFirst(), attemptFrames).map { $0 - $1 }
        #expect(gaps == [1, 2, 4, 8], Comment(rawValue: "試したフレーム \(attemptFrames)"))
        #expect(canvas.warnings.hasWarned(.positionLayoutUnavailable))
        if kind != .drawAllocation {
            #expect(layouts.placerCount == 0)
            #expect(coveredPixels(try canvas.target.readPixels()) == 0, "失敗したのに描かれた")
        }

        // 直す: 次に試してよいフレームで置ける。その間隔は前の倍 (16)
        inject(nil)
        var recovered: Int?
        // 直った回は、3 回目の呼び出しがもう 1 つ組を足すので、試みが 2 回になりうる
        for _ in 0..<20 where recovered == nil { recovered = try drawFrame(limit: 2) }
        let last = try #require(attemptFrames.last)
        #expect(recovered == last + 16, Comment(rawValue: "直った後の試み \(String(describing: recovered))"))
        // 直った後は毎フレーム置ける (試し直さずに済む)
        let settled = attempts()
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.shape(cube, at: positions, layout: .position)
        }
        #expect(attempts() == settled)
        #expect(layouts.placerCount == 1)
        #expect(layouts.kernels != nil)
        if kind == .drawAllocation {
            #expect((layouts.existingPlacer(for: positions)?.draws.count ?? 0) >= 2)
        }
        #expect(coveredPixels(try canvas.target.readPixels()) > 0, "直ったのに描かれない")
    }

    // MARK: - setup() など、描く外

    final class PlacedInSetup: Sketch {
        var cube: Shape!
        var positions: Numbers!
        var fill: Computation!
        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 64) }
        func setup() throws {
            cube = createShape {
                noStroke()
                box(10)
            }
            positions = try makeNumbers(count: 6)
            fill = try makeComputation(
                "kernel void fill(device float *p [[buffer(0)]], uint id [[thread_position_in_grid]]) "
                    + "{ p[id] = 1.0; }",
                name: "fill")
            // 計算が先に、同じ場面 (描く外) で断られる
            compute(fill, over: 6, writes: [positions])
            shape(cube, at: positions, layout: .position)
        }
        func draw() {}
    }

    @Test("setup() で呼ぶと、この口の名前で 1 度知らせる。計算を頼む口の注意とは別の鍵で言う")
    func outsideTheFrameNamesThisCall() throws {
        let runtime = try SketchRuntime(sketch: PlacedInSetup(), gpu: try RenderDevice())
        try runtime.advance()
        let warnings = runtime.canvas.warnings
        let message = try #require(warnings.message(for: .positionLayoutOutsideFrame))
        #expect(message.hasPrefix("shape(at:layout:)"), Comment(rawValue: message))
        #expect(message.contains("draw()"), Comment(rawValue: message))
        #expect(warnings.hasWarned(.computeOutsideFrame), "検査の前提: 先に計算の口が断られている")
        #expect(runtime.canvas.positionLayouts.placerCount == 0, "断った呼び出しが置き場を作った")
    }

    @Test("フレームの外の注意は、本体の面は draw()、自分でフレームを開く面は beginDraw() と endDraw() と言い分ける")
    func outsideTheFrameNoticeFollowsTheSurface() throws {
        // 本体の面 (setup() の中)
        let runtime = try SketchRuntime(sketch: PlacedInSetup(), gpu: try RenderDevice())
        try runtime.advance()
        let body = try #require(runtime.canvas.warnings.message(for: .positionLayoutOutsideFrame))

        // 自分でフレームを開く面。持ち越しの区間は本体の面だけが立てるので、検査で立てて関所の先へ通す
        let canvas = try makeCanvas()
        canvas.carriesOver = true
        let cube = cube(canvas)
        let positions = try canvas.makeNumbers(count: 6)
        canvas.shape(cube, at: positions, layout: .position)
        let target = try #require(canvas.warnings.message(for: .positionLayoutOutsideFrame))

        #expect(body != target, "本体の面と自分でフレームを開く面で文面が同じ")
        #expect(body.contains("from draw()"), Comment(rawValue: body))
        #expect(!body.contains("inside its draw { }"), Comment(rawValue: body))
        #expect(target.hasPrefix("shape(at:layout:)"), Comment(rawValue: target))
        #expect(target.contains("beginDraw() and endDraw()"), Comment(rawValue: target))
        #expect(target.contains("draw { }"), Comment(rawValue: target))
        #expect(!target.contains("from draw()"), Comment(rawValue: target))
    }
}

/// 数の並びでは置けない形。
enum IneligibleShape: CaseIterable, CustomTestStringConvertible {
    case outlined
    case twoPieces
    case indexed
    case translucent
    case flat
    /// 自分で並べた頂点 (`beginShape`) は巻き方の向きを求めず部品を持たないが、半透明の色なら通してはならない。
    case freeformTranslucent
    /// 同じく部品を持たない形が、重ねる以外の混ぜ方で描く。
    case freeformBlended

    var testDescription: String { "\(self)" }

    /// 注意の文面に入るはずの理由の一部。
    var reason: String {
        switch self {
        case .outlined: "3D outlines"
        case .twoPieces: "2 pieces"
        case .indexed: "by index"
        case .translucent: "back faces first"
        case .flat: "not a 3D solid"
        case .freeformTranslucent, .freeformBlended: "back faces first"
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
        case .freeformTranslucent:
            canvas.createShape {
                canvas.noStroke()
                canvas.fill(204, 153, 102, 128)
                canvas.beginShape(.triangles)
                for point in [(-18, -18), (18, -18), (0, 18)] as [(Float, Float)] {
                    canvas.vertex(point.0, point.1, 0)
                }
                canvas.endShape()
            }
        case .freeformBlended:
            canvas.createShape {
                canvas.noStroke()
                canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
                canvas.blendMode(.add)
                canvas.beginShape(.triangles)
                for point in [(-18, -18), (18, -18), (0, 18)] as [(Float, Float)] {
                    canvas.vertex(point.0, point.1, 0)
                }
                canvas.endShape()
                canvas.blendMode(.blend)
            }
        }
    }
}
