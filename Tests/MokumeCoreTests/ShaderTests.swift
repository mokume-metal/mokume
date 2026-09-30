// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 利用者が書いた塗りの検査。GPU を要する。
@Suite(
    "利用者が書く塗り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShaderTests {
    private func makeCanvas(width: Int = 32, height: Int = 32) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 渡した値をそのまま色にする断片。値の届き方を見るのに使う。
    private static let valueShader = """
        float4 paint(Fragment in, Values values) {
            return float4(values.level, 0.0, 0.0, 1.0);
        }
        """

    // MARK: - 経路に載ること

    @Test("断片は、図形をまとめて描く経路に載る")
    func aFragmentRidesTheBatchedPath() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }")

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            // 矩形と円を続けて置く。まとめて描く経路に載らないと、ここが対象外になる
            canvas.rect(0, 0, 16, 32)
            canvas.circle(24, 16, 12)
        }
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(canvas.get(8, 16) == .linear(red: 0, green: 1, blue: 0))
        #expect(canvas.get(24, 16) == .linear(red: 0, green: 1, blue: 0))
    }

    @Test("断片は、字と画像を描く経路にも載る")
    func aFragmentAlsoRidesTheTextAndImagePaths() throws {
        let canvas = try makeCanvas(width: 64, height: 32)
        // **どちらの経路でも読む面は色である。** 読んだ濃さで青を出す 1 本で足りる
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return float4(0.0, 0.0, 1.0, 1.0) * in.texel.a;
            }
            """)
        let image = try canvas.createImage(8, 8)
        image.fill(.linear(red: 1, green: 0, blue: 0))

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shader(shader)
            canvas.textFont("Helvetica")
            canvas.textSize(24)
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.text("I", 8, 26)
            canvas.image(image, 40, 8, 16, 16)
        }
        // 画像の面を読む経路でも断片が効いている (赤ではなく青になる)
        #expect(canvas.get(48, 16) == .linear(red: 0, green: 0, blue: 1))
        // 字を読む経路でも同じ断片が効いている (白ではなく青が出ている)
        var sawBlueGlyph = false
        for y in 8..<26 {
            for x in 4..<28 {
                let pixel = canvas.get(x, y)
                if pixel.blue > 0.5, pixel.red < 0.1, pixel.green < 0.1 { sawBlueGlyph = true }
            }
        }
        #expect(sawBlueGlyph)
    }

    @Test("組み込みの塗りへ戻せる")
    func theBuiltInPaintCanBeRestored() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }")

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 32)
            canvas.resetShader()
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(16, 0, 16, 32)
        }
        #expect(canvas.get(8, 16) == .linear(red: 0, green: 1, blue: 0))
        #expect(canvas.get(24, 16) == .linear(red: 1, green: 0, blue: 0))
    }

    @Test("断片で塗っても、混ぜ方は組み込みと同じに効く")
    func blendingWorksTheSameUnderAUserFragment() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let shader = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return float4(0.25, 0.0, 0.0, 1.0); }")

        try canvas.draw {
            canvas.background(.linear(red: 0.5, green: 0, blue: 0))
            canvas.noStroke()
            canvas.blendMode(.add)
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
        }
        #expect(canvas.get(8, 8).red == 0.75)
    }

    // MARK: - 渡した値

    /// 完了条件「利用者が渡した値は、列の先頭で取り込んだ値で列全体が描かれる」。
    ///
    /// **値を変えたら、そこで列が切れる。** 切れないと、既に置いた図形まで後の値で
    /// 描かれる — 前身ではこれが「2 つの図形が両方あとの値になる」形で出た。
    @Test("値を変える前に置いた図形は、変える前の値で描かれる")
    func shapesKeepTheValueTheyWereDrawnWith() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        let shader = try canvas.makeShader(Self.valueShader, values: ["level": 0.25])

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
            shader.set("level", 1)
            canvas.rect(16, 0, 16, 16)
        }
        #expect(canvas.get(8, 8).red == 0.25)
        #expect(canvas.get(24, 8).red == 1)
    }

    @Test("宣言していない名前は受け付けない")
    func undeclaredNamesAreRefused() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let shader = try canvas.makeShader(Self.valueShader, values: ["level": 0.5])
        shader.set("unknown", 1)

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
        }
        #expect(canvas.get(8, 8).red == 0.5)
    }

    @Test("組み込みの入力が届く")
    func theBuiltInInputsArrive() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return float4(in.place.x, in.time, in.resolution.x / 64.0, 1.0);
            }
            """)
        canvas.time = 0.5

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 32, 16)
        }
        let left = canvas.get(0, 8)
        let right = canvas.get(31, 8)
        #expect(left.red < right.red, "面の中の位置が左右で変わっていない")
        #expect(left.green == 0.5, "秒数が届いていない")
        #expect(left.blue == 0.5, "面の大きさが届いていない")
    }

    // MARK: - 渡せる値の数

    /// 列 1 つぶんの区画に**ちょうど収まる**宣言 (float 換算 64 個 = 色 16 個)。
    ///
    /// `ShaderSource.pack` は成分の数 → 名前の降順で並べるので、`c00` は**区画の末尾 4 つ** —
    /// 次の区画と隣り合う位置に載る。潰れたかどうかはここを見れば分かる。
    private static func fullSlotValues(last: LinearRGBA) -> [String: ShaderValue] {
        var values: [String: ShaderValue] = ["c00": .color(last)]
        for index in 1..<16 {
            values["c\(index)"] = .color(.linear(red: 0, green: 0, blue: 0))
        }
        return values
    }

    /// 末尾の値をそのまま色にする断片。区画の端が届いているかを見るのに使う。
    private static let lastValueShader =
        "float4 paint(Fragment in, Values values) { return values.c00; }"

    /// 完了条件「上限ちょうどの塗りを 2 つ並べても、互いの区画を潰さない」。
    @Test("上限ちょうどの値を宣言した塗りは、隣の列を潰さずに描ける")
    func aFullSlotOfValuesDoesNotSpillIntoTheNextColumn() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        let green = try canvas.makeShader(
            Self.lastValueShader, name: "full-green",
            values: Self.fullSlotValues(last: .linear(red: 0, green: 1, blue: 0)))
        let blue = try canvas.makeShader(
            Self.lastValueShader, name: "full-blue",
            values: Self.fullSlotValues(last: .linear(red: 0, green: 0, blue: 1)))

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            // 塗りを変えると列が切れるので、区画が 2 つ並ぶ。はみ出していれば後の列が前の列を潰す
            canvas.shader(green)
            canvas.rect(0, 0, 16, 16)
            canvas.shader(blue)
            canvas.rect(16, 0, 16, 16)
        }
        #expect(canvas.get(8, 8) == .linear(red: 0, green: 1, blue: 0))
        #expect(canvas.get(24, 8) == .linear(red: 0, green: 0, blue: 1))
    }

    /// 完了条件「1 つ超えると断られ、置き場への書き込みまで到達しない」(#348)。
    ///
    /// **超えた値で描く検査は置かない。** 描けば置き場の外へ書く経路をそのまま走らせる
    /// ことになり、検査そのものが壊れたメモリの上で動く。
    @Test("区画に収まらない数の値を宣言すると、読み込みの時点で断られる")
    func moreValuesThanASlotHoldsAreRefusedAtLoad() throws {
        let canvas = try makeCanvas()
        // 色 16 個 (64 個) に数を 1 つ足して 65 個。詰め物込みで 68 個になり、区画 (64) を超える
        var values = Self.fullSlotValues(last: .linear(red: 0, green: 1, blue: 0))
        values["extra"] = 1

        // 詰め物込みで 68 個。何個で上限が何個かが、断る文から読めること
        #expect(
            throws: ShaderFailure.tooManyValues(path: "overflowing", count: 68, capacity: 64)
        ) {
            try canvas.makeShader(Self.lastValueShader, name: "overflowing", values: values)
        }

        // 在処から読む経路も同じ。断るのは断片の中身ではなく**宣言の数**なので、両方に効く
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")
        try Self.lastValueShader.write(to: url, atomically: true, encoding: .utf8)
        #expect(
            throws: ShaderFailure.tooManyValues(path: url.path, count: 68, capacity: 64)
        ) {
            try canvas.loadShader(url.path, values: values)
        }
    }

    // MARK: - 面を渡す (#407)

    /// 2 枚を読む断片。**どちらの名前がどちらの面に届いたか**を色で読めるよう、
    /// 面ごとに別の成分だけを取り出す (掛け合わせるだけでは名前の取り違えが見えない)。
    private static let blendShader = """
        float4 paint(Fragment in, Values values, Surfaces surfaces) {
            return float4(
                mokume_sample(surfaces.grain, in.place).r,
                mokume_sample(surfaces.smudge, in.place).g,
                0.0, 1.0);
        }
        """

    /// 完了条件 3「`surfaces.<名前>` で読める」。
    @Test("名前で渡した 2 枚の面が、それぞれの名前のまま断片へ届く")
    func twoNamedSurfacesMeetInsideTheFragment() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        // **2 枚は別の成分で見分けられるようにしておく。** 名前と面が入れ替わったら
        // 赤も緑も 1 になるので、取り違えがそのまま出る
        let grain = try canvas.createImage(4, 4)
        grain.fill(.linear(red: 0.25, green: 1, blue: 0))
        let smudge = try canvas.createImage(4, 4)
        smudge.fill(.linear(red: 1, green: 0.5, blue: 0))

        let shader = try canvas.makeShader(
            Self.blendShader,
            surfaces: ["grain": .image(grain), "smudge": .image(smudge)])

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
        }
        let pixel = canvas.get(8, 8)
        #expect(abs(pixel.red - 0.25) < 0.01)
        #expect(abs(pixel.green - 0.5) < 0.01)
    }

    /// 完了条件 2「読み込んだ絵と、自分で描いた面の両方」。
    @Test("自分で描いた面も、そのまま渡せる")
    func aDrawnSurfaceCanBeHandedOverTheSameWay() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let scratch = try canvas.createGraphics(8, 8)
        scratch.beginDraw()
        scratch.background(.linear(red: 0, green: 0, blue: 1))
        scratch.endDraw()

        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                return mokume_sample(surfaces.painted, in.place);
            }
            """,
            surfaces: ["painted": .graphics(scratch)])

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
        }
        #expect(canvas.get(8, 8) == .linear(red: 0, green: 0, blue: 1))
    }

    /// 完了条件 6「差し替えは列を閉じてから効く」。値と同じ規則であることを見る。
    @Test("面を差し替える前に置いた図形は、差し替える前の面で描かれる")
    func shapesKeepTheSurfaceTheyWereDrawnWith() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        let first = try canvas.createImage(4, 4)
        first.fill(.linear(red: 1, green: 0, blue: 0))
        let second = try canvas.createImage(4, 4)
        second.fill(.linear(red: 0, green: 1, blue: 0))

        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                return mokume_sample(surfaces.tone, in.place);
            }
            """,
            surfaces: ["tone": .image(first)])

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
            shader.set("tone", .image(second))
            canvas.rect(16, 0, 16, 16)
        }
        #expect(canvas.get(8, 8) == .linear(red: 1, green: 0, blue: 0))
        #expect(canvas.get(24, 8) == .linear(red: 0, green: 1, blue: 0))
    }

    // MARK: - 置いた図形は、置いた時点の塗りで描かれる (#1683)

    /// 断片を作る面と、使う面の組 (#1652)。
    ///
    /// 上の 2 本は作った面で使う場合だけを見ている。`set` の知らせが作った面にしか届かないと、
    /// 他の面で使ったときだけ前に置いた図形が後の値で描かれる。
    enum Pairing: String, CaseIterable, CustomTestStringConvertible {
        case mainOnMain, mainOnLayer, layerOnMain, layerOnOtherLayer
        var testDescription: String { rawValue }
    }

    /// 組に合わせて、断片を作る面と使う面を返す。`main` は窓の側の面。
    private func surfaces(
        for pairing: Pairing, main: Canvas
    ) throws -> (maker: Canvas, user: Canvas) {
        let layer = try main.createGraphics(Int(main.width), Int(main.height))
        switch pairing {
        case .mainOnMain: return (main, main)
        case .mainOnLayer: return (main, layer)
        case .layerOnMain: return (layer, main)
        case .layerOnOtherLayer:
            return (layer, try main.createGraphics(Int(main.width), Int(main.height)))
        }
    }

    /// `user` の上で 1 フレーム描く。描き場所なら本体のフレームの中で開いて閉じる。
    private func drawFrame(on user: Canvas, main: Canvas, _ body: () -> Void) throws {
        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            guard user !== main else { return body() }
            user.beginDraw()
            body()
            user.endDraw()
        }
    }

    /// 完了条件 1 (#1683)・1・2 (#1652)。値の `set` の前に置いた図形は前の値で描かれる。
    @Test("値を変える前に置いた図形は、どの面で作ってどの面で使っても、変える前の値で描かれる",
        arguments: Pairing.allCases)
    func shapesKeepTheValueOnEverySurface(pairing: Pairing) throws {
        let main = try makeCanvas(width: 32, height: 16)
        let (maker, user) = try surfaces(for: pairing, main: main)
        let shader = try maker.makeShader(Self.valueShader, values: ["level": 1])

        try drawFrame(on: user, main: main) {
            user.background(.linear(red: 0, green: 0, blue: 0))
            user.noStroke()
            user.shader(shader)
            user.rect(0, 0, 16, 16)
            shader.set("level", 0.25)
            user.rect(16, 0, 16, 16)
            user.resetShader()
        }
        #expect(abs(user.get(8, 8).red - 1) < 0.01, "set より前に置いた図形が後の値で描かれた")
        #expect(abs(user.get(24, 8).red - 0.25) < 0.01)
    }

    /// 完了条件 1 (#1683)・2 (#1652)。面の `set` でも同じ。
    @Test("面を差し替える前に置いた図形は、どの面で作ってどの面で使っても、差し替える前の面で描かれる",
        arguments: Pairing.allCases)
    func shapesKeepTheSurfaceOnEverySurface(pairing: Pairing) throws {
        let main = try makeCanvas(width: 32, height: 16)
        let (maker, user) = try surfaces(for: pairing, main: main)
        let first = try main.createImage(4, 4)
        first.fill(.linear(red: 1, green: 0, blue: 0))
        let second = try main.createImage(4, 4)
        second.fill(.linear(red: 0, green: 1, blue: 0))
        let shader = try maker.makeShader(Self.toneShader, surfaces: ["tone": .image(first)])

        try drawFrame(on: user, main: main) {
            user.background(.linear(red: 0, green: 0, blue: 0))
            user.noStroke()
            user.shader(shader)
            user.rect(0, 0, 16, 16)
            shader.set("tone", .image(second))
            user.rect(16, 0, 16, 16)
            user.resetShader()
        }
        let (left, right) = (user.get(8, 8), user.get(24, 8))
        #expect(left.red > 0.99 && left.green < 0.01, "set より前に置いた図形が後の面で描かれた")
        #expect(right.red < 0.01 && right.green > 0.99)
    }

    /// 完了条件 2 (#1683)・3 (#1652)。同じ断片を 2 つの面に置いてから `set` する。
    ///
    /// 作るのはどちらでもない第 3 の面にする — 作った面の列だけが閉じる形なら、2 面とも破れる。
    @Test("同じ断片を 2 つの面で同時に使っても、どちらの面でも set より前の図形は前の値で描かれる")
    func oneShaderOnTwoSurfacesKeepsTheValueOnBoth() throws {
        let main = try makeCanvas(width: 32, height: 16)
        let layer = try main.createGraphics(32, 16)
        let maker = try main.createGraphics(32, 16)
        let shader = try maker.makeShader(Self.valueShader, values: ["level": 1])

        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            main.noStroke()
            layer.beginDraw()
            layer.background(.linear(red: 0, green: 0, blue: 0))
            layer.noStroke()
            layer.shader(shader)
            layer.rect(0, 0, 16, 16)
            main.shader(shader)
            main.rect(0, 0, 16, 16)
            shader.set("level", 0.25)
            layer.rect(16, 0, 16, 16)
            main.rect(16, 0, 16, 16)
            layer.resetShader()
            layer.endDraw()
            main.resetShader()
        }
        for (name, canvas) in [("本体", main), ("描き場所", layer)] {
            #expect(abs(canvas.get(8, 8).red - 1) < 0.01, "\(name): set より前の図形が後の値で描かれた")
            #expect(abs(canvas.get(24, 8).red - 0.25) < 0.01, "\(name)")
        }
    }

    /// 描き場所を 1 色で塗る。
    private func paint(_ graphics: Canvas, _ color: LinearRGBA) {
        graphics.beginDraw()
        graphics.background(color)
        graphics.endDraw()
    }

    /// 面 `pic` をそのまま色にする断片。
    private static let pictureShader = """
        float4 paint(Fragment in, Values values, Surfaces surfaces) {
            return mokume_sample(surfaces.pic, in.uv);
        }
        """

    /// 面 `tone` をそのまま色にする断片。
    private static let toneShader = """
        float4 paint(Fragment in, Values values, Surfaces surfaces) {
            return mokume_sample(surfaces.tone, in.place);
        }
        """

    /// 赤・緑・青のどれが最も強く出ているか。描き場所の色は面の形式で丸まるので、名前で比べる。
    private static func hue(_ pixel: LinearRGBA) -> String {
        guard max(pixel.red, pixel.green, pixel.blue) > 0.5 else { return "黒" }
        if pixel.red >= pixel.green && pixel.red >= pixel.blue { return "赤" }
        return pixel.green >= pixel.blue ? "緑" : "青"
    }

    /// 完了条件 3 (#1683)・1・2 (#1653)。断片の面に渡した描き場所を、置いた後に描き換える。
    ///
    /// `solid` は立体で置くか。平面と立体は別の列を開くので、両方を見る。描き換えた後に同じ
    /// 断片のまま置いた右の図形は、描き換えた後の絵で描かれる (#1543 の貼る絵と同じ形)。
    @Test("断片の面に渡した描き場所を置いた後に描き換えても、置くたびにその時点の絵で描かれる",
        arguments: [false, true])
    func aShaderSurfaceKeepsThePictureOfEachPlacement(solid: Bool) throws {
        let main = try makeCanvas(width: 64, height: 64)
        let layer = try main.createGraphics(16, 16)
        let shader = try main.makeShader(
            Self.pictureShader, surfaces: ["pic": .graphics(layer)])
        func place(_ x: Float) {
            guard solid else { return main.rect(x, 0, 24, 24) }
            main.push()
            main.translate(x + 12, 12, 0)
            main.plane(24, 24)
            main.pop()
        }

        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            main.noStroke()
            paint(layer, .linear(red: 1, green: 0, blue: 0))
            main.shader(shader)
            place(0)
            paint(layer, .linear(red: 0, green: 0, blue: 1))
            place(32)
            paint(layer, .linear(red: 0, green: 1, blue: 0))
            main.resetShader()
        }
        #expect(Self.hue(main.get(12, 12)) == "赤", "置いた後に描き換えた絵が出た")
        #expect(Self.hue(main.get(44, 12)) == "青", "置いた後に描き換えた絵が出た")
    }

    /// 描き場所を読む 2 つの口。貼る絵 (`texture()`) と断片の面。
    enum Reading: String, CaseIterable, CustomTestStringConvertible {
        case texture, shaderSurface
        var testDescription: String { rawValue }
    }

    /// 描き場所がフレームの途中で描き切る (`loadPixels()`) ときの、「描き切る前に置いた」の注意。
    ///
    /// **注意は置いた時点で決まる** (#1683 の反証 2)。`beginDraw()` より前に置いた図形は描き切る
    /// 前の面を読んでいないので言わず、`beginDraw()` の後に置いた図形は言う。閉じる時点や
    /// 描き切らせる時点で決めると、前者で言い、後者で黙る形に化けうる。
    @Test("描き場所を途中で描き切るとき、描き切る前に置いた注意は置いた時点で決まる",
        arguments: [false, true])
    func placingWhileDrawingIsDecidedWhenPlaced(placedWhileDrawing: Bool) throws {
        let main = try makeCanvas(width: 64, height: 64)
        let layer = try main.createGraphics(16, 16)
        let shader = try main.makeShader(
            Self.pictureShader, surfaces: ["pic": .graphics(layer)])

        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            main.noStroke()
            paint(layer, .linear(red: 1, green: 0, blue: 0))
            main.shader(shader)
            if !placedWhileDrawing { main.rect(0, 0, 24, 24) }
            layer.beginDraw()
            layer.background(.linear(red: 0, green: 0, blue: 1))
            if placedWhileDrawing { main.rect(0, 0, 24, 24) }
            layer.loadPixels()
            layer.endDraw()
            main.resetShader()
        }
        #expect(Self.hue(main.get(12, 12)) == "赤", "置いた後に描き換えた絵が出た")
        #expect(main.warnings.hasWarned(.placingWhileDrawing) == placedWhileDrawing)
    }

    /// 描いている最中 (`beginDraw()`〜`endDraw()`) の描き場所を読んで置いた図形 (#1683 の反証 1)。
    ///
    /// 公開の説明 (`createGraphics`) は「`endDraw()` の前に置くと 1 フレーム前の絵が出る
    /// (そのときは注意が出る)」としている。貼る絵と断片の面の、どちらの口で読んでも同じ絵と
    /// 同じ注意になる。
    ///
    /// `folded` は、描き始める前に同じ形を 2 つ置いておくか。置いておくと雛形が開いたまま残り、
    /// 描いている最中に置く 3 つ目は畳んだ置き場所を足すだけの口 (`appendFolded`) を通る。
    @Test("描いている最中の描き場所を読んで置くと、どちらの口でも前の絵が出て注意が出る",
        arguments: Reading.allCases, [false, true])
    func placingWhileDrawingShowsThePreviousPictureAndIsTold(
        reading: Reading, folded: Bool
    ) throws {
        let main = try makeCanvas(width: 64, height: 64)
        let layer = try main.createGraphics(16, 16)
        let shader = try main.makeShader(
            Self.pictureShader, surfaces: ["pic": .graphics(layer)])
        paint(layer, .linear(red: 1, green: 0, blue: 0))

        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            main.noStroke()
            switch reading {
            case .texture: main.texture(layer)
            case .shaderSurface: main.shader(shader)
            }
            if folded {
                main.rect(32, 0, 24, 24)
                main.rect(32, 32, 24, 24)
            }
            layer.beginDraw()
            layer.background(.linear(red: 0, green: 0, blue: 1))
            main.rect(0, 0, 24, 24)
            layer.endDraw()
            main.resetShader()
            main.noTexture()
        }
        #expect(Self.hue(main.get(12, 12)) == "赤", "描き切る前の描き場所から、描き切った後の絵が出た")
        #expect(main.warnings.hasWarned(.placingWhileDrawing))
    }

    /// 形の組み立ては置くことではない。描いている最中の描き場所を読む塗りで形を組み立てても、
    /// 「描き切る前に置いた」とは言わない — 形の絵は、形を置いた時点で読む。
    @Test("描いている最中の描き場所を読む塗りで形を組み立てても、置いていなければ注意しない",
        arguments: Reading.allCases)
    func buildingAShapeIsNotPlacing(reading: Reading) throws {
        let main = try makeCanvas(width: 64, height: 64)
        let layer = try main.createGraphics(16, 16)
        let shader = try main.makeShader(
            Self.pictureShader, surfaces: ["pic": .graphics(layer)])
        paint(layer, .linear(red: 1, green: 0, blue: 0))

        var tile: Shape?
        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            layer.beginDraw()
            layer.background(.linear(red: 0, green: 0, blue: 1))
            tile = main.createShape {
                main.noStroke()
                switch reading {
                case .texture: main.texture(layer)
                case .shaderSurface: main.shader(shader)
                }
                main.rect(0, 0, 24, 24)
            }
            layer.endDraw()
            if let tile { main.shape(tile, 0, 0) }
        }
        #expect(Self.hue(main.get(12, 12)) == "青")
        #expect(!main.warnings.hasWarned(.placingWhileDrawing))
    }

    /// 断片の面の記録は、記録済みなら積むたびには取り直さない (#1683 の反証 2 回目)。
    /// 控えが外れるべき場面で外れないと、読む描き場所が替わった後に置いた図形が守られない。
    enum NoteRefresh: String, CaseIterable, CustomTestStringConvertible {
        /// 別の描き場所を読む断片へ当て替える
        case otherShader
        /// 同じ断片の面を、別の描き場所へ差し替える
        case surfaceSet
        /// 置いた面の描き切りが一度失敗する (記録は残るが、相手の `placers` からは外れる)
        case failedSettle
        /// 背景で塗り直す (溜めたものと一緒に置いた記録も落ちる)
        case background
        var testDescription: String { rawValue }

        /// 右の矩形を置いた時点で、それが読む描き場所の色。
        var expected: String {
            switch self {
            case .otherShader, .surfaceSet, .failedSettle: "赤"
            case .background: "緑"
            }
        }
    }

    @Test("読む描き場所が替わっても、描き切りに失敗しても、次に置いた図形はその時点の絵で描かれる",
        arguments: NoteRefresh.allCases)
    func theSurfaceNoteIsRefreshedWhenItMustBe(refresh: NoteRefresh) throws {
        let main = try makeCanvas(width: 64, height: 64)
        let first = try main.createGraphics(16, 16)
        let second = try main.createGraphics(16, 16)
        let one = try main.makeShader(Self.pictureShader, surfaces: ["pic": .graphics(first)])
        let other = try main.makeShader(Self.pictureShader, surfaces: ["pic": .graphics(second)])
        paint(first, .linear(red: 0, green: 1, blue: 0))
        paint(second, .linear(red: 1, green: 0, blue: 0))

        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            main.noStroke()
            main.shader(one)
            main.rect(0, 0, 24, 24)
            switch refresh {
            case .otherShader:
                main.shader(other)
            case .surfaceSet:
                one.set("pic", .graphics(second))
            case .failedSettle:
                // 左の矩形は first を読んでいる。描き換える前の描き切りを 1 度だけ失敗させる
                main.failureForTesting = .timedOut(seconds: 5)
                paint(first, .linear(red: 1, green: 0, blue: 0))
                main.failureForTesting = nil
            case .background:
                main.background(.linear(red: 0, green: 0, blue: 0))
            }
            main.rect(32, 0, 24, 24)
            // 右の矩形が読んでいる描き場所を、置いた後に描き換える
            switch refresh {
            case .otherShader, .surfaceSet: paint(second, .linear(red: 0, green: 0, blue: 1))
            case .failedSettle, .background: paint(first, .linear(red: 0, green: 0, blue: 1))
            }
            main.resetShader()
        }
        #expect(Self.hue(main.get(44, 12)) == refresh.expected, "置いた後に描き換えた絵が出た")
    }

    /// 完了条件 3 (#1683) の「置き続ければ」。断片はフレームを越えて効くので、最初のフレームで
    /// 1 度だけ当てて置き続ける。描き切りのたびに記録は落ちるので、置くたびに記録し直す必要がある。
    @Test("最初のフレームで 1 度だけ当てた断片でも、後のフレームで置いた時点の絵が出る")
    func aShaderSurfaceKeepsItsPictureAcrossFrames() throws {
        let main = try makeCanvas(width: 64, height: 64)
        let layer = try main.createGraphics(16, 16)
        let shader = try main.makeShader(
            Self.pictureShader, surfaces: ["pic": .graphics(layer)])

        for frame in 0..<3 {
            try main.draw {
                main.background(.linear(red: 0, green: 0, blue: 0))
                main.noStroke()
                paint(layer, .linear(red: 0, green: 0, blue: 1))
                if frame == 0 { main.shader(shader) }
                main.rect(0, 0, 24, 24)
                paint(layer, .linear(red: 0, green: 1, blue: 0))
            }
            #expect(
                Self.hue(main.get(12, 12)) == "青",
                "\(frame + 1) フレーム目で、置いた後に描き換えた絵が出た")
        }
    }

    /// 完了条件 4 (#1683)・3 (#1653)。記録した塗りで描き場所を読む形を、置いた後に描き換える。
    ///
    /// `liveShaderIsTheSame` は、置く側でも同じ断片を当てておくか。当てていれば記録した塗りと
    /// いまの塗りが一致して列が開いたまま残り、当てていなければ置き終えたところで列が閉じる。
    @Test("記録した塗りで描き場所を読む形も、置いた後に描き換えても置いた時点の絵で描かれる",
        arguments: [false, true])
    func aHeldShapeWithAShaderSurfaceKeepsThePicture(liveShaderIsTheSame: Bool) throws {
        let main = try makeCanvas(width: 64, height: 64)
        let layer = try main.createGraphics(16, 16)
        let shader = try main.makeShader(
            Self.pictureShader, surfaces: ["pic": .graphics(layer)])
        let tile = main.createShape {
            main.noStroke()
            main.shader(shader)
            main.rect(0, 0, 24, 24)
        }

        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            if liveShaderIsTheSame { main.shader(shader) }
            paint(layer, .linear(red: 1, green: 0, blue: 0))
            main.shape(tile, 0, 0)
            paint(layer, .linear(red: 0, green: 0, blue: 1))
            main.shape(tile, 32, 0)
            paint(layer, .linear(red: 0, green: 1, blue: 0))
            main.resetShader()
        }
        #expect(Self.hue(main.get(12, 12)) == "赤", "置いた後に描き換えた絵が出た")
        #expect(Self.hue(main.get(44, 12)) == "青", "置いた後に描き換えた絵が出た")
    }

    /// 完了条件 5 (#1683)。いまの列が読んでいない描き場所の描き換えと、いま塗っていない断片の
    /// `set` では列を切らない。
    ///
    /// 断片は前のフレームで 1 度使っただけで、このフレームの図形は組み込みの塗りで置く。
    /// 描き換わる側・変わる側が知らせる相手を「使ったことのある面」まで広げても、閉じるのは
    /// いまその塗りで置いている列だけである。
    @Test("いまの列が読んでいない描き場所を描き換えても、塗っていない断片を set しても、列は切れない")
    func unrelatedChangesDoNotSplitTheRun() throws {
        let main = try makeCanvas(width: 64, height: 64)
        let layer = try main.createGraphics(16, 16)
        let shader = try main.makeShader(
            Self.pictureShader, surfaces: ["pic": .graphics(layer)])
        let valued = try main.makeShader(Self.valueShader, values: ["level": 1])

        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            main.noStroke()
            main.shader(shader)
            main.rect(0, 0, 8, 8)
            main.shader(valued)
            main.rect(16, 0, 8, 8)
            main.resetShader()
        }
        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 0))
            main.noStroke()
            main.rect(0, 0, 8, 8)
            paint(layer, .linear(red: 0, green: 0, blue: 1))
            valued.set("level", 0.5)
            main.rect(16, 0, 8, 8)
        }
        #expect(main.drawCallsInLastFrame == 1)
    }

    /// 完了条件 5 の後半「宣言していない名前は警告して無視する」。
    @Test("宣言していない名前の面は受け付けない")
    func undeclaredSurfaceNamesAreRefused() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let declared = try canvas.createImage(4, 4)
        declared.fill(.linear(red: 1, green: 0, blue: 0))
        let stranger = try canvas.createImage(4, 4)
        stranger.fill(.linear(red: 0, green: 1, blue: 0))

        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                return mokume_sample(surfaces.tone, in.place);
            }
            """,
            surfaces: ["tone": .image(declared)])
        // **名前は宣言済みの名前より前に並ぶものを選ぶ。** 受け付けてしまえば口の
        // 割り当てが 1 つずれるので、無視されたかどうかが絵に出る
        shader.set("astray", .image(stranger))

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
        }
        // 宣言した面がそのまま効いている (知らない名前は捨てられた)
        #expect(canvas.get(8, 8) == .linear(red: 1, green: 0, blue: 0))
    }

    /// 完了条件 5 の前半「上限を超えた宣言は読み込みの時点で断る」。
    ///
    /// **超えた枚数で描く検査は置かない** — 値の側 (#348) と同じで、断る前提の宣言を
    /// 走らせると検査そのものが土台任せの状態で動く。
    @Test("口の数を超える面を宣言すると、読み込みの時点で断られる")
    func moreSurfacesThanThereArePortsAreRefusedAtLoad() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        var surfaces: [String: ShaderSurface] = [:]
        for index in 0...ShapePipeline.surfaceCapacity {
            surfaces["s\(index)"] = .image(image)
        }

        #expect(
            throws: ShaderFailure.tooManySurfaces(
                path: "crowded", count: ShapePipeline.surfaceCapacity + 1,
                capacity: ShapePipeline.surfaceCapacity)
        ) {
            try canvas.makeShader(Self.blendShader, name: "crowded", surfaces: surfaces)
        }

        // 在処から読む経路も同じ。断るのは中身ではなく**宣言の数**である
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("blend.metal")
        try Self.blendShader.write(to: url, atomically: true, encoding: .utf8)
        #expect(
            throws: ShaderFailure.tooManySurfaces(
                path: url.path, count: ShapePipeline.surfaceCapacity + 1,
                capacity: ShapePipeline.surfaceCapacity)
        ) {
            try canvas.loadShader(url.path, surfaces: surfaces)
        }
    }

    /// 完了条件 4「面を宣言していない断片は 1 ビットも変わらない」の機械側。
    ///
    /// 絵が動かないことは代表シーンの台帳が見る。ここが見るのは**組み上がる原稿**で、
    /// 面を宣言していなければ前置きが 1 バイトも増えないこと。
    @Test("面を宣言しなければ、前置きは 1 バイトも増えない")
    func aFragmentWithoutSurfacesGetsNoPreamble() {
        #expect(ShaderSource.declaration(of: [:] as [String: ShaderSurface]).isEmpty)

        let values: [String: ShaderValue] = ["level": 0.5]
        let body = "float4 paint(Fragment in, Values values) { return values.level; }"
        let withoutSurfaces = ShaderSource.assemble(common: "COMMON", values: values, body: body)
        #expect(
            withoutSurfaces
                == ShaderSource.declaration(of: values) + "COMMON" + "\n" + body + "\n")
    }

    /// 完了条件 3 の前提。**並びは名前順に固定**で、口の割り当てもこの順である。
    @Test("面の宣言は名前順に並び、口の数だけ受け取る")
    func theSurfaceDeclarationIsOrderedByName() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        let declaration = ShaderSource.declaration(
            of: ["grain": .image(image), "dirt": .image(image)])

        #expect(declaration.contains("#define MOKUME_SURFACES 2"))
        // 辞書に置いた順ではなく名前順。dirt が先、grain が後
        let dirt = try #require(declaration.range(of: "surfaces.dirt = s0;"))
        let grain = try #require(declaration.range(of: "surfaces.grain = s1;"))
        #expect(dirt.lowerBound < grain.lowerBound)
        // 受け取る口の数は宣言した枚数によらない (入口の側は断片ごとに変えられない)
        #expect(declaration.contains("texture2d<float> s\(ShapePipeline.surfaceCapacity - 1)"))
    }

    // MARK: - 組み立ての失敗

    /// 完了条件「断片のコンパイルが失敗したとき、絵が消えず、失敗の理由が観測から読める」。
    @Test("読み込みの時点で組み立てられなければ、理由のついたエラーになる")
    func aBrokenFragmentFailsToLoadWithAReason() throws {
        let canvas = try makeCanvas()
        #expect(throws: ShaderFailure.self) {
            try canvas.makeShader("float4 paint(Fragment in, Values values) { これは MSL ではない }")
        }
    }

    /// **差し替えに失敗しても、前の断片が残る。**
    ///
    /// 削ってから入れ直す形にすると、組み立てに失敗した瞬間に元の断片ごと消えて
    /// 絵が出なくなる。
    @Test("差し替えに失敗しても、絵が消えない")
    func afailedReloadKeepsThePreviousFragment() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")
        try "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }"
            .write(to: url, atomically: true, encoding: .utf8)

        let shader = try canvas.loadShader(url.path)
        try "これは MSL ではない".write(to: url, atomically: true, encoding: .utf8)
        shader.reload()

        #expect(shader.failure != nil)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 16, 16)
        }
        // 壊れた断片を保存しても、前の断片で描かれ続ける
        #expect(canvas.get(8, 8) == .linear(red: 0, green: 1, blue: 0))
        #expect(canvas.shaderFailures.count == 1)
    }

    // MARK: - 保存を拾う

    // 「見張りが死んでいたら永久に待たない」ための止め木は、下の `waitUntil` が
    // 自分で持っている (期限つきで待ち、越えたら名指しで落ちる)。**`.timeLimit` は
    // ここでは使えない** — 上限は走り出しからの時計で測られ、このパッケージの検査は
    // すべて main actor に載っているので、どんな値を書いても「検査全体が何秒で
    // 終わるか」を要求することになる (#564)。

    /// 完了条件「保存を 2 回連続で行い、2 回とも差し替わる」。
    ///
    /// **1 回だけ保存する検査には判別力が無い。** 置き換え保存のあと見張りを張り直さない
    /// 実装でも 1 回目は通り、死ぬのは 2 回目以降である。
    @Test("置き換えで保存すると、2 回続けて差し替わる")
    func twoConsecutiveAtomicSavesBothArrive() async throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")

        func write(_ green: String) throws {
            // `atomically: true` は別名で書いてから置き換える保存 — 編集器がよく使う形
            try "float4 paint(Fragment in, Values values) { return float4(0.0, \(green), 0.0, 1.0); }"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        try write("0.25")
        let shader = try canvas.loadShader(url.path)
        #expect(shader.generation == 0)

        // **絵で確かめる。** 差し替えの回数だけ見ても、届いた中身で描かれているかは
        // 分からない
        for green in [Float(0.5), 1] {
            let before = shader.generation
            try write("\(green)")
            try await waitUntil { shader.generation > before }
            #expect(shader.failure == nil)

            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.shader(shader)
                canvas.rect(0, 0, 16, 16)
            }
            #expect(canvas.get(8, 8).green == green, "保存した内容で描かれていない")
        }
    }

    @Test("その場で上書きして保存しても差し替わる")
    func anInPlaceSaveAlsoArrives() async throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")
        try "float4 paint(Fragment in, Values values) { return float4(0.0, 0.25, 0.0, 1.0); }"
            .write(to: url, atomically: true, encoding: .utf8)
        let shader = try canvas.loadShader(url.path)

        // `atomically: false` は開いているファイルをその場で書き換える保存
        try "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }"
            .write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { shader.generation >= 1 }
        #expect(shader.generation >= 1)
    }

    /// **置き換え保存のあと、その場の上書きも拾える。**
    ///
    /// 置き換えられた時点で、ファイル側の見張りは**消えたファイル**を指したままになる。
    /// その場の上書きは親ディレクトリを変えないので、張り直さない実装ではここで
    /// 完全に届かなくなる。置き換えだけを 2 回続ける検査では、親ディレクトリ側が
    /// 毎回拾ってしまうので**この壊れは見つからない**。
    @Test("置き換えて保存したあと、その場で上書きしても届く")
    func anInPlaceSaveAfterAnAtomicSaveStillArrives() async throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")

        func body(_ green: String) -> String {
            "float4 paint(Fragment in, Values values) { return float4(0.0, \(green), 0.0, 1.0); }"
        }
        try body("0.25").write(to: url, atomically: true, encoding: .utf8)
        let shader = try canvas.loadShader(url.path)

        // 1 回目: 置き換えで保存 (ここでファイル側の見張りの相手が入れ替わる)
        try body("0.5").write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil { shader.generation >= 1 }
        // **張り直しが済むのを待つ。** 置き換えの直後は、見張りがまだ消えたファイルを
        // 指している。時間ではなく「いまその場所にあるファイルと同じか」で待つ
        try await waitUntil { shader.watcher?.watchesCurrentFile == true }

        // 2 回目: その場で上書き。親ディレクトリは変わらないので、
        // 張り直していないと誰も拾わない
        try body("1.0").write(to: url, atomically: false, encoding: .utf8)
        try await waitUntil { shader.generation >= 2 }
        #expect(shader.generation >= 2)
    }

    @Test("見張りは、ファイルと親ディレクトリの両方に張る")
    func theWatcherCoversBothTheFileAndItsDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")
        try "x".write(to: url, atomically: true, encoding: .utf8)

        let watcher = FileWatcher(url: url) {}
        #expect(watcher.isWatchingFile)
        #expect(watcher.isWatchingDirectory)
    }

    /// 見張りの知らせは、main actor を譲らない間も 1 本までしか積まれない ([#1594] の反証 1)。
    ///
    /// 親ディレクトリの書き込みも拾うので、保存や連番の書き出しの行き先が断片と同じ
    /// ディレクトリなら、事象はフレームごとに起きる。事象ごとに 1 本積むと、譲らないループでは
    /// フレームに比例して溜まり、譲った後に溜まった本数だけ張り直しと読み直しが走る。
    ///
    /// **積んだ数で数える** — 譲らずに書いて、事象が届くのも譲らずに待ち、譲る前に自分の見張りが
    /// 積んだ知らせの数を読む。扱った回数では数えない。並列の検査のフレームの頭が、この見張りの
    /// 印も取るためである ([#1830] の反証 3。フレームの頭で取る側は ``ShaderWatchWithoutYieldingTests``)。
    ///
    /// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
    ///
    /// [#1594]: https://github.com/mokume-metal/mokume/issues/1594
    @Test("譲らずに何度書き換えても、見張りは譲った後に 1 度だけ扱う")
    func theWatcherCoalescesEventsWhileTheMainActorIsBusy() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("paint.metal")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        var changes = 0
        let watcher = FileWatcher(url: url) { changes += 1 }

        // **ここから譲らない。** 同期の手続きで書き、届くのも眠って待つ
        func writeWithoutYielding() -> Int {
            for index in 0..<20 {
                try? "\(index)".write(to: url, atomically: false, encoding: .utf8)
                Thread.sleep(forTimeInterval: 0.02)
            }
            Thread.sleep(forTimeInterval: 0.2)
            return watcher.arrivedEventCount
        }
        let arrived = writeWithoutYielding()
        try #require(arrived >= 10, "検査の前提: 20 回書いて事象が \(arrived) 回しか届いていない")
        // **積んだ数は、譲る前に自分の見張りの上で数える** ([#1830] の反証 3)。扱った回数は、
        // 譲った後に並列で走る別の検査のフレームの頭が、この見張りの印を取った分も入る
        #expect(
            watcher.queuedNoticeCount <= 1,
            """
            譲らずに事象を \(arrived) 回拾う間に、main actor へ \(watcher.queuedNoticeCount) 本積んだ。
            事象ごとに main actor へ積んでいる
            ([#1594](https://github.com/mokume-metal/mokume/issues/1594))。
            """)

        try await waitUntil { watcher.handledCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(watcher.queuedNoticeCount == 0, "譲った後も、積んだ知らせが走っていない")
        #expect(changes == watcher.handledCount)
    }

    // MARK: - 道具

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-shader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 条件が満たされるまで待つ。
    ///
    /// **待つ側が main actor を明け渡す。** 見張りは自前の待ち行列で受けてから
    /// main actor へ渡すので、待つ側が回り続けていると渡す先が空かない。
    private func waitUntil(
        _ condition: () -> Bool, within seconds: Double = 5,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "\(seconds) 秒待っても届かなかった", sourceLocation: sourceLocation)
    }
}

/// main actor を譲らずに ``SketchRuntime/advance()`` を回しても、断片の保存が届く ([#1830])。
///
/// 見張りは拾った事象を `Task { @MainActor }` で渡していたので、譲らないループ (窓を出さない
/// 書き出しや検査) では 1 本も走らず、何フレーム回しても古い断片のまま描いた。誰が `advance()` を
/// 叩くかは外側の話 (``SketchRuntime`` の説明) なので、叩き方で届き方が変わってはならない。
///
/// **検査はすべて同期の関数で書く** — `await` を 1 つでも挟むと、そこで積まれた `Task` が走って
/// 直っていなくても通る ([#1594] の `completionNoticesDoNotPileUpWithoutYielding`・[#1704] の
/// `ParameterWithoutYieldingTests` と同じ回し方)。事象が届くのは眠って待つ。
///
/// [#1594]: https://github.com/mokume-metal/mokume/issues/1594
/// [#1704]: https://github.com/mokume-metal/mokume/issues/1704
/// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
@Suite(
    "断片の保存は、譲らずに回しても次のフレームで届く (#1830)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShaderWatchWithoutYieldingTests {
    /// 黒の上に、渡された塗りで面を覆うスケッチ。`draw` の中で走らせる手続きも持てる。
    final class Idle: Sketch {
        var settings = SketchSettings(width: 8, height: 8, frameRate: 60)
        var duringDraw: (() -> Void)?
        var paint: Shader?
        /// 描いたら作者が止める (`noLoop()`)。
        var stopsAfterDrawing = false

        init() {}
        func draw() {
            if stopsAfterDrawing { noLoop() }
            duringDraw?()
            background(.linear(red: 0, green: 0, blue: 0))
            guard let paint else { return }
            noStroke()
            shader(paint)
            rect(0, 0, 8, 8)
            resetShader()
        }
    }

    /// 見張る断片 3 つ (塗り・効果・計算) と、その在処。
    private struct Fragments {
        let shader: Shader
        let effect: EffectShader
        let computation: Computation
        let urls: [URL]

        /// 3 つの差し替えの回数。
        var generations: [Int] { [shader.generation, effect.generation, computation.generation] }
        var watchers: [FileWatcher] {
            [shader.watcher, effect.watcher, computation.watcher].compactMap { $0 }
        }
    }

    private static func shaderBody(_ green: String) -> String {
        "float4 paint(Fragment in, Values values) { return float4(0.0, \(green), 0.0, 1.0); }"
    }
    private static func effectBody(_ scale: String) -> String {
        "float4 effect(Pixel in, Values values) { return in.color * \(scale); }"
    }
    private static func computationBody(_ value: String) -> String {
        """
        kernel void fill(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]])
        {
            out[id] = \(value);
        }
        """
    }

    private func load(on canvas: Canvas) throws -> Fragments {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-unyielding-shader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paint = directory.appendingPathComponent("paint.metal")
        let tint = directory.appendingPathComponent("tint.metal")
        let fill = directory.appendingPathComponent("fill.metal")
        try Self.shaderBody("0.25").write(to: paint, atomically: true, encoding: .utf8)
        try Self.effectBody("0.5").write(to: tint, atomically: true, encoding: .utf8)
        try Self.computationBody("0.5").write(to: fill, atomically: true, encoding: .utf8)
        return Fragments(
            shader: try canvas.loadShader(paint.path),
            effect: try canvas.loadEffect(tint.path),
            computation: try canvas.loadComputation(fill.path),
            urls: [paint, tint, fill])
    }

    /// 3 つを書き換え、**譲らずに**事象が届くのを待つ。
    private func rewrite(_ fragments: Fragments, _ revision: Int) throws {
        let before = fragments.watchers.map(\.arrivedEventCount)
        try Self.shaderBody("0.\(revision)").write(to: fragments.urls[0], atomically: true, encoding: .utf8)
        try Self.effectBody("0.\(revision)").write(to: fragments.urls[1], atomically: true, encoding: .utf8)
        try Self.computationBody("\(revision).0").write(to: fragments.urls[2], atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(5)
        func arrived() -> Bool {
            zip(fragments.watchers.map(\.arrivedEventCount), before).allSatisfy { $0 > $1 }
        }
        while !arrived(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        // 1 度の保存でファイル側と親ディレクトリ側の両方が拾うので、後から届く分も待つ
        Thread.sleep(forTimeInterval: 0.1)
        try #require(arrived(), "検査の前提: 書き換えた事象が 5 秒待っても見張りに届いていない")
    }

    @Test("譲らずに回しても、書き換えた断片は次のフレームで読み直される (塗り・効果・計算)")
    func aSaveArrivesAtTheNextFrameWithoutYielding() throws {
        let sketch = Idle()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        let fragments = try load(on: runtime.canvas)
        sketch.paint = fragments.shader
        try runtime.advance()
        try #require(fragments.generations == [0, 0, 0])
        var green = try runtime.target.readPixels()[4, 4].green

        for revision in 1...2 {
            try rewrite(fragments, revision)
            try runtime.advance()
            #expect(
                fragments.generations == [revision, revision, revision],
                """
                譲らずに \(revision) 回目の保存をしてから 1 フレーム回したが、読み直した回数が \
                \(fragments.generations) (塗り・効果・計算)。見張りの知らせが、譲らない間は届かない
                """)
            // 読み直しただけでなく、そのフレームが新しい断片で描かれている
            let drawn = try runtime.target.readPixels()[4, 4].green
            #expect(drawn != green, "保存の次のフレームが、まだ古い断片で描かれている")
            green = drawn
        }
    }

    @Test("描いている最中に書き換えても、そのフレームの中では読み直さない")
    func aSaveDuringDrawWaitsForTheFrameBoundary() throws {
        let sketch = Idle()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        let fragments = try load(on: runtime.canvas)
        let graphics: Canvas? = try runtime.canvas.createGraphics(4, 4)
        try runtime.advance()

        var atStart: [Int] = []
        var atEnd: [Int] = []
        var rewriteFailure: (any Error)?
        sketch.duringDraw = {
            atStart = fragments.generations
            do { try rewrite(fragments, 1) } catch { rewriteFailure = error }
            // 書き換えた後で使う。**使うときに取る**形だと、ここで組み直してしまう
            runtime.canvas.shader(fragments.shader)
            runtime.canvas.rect(0, 0, 4, 4)
            runtime.canvas.resetShader()
            // 描き場所のフレームを入れ子に描く。**面の描き始めで取る**形だと、ここで組み直す
            graphics?.beginDraw()
            graphics?.background(.linear(red: 0, green: 0, blue: 0))
            graphics?.endDraw()
            atEnd = fragments.generations
        }
        try runtime.advance()
        sketch.duringDraw = nil
        if let rewriteFailure { throw rewriteFailure }
        #expect(atStart == atEnd, "描いている最中に組み直した: \(atStart) → \(atEnd)")

        try runtime.advance()
        #expect(fragments.generations == [1, 1, 1], "次のフレームの境目で読み直していない")
    }

    @Test("譲らずに何度書き換えても、積まれる知らせは 1 本までで、扱うのは境目ごとに 1 度")
    func savesWithoutYieldingDoNotPileUp() throws {
        let sketch = Idle()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        let fragments = try load(on: runtime.canvas)
        try runtime.advance()
        let handled = fragments.watchers.map(\.handledCount)

        for revision in 1...5 {
            try rewrite(fragments, revision)
            try runtime.advance()
        }
        #expect(fragments.generations == [5, 5, 5])
        for watcher in fragments.watchers {
            #expect(watcher.queuedNoticeCount <= 1, "譲らない間に知らせが積み上がっている")
        }
        // 保存 1 度でファイル側と親ディレクトリ側が拾っても、扱うのは境目ごとに 1 度。**この検査は
        // 同期で回るので、間に他の検査のフレームは入らない** — 扱った回数はこの検査の分だけである
        #expect(zip(fragments.watchers.map(\.handledCount), handled).allSatisfy { $0 - $1 == 5 })
    }

    /// 反証 1 ([#1830])。ランタイムを通さずに面を直に回すループ (`Canvas(target:gpu:)` と `draw(_:)`)
    /// でも届く。取る口がランタイムにしか無いと、この形は譲らない限り古い断片のまま描く。
    ///
    /// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
    @Test("ランタイムを通さずに面を直に回しても、書き換えた断片は次のフレームで読み直される")
    func aSaveArrivesWhenTheCanvasIsDrivenDirectly() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        try canvas.draw {}
        let fragments = try load(on: canvas)
        try canvas.draw {}
        try #require(fragments.generations == [0, 0, 0])

        for revision in 1...2 {
            try rewrite(fragments, revision)
            try canvas.draw {}
            #expect(
                fragments.generations == [revision, revision, revision],
                "面を直に回して \(revision) 回目の保存をした次のフレームで、読み直した回数が \(fragments.generations)")
        }
    }

    /// 反証 2 ([#1830])。断片と同じディレクトリへ連番を書き出すと、見張りは親ディレクトリの事象を
    /// フレームごとに拾う。組み立てに失敗する断片を毎フレーム組み直して警告しない・中身が
    /// 変わらなければファイル側を張り直さない。
    ///
    /// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
    @Test("組み立てに失敗する断片は、隣へ毎フレーム書き出しても、組み直さず 1 度だけ知らせる")
    func aBrokenFragmentIsReportedOnceWhileFramesAreWrittenBesideIt() throws {
        let sketch = Idle()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        let fragments = try load(on: runtime.canvas)
        sketch.paint = fragments.shader
        try runtime.advance()
        let shader = fragments.shader
        let watcher = try #require(shader.watcher)
        let directory = fragments.urls[0].deletingLastPathComponent()

        /// 何かを書いて、この見張りに事象が届くのを譲らずに待つ。
        func touch(_ write: () throws -> Void) throws {
            let before = watcher.arrivedEventCount
            try write()
            let deadline = Date().addingTimeInterval(5)
            while watcher.arrivedEventCount <= before, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            Thread.sleep(forTimeInterval: 0.05)
            try #require(watcher.arrivedEventCount > before, "検査の前提: 書いた事象が見張りに届いていない")
        }

        // その場で上書きして壊す (置き換えると、ファイル側を張り直すのが正しい)
        try touch {
            try "これは MSL ではない".write(to: fragments.urls[0], atomically: false, encoding: .utf8)
        }
        try runtime.advance()
        try #require(shader.failure != nil, "検査の前提: 壊した断片の組み立てが失敗していない")
        let reports = shader.failureReports
        let watches = watcher.fileWatchCount
        let handled = watcher.handledCount

        for frame in 0..<8 {
            try touch {
                try runtime.target.writePNG(to: directory.appendingPathComponent("frame-\(frame).png"))
            }
            try runtime.advance()
        }
        try #require(watcher.handledCount - handled >= 8, "検査の前提: 書き出しの事象をフレームごとに扱っていない")
        #expect(
            shader.failureReports == reports,
            "同じ中身の失敗を、書き出しのたびに \(shader.failureReports - reports) 回言い直した")
        #expect(watcher.fileWatchCount == watches, "中身の変わらない断片のファイル側を、フレームごとに張り直した")
        #expect(shader.generation == 0)

        // 直して保存すれば、次のフレームで組み上がり、失敗の控えも下りる
        try touch {
            try Self.shaderBody("0.75").write(to: fragments.urls[0], atomically: false, encoding: .utf8)
        }
        try runtime.advance()
        #expect(shader.generation == 1)
        #expect(shader.failure == nil)
    }

    // MARK: - 2 回目の反証 (#1830)

    /// 何かを書いて、見張りに事象が届くのを譲らずに待つ。
    ///
    /// - Parameter required: 届くことが検査の前提か。届くかどうかそのものを見るなら `false` にして、
    ///   届かなければ待ちを切り上げる (見るのは呼んだ側の表明)。
    private func touch(
        _ watcher: FileWatcher, required: Bool = true, _ write: () throws -> Void
    ) throws {
        let before = watcher.arrivedEventCount
        try write()
        let deadline = Date().addingTimeInterval(required ? 5 : 1)
        while watcher.arrivedEventCount <= before, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.05)
        guard required else { return }
        try #require(watcher.arrivedEventCount > before, "検査の前提: 書いた事象が見張りに届いていない")
    }

    /// 2 回目の反証 1。外から止めた間と、作者の `noLoop()` で描き直しを頼まれていない間は、
    /// ランタイムが描かずに戻る。本体の面の頭が来ないので、そこでも取らないと、譲らないループでは
    /// 保存が扱われず、観測の目録 (`shaderFailures`) も古いまま残る。
    @Test("外から止めた間も、作者が止めた間も、譲らずに回せば保存を扱う", arguments: [false, true])
    func aSaveArrivesWhileTheSketchIsStopped(stoppedByTheAuthor: Bool) throws {
        let sketch = Idle()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        let fragments = try load(on: runtime.canvas)
        try runtime.advance()
        let shader = fragments.shader
        let watcher = try #require(shader.watcher)
        if stoppedByTheAuthor {
            sketch.stopsAfterDrawing = true
            try runtime.advance()
        } else {
            runtime.pause()
        }

        try touch(watcher) {
            try "これは MSL ではない".write(to: fragments.urls[0], atomically: false, encoding: .utf8)
        }
        try runtime.advance()
        #expect(shader.failure != nil, "止めている間に壊した断片を、譲らずに回しても扱っていない")
        #expect(runtime.canvas.shaderFailures.count == 1, "観測の目録に、壊した断片の理由が載っていない")

        try touch(watcher) {
            try Self.shaderBody("0.75").write(to: fragments.urls[0], atomically: false, encoding: .utf8)
        }
        try runtime.advance()
        #expect(shader.generation == 1, "止めている間に直した断片を、譲らずに回しても読み直していない")
        #expect(runtime.canvas.shaderFailures.isEmpty, "直した後も、観測の目録に古い理由が残っている")
    }

    /// 2 回目の反証 2。組み直して入れ替えた古いパイプラインの状態は、投入済みのフレームが終わる
    /// まで抱える。この世代のコマンドは読む相手を保持しないので、抱える者がいないと、前のフレームが
    /// まだ走っている間に手放しうる。**差し替えの直後に誰かが抱えていて、待った後には手放している**
    /// ことを見る (抱え続けても漏れる)。
    @Test("入れ替えた古い状態は、投入済みのフレームが終わるまで抱え、終われば手放す")
    func replacedStatesAreHeldUntilSubmittedFramesFinish() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        let fragments = try load(on: canvas)
        let shader = fragments.shader
        weak var flat: AnyObject? = shader.states.composite
        weak var solid: AnyObject? = shader.solidStates.blend
        weak var effect: AnyObject? = fragments.effect.state
        weak var computation: AnyObject? = fragments.computation.state
        // 塗りで描いたフレームを、待たずに投入しておく
        try canvas.draw {
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 8, 8)
            canvas.resetShader()
        }

        try Self.shaderBody("0.5").write(to: fragments.urls[0], atomically: false, encoding: .utf8)
        try Self.effectBody("0.25").write(to: fragments.urls[1], atomically: false, encoding: .utf8)
        try Self.computationBody("2.0").write(to: fragments.urls[2], atomically: false, encoding: .utf8)
        shader.reload()
        fragments.effect.reload()
        fragments.computation.reload()
        try #require(fragments.generations == [1, 1, 1], "検査の前提: 組み直していない")
        #expect(flat != nil, "入れ替えた塗りの平面の状態を、誰も抱えていない")
        #expect(solid != nil, "入れ替えた塗りの立体の状態を、誰も抱えていない")
        #expect(effect != nil, "入れ替えた効果の状態を、誰も抱えていない")
        #expect(computation != nil, "入れ替えた計算の状態を、誰も抱えていない")

        try canvas.gpu.settle()
        #expect(flat == nil && solid == nil && effect == nil && computation == nil, "終わった後も抱え続けている")
        // 入れ替えた直後のフレームも描ける (検査の段は MTL_DEBUG_LAYER=1 で回る)
        try canvas.draw {
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 8, 8)
            canvas.resetShader()
        }
        try canvas.gpu.settle()
        #expect(canvas.gpu.commandFaultCount == 0)
    }

    /// 2 回目の反証 3・4。控えるのは組み立て (翻訳) の失敗だけで、それ以外は次に拾ったときに
    /// 組み直す。`failure` は、いま効いている中身とファイルが揃えば下りる。同じ理由は言い直さない。
    @Test("組み直さないのは翻訳に失敗した中身だけで、失敗の控えは効いている中身へ戻すと下りる")
    func onlyCompilationFailuresAreRemembered() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-shader-box-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("paint.metal")
        let good = Self.shaderBody("0.25")
        try good.write(to: url, atomically: false, encoding: .utf8)
        let box = ShaderBox(
            name: "paint", url: url, body: good, values: [:], label: "shader", valuesHint: "")

        // 中身と関係ない失敗は控えない。同じ中身でも、次に拾えば組み直す
        try Self.shaderBody("0.5").write(to: url, atomically: false, encoding: .utf8)
        var attempts = 0
        for _ in 0..<2 {
            box.reload { (_: String) throws(RenderFailure) in
                attempts += 1
                throw .pipelineUnavailable(reason: "for testing")
            }
        }
        #expect(attempts == 2, "中身と関係ない失敗まで控え、同じ中身を組み直さなくなった")
        #expect(box.failureReports == 1, "同じ理由の失敗を言い直した")

        // 翻訳の失敗は控え、同じ中身なら組み直さない
        attempts = 0
        try "これは MSL ではない".write(to: url, atomically: false, encoding: .utf8)
        for _ in 0..<2 {
            box.reload { (_: String) throws(RenderFailure) in
                attempts += 1
                throw .shaderCompilationFailed(name: "paint", reason: "for testing")
            }
        }
        #expect(attempts == 1)
        #expect(box.failure != nil)

        // いま効いている中身へ戻して保存すれば、組み直さずに控えが下りる
        try good.write(to: url, atomically: false, encoding: .utf8)
        box.reload { (_: String) throws(RenderFailure) in attempts += 1 }
        #expect(attempts == 1, "効いている中身と同じなのに組み直した")
        #expect(box.failure == nil, "効いている中身へ戻したのに、失敗の控えが残っている")
        #expect(box.generation == 0)

        // 読めないままなら、何度拾っても 1 度だけ言う
        let reports = box.failureReports
        try FileManager.default.removeItem(at: url)
        box.reload { (_: String) throws(RenderFailure) in }
        box.reload { (_: String) throws(RenderFailure) in }
        #expect(box.failureReports == reports + 1)
    }

    /// 2 回目の反証 5。消して作り直したファイルも、張り直して見張り続ける。張り直すかは、ファイルが
    /// 誰か (通し番号と生まれた時刻) で決める。**APFS は番号を使い回さないので、この検査は番号だけの
    /// 比べ方でも緑になる** — 見ているのは「消して作り直した後も届く」ことで、張り直しを止めると赤になる。
    @Test("消して作り直したファイルも、その後のその場の上書きまで届く")
    func aFileDeletedAndRecreatedIsWatchedAgain() throws {
        let sketch = Idle()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        let fragments = try load(on: runtime.canvas)
        try runtime.advance()
        let shader = fragments.shader
        let watcher = try #require(shader.watcher)
        let url = fragments.urls[0]

        try touch(watcher) { try FileManager.default.removeItem(at: url) }
        try runtime.advance()
        try touch(watcher) {
            try Self.shaderBody("0.5").write(to: url, atomically: false, encoding: .utf8)
        }
        try runtime.advance()
        #expect(shader.generation == 1, "消して作り直した断片を読み直していない")

        // その場の上書きは親ディレクトリを変えない。ファイル側を張り直していなければ届かない
        try touch(watcher, required: false) {
            try Self.shaderBody("0.75").write(to: url, atomically: false, encoding: .utf8)
        }
        try runtime.advance()
        #expect(shader.generation == 2, "作り直したファイルのその場の上書きが届かない")
    }
}
