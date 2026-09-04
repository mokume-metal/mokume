// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 平面の図形をたくさん置くときの検査。GPU を要する。
///
/// **絵だけでは、畳まれていなくても同じ絵が出る。** 畳まれていることは組み立てて積んだ
/// 頂点の数で数え、畳み方が絵を変えていないことは画素で見る ([ADR-0019] 決定 4)。
///
/// 数えるのが**描画の呼び出し回数ではない**のは、平面が元から 1 つの列にまとまるためで
/// ある — 畳んでも畳まなくても回数は変わらず、変わるのは積む頂点の数のほうで、それが
/// [#424](https://github.com/mokume-metal/mokume/issues/424) で律速だったものである。
///
/// 基本図形 (矩形・楕円・扇形・線・点) は [#752](https://github.com/mokume-metal/mokume/issues/752)
/// で距離関数の経路へ移り、頂点を 1 つも積まなくなった (`FormShapeTests`)。ここに残る
/// 雛形の畳みが効くのは、貼る絵か利用者の断片が効いている図形だけである。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "平面のまとめ描き",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FlatInstancingTests {
    private func makeCanvas(width: Int = 96, height: Int = 96) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 置き場所を格子状に並べる。
    private func grid(_ count: Int) -> [SIMD2<Float>] {
        (0..<count).map { index in
            SIMD2(10 + Float(index % 6) * 15, 10 + Float(index / 6) * 15)
        }
    }

    /// 塗りを揃えた場面で、渡した中身を描く。
    private func scene(_ canvas: Canvas, _ body: (Canvas) -> Void) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.fill(.opaque(red: 0.8, green: 0.6, blue: 0.4))
            canvas.stroke(.opaque(red: 0.1, green: 0.3, blue: 0.9))
            canvas.strokeWeight(2)
            body(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    // MARK: - 自動で畳まれる

    @Test("同じ円を 1 つ置いても 200 個置いても、積む頂点は同じ数")
    func repeatedCirclesStackTheSameVertices() throws {
        let one = try makeCanvas()
        _ = try scene(one) { $0.circle(48, 48, 14) }
        let many = try makeCanvas()
        _ = try scene(many) { canvas in
            for place in grid(200) { canvas.circle(place.x, place.y, 14) }
        }
        #expect(many.flatVerticesInLastFrame == one.flatVerticesInLastFrame)
        #expect(many.drawCallsInLastFrame == 1, "畳んだのに列が分かれている")
    }

    @Test("矩形と円を交互に置いても、列は分かれない")
    func alternatingFormsStayInOneCall() throws {
        // **畳もうとして列が増えては元も子もない。** 平面は元から 1 つの列にまとまるので、
        // 畳めない並びでは今までどおり 1 列に収まらなければならない
        let canvas = try makeCanvas()
        _ = try scene(canvas) { canvas in
            for place in grid(24) {
                canvas.rect(place.x, place.y, 8, 8)
                canvas.circle(place.x, place.y, 8)
            }
        }
        #expect(canvas.drawCallsInLastFrame == 1, "交互に置いただけで列が分かれている")
    }

    @Test("塗りと輪郭の色を置き場所ごとに変えても、畳まれたまま出る")
    func eachPlacementCarriesItsOwnColors() throws {
        // **置き場所は色を 2 つ持つ。** 塗りと輪郭は 1 つの雛形に入っていて、頂点の
        // 番号がどちらを掛けるかを決める — 境目を取り違えると、輪郭まで塗りの色で出る
        let canvas = try makeCanvas()
        let image = try scene(canvas) { canvas in
            canvas.stroke(.opaque(red: 0.1, green: 0.9, blue: 0.1))
            canvas.fill(.opaque(red: 1, green: 0.15, blue: 0.15))
            canvas.circle(26, 48, 20)
            canvas.fill(.opaque(red: 0.15, green: 0.15, blue: 1))
            canvas.circle(70, 48, 20)
        }
        #expect(canvas.drawCallsInLastFrame == 1, "色を変えただけで列が分かれている")
        #expect(image[26, 48].red > image[26, 48].blue, "左の塗りが赤くない")
        #expect(image[70, 48].blue > image[70, 48].red, "右の塗りが青くない")
        // 周の上 (中心から半径 10) は、どちらも輪郭の緑で出る
        #expect(image[36, 48].green > image[36, 48].red, "左の輪郭が塗りの色で出ている")
        #expect(image[80, 48].green > image[80, 48].blue, "右の輪郭が塗りの色で出ている")
    }

    // MARK: - 畳んでも絵が変わらない

    /// 畳めない側を必ず踏ませる。**上限 1 なら図形ごとに列が分かれる。**
    ///
    /// 通常は数万個置かないと踏めない経路なので、立体と同じ上限の差し替え口を使う
    /// (`instanceCapacity`)。新しい機構は足していない。
    private func apart(_ canvas: Canvas) -> Canvas {
        canvas.instanceCapacity = 1
        return canvas
    }

    @Test("畳んでも、1 つずつ置いたときと同じ絵になる")
    func foldingDoesNotChangeThePicture() throws {
        func picture(_ canvas: Canvas) throws -> DisplayImage {
            try scene(canvas) { canvas in
                for place in grid(24) { canvas.circle(place.x, place.y, 12) }
            }
        }
        let together = try makeCanvas()
        let split = apart(try makeCanvas())
        #expect(try picture(together).bytes == (try picture(split)).bytes)
        #expect(together.drawCallsInLastFrame == 1)
        #expect(split.drawCallsInLastFrame == 24, "上限で列が分かれていない")
    }

    @Test("変換を積んで置いても、畳んだ絵と 1 つずつの絵が一致する")
    func foldingKeepsTransformedShapesIdentical() throws {
        func picture(_ canvas: Canvas) throws -> DisplayImage {
            try scene(canvas) { canvas in
                for (index, place) in grid(18).enumerated() {
                    canvas.push()
                    canvas.translate(place.x, place.y)
                    canvas.rotate(Float(index) * 0.2)
                    canvas.scale(1 + Float(index) * 0.02, 1)
                    canvas.rect(-5, -5, 10, 10)
                    canvas.pop()
                }
            }
        }
        #expect(try picture(try makeCanvas()).bytes == (try picture(apart(try makeCanvas()))).bytes)
    }

    @Test("上限を超えても、絵は変わらず列だけが増える")
    func exceedingTheCapacityOnlyAddsCalls() throws {
        func picture(_ canvas: Canvas) throws -> DisplayImage {
            try scene(canvas) { canvas in
                for place in grid(12) { canvas.circle(place.x, place.y, 12) }
            }
        }
        let full = try makeCanvas()
        let whole = try picture(full)
        #expect(full.drawCallsInLastFrame == 1)

        let limited = try makeCanvas()
        limited.instanceCapacity = 3
        let split = try picture(limited)
        #expect(limited.drawCallsInLastFrame == 4, "上限で列が分かれていない")
        #expect(whole.bytes == split.bytes, "畳み方で絵が変わっている")
    }

    @Test("畳めないものを挟んでも、絵は変わらない")
    func uncollapsibleThingsInBetweenKeepThePicture() throws {
        // 字・線・その場で並べた頂点は畳めない。**何も動かさない置き場所**を通るので、
        // 畳んだ図形と混ざっても絵は変わらないはず
        func picture(_ canvas: Canvas) throws -> DisplayImage {
            try scene(canvas) { canvas in
                for place in grid(12) { canvas.circle(place.x, place.y, 10) }
                canvas.line(4, 4, 92, 92)
                canvas.text("mokume", 8, 90)
                for place in grid(12) { canvas.rect(place.x, place.y, 9, 9) }
            }
        }
        #expect(try picture(try makeCanvas()).bytes == (try picture(apart(try makeCanvas()))).bytes)
    }

    @Test("塗りを止めた図形も、輪郭だけで畳まれる")
    func strokeOnlyShapesFoldToo() throws {
        let canvas = try makeCanvas()
        let image = try scene(canvas) { canvas in
            canvas.noFill()
            for place in grid(12) { canvas.circle(place.x, place.y, 10) }
        }
        let one = try makeCanvas()
        _ = try scene(one) { canvas in
            canvas.noFill()
            canvas.circle(48, 48, 10)
        }
        #expect(canvas.flatVerticesInLastFrame == one.flatVerticesInLastFrame)
        // 最初の円は中心 (10, 10)・半径 5。周の上を見る (中心は塗られていない)
        #expect(image[15, 10].blue > image[15, 10].red, "輪郭が出ていない")
        #expect(image[10, 10].blue == 0, "止めたはずの塗りが出ている")
    }

    // MARK: - 並びの取り決め

    @Test("置き場所の並びは、シェーダ側と同じ大きさである")
    func theInstanceLayoutMatchesTheShader() throws {
        #expect(MemoryLayout<FlatInstance>.stride == FlatInstance.expectedStride)
    }
}
