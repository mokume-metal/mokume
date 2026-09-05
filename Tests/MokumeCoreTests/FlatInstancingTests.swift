// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 平面の雛形を畳んでたくさん置くときの検査 ([#424])。GPU を要する。
///
/// **絵だけでは、畳まれていなくても同じ絵が出る。** 畳まれていることは組み立てて積んだ
/// 頂点の数で数え、畳み方が絵を変えていないことは画素で見る ([ADR-0019] 決定 4)。
///
/// 数えるのが**描画の呼び出し回数ではない**のは、平面が元から 1 つの列にまとまるためで
/// ある — 畳んでも畳まなくても回数は変わらず、変わるのは積む頂点の数のほうで、それが
/// #424 で律速だったものである。
///
/// ## どの塗りで駆動するか
///
/// 基本図形 (矩形・楕円・扇形・線・点) は [#752] で距離関数の経路へ移り、頂点を 1 つも
/// 積まなくなった (`FormShapeTests`)。**素の図形はもうここへ来ない** — `formAllowed(fills:)`
/// が距離関数へ流すので、雛形の畳みに届くのは次の 2 つだけである:
///
/// - **貼る絵** (`texture()`) が効いた塗りを持つ図形 (輪郭は持てない。1 つの図形の
///   途中で読む面が割れるので、`draw(folding:at:outline:)` が畳まずに落とす)
/// - **利用者の断片** (`shader()`) が効いている間の図形 (塗りも輪郭も畳める)
///
/// だから検査もこの 2 つで駆動する。**素の図形で書くと、畳みが丸ごと壊れても緑のまま
/// 通る** — 距離関数の経路に流れて `flatVertices` が 0 対 0 で釣り合うためで、
/// [#770] はその状態を直したものである。
///
/// [#424]: https://github.com/mokume-metal/mokume/issues/424
/// [#752]: https://github.com/mokume-metal/mokume/issues/752
/// [#770]: https://github.com/mokume-metal/mokume/issues/770
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "平面のまとめ描き",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FlatInstancingTests {
    /// 雛形の畳みへ届く塗り。**これ以外の塗りは距離関数の経路へ行く。**
    enum Paint: CaseIterable {
        /// 貼る絵 (`texture()`) が効いた塗り。輪郭は持てない (持つと畳まれない)。
        case textured
        /// 利用者の断片 (`shader()`) が効いている間。塗りも輪郭も畳める。
        case shaded
    }

    private func makeCanvas(width: Int = 96, height: Int = 96) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 置き場所を格子状に並べる。**どれも重ならない** — 重なると、畳み方で変わるのは
    /// 頂点を積む順だけなのに、絵の比較が重ね順の違いを拾ってしまう。
    private func grid(_ count: Int) -> [SIMD2<Float>] {
        (0..<count).map { index in
            SIMD2(10 + Float(index % 6) * 15, 10 + Float(index / 6) * 15)
        }
    }

    /// 畳みへ届く塗りを整えて、渡した中身を描く。
    ///
    /// 断片は**図形の色をそのまま返す** — 塗りと輪郭の色が置き場所から来ていることを
    /// 画素で見るために、断片が色を作ってしまっては困る。
    private func scene(
        _ canvas: Canvas, _ paint: Paint, _ body: (Canvas) -> Void
    ) throws -> DisplayImage {
        switch paint {
        case .textured:
            let sheet = try canvas.createImage(8, 8)
            sheet.fill(.linear(red: 1, green: 1, blue: 1))
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
                canvas.noStroke()
                canvas.texture(sheet)
                body(canvas)
            }
        case .shaded:
            let shader = try canvas.makeShader(
                "float4 paint(Fragment in, Values values) { return in.color; }")
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
                canvas.stroke(.linear(red: 0.1, green: 0.3, blue: 0.9))
                canvas.strokeWeight(2)
                canvas.shader(shader)
                body(canvas)
            }
        }
        return try canvas.target.encodeForDisplay()
    }

    // MARK: - 自動で畳まれる

    @Test(
        "同じ円を 1 つ置いても 200 個置いても、積む頂点は同じ数",
        arguments: Paint.allCases)
    func repeatedCirclesStackTheSameVertices(_ paint: Paint) throws {
        let one = try makeCanvas()
        _ = try scene(one, paint) { $0.circle(48, 48, 14) }
        let many = try makeCanvas()
        _ = try scene(many, paint) { canvas in
            for place in grid(200) { canvas.circle(place.x, place.y, 14) }
        }
        #expect(one.flatVerticesInLastFrame > 0, "この塗りが畳みの経路へ来ていない")
        #expect(many.flatVerticesInLastFrame == one.flatVerticesInLastFrame)
        #expect(many.drawCallsInLastFrame == 1, "畳んだのに列が分かれている")
        // 1 つ目を普通に置いたぶんと、雛形を積み直したぶん。**200 個ぶんは組み立てない**
        #expect(many.flatOutlinesInLastFrame == 2, "置いた数だけ周を組み立てている")
    }

    @Test("塗りと輪郭の色を置き場所ごとに変えても、畳まれたまま出る")
    func eachPlacementCarriesItsOwnColors() throws {
        // **置き場所は色を 2 つ持つ。** 塗りと輪郭は 1 つの雛形に入っていて、頂点の
        // 番号がどちらを掛けるかを決める — 境目を取り違えると、輪郭まで塗りの色で出る。
        // 輪郭も畳める側の塗り (利用者の断片) で見る
        let canvas = try makeCanvas()
        let image = try scene(canvas, .shaded) { canvas in
            canvas.stroke(.linear(red: 0.1, green: 0.9, blue: 0.1))
            canvas.fill(.linear(red: 1, green: 0.15, blue: 0.15))
            canvas.circle(26, 48, 20)
            canvas.fill(.linear(red: 0.15, green: 0.15, blue: 1))
            canvas.circle(70, 48, 20)
        }
        // 色は鍵に入らないので、**2 つで雛形 1 つぶん**しか積まない
        let one = try makeCanvas()
        _ = try scene(one, .shaded) { $0.circle(26, 48, 20) }
        #expect(canvas.drawCallsInLastFrame == 1, "色を変えただけで列が分かれている")
        #expect(
            canvas.flatVerticesInLastFrame == one.flatVerticesInLastFrame,
            "色を変えただけで畳まれなくなっている")
        #expect(image[26, 48].red > image[26, 48].blue, "左の塗りが赤くない")
        #expect(image[70, 48].blue > image[70, 48].red, "右の塗りが青くない")
        // 周の上 (中心から半径 10) は、どちらも輪郭の緑で出る
        #expect(image[36, 48].green > image[36, 48].red, "左の輪郭が塗りの色で出ている")
        #expect(image[80, 48].green > image[80, 48].blue, "右の輪郭が塗りの色で出ている")
    }

    @Test("塗りを止めた図形も、輪郭だけで畳まれる")
    func strokeOnlyShapesFoldToo() throws {
        // 貼る絵は**塗りにしか効かない**ので、塗りを止めた図形は距離関数の経路へ行く
        // (`formAllowed(fills:)`)。輪郭だけの畳みが残っているのは断片の側だけ
        let canvas = try makeCanvas()
        let image = try scene(canvas, .shaded) { canvas in
            canvas.noFill()
            for place in grid(12) { canvas.circle(place.x, place.y, 10) }
        }
        let one = try makeCanvas()
        _ = try scene(one, .shaded) { canvas in
            canvas.noFill()
            canvas.circle(48, 48, 10)
        }
        #expect(one.flatVerticesInLastFrame > 0, "輪郭だけの図形が畳みの経路へ来ていない")
        #expect(canvas.flatVerticesInLastFrame == one.flatVerticesInLastFrame)
        // 最初の円は中心 (10, 10)・半径 5。周の上を見る (中心は塗られていない)
        #expect(image[15, 10].blue > image[15, 10].red, "輪郭が出ていない")
        #expect(image[10, 10].blue == 0, "止めたはずの塗りが出ている")
    }

    // MARK: - 2 つ目が来るまで待つ

    @Test("矩形と円を交互に置いても、列は分かれない", arguments: Paint.allCases)
    func alternatingFormsStayInOneCall(_ paint: Paint) throws {
        // **畳もうとして列が増えては元も子もない。** 平面は元から 1 つの列にまとまるので、
        // 畳めない並びでは今までどおり 1 列に収まらなければならない。1 つ目から雛形を
        // 開くと、ここで図形の数だけ列が分かれる (`pendingFlat` が防いでいるもの)
        let canvas = try makeCanvas()
        _ = try scene(canvas, paint) { canvas in
            for place in grid(24) {
                canvas.rect(place.x, place.y, 8, 8)
                canvas.circle(place.x, place.y, 8)
            }
        }
        #expect(canvas.drawCallsInLastFrame == 1, "交互に置いただけで列が分かれている")
        #expect(canvas.flatOutlinesInLastFrame == 48, "畳めない並びが畳まれている")
    }

    @Test(
        "間に何か挟むと畳まれず、挟まなければ畳まれる",
        arguments: Paint.allCases)
    func anInterruptionCancelsTheWait(_ paint: Paint) throws {
        // 待ち合わせは**溜め場の末尾にいる間だけ**成立する (`vertexEnd == vertices.count`)。
        // 間に畳めないもの (任意多角形) が入ると 1 つ目の頂点はもう抜けないので、畳まない
        func stack(interrupted: Bool) throws -> Int {
            let canvas = try makeCanvas()
            _ = try scene(canvas, paint) { canvas in
                canvas.circle(20, 20, 12)
                if interrupted { canvas.triangle(60, 10, 90, 10, 75, 40) }
                canvas.circle(20, 60, 12)
                if !interrupted { canvas.triangle(60, 10, 90, 10, 75, 40) }
            }
            return canvas.flatVerticesInLastFrame
        }
        let folded = try stack(interrupted: false)
        let loose = try stack(interrupted: true)
        #expect(folded < loose, "待ち合わせが挟んだものを跨いでいる")
    }

    // MARK: - 上限で列を開き直す

    /// 上限は既定 8192。**仕組みの都合ではなく規律**なので、検査からは下げて
    /// 「まとめきれずに開き直す」経路を必ず踏ませる (立体と同じ差し替え口)。
    @Test("上限に達したら、同じ形のまま雛形を開き直す", arguments: Paint.allCases)
    func reachingTheCapacityReopensTheTemplate(_ paint: Paint) throws {
        #expect(Canvas.defaultInstanceCapacity == 8192, "既定の上限が説明と食い違っている")

        let whole = try makeCanvas()
        let full = try scene(whole, paint) { canvas in
            for place in grid(12) { canvas.circle(place.x, place.y, 12) }
        }
        #expect(whole.drawCallsInLastFrame == 1)
        let template = whole.flatVerticesInLastFrame
        #expect(template > 0, "この塗りが畳みの経路へ来ていない")

        // 上限 3 — 12 個が 4 本に割れる。**開き直すたびに雛形を積み直す**ので、
        // 積む頂点は雛形 4 つぶんちょうどになる
        let limited = try makeCanvas()
        limited.instanceCapacity = 3
        let split = try scene(limited, paint) { canvas in
            for place in grid(12) { canvas.circle(place.x, place.y, 12) }
        }
        #expect(limited.drawCallsInLastFrame == 4, "上限で列が分かれていない")
        #expect(limited.flatVerticesInLastFrame == template * 4, "雛形を積み直していない")
        #expect(full.bytes == split.bytes, "畳み方で絵が変わっている")
    }

    @Test("上限 1 なら、待ち合わせから昇格した 2 つ目も別の列になる", arguments: Paint.allCases)
    func aCapacityOfOneSplitsThePromotedPairToo(_ paint: Paint) throws {
        // 上限に届くもう 1 つの口は、**待ち合わせていた 1 つ目を昇格させる側**にある。
        // 上限 1 では 2 つ目がその場で別の雛形へ回るので、ここを踏まないと分岐が死ぬ
        let whole = try makeCanvas()
        let full = try scene(whole, paint) { canvas in
            for place in grid(12) { canvas.circle(place.x, place.y, 12) }
        }
        let template = whole.flatVerticesInLastFrame
        #expect(template > 0, "この塗りが畳みの経路へ来ていない")

        let apart = try makeCanvas()
        apart.instanceCapacity = 1
        let split = try scene(apart, paint) { canvas in
            for place in grid(12) { canvas.circle(place.x, place.y, 12) }
        }
        #expect(apart.drawCallsInLastFrame == 12, "上限 1 で図形ごとに列が分かれていない")
        #expect(apart.flatVerticesInLastFrame == template * 12, "雛形を積み直していない")
        #expect(full.bytes == split.bytes, "畳み方で絵が変わっている")
    }

    // MARK: - 畳んでも絵が変わらない

    @Test("畳める並びと畳めない並びで、絵は 1 ビットも違わない", arguments: Paint.allCases)
    func foldingDoesNotChangeThePicture(_ paint: Paint) throws {
        // **同じ図形を、畳める順と畳めない順で置く。** 置き場所は互いに重ならないので、
        // 重ね順が変わっても絵は同じでなければならない — 違えば、畳んだ側が変換か色を
        // 取り違えている
        let places = grid(24)
        func picture(_ canvas: Canvas, folded: Bool) throws -> DisplayImage {
            try scene(canvas, paint) { canvas in
                if folded {
                    for place in stride(from: 0, to: places.count, by: 2).map({ places[$0] }) {
                        canvas.rect(place.x, place.y, 9, 9)
                    }
                    for place in stride(from: 1, to: places.count, by: 2).map({ places[$0] }) {
                        canvas.circle(place.x, place.y, 9)
                    }
                } else {
                    for (index, place) in places.enumerated() {
                        if index.isMultiple(of: 2) {
                            canvas.rect(place.x, place.y, 9, 9)
                        } else {
                            canvas.circle(place.x, place.y, 9)
                        }
                    }
                }
            }
        }
        let together = try makeCanvas()
        let folded = try picture(together, folded: true)
        let apart = try makeCanvas()
        let loose = try picture(apart, folded: false)
        #expect(
            together.flatVerticesInLastFrame < apart.flatVerticesInLastFrame,
            "畳める並びで畳まれていない")
        #expect(folded.bytes == loose.bytes, "畳み方で絵が変わっている")
    }

    @Test("変換を積んで置いても、畳んだ絵と 1 つずつの絵が一致する", arguments: Paint.allCases)
    func foldingKeepsTransformedShapesIdentical(_ paint: Paint) throws {
        // 変換は置き場所が持つ。**雛形の頂点には掛けない**ので、取り違えると二重に効く
        func picture(_ canvas: Canvas) throws -> DisplayImage {
            try scene(canvas, paint) { canvas in
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
        let together = try makeCanvas()
        let folded = try picture(together)
        let apart = try makeCanvas()
        apart.instanceCapacity = 1
        let loose = try picture(apart)
        #expect(together.drawCallsInLastFrame == 1)
        #expect(apart.drawCallsInLastFrame == 18, "上限で列が分かれていない")
        #expect(folded.bytes == loose.bytes, "畳み方で絵が変わっている")
    }

    @Test("畳めないものを挟んでも、絵は変わらない", arguments: Paint.allCases)
    func uncollapsibleThingsInBetweenKeepThePicture(_ paint: Paint) throws {
        // 字・線・その場で並べた頂点は畳めない。**何も動かさない置き場所**を通るので、
        // 畳んだ図形と混ざっても絵は変わらないはず
        func picture(_ canvas: Canvas) throws -> DisplayImage {
            try scene(canvas, paint) { canvas in
                for place in grid(12) { canvas.circle(place.x, place.y, 10) }
                canvas.line(4, 4, 92, 92)
                canvas.text("mokume", 8, 90)
                for place in grid(12) { canvas.rect(place.x, place.y, 9, 9) }
            }
        }
        let together = try makeCanvas()
        let folded = try picture(together)
        let apart = try makeCanvas()
        apart.instanceCapacity = 1
        let loose = try picture(apart)
        #expect(
            together.drawCallsInLastFrame < apart.drawCallsInLastFrame,
            "畳めるものが畳まれていない")
        #expect(folded.bytes == loose.bytes, "畳み方で絵が変わっている")
    }

    // MARK: - 並びの取り決め

    @Test("置き場所の並びは、シェーダ側と同じ大きさである")
    func theInstanceLayoutMatchesTheShader() throws {
        #expect(MemoryLayout<FlatInstance>.stride == FlatInstance.expectedStride)
    }
}
