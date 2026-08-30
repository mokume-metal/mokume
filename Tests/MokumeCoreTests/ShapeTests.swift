// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 保持した形の検査。GPU を要する。
@Suite(
    "保持した形",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShapeTests {
    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    private func makeDot(_ canvas: Canvas, _ color: LinearRGBA) -> Shape {
        canvas.createShape {
            canvas.noStroke()
            canvas.fill(color)
            canvas.rect(0, 0, 4, 4)
        }
    }

    // MARK: - 畳まれていること

    /// 完了条件「組にした形が 1 度の描画に畳まれる」。
    ///
    /// **絵ではなく描画の呼び出し回数で見る。** 子を 1 つずつ描く実装でも絵は同じに
    /// なるので、絵を見ても畳まれているかは判定できない。
    @Test("組にした形は、何個入っていても 1 度の描画で出る")
    func aGroupCollapsesIntoASingleDrawCall() throws {
        let canvas = try makeCanvas()
        let group = Shape.group((0..<500).map { _ in makeDot(canvas, .opaque(red: 1, green: 0, blue: 0)) })

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.shape(group, 8, 8)
        }
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(group.vertexCount == 500 * 6)
    }

    @Test("組にしても、区切りの数は増えない")
    func groupingDoesNotAddRuns() throws {
        let canvas = try makeCanvas()
        let one = makeDot(canvas, .opaque(red: 1, green: 0, blue: 0))
        #expect(one.drawCallCount == 1)
        #expect(Shape.group([one, one, one]).drawCallCount == 1)
        #expect((one + one).drawCallCount == 1)
    }

    @Test("続けて置いた形どうしも、同じ 1 度の描画に並ぶ")
    func consecutiveShapesShareTheSameDrawCall() throws {
        let canvas = try makeCanvas()
        let dot = makeDot(canvas, .opaque(red: 0, green: 1, blue: 0))

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            for index in 0..<10 { canvas.shape(dot, Float(index) * 5, 8) }
        }
        #expect(canvas.drawCallsInLastFrame == 1)
    }

    /// 完了条件「大量の要素で、毎フレーム組み立てるより速い」。
    ///
    /// **数字そのものは環境に依るので、倍率にだけ条件を置く。** 保持の意味は
    /// 「組み立て直さずに済む」ことなので、ここが逆転していたら道具として成立しない。
    ///
    /// **最適化した実行ファイルでしか測らない。** 検査用の実行ファイルは既定では
    /// 最適化されておらず、そこで測ると再生側の行列計算が関数呼び出しのまま残り、
    /// 組み立て側との差が実際と逆に出る (実測: 最適化なしで 62ms 対 53ms、
    /// 最適化ありで逆転)。**速さの主張は最適化した実行ファイルについてのもの**なので、
    /// 測れない構成では測らずに、測っていないことを出力へ出す。
    @Test(
        "大量の要素では、毎フレーム組み立てるより速い",
        .enabled(if: !isDebugBuild, "最適化していない実行ファイルでは速さを測らない"))
    func replayingBeatsRebuildingForManyElements() throws {
        let canvas = try makeCanvas(width: 256, height: 256)
        let count = 4000

        func build(on canvas: Canvas) {
            canvas.noStroke()
            for index in 0..<count {
                canvas.fill(.opaque(red: 1, green: 0, blue: 0))
                canvas.circle(Float(index % 250) + 3, Float(index / 250) + 3, 5)
            }
        }

        let retained = canvas.createShape { build(on: canvas) }

        // 温める。1 回目には確保のぶんが混ざる
        for _ in 0..<3 {
            try canvas.draw { build(on: canvas) }
            try canvas.draw { canvas.shape(retained) }
        }

        let rebuilt = try measure { try canvas.draw { build(on: canvas) } }
        let replayed = try measure { try canvas.draw { canvas.shape(retained) } }

        #expect(
            replayed * 2 < rebuilt,
            "保持した形の再生 \(replayed * 1000)ms が、組み立て直し \(rebuilt * 1000)ms の半分未満に収まらない")
    }

    private func measure(_ body: () throws -> Void) rethrows -> Double {
        var best = Double.infinity
        for _ in 0..<5 {
            let started = Date()
            try body()
            best = min(best, Date().timeIntervalSince(started))
        }
        return best
    }

    // MARK: - 焼き付いた色

    /// 完了条件「保持した形が、周囲のスタイル変更に影響されない」。
    @Test("置くときに塗りを変えても、形の色は変わらない")
    func ambientFillDoesNotReachARetainedShape() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let dot = canvas.createShape {
            canvas.noStroke()
            canvas.fill(.opaque(red: 1, green: 0, blue: 0))
            canvas.rect(0, 0, 16, 16)
        }

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.fill(.opaque(red: 0, green: 0, blue: 1))
            canvas.shape(dot)
        }
        #expect(canvas.get(8, 8) == .opaque(red: 1, green: 0, blue: 0))
    }

    @Test("置くときに輪郭を止めても、形の輪郭は出る")
    func ambientNoStrokeDoesNotReachARetainedShape() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        let outlined = canvas.createShape {
            canvas.noFill()
            canvas.stroke(.opaque(red: 0, green: 1, blue: 0))
            canvas.strokeWeight(4)
            canvas.rect(8, 8, 16, 16)
        }

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shape(outlined)
        }
        #expect(canvas.get(8, 8).green > 0.5)
    }

    // MARK: - 記録が外へ漏れないこと

    @Test("組み立ての間に触ったスタイルは、外へ残らない")
    func buildingDoesNotLeakStyle() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.opaque(red: 0, green: 0, blue: 1))
            _ = canvas.createShape {
                canvas.fill(.opaque(red: 1, green: 0, blue: 0))
                canvas.blendMode(.add)
                canvas.rect(0, 0, 4, 4)
            }
            // 組み立ての中で変えた塗りと混ぜ方が残っていれば、ここが赤くなる
            canvas.rect(0, 0, 16, 16)
        }
        #expect(canvas.get(8, 8) == .opaque(red: 0, green: 0, blue: 1))
    }

    @Test("組み立てたぶんが、そのフレームの絵に紛れ込まない")
    func buildingDoesNotDrawByItself() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            _ = canvas.createShape {
                canvas.noStroke()
                canvas.fill(.opaque(red: 1, green: 0, blue: 0))
                canvas.rect(0, 0, 16, 16)
            }
        }
        #expect(canvas.get(8, 8) == .opaque(red: 0, green: 0, blue: 0))
    }

    @Test("どこで組み立てても、同じ形になる")
    func theBuildingPlaceDoesNotChangeTheShape() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        var here = Shape.empty
        var moved = Shape.empty
        try canvas.draw {
            here = makeDot(canvas, .opaque(red: 1, green: 0, blue: 0))
            canvas.push()
            canvas.translate(17, 9)
            canvas.rotate(0.7)
            moved = makeDot(canvas, .opaque(red: 1, green: 0, blue: 0))
            canvas.pop()
        }
        #expect(here.vertices.map(\.position) == moved.vertices.map(\.position))
    }

    /// **形が持つ混ぜ方で描かれる。** 状態を戻すときに列を閉じないと、形の頂点が
    /// 戻したあとの混ぜ方で描かれる。
    @Test("形は、自分が持っている混ぜ方で描かれる")
    func aShapeIsDrawnWithItsOwnBlendMode() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let adding = canvas.createShape {
            canvas.noStroke()
            canvas.blendMode(.add)
            canvas.fill(.opaque(red: 0.25, green: 0, blue: 0))
            canvas.rect(0, 0, 16, 16)
        }

        try canvas.draw {
            canvas.background(.opaque(red: 0.5, green: 0, blue: 0))
            canvas.blendMode(.blend)
            canvas.shape(adding)
        }
        // 足し合わせなら 0.75。置き換えなら 0.25 になる
        #expect(canvas.get(8, 8).red == 0.75)
    }

    @Test("形が持ち込んだ混ぜ方は、置いたあとに残らない")
    func aShapeDoesNotLeakItsBlendMode() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let adding = canvas.createShape {
            canvas.noStroke()
            canvas.blendMode(.add)
            canvas.fill(.opaque(red: 0.5, green: 0, blue: 0))
            canvas.rect(0, 0, 8, 8)
        }

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shape(adding)
            // 混ぜ方が残っていれば、下地の赤に足されて 1.0 を超える
            canvas.fill(.opaque(red: 0.5, green: 0, blue: 0))
            canvas.rect(0, 8, 8, 8)
        }
        #expect(canvas.get(4, 12).red == 0.5)
    }

    // MARK: - 置き方

    @Test("置いた場所に出る")
    func aShapeLandsWhereItIsPlaced() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        let dot = makeDot(canvas, .opaque(red: 1, green: 0, blue: 0))

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.shape(dot, 20, 12)
        }
        #expect(canvas.get(22, 14) == .opaque(red: 1, green: 0, blue: 0))
        #expect(canvas.get(2, 2) == .opaque(red: 0, green: 0, blue: 0))
    }

    @Test("置くときの変換が効く")
    func theAmbientTransformApplies() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        let dot = makeDot(canvas, .opaque(red: 1, green: 0, blue: 0))

        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.push()
            canvas.translate(20, 12)
            canvas.shape(dot)
            canvas.pop()
        }
        #expect(canvas.get(22, 14) == .opaque(red: 1, green: 0, blue: 0))
    }

    @Test("保持した形の絵は、その場で描いた絵と一致する")
    func retainedAndImmediateDrawTheSamePicture() throws {
        func paint(_ canvas: Canvas) {
            canvas.stroke(.opaque(red: 0.2, green: 0.9, blue: 1))
            canvas.strokeWeight(3)
            canvas.fill(.opaque(red: 0.95, green: 0.4, blue: 0.2))
            canvas.beginShape()
            canvas.vertex(6, 6)
            canvas.vertex(26, 10)
            canvas.bezierVertex(30, 20, 20, 28, 8, 26)
            canvas.endShape(.close)
        }

        let immediate = try makeCanvas(width: 32, height: 32)
        try immediate.draw {
            immediate.background(.opaque(red: 0, green: 0, blue: 0))
            paint(immediate)
        }

        let retained = try makeCanvas(width: 32, height: 32)
        let shape = retained.createShape { paint(retained) }
        try retained.draw {
            retained.background(.opaque(red: 0, green: 0, blue: 0))
            retained.shape(shape)
        }

        #expect(try retained.target.readPixels() == immediate.target.readPixels())
    }

    @Test("何も入っていない形を置いても、何も起きない")
    func placingAnEmptyShapeDoesNothing() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 1))
            canvas.shape(.empty)
            canvas.shape(canvas.createShape {})
        }
        #expect(canvas.get(4, 4) == .opaque(red: 0, green: 0, blue: 1))
        #expect(Shape.empty.isEmpty)
    }
}

/// 最適化していない実行ファイルか。
///
/// `assert` は最適化すると消えるので、その中で立てた旗が残っているかで分かる。
nonisolated let isDebugBuild: Bool = {
    var debug = false
    assert(
        {
            debug = true
            return true
        }())
    return debug
}()
