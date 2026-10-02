// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// **細かさ (`pixelDensity`) を変えても、出す画素で書いた値は出す画素で見て同じ結果になる**
/// ([#1686])。GPU を要する。
///
/// `SketchSettings.pixelDensity` の説明は「座標は出す細かさのままなので、スケッチのコードは
/// 1 行も変わらない」と言う ([ADR-0015] 決定 1)。この約束の破れは、物差しが経路を 1 つずつ
/// 突くたびに 1 件ずつ起票されてきた (#1488・#1477・#1545・#1637・#1639・#1641)。欠けていた
/// のは口の一覧とそれを回す検査で、ここがその 1 か所である。
///
/// ## 口の表
///
/// 出す画素で書いた値を描く面へ写す口を、下の 2 つの列挙 (``Amount``・``Outline``) に並べる。
/// **口を足したら、ここの列挙にも 1 行足す** — 換算を持たずに入った口は、どの検査も赤く
/// しないからである。表の正本は #1686 の「範囲」で、この列挙はその写しではなく、表の行を
/// 1 つずつ回す引数の一覧である。
///
/// | 口 | 列挙の行 | 比べ方 |
/// | --- | --- | --- |
/// | 座標 | ``Outline/fill`` | 形 |
/// | 線の半画素の寄せ | ``Outline/thickLine``・``Outline/thickQuad`` | 形 |
/// | 線・輪郭・点の太さ (距離関数の経路・#1488) | ``Amount/line``・``Amount/rectOutline``・``Amount/point`` | 量 |
/// | 細い塗り (距離関数の経路・#1477) | ``Amount/thinFill`` | 量 |
/// | 線・輪郭・点の太さ (三角形の経路・#1637) | ``Amount/quad`` ほか、三角形の経路の行すべて | 量 |
/// | 効果の半径 (#1545) | ``Outline/blur`` | 形 (2 つの濃さで切る) |
/// | 効果の断片の `position` / `size` (#1639) | ``Outline/effectPosition``・``Outline/effectSize`` | 形 |
/// | 塗りの断片の `position` / `resolution` (#1639) | ``Outline/paintPosition``・``Outline/paintResolution`` | 形 |
/// | 切り抜きの矩形 (#1641) | ``Outline/clip`` | 形 (同じ矩形の `rect` と比べる) |
/// | 字形 | ``Outline/text`` | 形 |
/// | 影の焼き付け | ``Outline/shadow`` | 形 |
/// | 粒の大きさ | ``Outline/particles`` | 形 |
/// | 画像の貼り方 | ``Outline/image`` | 形 |
///
/// ## 2 つの比べ方
///
/// - **量** (太さ・面積の口): 描く面 (`Canvas.target`) の線形の値を足す。線は、線を横切る列の
///   和が「太さ × 細かさ」の ±10%、点は全体の和が「面積 × 細かさの 2 乗」の ±10%。置く位置を
///   出す画素で 0.5 ずつ (描く画素で 0.25 ずつ) ずらして、どの位置でも成り立つことを見る
///   (細かさ 1 の 1 画素より細い線も、同じ式で見る — `strokeWeight` の説明は経路も細かさも
///   限らない)
/// - **形** (位置・矩形の口): 出す面 (`Canvas.output`) を 50% で白黒にした形を、細かさ 1 の
///   同じ絵 (切り抜きは同じ細かさの `rect`) と比べる。縁のずれは描く画素の半分 (細かさ 1 で
///   0・0.5 で 1 出す画素) まで許す。比べる相手の値がちょうど半分に近い画素 (0.45…0.55) は、
///   どちらへ倒れても正しいので数えない
///
/// [#1686]: https://github.com/mokume-metal/mokume/issues/1686
/// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
@Suite(
    "細かさを変えても、出す画素で書いた値は出す画素で見て同じ結果になる",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct DensityInvarianceTests {
    /// 出す面の大きさ (正方形)。
    static let size = 128

    /// 比べる細かさ。
    static let densities: [Float] = [1, 0.5]

    /// 出す大きさ ``size`` の面を、細かさ `density` で作る。
    private static func makeCanvas(density: Float) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: size, height: size)
        return try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
    }

    // MARK: - 量の口

    /// 太さ・面積で比べる口。**口を足したら、ここに 1 行足す** (型の説明の表)。
    ///
    /// 線の口は、上の縁が y = 40 + ずらし の横線を引き、出す画素の x = 54…74 の列を見る
    /// (縦の辺・稜線と、端・角の形を避ける)。
    /// 点の口は (64 + ずらし, 64 + ずらし) に 1 つ置く。
    enum Amount: String, CaseIterable, Sendable {
        // 距離関数の経路 (#1488・#1477)
        case line = "line (距離関数)"
        case rectOutline = "rect の輪郭 (距離関数)"
        case point = "point (距離関数)"
        case thinFill = "細い塗り (距離関数)"
        // 三角形の経路 (#1637)
        case quad = "quad の輪郭 (三角形の経路)"
        case triangle = "triangle の輪郭 (三角形の経路)"
        case polygon = "beginShape の輪郭 (三角形の経路)"
        case shaderLine = "shader() の line (三角形の経路)"
        case shaderRect = "shader() の rect の輪郭 (三角形の経路)"
        case foldedRect = "shader() の rect を畳んだ雛形 (三角形の経路)"
        case shaderPoint = "shader() の point (三角形の経路)"
        case shaderSquarePoint = "shader() の四角い point (三角形の経路)"
        case retained = "保持した形を縮めて置く (三角形の経路)"
        case solidPolygon = "奥行きのある beginShape の輪郭 (立体の線)"
        case box = "noFill() の box の稜線 (立体の線)"
        // 縦と横で倍率の違う変換。細さは線の向きに垂直に測る (距離関数の経路が軸ごとに測るのと
        // 同じ測り方)。距離関数の経路の同じ行は置かない — 描く画素で 0.07 より細い線では 10% を
        // 越えて少なく出て (縁の遊び 1/256 によるとみられる)、この物差しの幅に収まらない
        case stretchedQuad = "scale(4, 0.25) の quad の輪郭 (三角形の経路)"
        case squashedQuad = "scale(1, 0.1) の quad の輪郭 (三角形の経路)"
        // 被覆は断片の後で掛ける。断片が `in.color` を掛けなくても、`in.color.a` を読んでも同じ量
        case shaderOwnColor = "in.color を使わない shader() の quad の輪郭 (三角形の経路)"
        case shaderReadsAlpha = "in.color.a の 2 乗を返す shader() の quad の輪郭 (三角形の経路)"
        // 入れ子の記録で、半透明の色を掛けて置いた輪郭も、外側を置くときに細さを測る
        case nestedTranslucent = "半透明の色で入れ子に置いた保持した形 (三角形の経路)"

        /// 線を横切る列の和に、線の太さが何本ぶん入るか。点は 0 (全体の和で見る)。
        ///
        /// 閉じた四角の輪郭は上と下の辺の 2 本、箱は正面と背面の上下の稜線の 4 本が見る列を
        /// 横切る。三角形は上の辺と斜めの辺の 2 本で、斜めの辺は列で測ると太さの 1 / cos 倍になる。
        ///
        /// 縦横で倍率の違う変換の行は、横の辺の太さが縦の倍率ぶん細る。半透明の色 (不透明度 0.5)
        /// で置いた行は、光の量も半分になる。
        var crossings: Double {
            switch self {
            case .point, .shaderPoint, .shaderSquarePoint: 0
            case .line, .thinFill, .shaderLine: 1
            case .triangle: 1 + (1 + Double(60 * 60) / Double(88 * 88)).squareRoot()
            case .box: 4
            case .stretchedQuad: 2 * 0.25
            case .squashedQuad: 2 * 0.1
            case .nestedTranslucent: 2 * 0.5
            default: 2
            }
        }

        /// 塗りで量を出す口か (線の太さの代わりに塗りの幅で書く)。
        var isFill: Bool { self == .thinFill }

        @MainActor
        func draw(on canvas: Canvas, weight: Float, offset: Float) throws {
            let y = 40 + offset
            canvas.strokeWeight(weight)
            switch self {
            case .line: canvas.line(20, y, 108, y)
            case .rectOutline: canvas.rect(20, y, 88, 40)
            case .point: canvas.point(64 + offset, 64 + offset)
            case .thinFill:
                canvas.noStroke()
                canvas.fill(255)
                canvas.rect(20, y, 88, weight)
            case .quad: canvas.quad(20, y, 108, y, 108, y + 40, 20, y + 40)
            case .triangle: canvas.triangle(20, y, 108, y, 20, y + 60)
            case .polygon:
                canvas.beginShape()
                canvas.vertex(20, y)
                canvas.vertex(108, y)
                canvas.vertex(108, y + 40)
                canvas.vertex(20, y + 40)
                canvas.endShape(.close)
            case .shaderLine:
                canvas.shader(try Self.plainShader(canvas))
                canvas.line(20, y, 108, y)
            case .shaderRect:
                canvas.shader(try Self.plainShader(canvas))
                canvas.rect(20, y, 88, 40)
            case .foldedRect:
                // 同じ形が 2 つ続くと 2 つ目で雛形を開く (``Canvas/draw(folding:at:outline:)``)。
                // 1 つ目は面の外へ置き、見るのは雛形から置いた 2 つ目である
                canvas.shader(try Self.plainShader(canvas))
                canvas.rect(20, y - 400, 88, 40)
                canvas.rect(20, y, 88, 40)
            case .shaderPoint:
                canvas.shader(try Self.plainShader(canvas))
                canvas.point(64 + offset, 64 + offset)
            case .shaderSquarePoint:
                canvas.shader(try Self.plainShader(canvas))
                canvas.strokeCap(.project)
                canvas.point(64 + offset, 64 + offset)
            case .retained:
                // 太さを倍で記録し、半分に縮めて置く。置いた後の太さが `weight` になる
                canvas.strokeWeight(weight * 2)
                let shape = canvas.createShape {
                    canvas.quad(0, 0, 176, 0, 176, 80, 0, 80)
                }
                canvas.translate(20, y)
                canvas.scale(0.5, 0.5)
                canvas.shape(shape)
            case .solidPolygon:
                canvas.beginShape()
                canvas.vertex(20, y, 0)
                canvas.vertex(108, y, 0)
                canvas.vertex(108, y + 40, 0)
                canvas.vertex(20, y + 40, 0)
                canvas.endShape(.close)
            case .box:
                canvas.translate(64, 64 + offset, -20)
                canvas.box(40)
            case .stretchedQuad, .squashedQuad:
                let (sx, sy): (Float, Float) = self == .squashedQuad ? (1, 0.1) : (4, 0.25)
                canvas.translate(20, y)
                canvas.scale(sx, sy)
                canvas.quad(0, 0, 88 / sx, 0, 88 / sx, 40 / sy, 0, 40 / sy)
            case .shaderOwnColor, .shaderReadsAlpha:
                let body =
                    self == .shaderOwnColor
                    ? "float4 paint(Fragment in, Values values) { return float4(1, 1, 1, 1); }"
                    // `stroke()` の不透明度 1 がそのまま届くなら、2 乗しても 1 のまま
                    : "float4 paint(Fragment in, Values values) { return float4(in.color.a * in.color.a); }"
                canvas.shader(try canvas.makeShader(body))
                canvas.quad(20, y, 108, y, 108, y + 40, 20, y + 40)
            case .nestedTranslucent:
                let inner = canvas.createShape {
                    canvas.quad(0, 0, 88, 0, 88, 40, 0, 40)
                }
                let outer = canvas.createShape {
                    canvas.shape(
                        inner,
                        at: [Placement(fill: LinearRGBA(premultipliedRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.5))])
                }
                canvas.translate(20, y)
                canvas.shape(outer)
            }
        }

        /// 色をそのまま返す断片。三角形の経路へ落とすためだけに使う。
        @MainActor
        private static func plainShader(_ canvas: Canvas) throws -> Shader {
            try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        }
    }

    /// 描く面の、出す画素の x = 54…74 にあたる列の和の平均。
    private static func columnSum(_ pixels: PixelBuffer, density: Float) -> Double {
        let first = Int((54 * density).rounded(.down))
        let last = Int((74 * density).rounded(.down))
        var total = 0.0
        for x in first..<last {
            for y in 0..<pixels.height { total += Double(pixels[x, y].red) }
        }
        return total / Double(last - first)
    }

    private static func totalSum(_ pixels: PixelBuffer) -> Double {
        var total = 0.0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width { total += Double(pixels[x, y].red) }
        }
        return total
    }

    /// 太さ・面積の口が、細かさと置く位置によらず、描く画素での太さ (面積) ぶんの濃さで出る。
    @Test(
        "太さ・面積の口は、細かさと置く位置によらず描く画素での太さ (面積) ぶんの濃さで出る",
        arguments: Amount.allCases, [Float(1), 0.5, 0.2])
    func amountKeepsItsWeight(_ mouth: Amount, _ weight: Float) throws {
        var broken: [String] = []
        for density in Self.densities {
            // 点は描く画素で 1 画素より小さいときだけ見る。1 画素以上の点の形は経路ごとの
            // 量子化で、この約束の外 (ADR-0039 決定 3)
            if mouth.crossings == 0, weight * density >= 1 { continue }
            for offset in [Float(0), 0.5, 1, 1.5] {
                let canvas = try Self.makeCanvas(density: density)
                try Self.draw(on: canvas) {
                    canvas.background(0)
                    canvas.noFill()
                    canvas.stroke(255)
                    try mouth.draw(on: canvas, weight: weight, offset: offset)
                }
                let pixels = try canvas.target.readPixels()
                let drawn = Double(weight * density)
                let (measured, expected) =
                    mouth.crossings == 0
                    ? (Self.totalSum(pixels), drawn * drawn)
                    : (Self.columnSum(pixels, density: density), drawn * mouth.crossings)
                if abs(measured - expected) > 0.1 * expected {
                    broken.append("細かさ \(density)・ずらし \(offset): \(measured) (期待 \(expected))")
                }
            }
        }
        #expect(broken.isEmpty, "\(mouth.rawValue)・太さ \(weight): \(broken.joined(separator: " / "))")
    }

    /// #1637 の本文の再現 (`ThinOutline`)。軸に沿った `quad` の太さ 1 の輪郭を、上辺 y = 10 と 11
    /// に置き、**出す面**の赤の総和 (線の光の量) を細かさ 1 の y = 10 と比べる。直す前は細かさ 0.5
    /// で y = 10 が 0・y = 11 が 351 (細かさ 1 は 280) だった。±20% は拡大の段が総光量を少し
    /// 増やす分を見込んだ幅 (本文と同じ)。
    @Test("細かさ 0.5 の quad の太さ 1 の輪郭は、上辺の偶奇によらず細かさ 1 と同じ光の量で出る (#1637)")
    func thinQuadOutlineKeepsItsLight() throws {
        func light(y: Float, density: Float) throws -> Double {
            let gpu = try RenderDevice()
            let output = try RenderTarget(gpu: gpu, width: 100, height: 100)
            let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
            try canvas.draw {
                canvas.background(0)
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(1)
                canvas.quad(10, y, 90, y, 90, y + 60, 10, y + 60)
            }
            return Self.totalSum(try canvas.output.readPixels())
        }
        let reference = try light(y: 10, density: 1)
        for y: Float in [10, 11] {
            let low = try light(y: y, density: 0.5)
            #expect(
                abs(low - reference) < reference * 0.2,
                "細かさ 0.5・上辺 y = \(y) の光の量 \(low) (細かさ 1 は \(reference))")
        }
    }

    /// **立体の線は、置く面の細かさで補う** (#1637)。細かさ 0.5 の本体で記録した `box` の稜線を
    /// 描き場所 (細かさ 1) へ置くと、太さ 1 のまま出る。逆に描き場所で記録して本体へ置くと、
    /// 本体の細かさで補う。保持した線を GPU で組む経路 (#1756) と CPU の帯の両方で見る。
    ///
    /// 直す前は、記録した面の細かさで補いが焼き付いていた (描き場所で太さ 2・半分の濃さ)。
    @Test(
        "保持した立体の線は、置く面の細かさで補う (#1637)",
        arguments: [true, false], [true, false])
    func retainedSolidStrokesFollowTheSurfaceTheyArePlacedOn(
        _ recordOnMain: Bool, _ onGPU: Bool
    ) throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        canvas.placesRetainedStrokesOnGPU = onGPU
        let pad = try canvas.createGraphics(Self.size, Self.size)
        pad.placesRetainedStrokesOnGPU = onGPU
        func record(on surface: Canvas) -> Shape {
            surface.createShape {
                surface.noFill()
                surface.stroke(255)
                surface.strokeWeight(1)
                surface.box(40)
            }
        }
        func place(_ shape: Shape, on surface: Canvas) {
            surface.background(0)
            surface.translate(64, 64, -20)
            surface.shape(shape)
        }
        try canvas.draw {
            pad.beginDraw()
            let shape = recordOnMain ? record(on: canvas) : record(on: pad)
            if recordOnMain { place(shape, on: pad) } else { place(shape, on: canvas) }
            pad.endDraw()
            if recordOnMain { canvas.background(0) }
        }
        let (surface, density): (Canvas, Float) = recordOnMain ? (pad, 1) : (canvas, 0.5)
        let pixels = try surface.target.readPixels()
        let measured = Self.columnSum(pixels, density: density)
        let expected = 4 * Double(density)
        let route = recordOnMain ? "本体で記録して描き場所" : "描き場所で記録して本体"
        #expect(
            abs(measured - expected) <= 0.1 * expected,
            "\(route)へ置いた box の稜線の列の和: \(measured) (期待 \(expected))")
        // 光の量だけでなく太さも見る。細かさ 1 の面では太さ 1 の満濃度の線で、記録した面の補い
        // (太さ 2・半分の濃さ) が焼き付いていれば、列のいちばん明るい画素が 0.5 になる
        if recordOnMain {
            let column = Int(64 * density)
            let brightest = (0..<pixels.height).map { pixels[column, $0].red }.max() ?? 0
            #expect(brightest > 0.9, "\(route)へ置いた box の稜線のいちばん明るい画素: \(brightest)")
        }
    }

    /// **補っても速い経路から外れない** (#1637)。細かさ 0.5 では既定の太さ 1 がいつも細い側に
    /// 入るので、補いが速い経路を外すと、細かさを下げたスケッチがかえって遅くなる。
    ///
    /// - 組み込みの立体の稜線は GPU で広げる (#1756)。補いは置き場所が持つ (太さと被覆)
    /// - `shader()` の `rect` は、同じ変換の置き場所どうしで畳む
    /// - 保持した形の細い輪郭は、同じ大きさで置き続けるかぎり 1 度しか組み直さない
    @Test("細かさ 0.5 の細い線も、GPU の稜線・畳み・組み直しの控えの速い経路を通る (#1637)")
    func thinStrokesKeepTheFastRoutes() throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        let plain = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return in.color; }")
        var shape = Shape.empty
        for frame in 0..<2 {
            try canvas.draw {
                canvas.background(0)
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(1)
                canvas.pushMatrix()
                canvas.translate(64, 64, -20)
                canvas.box(40)
                canvas.popMatrix()
                canvas.closeBatch()
                #expect(
                    canvas.batches.compactMap(\.strokeGeometry).count == 1,
                    "細かさ 0.5 の box の稜線が GPU で広げる経路に入らない")
                canvas.shader(plain)
                for index in 0..<4 { canvas.rect(10 + Float(index) * 20, 10, 12, 12) }
                // 1 つ目は畳む相手を待って置き、2 つ目から雛形を開いて置き場所を足す
                #expect(canvas.openFlat != nil, "細い輪郭の rect が畳まれない")
                #expect(canvas.flatInstances.count == 5, "畳んだ置き場所の数: \(canvas.flatInstances.count)")
                canvas.resetShader()
                if frame == 0 { shape = canvas.createShape { canvas.quad(0, 0, 40, 0, 40, 20, 0, 20) } }
                for index in 0..<3 {
                    canvas.pushMatrix()
                    canvas.translate(10 + Float(index) * 30, 80)
                    canvas.scale(0.5, 0.5)
                    canvas.shape(shape)
                    canvas.popMatrix()
                }
            }
        }
        #expect(canvas.thinStrokesRebuilt == 1, "組み直した回数: \(canvas.thinStrokesRebuilt)")
    }

    // MARK: - 形の口

    /// 位置・矩形で比べる口。**口を足したら、ここに 1 行足す** (型の説明の表)。
    enum Outline: String, CaseIterable, Sendable {
        case fill = "塗りの位置"
        case thickLine = "太い line の位置 (距離関数)"
        case thickQuad = "太い quad の輪郭の位置 (三角形の経路)"
        case blur = "効果の半径 (blur)"
        case effectPosition = "効果の断片の position"
        case effectSize = "効果の断片の size"
        case paintPosition = "塗りの断片の position"
        case paintResolution = "塗りの断片の resolution"
        case clip = "切り抜きの矩形"
        case text = "字形"
        case shadow = "影の焼き付け"
        case particles = "粒の大きさ"
        case image = "画像の貼り方"

        /// 置く位置のずらし (出す画素)。切り抜きは縁を整数から 0.1…0.9 ずらす (#1641 完了条件 4)。
        var offsets: [Float] {
            switch self {
            case .clip: [0, 0.1, 0.25, 0.5, 0.75, 0.9]
            case .effectPosition, .effectSize, .paintPosition, .paintResolution, .particles: [0]
            default: [0, 0.5, 1, 1.5]
            }
        }

        /// 白黒にする濃さ。効果の半径は、ぼけの裾と肩の 2 か所で切る (どちらも半径で動く)。
        var thresholds: [Float] { self == .blur ? [0.25, 0.75] : [0.5] }

        /// 細かさ 1 の同じ絵ではなく、同じ細かさの別の絵と比べるか。
        var hasReference: Bool { self == .clip }

        @MainActor
        func draw(on canvas: Canvas, offset o: Float, reference: Bool) throws {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            switch self {
            case .fill:
                canvas.rect(20.5 + o, 30.25 + o, 50, 40)
            case .thickLine:
                canvas.stroke(255)
                canvas.strokeWeight(6)
                canvas.line(20 + o, 30 + o, 100 + o, 90 + o)
            case .thickQuad:
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(6)
                canvas.quad(20 + o, 30 + o, 100 + o, 24 + o, 96 + o, 100 + o, 30 + o, 90 + o)
            case .blur:
                canvas.rect(40 + o, 40 + o, 48, 48)
                canvas.effects([.blur(radius: 6)])
            case .effectPosition:
                canvas.effects([.custom(try canvas.makeEffect(Self.checker("in.position")))])
            case .effectSize:
                canvas.effects([.custom(try canvas.makeEffect(Self.checker("in.place * in.size")))])
            case .paintPosition:
                canvas.shader(try canvas.makeShader(Self.paintChecker("in.position")))
                canvas.rect(0, 0, 128, 128)
            case .paintResolution:
                canvas.shader(try canvas.makeShader(Self.paintChecker("in.place * in.resolution")))
                canvas.rect(0, 0, 128, 128)
            case .clip:
                let (x, y, w, h) = (20 + o, 30 + o, 51, 40.5 - o)
                if reference {
                    canvas.rect(x, y, w, h)
                } else {
                    canvas.clip(x, y, w, h)
                    canvas.rect(0, 0, 128, 128)
                    canvas.noClip()
                }
            case .text:
                canvas.textSize(56)
                canvas.text("Hm", 16 + o, 90 + o)
            case .shadow:
                canvas.ambientLight(80)
                canvas.directionalLight(.linear(red: 1, green: 1, blue: 1), 0.5, 0.4, -1)
                canvas.shadows(true)
                canvas.fill(255)
                canvas.pushMatrix()
                canvas.translate(64, 64, 0)
                canvas.plane(128, 128)
                canvas.popMatrix()
                canvas.translate(52 + o, 52 + o, 30)
                canvas.box(24)
            case .particles:
                let dust = try canvas.makeParticles(count: 4)
                var randomness = Randomness(seed: 1686)
                canvas.emit(
                    dust, from: .point(64.5, 60.25), rate: (4 / canvas.deltaTime).nextUp,
                    speed: 0...0, angle: 0...0, life: 100...100, size: 20...20,
                    color: .linear(red: 1, green: 1, blue: 1), using: &randomness)
                canvas.particles(dust)
            case .image:
                let picture = try canvas.createImage(8, 8)
                for y in 0..<8 {
                    for x in 0..<8 where (x / 2 + y / 2) % 2 == 0 {
                        picture.set(x, y, .linear(red: 1, green: 1, blue: 1))
                    }
                }
                canvas.image(picture, 20.5 + o, 30.5 + o, 64, 64)
            }
        }

        /// `floor(座標 / 8)` の市松を出す効果。
        static func checker(_ coordinate: String) -> String {
            """
            float4 effect(Pixel in, Values values) {
                float2 cell = floor((\(coordinate)) / 8.0);
                return fmod(cell.x + cell.y, 2.0) < 0.5 ? float4(1, 1, 1, 1) : float4(0, 0, 0, 1);
            }
            """
        }

        /// `floor(座標 / 8)` の市松で塗る断片。
        static func paintChecker(_ coordinate: String) -> String {
            """
            float4 paint(Fragment in, Values values) {
                float2 cell = floor((\(coordinate)) / 8.0);
                return fmod(cell.x + cell.y, 2.0) < 0.5 ? float4(1, 1, 1, 1) : float4(0, 0, 0, 1);
            }
            """
        }
    }

    /// 出す面を描いて読む。
    @MainActor
    private static func output(
        _ mouth: Outline, density: Float, offset: Float, reference: Bool = false
    ) throws -> PixelBuffer {
        let canvas = try makeCanvas(density: density)
        try draw(on: canvas) { try mouth.draw(on: canvas, offset: offset, reference: reference) }
        return try canvas.output.readPixels()
    }

    /// 1 フレーム描く。描く中で投げた失敗 (断片の組み立てなど) は、描き終えてから投げ直す。
    @MainActor
    private static func draw(on canvas: Canvas, _ body: () throws -> Void) throws {
        var failure: (any Error)?
        try canvas.draw {
            do { try body() } catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// `candidate` を `threshold` で白黒にした形が、`reference` の形から `reach` 画素より
    /// 遠くずれている画素の数と、最初のいくつかの場所。
    ///
    /// `reference` の値がちょうど半分に近い画素は、どちらへ倒れても正しいので数えない。
    static func displaced(
        _ candidate: PixelBuffer, from reference: PixelBuffer, threshold: Float, reach: Int
    ) -> (count: Int, examples: [String]) {
        func white(_ buffer: PixelBuffer, _ x: Int, _ y: Int) -> Bool { buffer[x, y].red > threshold }
        var count = 0
        var examples: [String] = []
        for y in 0..<reference.height {
            for x in 0..<reference.width {
                let value = reference[x, y].red
                guard abs(value - threshold) > 0.05 else { continue }
                let wanted = white(candidate, x, y)
                guard wanted != (value > threshold) else { continue }
                // 近くの `reach` 画素以内に、比べる相手の同じ色があればずれの内
                var near = false
                for dy in -reach...reach {
                    for dx in -reach...reach {
                        let (nx, ny) = (x + dx, y + dy)
                        guard nx >= 0, ny >= 0, nx < reference.width, ny < reference.height else {
                            continue
                        }
                        if white(reference, nx, ny) == wanted { near = true }
                    }
                }
                if !near {
                    count += 1
                    if examples.count < 4 { examples.append("(\(x), \(y))") }
                }
            }
        }
        return (count, examples)
    }

    /// 位置・矩形の口が、細かさによらず出す画素で見て同じ形に出る。
    @Test("位置・矩形の口は、細かさによらず出す画素で見て同じ形に出る", arguments: Outline.allCases)
    func outlineStaysInPlace(_ mouth: Outline) throws {
        var broken: [String] = []
        for offset in mouth.offsets {
            let full = try Self.output(mouth, density: 1, offset: offset)
            // 何も描かれない絵どうしを比べて緑にしない
            let whites = full.components.enumerated().filter { $0.offset % 4 == 0 && $0.element > 0.5 }.count
            try #require(
                whites > 0 && whites < Self.size * Self.size,
                "\(mouth.rawValue): 細かさ 1 の絵が白黒に分かれない (白 \(whites) 画素)")
            for density in Self.densities {
                let candidate =
                    density == 1 ? full : try Self.output(mouth, density: density, offset: offset)
                let reference =
                    mouth.hasReference
                    ? try Self.output(mouth, density: density, offset: offset, reference: true)
                    : full
                // 描く画素の半分を、出す画素へ直したもの (細かさ 1 で 0・0.5 で 1)
                let reach = Int((0.5 / density).rounded(.down))
                for threshold in mouth.thresholds {
                    let (count, examples) = Self.displaced(
                        candidate, from: reference, threshold: threshold, reach: reach)
                    if count > 0 {
                        broken.append(
                            "細かさ \(density)・ずらし \(offset)・濃さ \(threshold): \(count) 画素"
                                + " (\(examples.joined(separator: " ")))")
                    }
                }
            }
        }
        #expect(broken.isEmpty, "\(mouth.rawValue): \(broken.joined(separator: " / "))")
    }
}
