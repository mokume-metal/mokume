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
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 4 隅を 2 枚の三角形で張った立体の面。番号で指すかを選べる。
    private func patch(_ canvas: Canvas, indexed: Bool, x: Float = 0) {
        let corners: [SIMD2<Float>] = [
            SIMD2(x, 0), SIMD2(x + 20, 0), SIMD2(x + 20, 20), SIMD2(x, 20),
        ]
        let order = [0, 1, 2, 0, 2, 3]
        canvas.noStroke()
        canvas.fill(.linear(red: 1, green: 0, blue: 0))
        canvas.beginShape(.triangles)
        canvas.normal(0, 0, 1)
        if indexed {
            for corner in corners { canvas.vertex(corner.x, corner.y, 0) }
            for number in order { canvas.index(number) }
        } else {
            for number in order { canvas.vertex(corners[number].x, corners[number].y, 0) }
        }
        canvas.endShape()
    }

    private func makeDot(_ canvas: Canvas, _ color: LinearRGBA) -> Shape {
        canvas.createShape {
            canvas.noStroke()
            canvas.fill(color)
            canvas.rect(0, 0, 4, 4)
        }
    }

    /// 組み立ての中で変換とスタイルを積んで置く葉。`Sketches/TypeAndImagery.swift` が
    /// `setup()` で書いているのと同じ形である。**頂点の並びで記録する**ので、置かれた
    /// 座標をそのまま読める。
    private func makeLeaf(_ canvas: Canvas) -> Shape {
        canvas.createShape {
            canvas.push()
            canvas.translate(17, 9)
            canvas.rotate(0.7)
            canvas.noStroke()
            canvas.fill(.linear(red: 0, green: 0.8, blue: 0.3))
            canvas.beginShape()
            canvas.vertex(0, -8)
            canvas.vertex(6, 0)
            canvas.vertex(0, 8)
            canvas.vertex(-6, 0)
            canvas.endShape(.close)
            canvas.pop()
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
        let group = Shape.group((0..<500).map { _ in makeDot(canvas, .linear(red: 1, green: 0, blue: 0)) })

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(group, 8, 8)
        }
        #expect(canvas.drawCallsInLastFrame == 1)
        // 矩形は距離関数で描く基本図形なので、頂点ではなく置き場所として記録される (#752)
        #expect(group.vertexCount == 0)
        #expect(group.forms.count == 500)
    }

    @Test("組にしても、区切りの数は増えない")
    func groupingDoesNotAddRuns() throws {
        let canvas = try makeCanvas()
        let one = makeDot(canvas, .linear(red: 1, green: 0, blue: 0))
        #expect(one.drawCallCount == 1)
        #expect(Shape.group([one, one, one]).drawCallCount == 1)
        #expect((one + one).drawCallCount == 1)
    }

    @Test("番号で指した形を保持すると、持ち歩く頂点も面の数だけ増えない")
    func indexedShapeHoldsSharedVertices() throws {
        // #938 の完了条件を数で見る側。**保持した形が物差しになる** —
        // ``Shape/vertexCount`` は公開されているので、利用者からも同じ数が読める
        let canvas = try makeCanvas()
        let expanded = canvas.createShape { patch(canvas, indexed: false) }
        let indexed = canvas.createShape { patch(canvas, indexed: true) }

        #expect(expanded.vertexCount == 6)  // 三角形 2 枚 × 3 点
        #expect(indexed.vertexCount == 4)  // 四角の 4 隅
    }

    @Test("番号で指した形を組にしても、区切りの数は増えない")
    func groupingIndexedShapesDoesNotAddRuns() throws {
        // 番号は並びの位置そのものなので、繋ぐときに値をずらさないと畳めない。
        // 畳めないと**組にしても描く回数が増えない**という ``Shape/drawCallCount`` の
        // 宣言が、番号を使ったときだけ破れる
        let canvas = try makeCanvas()
        let one = canvas.createShape { patch(canvas, indexed: true) }
        #expect(one.drawCallCount == 1)
        #expect(Shape.group([one, one, one]).drawCallCount == 1)
        #expect(Shape.group([one, one, one]).vertexCount == 12)
    }

    @Test("組にして置いた番号の形は、1 つずつ置いたのと同じ絵になる")
    func groupedIndexedShapesMatchSeparatePlacements() throws {
        // 畳むときに番号の値へ写し先のずれを足し忘れると、2 つ目以降が 1 つ目の点を
        // 指す。**中身の違う形を組にしないと出ない** — 同じ形を 2 つ組にした場合は、
        // 間違った先を指しても同じ頂点が並んでいるので絵が変わらない
        let canvas = try makeCanvas()
        let left = canvas.createShape { patch(canvas, indexed: true, x: 0) }
        let right = canvas.createShape { patch(canvas, indexed: true, x: 26) }

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(Shape.group([left, right]), 4, 4)
        }
        let grouped = try canvas.target.encodeForDisplay()

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(left, 4, 4)
            canvas.shape(right, 4, 4)
        }
        let separate = try canvas.target.encodeForDisplay()

        var differing = 0
        for y in 0..<grouped.height {
            for x in 0..<grouped.width where grouped[x, y] != separate[x, y] { differing += 1 }
        }
        #expect(differing == 0)
    }

    @Test("続けて置いた形どうしも、同じ 1 度の描画に並ぶ")
    func consecutiveShapesShareTheSameDrawCall() throws {
        let canvas = try makeCanvas()
        let dot = makeDot(canvas, .linear(red: 0, green: 1, blue: 0))

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
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
    /// 組み立て側との差が実際より小さく出る (実測: 最適化なしで 490ms 対 122ms = 4.0x、
    /// 最適化ありで 28.6ms 対 1.9ms = 15x)。**速さの主張は最適化した実行ファイルに
    /// ついてのもの**なので、測れない構成では測らずに、測っていないことを出力へ出す
    /// (最適化なしでも壁 2 倍は越えるが、debug の数字は性能の根拠にしない)。
    ///
    /// ## なぜ曲線と輪郭を持つ形なのか
    ///
    /// 測る絵は `changelog.d/retained-shapes.feature.md` が数字を引いている形
    /// (「曲線と輪郭を持つ形 2000 個」) と、参照シーンの `drawRetainedShapes`
    /// (`SceneLedgerTests.swift`) が使っている葉に揃えてある。**公開した約束と同じ形で
    /// 測る**のが選ぶ理由で、倍率が大きく出るからではない。
    ///
    /// ## この検査が見ていないもの
    ///
    /// **基本図形だけで組んだ形 (置き場所の経路) の速さは見ていない。** `circle()` や
    /// `rect()` は 1 インスタンス 1 クアッド + 距離関数で描くようになったので
    /// ([#772](https://github.com/mokume-metal/mokume/issues/772))、組み立て直しでも
    /// 置き場所を 1 個 append するだけになった — 再生側 (`placeForms`) も同じ append で
    /// **仕事量が一致し**、倍率は 2.15–2.43x に留まって壁 2 倍がノイズの中に入る
    /// ([#1086](https://github.com/mokume-metal/mokume/issues/1086) で実測)。
    /// **これは退行ではなく `circle()` が 60 倍速くなった成果の裏側**で、速さの根拠は
    /// `placeForms` の実装コメント (「頂点を 1 つも触らないので、円を含む形も、頂点を
    /// 並べた形と同じ速さで置ける」) が持つ。置き場所の経路が**畳まれている**ことは、
    /// この suite の「組にした形は、何個入っていても 1 度の描画で出る」が
    /// `drawCallsInLastFrame` と `Shape/forms` の数で**決定論的に (debug でも)** 見ている。
    ///
    /// ## 1 窓目は GPU のフレーム壁を測る
    ///
    /// 暖機で飛んでいるフレームがあると、`measure` の最初の窓は環にした置き場の
    /// 空き待ち ([#754](https://github.com/mokume-metal/mokume/issues/754)) に毎回入り、
    /// CPU の投入費用ではなく GPU のフレーム所要時間を測る。GPU の仕事は組み立て直しでも
    /// 再生でも同じ絵なので、**壁に当たった窓では両方が同じ数字になり倍率が 1 へ潰れる**
    /// (#1086 が報告した 0.446 対 0.450 がこれである)。だから **CPU の費用が壁より
    /// 十分に高い絵で測る** — 葉 2000 個の組み立て直しは 28ms で、壁 (0.45ms) の 60 倍以上
    /// ある。基本図形だけの絵では届かない。
    @Test(
        "大量の要素では、毎フレーム組み立てるより速い",
        .enabled(if: !isDebugBuild, "最適化していない実行ファイルでは速さを測らない"))
    func replayingBeatsRebuildingForManyElements() throws {
        let canvas = try makeCanvas(width: 256, height: 256)
        let count = 2000

        // 曲線 (bezierVertex) と輪郭 (stroke) を持つ葉。参照シーンの drawRetainedShapes と
        // 同じ組み立てで、頂点を三角形へ開く経路に乗る
        func build(on canvas: Canvas) {
            for index in 0..<count {
                canvas.fill(.linear(red: 0.4, green: 0.85, blue: 0.45))
                canvas.stroke(.linear(red: 0.12, green: 0.35, blue: 0.2))
                canvas.strokeWeight(2)
                let x = Float(index % 50) * 4 + 20
                let y = Float(index / 50) * 5 + 20
                canvas.beginShape()
                canvas.vertex(x, y - 14)
                canvas.bezierVertex(x + 10, y - 9, x + 10, y + 9, x, y + 14)
                canvas.bezierVertex(x - 10, y + 9, x - 10, y - 9, x, y - 14)
                canvas.endShape(.close)
            }
        }

        let retained = canvas.createShape { build(on: canvas) }

        // **測る前に、頂点の経路に乗っていることを数で確かめる。** 絵を基本図形だけの
        // ものに替えると置き場所の経路へ移り、測っているものが変わったことに気付かないまま
        // 倍率だけが通る (上の「この検査が見ていないもの」)
        #expect(retained.vertexCount > 0)

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
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(0, 0, 16, 16)
        }

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.fill(.linear(red: 0, green: 0, blue: 1))
            canvas.shape(dot)
        }
        #expect(canvas.get(8, 8) == .linear(red: 1, green: 0, blue: 0))
    }

    @Test("置くときに輪郭を止めても、形の輪郭は出る")
    func ambientNoStrokeDoesNotReachARetainedShape() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        let outlined = canvas.createShape {
            canvas.noFill()
            canvas.stroke(.linear(red: 0, green: 1, blue: 0))
            canvas.strokeWeight(4)
            canvas.rect(8, 8, 16, 16)
        }

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shape(outlined)
        }
        #expect(canvas.get(8, 8).green > 0.5)
    }

    // MARK: - 焼き付いた塗り (利用者の断片)

    /// 面を 1 枚読んでそのまま返す断片。**面の差し替えが絵に出る**ので、
    /// どの面で描かれたかを画素で見分けられる。
    private static let toneShader = """
        float4 paint(Fragment in, Values values, Surfaces surfaces) {
            return mokume_sample(surfaces.tone, in.place);
        }
        """

    /// 完了条件 1。**`fill` / `stroke` と同じく、断片も形の中に焼き付く。**
    ///
    /// 焼き付かないと「組み立てるコードを読めば何色になるかが分かる」という
    /// ``Sketch/createShape(_:)`` の約束が `shader()` のときだけ破れる。
    @Test("断片で塗った形は、置く前に断片を外しても記録した塗りで出る")
    func aRetainedShapeKeepsTheFragmentItWasBuiltWith() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let green = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }")

        canvas.shader(green)
        let painted = canvas.createShape {
            canvas.noStroke()
            // 断片が落ちていれば、この頂点の色 (赤) がそのまま出る
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(0, 0, 16, 16)
        }
        canvas.resetShader()

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(painted)
        }
        #expect(canvas.get(8, 8) == .linear(red: 0, green: 1, blue: 0))
    }

    /// 完了条件 1 の逆向き。**置く側の断片は形に届かない。**
    @Test("置くときに断片を掛けても、組み込みの塗りで記録した形は組み込みのまま")
    func anAmbientFragmentDoesNotReachARetainedShape() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        // 任意多角形は距離関数の経路に載らないので、三角形の列として記録される
        let plain = canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(16, 0)
            canvas.vertex(16, 16)
            canvas.vertex(0, 16)
            canvas.endShape(.close)
        }
        let green = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }")

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shader(green)
            canvas.shape(plain)
        }
        #expect(canvas.get(8, 8) == .linear(red: 1, green: 0, blue: 0))
    }

    /// 完了条件 2。**面だけ差し替えた 2 区間は、組にしても 1 本に畳まれない。**
    ///
    /// 畳まれると 1 つ目の面で両方が描かれる — `Shader/set(_:_:)-(_,ShaderSurface)` は
    /// 列を閉じるが値は変えないので、面を見ない判定では区別が付かない。
    @Test("面だけ差し替えて組み立てた 2 つの形は、組にしてもそれぞれの面で描かれる")
    func groupingKeepsTheSurfaceOfEachRun() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        let first = try canvas.createImage(4, 4)
        first.fill(.linear(red: 1, green: 0, blue: 0))
        let second = try canvas.createImage(4, 4)
        second.fill(.linear(red: 0, green: 1, blue: 0))
        let shader = try canvas.makeShader(
            Self.toneShader, surfaces: ["tone": .image(first)])

        canvas.shader(shader)
        let left = canvas.createShape {
            canvas.noStroke()
            canvas.rect(0, 0, 16, 16)
        }
        shader.set("tone", .image(second))
        let right = canvas.createShape {
            canvas.noStroke()
            canvas.rect(16, 0, 16, 16)
        }
        canvas.resetShader()

        let both = Shape.group([left, right])
        // 面が違えば設定が違うので、区間は 2 本のまま
        #expect(both.drawCallCount == 2)

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 1))
            canvas.shape(both)
        }
        #expect(canvas.get(8, 8) == .linear(red: 1, green: 0, blue: 0))
        #expect(canvas.get(24, 8) == .linear(red: 0, green: 1, blue: 0))
    }

    /// 完了条件 3。**畳み判定が塗りの設定を全部見ている**ことを、1 つずつ変えて見る。
    ///
    /// ここが赤くなったら、`Shape.Run` に足したフィールドが判定から漏れている。
    @Test("塗りの設定が 1 つでも違えば、組にしても畳まれない")
    func runsThatDifferInAnyPaintSettingAreNotMerged() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        func box(_ x: Float) -> Shape {
            canvas.createShape {
                canvas.noStroke()
                canvas.rect(x, 0, 16, 16)
            }
        }

        // 何も変えなければ畳まれる (この検査自身が、下の 2 本の対照になる)
        let sameShader = try canvas.makeShader(
            Self.toneShader,
            surfaces: ["tone": .image(try canvas.createImage(4, 4))])
        canvas.shader(sameShader)
        #expect(Shape.group([box(0), box(16)]).drawCallCount == 1)

        // 面だけ差し替える
        let other = try canvas.createImage(4, 4)
        let left = box(0)
        sameShader.set("tone", .image(other))
        #expect(Shape.group([left, box(16)]).drawCallCount == 2)
        canvas.resetShader()

        // 値だけ差し替える
        let valued = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(values.level, 0.0, 0.0, 1.0); }",
            values: ["level": 0.25])
        canvas.shader(valued)
        let dim = box(0)
        valued.set("level", 0.75)
        #expect(Shape.group([dim, box(16)]).drawCallCount == 2)

        // 断片だけ差し替える
        let bright = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(1.0, 1.0, 1.0, 1.0); }")
        let byValued = box(0)
        canvas.shader(bright)
        #expect(Shape.group([byValued, box(16)]).drawCallCount == 2)
        canvas.resetShader()

        // 数の並びだけ差し替える
        let numbers = try canvas.makeNumbers(count: 4)
        canvas.shader(bright)
        let withoutNumbers = box(0)
        canvas.numbers(numbers)
        #expect(Shape.group([withoutNumbers, box(16)]).drawCallCount == 2)
        canvas.resetNumbers()
        canvas.resetShader()
    }

    // MARK: - 記録が外へ漏れないこと

    @Test("組み立ての間に触ったスタイルは、外へ残らない")
    func buildingDoesNotLeakStyle() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.linear(red: 0, green: 0, blue: 1))
            _ = canvas.createShape {
                canvas.fill(.linear(red: 1, green: 0, blue: 0))
                canvas.blendMode(.add)
                canvas.rect(0, 0, 4, 4)
            }
            // 組み立ての中で変えた塗りと混ぜ方が残っていれば、ここが赤くなる
            canvas.rect(0, 0, 16, 16)
        }
        #expect(canvas.get(8, 8) == .linear(red: 0, green: 0, blue: 1))
    }

    /// 断片はスタイルの一式に含まれない (積み降ろしでは戻らない) ので、組み立てが
    /// 自分で戻さないと外へ残る ([#836])。
    ///
    /// [#836]: https://github.com/mokume-metal/mokume/issues/836
    @Test("組み立ての間に掛けた断片は、外へ残らない")
    func buildingDoesNotLeakTheFragment() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let green = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }")
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.linear(red: 0, green: 0, blue: 1))
            _ = canvas.createShape {
                canvas.shader(green)
                canvas.rect(0, 0, 4, 4)
            }
            // 組み立ての中で掛けた断片が残っていれば、ここが緑になる
            canvas.rect(0, 0, 16, 16)
        }
        #expect(canvas.get(8, 8) == .linear(red: 0, green: 0, blue: 1))
    }

    /// 数の並びも断片と同じく、スタイルの一式に含まれない ([#836])。
    ///
    /// 断片は並びの**先頭だけ**を読む。渡していない列に束ねられるのは 1 個の 0 なので、
    /// 添字を振って読むと範囲外読み出しになる ([#919])。
    ///
    /// [#836]: https://github.com/mokume-metal/mokume/issues/836
    /// [#919]: https://github.com/mokume-metal/mokume/issues/919
    @Test("組み立ての間に渡した並びは、外へ残らない")
    func buildingDoesNotLeakTheNumbers() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let showFirst = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                float v = in.numbers[0];
                return float4(v, v, v, 1);
            }
            """)
        let lit = try canvas.makeNumbers(count: 1)
        lit.fill(1)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(showFirst)
            _ = canvas.createShape {
                canvas.numbers(lit)
                canvas.rect(0, 0, 4, 4)
            }
            // 組み立ての中で渡した並びが残っていれば、ここが白くなる
            canvas.rect(0, 0, 16, 16)
        }
        #expect(canvas.get(8, 8) == .linear(red: 0, green: 0, blue: 0))
    }

    /// 積み降ろし (`pushStyle()` / `pushMatrix()`) はフレームの中でしか効かない。組み立てが
    /// それに頼ると、`setup()` で組み立てたときに退避も復帰も空振りし、利用者が触っていない
    /// 積み降ろしの警告だけが出る ([#1041])。
    ///
    /// [#1041]: https://github.com/mokume-metal/mokume/issues/1041
    @Test("フレームの外で組み立てても、中で触った塗りは外へ残らず、警告も出ない")
    func buildingOutsideTheFrameDoesNotLeakStyle() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        canvas.fill(.linear(red: 0, green: 0, blue: 1))
        _ = canvas.createShape {
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(0, 0, 4, 4)
        }
        #expect(canvas.style.fill == .linear(red: 0, green: 0, blue: 1))
        #expect(!canvas.warnings.hasWarned(.styleOutsideFrame))
        #expect(!canvas.warnings.hasWarned(.transformOutsideFrame))
    }

    /// 組み立ての中は**形自身の座標で記録する文脈**なので、中で書いた変換もスタイルの
    /// 積み降ろしも形に焼き付く。フレームの外でだけ落ちると、`setup()` で組み立てた形が
    /// 1 か所へ重なる ([#1172]) — 参照スケッチ (`Sketches/TypeAndImagery.swift`) の
    /// 9 枚の葉がそうなっていた。
    ///
    /// [#1172]: https://github.com/mokume-metal/mokume/issues/1172
    @Test("フレームの外で組み立てても、中で書いた変換は形に焼き付く")
    func buildingOutsideTheFrameKeepsTheTransformWrittenInside() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        var inside = Shape.empty
        try canvas.draw { inside = makeLeaf(canvas) }
        let outside = makeLeaf(canvas)

        #expect(!outside.isEmpty)
        #expect(outside.vertices.map(\.position) == inside.vertices.map(\.position))
        #expect(!canvas.warnings.hasWarned(.transformOutsideFrame))
        #expect(!canvas.warnings.hasWarned(.styleOutsideFrame))
    }

    /// 積み降ろしは**記録の中で閉じる**。積んだまま抜けたぶんが外の段として残ると、
    /// 組み立てのあとの `pop()` が、記録の中で積んだ状態へ戻してしまう ([#1172])。
    ///
    /// [#1172]: https://github.com/mokume-metal/mokume/issues/1172
    @Test("組み立ての中で積んだまま抜けても、外の変換は動かない")
    func buildingDoesNotLeakTheStackItPushed() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        var expected = Transform.identity
        expected.translate(x: 5, y: 5)
        try canvas.draw {
            canvas.translate(5, 5)
            _ = canvas.createShape {
                canvas.push()
                canvas.translate(9, 9)
                canvas.rect(0, 0, 4, 4)
            }
            // 記録の中で積んだ段が外へ残っていれば、ここで (9, 9) ぶん動いた状態へ戻る
            canvas.pop()
            #expect(canvas.transform == expected)
        }
    }

    /// 逆向きも同じ — 記録の中の `pop()` は、記録より前に積んだ段を取らない ([#1172])。
    ///
    /// [#1172]: https://github.com/mokume-metal/mokume/issues/1172
    @Test("組み立ての中の pop() は、外で積んだ段を取らない")
    func buildingDoesNotPopTheStackFromOutside() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.fill(.linear(red: 0, green: 0, blue: 1))
            canvas.push()
            canvas.translate(5, 5)
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            _ = canvas.createShape {
                canvas.pop()
                canvas.rect(0, 0, 4, 4)
            }
            // 外の段はまだ積まれたまま。ここで初めて積む前の状態へ戻る
            canvas.pop()
            #expect(canvas.transform == .identity)
            #expect(canvas.style.fill == .linear(red: 0, green: 0, blue: 1))
        }
    }

    @Test("組み立てたぶんが、そのフレームの絵に紛れ込まない")
    func buildingDoesNotDrawByItself() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            _ = canvas.createShape {
                canvas.noStroke()
                canvas.fill(.linear(red: 1, green: 0, blue: 0))
                canvas.rect(0, 0, 16, 16)
            }
        }
        #expect(canvas.get(8, 8) == .linear(red: 0, green: 0, blue: 0))
    }

    @Test("どこで組み立てても、同じ形になる")
    func theBuildingPlaceDoesNotChangeTheShape() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        var here = Shape.empty
        var moved = Shape.empty
        try canvas.draw {
            here = makeDot(canvas, .linear(red: 1, green: 0, blue: 0))
            canvas.push()
            canvas.translate(17, 9)
            canvas.rotate(0.7)
            moved = makeDot(canvas, .linear(red: 1, green: 0, blue: 0))
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
            canvas.fill(.linear(red: 0.25, green: 0, blue: 0))
            canvas.rect(0, 0, 16, 16)
        }

        try canvas.draw {
            canvas.background(.linear(red: 0.5, green: 0, blue: 0))
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
            canvas.fill(.linear(red: 0.5, green: 0, blue: 0))
            canvas.rect(0, 0, 8, 8)
        }

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shape(adding)
            // 混ぜ方が残っていれば、下地の赤に足されて 1.0 を超える
            canvas.fill(.linear(red: 0.5, green: 0, blue: 0))
            canvas.rect(0, 8, 8, 8)
        }
        #expect(canvas.get(4, 12).red == 0.5)
    }

    // MARK: - 置き方

    @Test("置いた場所に出る")
    func aShapeLandsWhereItIsPlaced() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        let dot = makeDot(canvas, .linear(red: 1, green: 0, blue: 0))

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(dot, 20, 12)
        }
        #expect(canvas.get(22, 14) == .linear(red: 1, green: 0, blue: 0))
        #expect(canvas.get(2, 2) == .linear(red: 0, green: 0, blue: 0))
    }

    @Test("置くときの変換が効く")
    func theAmbientTransformApplies() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        let dot = makeDot(canvas, .linear(red: 1, green: 0, blue: 0))

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.push()
            canvas.translate(20, 12)
            canvas.shape(dot)
            canvas.pop()
        }
        #expect(canvas.get(22, 14) == .linear(red: 1, green: 0, blue: 0))
    }

    @Test("保持した形の絵は、その場で描いた絵と一致する")
    func retainedAndImmediateDrawTheSamePicture() throws {
        func paint(_ canvas: Canvas) {
            canvas.stroke(.linear(red: 0.2, green: 0.9, blue: 1))
            canvas.strokeWeight(3)
            canvas.fill(.linear(red: 0.95, green: 0.4, blue: 0.2))
            canvas.beginShape()
            canvas.vertex(6, 6)
            canvas.vertex(26, 10)
            canvas.bezierVertex(30, 20, 20, 28, 8, 26)
            canvas.endShape(.close)
        }

        let immediate = try makeCanvas(width: 32, height: 32)
        try immediate.draw {
            immediate.background(.linear(red: 0, green: 0, blue: 0))
            paint(immediate)
        }

        let retained = try makeCanvas(width: 32, height: 32)
        let shape = retained.createShape { paint(retained) }
        try retained.draw {
            retained.background(.linear(red: 0, green: 0, blue: 0))
            retained.shape(shape)
        }

        #expect(try retained.target.readPixels() == immediate.target.readPixels())
    }

    // MARK: - 形の中で置いた立体の塗りと変換 (#1297)

    /// 形を (100, 100) に置いた絵。**光を置かない**ので、塗った色がそのまま画素に出る。
    private func picture(placing shape: Shape, on canvas: Canvas) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(shape, 100, 100)
        }
        return try canvas.target.encodeForDisplay()
    }

    /// 背景 (黒) でない画素の数。見るのは `center` から縦横 `reach` 画素の正方形の中だけ。
    private func litCount(
        _ image: DisplayImage, around center: (x: Int, y: Int), reach: Int,
        where matches: ((red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)) -> Bool = {
            $0.red > 0 || $0.green > 0 || $0.blue > 0
        }
    ) -> Int {
        var count = 0
        for y in (center.y - reach)...(center.y + reach) {
            for x in (center.x - reach)...(center.x + reach) where matches(image[x, y]) {
                count += 1
            }
        }
        return count
    }

    /// 赤が勝っている画素か。**255, 0, 0 とは比べない** — 書き出しは表示の色域で符号化する
    /// ので、`fill(255, 0, 0)` の赤も 234, 51, 35 前後で出る。落ちた箱の白 (3 成分が揃う) と
    /// 背景の黒は、どちらもここを通らない。
    private func isRed(_ sample: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)) -> Bool {
        sample.red > 128 && sample.red > 3 * UInt16(sample.green) && sample.red > 3 * UInt16(sample.blue)
    }

    /// 完了条件 1。**立体の色と変換は頂点に焼く。** 組み込みの形は頂点を白で持ち、色と
    /// 変換を置き場所の側に持つので、記録が置き場所を捨てると形の原点に白い箱が出る。
    @Test("形の中で塗って動かした立体は、その色でその場所に出る")
    func aSolidKeepsTheFillAndTransformWrittenInside() throws {
        let canvas = try makeCanvas(width: 200, height: 160)
        let crate = canvas.createShape {
            canvas.noStroke()
            canvas.fill(255, 0, 0)
            canvas.translate(50, 0, 0)
            canvas.box(20)
        }
        let image = try picture(placing: crate, on: canvas)

        #expect(isRed(image[150, 100]), "中で動かした先に赤い箱が出ていない")
        #expect(litCount(image, around: (100, 100), reach: 15) == 0, "形の原点に何かが出ている")
    }

    /// 完了条件 2。同じ形が続くと 2 個目からは置き場所しか増えないので、置き場所を
    /// 捨てる記録には 1 個ぶんの頂点しか残らない。
    @Test("形の中で動かして 2 つ置いた立体は、2 つとも出る")
    func twoSolidsInsideAShapeBothAppear() throws {
        let canvas = try makeCanvas(width: 200, height: 160)
        let pair = canvas.createShape {
            canvas.noStroke()
            canvas.box(10)
            canvas.translate(30, 0, 0)
            canvas.box(10)
        }
        let image = try picture(placing: pair, on: canvas)

        #expect(litCount(image, around: (100, 100), reach: 2) > 0, "1 つ目の箱が出ていない")
        #expect(litCount(image, around: (130, 100), reach: 2) > 0, "2 つ目の箱が出ていない")
        #expect(litCount(image, around: (115, 100), reach: 2) == 0, "2 つの箱の間が埋まっている")
    }

    /// 完了条件 5。**焼き込んでも区間は増えない** — 焼いた頂点はその場で並べる列へ積む
    /// ので、2 つの箱は 1 本の区間に並ぶ。焼く前から 1 で、焼いた後も保つことを見る。
    @Test("形の中で 2 つ置いた立体も、描く回数は 1 回")
    func twoSolidsInsideAShapeStayInOneRun() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        let pair = canvas.createShape {
            canvas.noStroke()
            canvas.box(10)
            canvas.translate(30, 0, 0)
            canvas.box(10)
        }
        #expect(pair.drawCallCount == 1)
    }

    /// 完了条件 8。**置き場所を頂点へ焼いたこと**を数で見る。2 つ目の箱が置き場所 1 つで
    /// 済む作り (置き場所を記録に持たせる道) では、頂点は 1 組のままになる。
    @Test("形の中で 2 つ置いた立体は、頂点を 2 組ぶん持つ")
    func twoSolidsInsideAShapeHoldTwoSetsOfVertices() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        let single = canvas.createShape {
            canvas.noStroke()
            canvas.box(10)
        }
        let pair = canvas.createShape {
            canvas.noStroke()
            canvas.box(10)
            canvas.translate(30, 0, 0)
            canvas.box(10)
        }
        #expect(single.vertexCount > 0)
        #expect(pair.vertexCount == 2 * single.vertexCount)
    }

    /// 完了条件 3。**線は元から世界の座標へ焼かれていた**ので、塗りだけが形の原点へ
    /// 落ちて 2 つがずれた。塗りも線も、中で動かした先の同じ箱に載ることを見る。
    @Test("形の中で線を付けて動かした立体は、塗りと線が同じ箱に載る")
    func aStrokedSolidKeepsFillAndStrokeTogether() throws {
        let canvas = try makeCanvas(width: 200, height: 160)
        let crate = canvas.createShape {
            canvas.stroke(0, 0, 255)
            canvas.fill(255, 0, 0)
            canvas.translate(50, 0, 0)
            canvas.box(20)
        }
        let image = try picture(placing: crate, on: canvas)

        #expect(isRed(image[150, 100]), "中で動かした先の箱に塗りが載っていない")
        let blue = litCount(image, around: (150, 100), reach: 20) {
            $0.blue > 0 && $0.red == 0
        }
        #expect(blue > 0, "中で動かした先の箱に線が載っていない")
        #expect(litCount(image, around: (100, 100), reach: 15) == 0, "形の原点に何かが出ている")
    }

    /// 完了条件 4 の前半。**入れ子の置き場所も焼く。** 組み立ての中で置き直した形の
    /// 置き場所を記録が捨てると、中で書いた `translate` が落ちる。
    @Test("立体を含む形を形の中で動かして置いても、動かした先に出る")
    func aNestedSolidShapeKeepsTheTransformWrittenOutside() throws {
        let canvas = try makeCanvas(width: 200, height: 160)
        let inner = canvas.createShape {
            canvas.noStroke()
            canvas.fill(255, 0, 0)
            canvas.box(20)
        }
        let outer = canvas.createShape {
            canvas.translate(50, 0, 0)
            canvas.shape(inner)
        }
        let image = try picture(placing: outer, on: canvas)

        #expect(isRed(image[150, 100]), "入れ子の形が動かした先に赤く出ていない")
        #expect(litCount(image, around: (100, 100), reach: 15) == 0, "形の原点に何かが出ている")
    }

    /// 入れ子の置き場所を焼くときは、**読む順も一緒に写す**。写さないと、番号で指した形が
    /// 3 つずつ束ねただけの並びとして描かれるか、元の形の頂点を指す。
    @Test("番号で指した立体の形も、形の中で動かして置いた先に出る")
    func aNestedIndexedSolidShapeKeepsTheTransformWrittenOutside() throws {
        let canvas = try makeCanvas(width: 200, height: 160)
        let inner = canvas.createShape { patch(canvas, indexed: true) }
        let outer = canvas.createShape {
            canvas.translate(30, 0, 0)
            canvas.shape(inner)
        }
        let image = try picture(placing: outer, on: canvas)

        #expect(outer.vertexCount == inner.vertexCount, "置き直しで頂点の共有が崩れている")
        // 面は三角形 2 枚。**両方の三角形の中を 1 点ずつ見る** — 読む順が落ちると、並べた
        // 順に 3 つずつ読まれて 1 枚目 (右上) しか出ない
        #expect(isRed(image[146, 104]), "動かした先の右上の三角形が出ていない")
        #expect(isRed(image[134, 116]), "動かした先の左下の三角形が出ていない")
        #expect(litCount(image, around: (110, 110), reach: 5) == 0, "元の場所に何かが出ている")
    }

    /// 完了条件 4 の後半。`Sketch.createShape` の doc にある組み方 (中で動かした形を
    /// `Shape.group` で繋ぐ) を、立体で書いたもの。
    @Test("中で動かした立体の形を組にしても、それぞれの場所に出る")
    func groupedSolidShapesKeepTheirOwnPlaces() throws {
        let canvas = try makeCanvas(width: 200, height: 160)
        let inner = canvas.createShape {
            canvas.noStroke()
            canvas.fill(255, 0, 0)
            canvas.box(20)
        }
        let left = canvas.createShape {
            canvas.translate(-30, 0, 0)
            canvas.shape(inner)
        }
        let right = canvas.createShape {
            canvas.translate(30, 0, 0)
            canvas.shape(inner)
        }
        let image = try picture(placing: Shape.group([left, right]), on: canvas)

        #expect(isRed(image[70, 100]), "左の箱が出ていない")
        #expect(isRed(image[130, 100]), "右の箱が出ていない")
        #expect(litCount(image, around: (100, 100), reach: 2) == 0, "2 つの箱が真ん中に重なっている")
    }

    /// 読み込んだモデルも組み込みの形と同じ経路 (`placeMesh`) を通るので、同じく焼く。
    ///
    /// **その場で描いた絵とは画素単位では比べない。** 焼いた頂点は CPU で行列を掛け、
    /// その場で描いた頂点は GPU で掛けるので、最下位ビットの違いで縁の画素が動きうる。
    /// 落ちていれば形の原点に白く出るので、ほぼ全部の画素が食い違う。
    @Test("形の中で置いたモデルも、中で書いた塗りと変換で出る")
    func aModelInsideAShapeKeepsTheFillAndTransformWrittenInside() throws {
        func paint(_ canvas: Canvas, _ model: Model) {
            canvas.noStroke()
            canvas.fill(255, 0, 0)
            canvas.translate(50, 0, 0)
            canvas.scale(0.4, 0.4, 0.4)
            canvas.model(model)
        }

        let immediate = try makeCanvas(width: 200, height: 160)
        let immediateModel = try immediate.loadModel(ModelFixture.pyramid)
        try immediate.draw {
            immediate.background(.linear(red: 0, green: 0, blue: 0))
            immediate.translate(100, 100, 0)
            paint(immediate, immediateModel)
        }
        let expected = try immediate.target.encodeForDisplay()

        let retained = try makeCanvas(width: 200, height: 160)
        let retainedModel = try retained.loadModel(ModelFixture.pyramid)
        let gem = retained.createShape { paint(retained, retainedModel) }
        let image = try picture(placing: gem, on: retained)

        var lit = 0
        var differing = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                if isRed(expected[x, y]) { lit += 1 }
                if expected[x, y] != image[x, y] { differing += 1 }
            }
        }
        #expect(lit > 100, "その場で描いたモデルが赤く出ていない (比べる相手が成り立っていない)")
        #expect(differing * 50 <= lit, "形の中で置いたモデルが、その場で描いた絵と食い違う")
    }

    // MARK: - 鏡映して置く (#1446)

    /// 光を正面から当てた場面へ、`place` で何かを置いた絵 (128×128・真ん中が原点)。
    private func frontLitPicture(_ canvas: Canvas, place: () -> Void) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(20)
            canvas.directionalLight(255, 255, 255, 0, 0, -1)
            canvas.noStroke()
            canvas.fill(230, 60, 40)
            canvas.translate(64, 64, 0)
            place()
        }
        return try canvas.target.encodeForDisplay()
    }

    /// 四角錐の角と面。**横の鏡映で自分に重なる**ので、鏡映して回した絵は逆に回した絵と
    /// 同じになる (``ModelFixture/pyramidText`` と同じ形・同じ巻き方)。
    private static let pyramidCorners: [SIMD3<Float>] = [
        SIMD3(-1, 0, -1), SIMD3(1, 0, -1), SIMD3(1, 0, 1), SIMD3(-1, 0, 1), SIMD3(0, 1.6, 0),
    ]
    private static let pyramidFaces: [[Int]] = [
        [0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4], [3, 2, 1], [3, 1, 0],
    ]

    @Test("向きを書かずに並べた立体の形を鏡映して置いても、見る側から光を受ける")
    func aMirroredShapeWithDerivedNormalsCatchesTheLight() throws {
        // 形から求めた向きは、断片が「裏を向いている」と判定した面で裏返す。置き場所で
        // 鏡映すると巻き方が裏返るので、表の巻き方を列ごと裏返さないと、見る側を向いた
        // 面が視線と逆の向きで光を受けて暗くなる
        func picture(mirrored: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas(width: 128, height: 128)
            let gem = canvas.createShape {
                canvas.noStroke()
                canvas.fill(230, 60, 40)
                canvas.beginShape(.triangles)
                for face in Self.pyramidFaces {
                    for corner in face {
                        let point = Self.pyramidCorners[corner] * 30
                        canvas.vertex(point.x, point.y, point.z)
                    }
                }
                canvas.endShape()
            }
            return try frontLitPicture(canvas) {
                if mirrored { canvas.scale(-1, 1, 1) }
                canvas.rotateY(mirrored ? 0.6 : -0.6)
                canvas.rotateX(0.5)
                canvas.shape(gem)
            }
        }

        let mirrored = try picture(mirrored: true)
        let rotated = try picture(mirrored: false)
        let difference = PictureDifference.between(mirrored, rotated)
        #expect(difference.shapePixels > 1000, "形が写っていない (\(difference))")
        #expect(difference.fraction <= 0.02, "鏡映した形が逆に回した形と食い違う (\(difference))")
    }

    @Test("形の中で鏡映して置いた箱は、鏡映せずに置いても、同じ形になる回転の箱と同じ絵に写る")
    func aBoxMirroredInsideAShapeLooksLikeTheEquivalentRotation() throws {
        // 記録の間は置き場所を頂点へ焼く (#1297) ので、鏡映は頂点の巻き方に焼き付き、
        // 置くときの置き場所は鏡映しない。焼いた頂点はその場で並べる列に入って両面で
        // 描かれ、箱は向きを書いて持つので、捨て方にも求めた向きの裏返しにも掛からない
        // — 直す前から写る見込みの経路で、#1446 の直しが崩さないことの見張り
        let baked = try makeCanvas(width: 128, height: 128)
        let crate = baked.createShape {
            baked.noStroke()
            baked.fill(230, 60, 40)
            baked.scale(-1, 1, 1)
            baked.rotateY(0.6)
            baked.rotateX(0.5)
            baked.box(56)
        }
        let placed = try frontLitPicture(baked) { baked.shape(crate) }

        let direct = try makeCanvas(width: 128, height: 128)
        let rotated = try frontLitPicture(direct) {
            direct.rotateY(-0.6)
            direct.rotateX(0.5)
            direct.box(56)
        }
        let difference = PictureDifference.between(placed, rotated)
        #expect(difference.shapePixels > 1000, "箱が写っていない (\(difference))")
        #expect(difference.fraction <= 0.02, "形の中で鏡映した箱が回転の箱と食い違う (\(difference))")
    }

    @Test("形の中で鏡映して置いた、面の向きの無いモデルも、見る側から光を受ける")
    func aModelMirroredInsideAShapeCatchesTheLight() throws {
        // 焼いた頂点は何も動かさない置き場所で描くので、列の表の巻き方は裏返らない。
        // 鏡映は焼いた三角形の巻き方に残るので、焼く側が巻き方を戻さないと、形から
        // 求めた向きが視線と逆の向きで光を受ける
        let baked = try makeCanvas(width: 128, height: 128)
        let bakedModel = try baked.loadModel(ModelFixture.pyramid, normalize: false)
        let gem = baked.createShape {
            baked.noStroke()
            baked.fill(230, 60, 40)
            baked.scale(-1, 1, 1)
            baked.rotateY(0.6)
            baked.rotateX(0.5)
            baked.scale(30, 30, 30)
            baked.model(bakedModel)
        }
        let placed = try frontLitPicture(baked) { baked.shape(gem) }

        let direct = try makeCanvas(width: 128, height: 128)
        let directModel = try direct.loadModel(ModelFixture.pyramid, normalize: false)
        let rotated = try frontLitPicture(direct) {
            direct.rotateY(-0.6)
            direct.rotateX(0.5)
            direct.scale(30, 30, 30)
            direct.model(directModel)
        }
        let difference = PictureDifference.between(placed, rotated)
        #expect(difference.shapePixels > 1000, "モデルが写っていない (\(difference))")
        #expect(
            difference.fraction <= 0.02, "形の中で鏡映したモデルが逆に回したモデルと食い違う (\(difference))")
    }

    @Test("番号で指した、向きを書かない形を形の中で鏡映して置き直しても、見る側から光を受ける")
    func anIndexedShapeMirroredInsideAShapeCatchesTheLight() throws {
        // 入れ子の置き直しは読む順ごと焼く。巻き方を戻すのは頂点ではなく読む順の側になる
        // ので、上の検査 (並べた順に読む頂点) とは別の枝を通る。頂点は三角形ごとに別に
        // 並べて共有しない — 共有すると向きが角ごとに均されて、鏡映で自分に重ならない
        func gem(on canvas: Canvas) -> Shape {
            canvas.createShape {
                canvas.noStroke()
                canvas.fill(230, 60, 40)
                canvas.beginShape(.triangles)
                for face in Self.pyramidFaces {
                    for corner in face {
                        let point = Self.pyramidCorners[corner] * 30
                        canvas.vertex(point.x, point.y, point.z)
                    }
                }
                for number in 0..<(Self.pyramidFaces.count * 3) { canvas.index(number) }
                canvas.endShape()
            }
        }

        let baked = try makeCanvas(width: 128, height: 128)
        let inner = gem(on: baked)
        let outer = baked.createShape {
            baked.scale(-1, 1, 1)
            baked.rotateY(0.6)
            baked.rotateX(0.5)
            baked.shape(inner)
        }
        let placed = try frontLitPicture(baked) { baked.shape(outer) }

        let direct = try makeCanvas(width: 128, height: 128)
        let reference = gem(on: direct)
        let rotated = try frontLitPicture(direct) {
            direct.rotateY(-0.6)
            direct.rotateX(0.5)
            direct.shape(reference)
        }
        let difference = PictureDifference.between(placed, rotated)
        #expect(difference.shapePixels > 1000, "形が写っていない (\(difference))")
        #expect(
            difference.fraction <= 0.02, "形の中で鏡映した形が逆に回した形と食い違う (\(difference))")
    }

    // MARK: - 貼る絵が記録に残ること

    /// 縞の絵を焼く。
    ///
    /// **一色にしない。** 焼き場 (字形の面) の空いている区画は白なので、白い絵を貼ると
    /// 「記録した面を読んだ」と「焼き場を読んだ」が同じ絵になり、[#914] を見分けられない。
    ///
    /// [#914]: https://github.com/mokume-metal/mokume/issues/914
    private func makeStripes(_ canvas: Canvas) throws -> Image {
        let picture = try canvas.createImage(8, 8)
        for y in 0..<8 {
            for x in 0..<8 {
                picture.set(
                    x, y,
                    (x + y) % 2 == 0
                        ? .linear(red: 0.9, green: 0.1, blue: 0.1)
                        : .linear(red: 0.1, green: 0.2, blue: 0.9))
            }
        }
        return picture
    }

    /// 完了条件 1・2。**組んだフレームより後で置いても、記録した絵で出る。**
    ///
    /// 置く側は `texture()` を呼んでいないので、面を置く側の状態で選び直す実装では
    /// 焼き場へ倒れる ([#914])。その場で描いた絵と突き合わせれば、倒れたことが画素に出る。
    ///
    /// [#914]: https://github.com/mokume-metal/mokume/issues/914
    @Test("絵を貼った立体は、組んだフレームより後で置いても記録した絵で出る")
    func retainedTexturedSolidKeepsItsPicture() throws {
        func paint(_ canvas: Canvas, _ picture: Image) {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.texture(picture)
            canvas.beginShape(.triangles)
            canvas.normal(0, 0, 1)
            canvas.vertex(-20, -20, 0, 0, 0)
            canvas.normal(0, 0, 1)
            canvas.vertex(20, -20, 0, 8, 0)
            canvas.normal(0, 0, 1)
            canvas.vertex(0, 20, 0, 4, 8)
            canvas.endShape()
        }

        let immediate = try makeCanvas()
        let immediatePicture = try makeStripes(immediate)
        try immediate.draw {
            immediate.background(.linear(red: 0, green: 0, blue: 0))
            immediate.push()
            immediate.translate(32, 32, 0)
            paint(immediate, immediatePicture)
            immediate.pop()
        }

        let retained = try makeCanvas()
        let retainedPicture = try makeStripes(retained)
        // **フレームの外で組む。** ここが #914 の要である
        let shape = retained.createShape { paint(retained, retainedPicture) }
        try retained.draw {
            retained.background(.linear(red: 0, green: 0, blue: 0))
            retained.push()
            retained.translate(32, 32, 0)
            retained.shape(shape)
            retained.pop()
        }

        #expect(try retained.target.readPixels() == immediate.target.readPixels())
    }

    /// 完了条件 3。**平面の区間でも同じことが成り立つ。**
    ///
    /// `beginFlat` は面を触らないので現状でも通るが、検査が無かった — 立体だけ直して
    /// 平面が割れる (あるいはその逆) を捕まえる場所として置く。
    @Test("絵を貼った平面の形も、組んだフレームより後で置いても記録した絵で出る")
    func retainedTexturedFlatKeepsItsPicture() throws {
        func paint(_ canvas: Canvas, _ picture: Image) {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.texture(picture)
            canvas.beginShape()
            canvas.vertex(8, 8, 0, 0)
            canvas.vertex(56, 8, 8, 0)
            canvas.vertex(56, 56, 8, 8)
            canvas.vertex(8, 56, 0, 8)
            canvas.endShape(.close)
        }

        let immediate = try makeCanvas()
        let immediatePicture = try makeStripes(immediate)
        try immediate.draw {
            immediate.background(.linear(red: 0, green: 0, blue: 0))
            paint(immediate, immediatePicture)
        }

        let retained = try makeCanvas()
        let retainedPicture = try makeStripes(retained)
        let shape = retained.createShape { paint(retained, retainedPicture) }
        try retained.draw {
            retained.background(.linear(red: 0, green: 0, blue: 0))
            retained.shape(shape)
        }

        #expect(try retained.target.readPixels() == immediate.target.readPixels())
    }

    /// 完了条件 4。**その場で並べる頂点は、その場で束ねた絵で決まる。**
    ///
    /// 記録した形とは向きが逆で、こちらは置く側 (= その場) の状態が正しい。
    /// これを守っているのは `appendSolidVertex` で、頂点ごとに `uv` の有無を見て
    /// 面を選び直している — つまり `beginSolids` の `useFillTexture()` は
    /// **この経路にとっては冗長である** (外しても本検査は通る。実測した)。
    ///
    /// それでも置くのは、#914 の直しがこちらの向きを壊していないことを見るためである。
    @Test("その場で並べる立体は、その場で束ねた絵で決まる")
    func immediateSolidUsesTheBoundPicture() throws {
        func paint(_ canvas: Canvas) {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.beginShape(.triangles)
            canvas.normal(0, 0, 1)
            canvas.vertex(-20, -20, 0, 0, 0)
            canvas.normal(0, 0, 1)
            canvas.vertex(20, -20, 0, 8, 0)
            canvas.normal(0, 0, 1)
            canvas.vertex(0, 20, 0, 4, 8)
            canvas.endShape()
        }

        let bound = try makeCanvas()
        let picture = try makeStripes(bound)
        try bound.draw {
            bound.background(.linear(red: 0, green: 0, blue: 0))
            bound.texture(picture)
            bound.push()
            bound.translate(32, 32, 0)
            paint(bound)
            bound.pop()
        }

        let unbound = try makeCanvas()
        try unbound.draw {
            unbound.background(.linear(red: 0, green: 0, blue: 0))
            unbound.noTexture()
            unbound.push()
            unbound.translate(32, 32, 0)
            paint(unbound)
            unbound.pop()
        }

        // 束ねた側は縞を読み、束ねていない側は焼き場を読む — **同じ絵にはならない**
        #expect(try bound.target.readPixels() != unbound.target.readPixels())
    }

    // MARK: - 組んだ後に書き換えた絵

    /// 形が絵を読む口。**記録した面は 2 か所に残る** — 貼る絵 (`Run.texture`) と、断片へ
    /// 渡した面 (`Run.paint.surfaces`)。貼る絵は平面と立体で置き直す経路が分かれる。
    enum PictureReader: String, CaseIterable, CustomTestStringConvertible {
        case flat
        case solid
        case shaderSurface

        var testDescription: String {
            switch self {
            case .flat: "貼った平面"
            case .solid: "貼った立体"
            case .shaderSurface: "断片の面"
            }
        }

        /// `picture` を読んで描く手順。形の中でもその場でも同じものを使う。
        @MainActor
        func body(_ canvas: Canvas, _ picture: Image) throws -> () -> Void {
            switch self {
            case .flat:
                return {
                    canvas.noStroke()
                    canvas.fill(.linear(red: 1, green: 1, blue: 1))
                    canvas.texture(picture)
                    canvas.beginShape()
                    canvas.vertex(8, 8, 0, 0)
                    canvas.vertex(56, 8, 8, 0)
                    canvas.vertex(56, 56, 8, 8)
                    canvas.vertex(8, 56, 0, 8)
                    canvas.endShape(.close)
                }
            case .solid:
                return {
                    canvas.noStroke()
                    canvas.fill(.linear(red: 1, green: 1, blue: 1))
                    canvas.texture(picture)
                    canvas.beginShape(.triangles)
                    canvas.normal(0, 0, 1)
                    canvas.vertex(12, 12, 0, 0, 0)
                    canvas.normal(0, 0, 1)
                    canvas.vertex(52, 12, 0, 8, 0)
                    canvas.normal(0, 0, 1)
                    canvas.vertex(32, 52, 0, 4, 8)
                    canvas.endShape()
                }
            case .shaderSurface:
                let shader = try canvas.makeShader(
                    """
                    float4 paint(Fragment in, Values values, Surfaces surfaces) {
                        return mokume_sample(surfaces.tone, in.place);
                    }
                    """,
                    surfaces: ["tone": .image(picture)])
                return {
                    canvas.noStroke()
                    canvas.shader(shader)
                    canvas.rect(8, 8, 48, 48)
                }
            }
        }
    }

    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)

    /// #1253 の完了条件 1・2。**組んだ後で書き換えた絵は、形だけを置き直したフレームにも出る。**
    ///
    /// 同じフレームで `image()` を描くと、そちらの経路が送るので隠れる。ここでは形の他に
    /// 何も描かず、書き換えた後の絵をその場で描いたものと突き合わせる。
    @Test(
        "組んだ後で絵を書き換えると、形だけを置き直したフレームに書き換えた画素が出る",
        arguments: PictureReader.allCases)
    func rewrittenPictureReachesAReplacedShape(_ reader: PictureReader) throws {
        let retained = try makeCanvas()
        let picture = try retained.createImage(8, 8)
        picture.fill(red)
        let shape = retained.createShape(try reader.body(retained, picture))
        try retained.draw {
            retained.background(.linear(red: 0, green: 0, blue: 0))
            retained.shape(shape)
        }
        let before = try retained.target.readPixels()

        picture.fill(green)
        try retained.draw {
            retained.background(.linear(red: 0, green: 0, blue: 0))
            retained.shape(shape)
        }
        let after = try retained.target.readPixels()

        let immediate = try makeCanvas()
        let immediatePicture = try immediate.createImage(8, 8)
        immediatePicture.fill(green)
        let paint = try reader.body(immediate, immediatePicture)
        try immediate.draw {
            immediate.background(.linear(red: 0, green: 0, blue: 0))
            paint()
        }

        // 書き換えが絵を変えることの裏 (変わらない絵なら、送らなくても一致してしまう)
        #expect(before != after, "書き換えた画素が面へ送られていない")
        #expect(after == (try immediate.target.readPixels()))
    }

    /// #1253 の完了条件 3。**書き換えていない絵は、置き直しても送りを頼まない。**
    ///
    /// 送りは描き切りが届けるので、頼んだことは登録簿 (`RenderDevice.pendingUploads`) に
    /// 載ったかで見る (#749)。置く口の直後に見て、書き換えたフレームでは載ることも見る —
    /// 載らない実装でも通る検査にしない。
    @Test("書き換えていない絵を読む形は、置き直しても送りを頼まない", arguments: PictureReader.allCases)
    func untouchedPictureIsNotSentAgainWhenReplaced(_ reader: PictureReader) throws {
        let canvas = try makeCanvas()
        let picture = try canvas.createImage(8, 8)
        picture.fill(red)
        let shape = canvas.createShape(try reader.body(canvas, picture))
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(shape)
        }
        #expect(!picture.needsUpload, "組んだときの絵が届いていない")

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(shape)
            canvas.shape(shape, 4, 4)
            #expect(!picture.isQueuedForUpload, "書き換えていない絵の送りを頼んでいる")
            #expect(canvas.gpu.pendingUploads.isEmpty)
        }

        picture.fill(green)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shape(shape)
            // 2 度置いても、登録簿には 1 度だけ載る
            canvas.shape(shape, 4, 4)
            #expect(picture.isQueuedForUpload, "書き換えた絵の送りを頼んでいない")
            #expect(canvas.gpu.pendingUploads.owners.count == 1)
        }
        #expect(!picture.needsUpload, "書き換えた絵が描き切りで届いていない")
    }

    @Test("何も入っていない形を置いても、何も起きない")
    func placingAnEmptyShapeDoesNothing() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 1))
            canvas.shape(.empty)
            canvas.shape(canvas.createShape {})
        }
        #expect(canvas.get(4, 4) == .linear(red: 0, green: 0, blue: 1))
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
