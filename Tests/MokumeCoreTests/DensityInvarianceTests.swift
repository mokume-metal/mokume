// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

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
/// | 細い塗り (三角形の経路・#1934) | ``Amount/shaderFill`` ほか、三角形の経路の塗りの行すべて | 量 |
/// | 線・輪郭・点の太さ (三角形の経路・#1637) | ``Amount/quad`` ほか、三角形の経路の線の行すべて | 量 |
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
///   和が「太さ × 細かさ」の ±10%、点と軸に沿わない塗りは全体の和が「面積 × 細かさの 2 乗」の
///   ±10%。置く位置を
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
        // 回した変換・縦横で倍率の違う変換の点。描く画素の軸に沿った正方形にして、面積で出す
        case rotatedShaderPoint = "rotate(π/4) の shader() の point (三角形の経路)"
        case squashedShaderPoint = "scale(1, 0.1) の shader() の point (三角形の経路)"
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
        // 三角形の経路の細い塗り (#1934)。`fill` の説明が名指す基本図形は、`shader()` /
        // `texture()` で三角形の経路へ落ちても、距離関数の経路 (``thinFill``) と同じく面積に
        // 比例した濃さで出る。太さの代わりに塗りの幅で書く
        case shaderFill = "shader() の細い rect の塗り (三角形の経路)"
        case textureFill = "texture() の細い rect の塗り (三角形の経路)"
        case foldedFill = "shader() の細い rect を畳んだ雛形 (三角形の経路)"
        case rotatedFill = "rotate(π/4) の shader() の細い rect (三角形の経路)"
        case squashedFill = "scale(1, 0.1) の shader() の細い rect (三角形の経路)"
        case retainedFill = "shader() で記録した rect を縮めて置く保持した形 (三角形の経路)"
        case shaderEllipse = "shader() の細長い ellipse の塗り (三角形の経路)"

        /// 線を横切る列の和に、線の太さが何本ぶん入るか。点は 0 (全体の和で見る)。
        ///
        /// 閉じた四角の輪郭は上と下の辺の 2 本、箱は正面と背面の上下の稜線の 4 本が見る列を
        /// 横切る。三角形は上の辺と斜めの辺の 2 本で、斜めの辺は列で測ると太さの 1 / cos 倍になる。
        ///
        /// 縦横で倍率の違う変換の行は、横の辺の太さが縦の倍率ぶん細る。半透明の色 (不透明度 0.5)
        /// で置いた行は、光の量も半分になる。
        var crossings: Double {
            switch self {
            case .point, .shaderPoint, .shaderSquarePoint, .rotatedShaderPoint, .squashedShaderPoint: 0
            case .line, .thinFill, .shaderLine, .shaderFill, .textureFill, .foldedFill, .squashedFill,
                .retainedFill:
                1
            case .triangle: 1 + (1 + Double(60 * 60) / Double(88 * 88)).squareRoot()
            case .box: 4
            case .stretchedQuad: 2 * 0.25
            case .squashedQuad: 2 * 0.1
            case .nestedTranslucent: 2 * 0.5
            default: 2
            }
        }

        /// 塗りで量を出す口か (線の太さの代わりに塗りの幅で書く)。
        var isFill: Bool {
            switch self {
            case .thinFill, .shaderFill, .textureFill, .foldedFill, .rotatedFill, .squashedFill,
                .retainedFill, .shaderEllipse:
                true
            default: false
            }
        }

        /// 面全体の和で見る塗りの、幅 1 のときの面積 (出す画素)。`nil` なら列か点で見る。
        ///
        /// 軸に沿わない帯 (回した `rect`) と、列ごとの幅が形に沿って変わる楕円は、列の和では
        /// 量が決まらないので面全体で見る。**描く画素で幅が 1 以上の行は見ない** — 三角形の経路の
        /// 縁には AA が無く、1 画素以上の塗りは描く画素の格子で丸まる (ADR-0039 決定 3)。
        var fillArea: Double? {
            switch self {
            case .rotatedFill: 60
            case .shaderEllipse: Double.pi / 4 * 88
            default: nil
            }
        }

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
            case .rotatedShaderPoint, .squashedShaderPoint:
                canvas.shader(try Self.plainShader(canvas))
                canvas.translate(64 + offset, 64 + offset)
                if self == .rotatedShaderPoint { canvas.rotate(Float.pi / 4) } else { canvas.scale(1, 0.1) }
                canvas.point(0, 0)
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
            case .shaderFill, .textureFill, .foldedFill, .rotatedFill, .squashedFill, .retainedFill,
                .shaderEllipse:
                try drawFill(on: canvas, weight: weight, offset: offset)
            }
        }

        /// 三角形の経路の細い塗りの行 (#1934)。白で塗り、輪郭は持たない。
        @MainActor
        private func drawFill(on canvas: Canvas, weight: Float, offset: Float) throws {
            let y = 40 + offset
            canvas.noStroke()
            canvas.fill(255)
            if self == .textureFill {
                let sheet = try canvas.createImage(2, 2)
                sheet.fill(.linear(red: 1, green: 1, blue: 1))
                canvas.texture(sheet)
            } else {
                canvas.shader(try Self.plainShader(canvas))
            }
            switch self {
            case .foldedFill:
                // 1 つ目は面の外へ置き、見るのは雛形から置いた 2 つ目である (``foldedRect`` と同じ)
                canvas.rect(20, y - 400, 88, weight)
                canvas.rect(20, y, 88, weight)
            case .rotatedFill:
                canvas.translate(64 + offset, 64 + offset)
                canvas.rotate(Float.pi / 4)
                canvas.rect(-30, -weight / 2, 60, weight)
            case .squashedFill:
                // 縦の倍率 0.1 で、描く画素での幅が `weight × 細かさ` になる
                canvas.translate(20, y)
                canvas.scale(1, 0.1)
                canvas.rect(0, 0, 88, weight * 10)
            case .retainedFill:
                // 幅を倍で記録し、半分に縮めて置く。置いた後の幅が `weight` になる。記録の中で
                // 効いている断片が形に焼き付く (三角形の経路で記録する)
                let shape = canvas.createShape { canvas.rect(0, 0, 176, weight * 2) }
                canvas.resetShader()
                canvas.translate(20, y)
                canvas.scale(0.5, 0.5)
                canvas.shape(shape)
            case .shaderEllipse:
                canvas.ellipse(64, y, 88, weight)
            default:
                canvas.rect(20, y, 88, weight)
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
            // 量子化で、この約束の外 (ADR-0039 決定 3)。縦横で倍率の違う点は、面積の倍率で縮む
            let areaFactor: Double = mouth == .squashedShaderPoint ? 0.1 : 1
            if mouth.crossings == 0, Double(weight * density) * areaFactor.squareRoot() >= 1 {
                continue
            }
            // 面全体で見る塗りも、描く画素で幅が 1 より細いときだけ見る (``Amount/fillArea``)
            if mouth.fillArea != nil, weight * density >= 1 { continue }
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
                let (measured, expected): (Double, Double)
                if let area = mouth.fillArea {
                    (measured, expected) = (Self.totalSum(pixels), area * drawn * Double(density))
                } else if mouth.crossings == 0 {
                    (measured, expected) = (Self.totalSum(pixels), drawn * drawn * areaFactor)
                } else {
                    (measured, expected) = (Self.columnSum(pixels, density: density), drawn * mouth.crossings)
                }
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

    /// **1 画素より小さい円は、`shader()` で三角形の経路へ落ちても、置く位置によらず外接する
    /// 正方形の面積ぶんで出る** (#1934 完了条件 2)。置き方は距離関数の経路の同じ約束
    /// (`FormShapeTests.subpixelCirclesKeepTheirBoundingSquare`・#1477 の判断 1 A) と同じで、
    /// 同じ位置の `shader()` 無しの円とも ±10% で揃う。
    ///
    /// 直す前は、半径 0.25 以下の円が三角形 1 枚の多角形になり、画素の中心を含めば満濃度の
    /// 1 画素、含まなければ何も出なかった。
    @Test(
        "1 画素より小さい shader() の円は、置く位置によらず外接する正方形の面積ぶんで出る (#1934)",
        arguments: [Float(0.2), 0.5])
    func subpixelShaderCirclesKeepTheirBoundingSquare(_ diameter: Float) throws {
        let centers: [(Float, Float)] = [(20, 20), (20.25, 20), (20.5, 20.5), (20.3, 20.7)]
        let expected = Double(diameter * diameter)
        func light(at x: Float, _ y: Float, shaded: Bool) throws -> Double {
            let canvas = try Self.makeCanvas(density: 1)
            try Self.draw(on: canvas) {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                if shaded {
                    canvas.shader(
                        try canvas.makeShader(
                            "float4 paint(Fragment in, Values values) { return in.color; }"))
                }
                canvas.circle(x, y, diameter)
            }
            return Self.totalSum(try canvas.target.readPixels())
        }
        var broken: [String] = []
        for (x, y) in centers {
            let shaded = try light(at: x, y, shaded: true)
            let plain = try light(at: x, y, shaded: false)
            if abs(shaded - expected) > 0.1 * expected {
                broken.append("中心 (\(x), \(y)): \(shaded) (期待 \(expected))")
            }
            if abs(shaded - plain) > 0.1 * plain {
                broken.append("中心 (\(x), \(y)): shader() 無しの円の和 \(plain) と食い違う (\(shaded))")
            }
        }
        #expect(broken.isEmpty, "直径 \(diameter) の shader() の円: \(broken.joined(separator: " / "))")
    }

    /// **長い向きが数画素しかない細い塗りも、置く位置によらず距離関数の経路と同じ量で出る**
    /// (#1934 の反証 2)。細い向きを広げるだけでは、長い向きの端が列 (行) の中心を跨ぐかどうかで
    /// 量が振れる — 細かさ 1 の `shader()` の `rect(x, …, 1.5, 0.5)` は、x が 10.4 なら 2 列ぶん
    /// (1.0)、10.6 なら 1 列ぶん (0.5) で出ていた。距離関数の経路は長い向きも箱フィルタで数える
    /// ので、置く位置にほぼ依らない。
    ///
    /// 長さ 1〜10 を、長い向きに 5 通りずらして置き、横長と縦長の両方で見る。`rect` は面積とも
    /// 比べ (回したものも)、楕円は同じ位置の `shader()` 無しの楕円と比べる (距離関数の経路も画素の
    /// 中のいちばん太い弦を取るので、短い楕円は面積より多めに出る)。
    @Test(
        "長い向きが短い細い shader() の塗りも、置く位置によらず距離関数の経路と同じ量で出る (#1934)",
        arguments: [false, true])
    func shortThinFillsKeepTheirLight(_ isEllipse: Bool) throws {
        let lengths: [Float] = [1, 1.5, 2, 3, 4.5, 7, 9.5, 10]
        let shifts: [Float] = [0, 0.25, 0.4, 0.6, 0.75]
        let thin: Float = isEllipse ? 0.4 : 0.5
        enum Pose: CaseIterable { case wide, tall, tilted }
        func light(_ pose: Pose, length: Float, shift: Float, shaded: Bool) throws -> Double {
            let canvas = try Self.makeCanvas(density: 1)
            try Self.draw(on: canvas) {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                if shaded {
                    canvas.shader(
                        try canvas.makeShader(
                            "float4 paint(Fragment in, Values values) { return in.color; }"))
                }
                // 長い向きの位置だけをずらす。細い向きは画素の中ほどに置く
                let along = 40 + shift
                switch (pose, isEllipse) {
                case (.wide, false): canvas.rect(along, 30.25, length, thin)
                case (.tall, false): canvas.rect(30.25, along, thin, length)
                case (.wide, true): canvas.ellipse(along, 30.5, length, thin)
                case (.tall, true): canvas.ellipse(30.5, along, thin, length)
                case (.tilted, _):
                    canvas.translate(along, 64 + shift)
                    canvas.rotate(0.3)
                    if isEllipse {
                        canvas.ellipse(0, 0, length, thin)
                    } else {
                        canvas.rect(-length / 2, -thin / 2, length, thin)
                    }
                }
            }
            return Self.totalSum(try canvas.target.readPixels())
        }
        var broken: [String] = []
        for pose in Pose.allCases {
            // 回した楕円は距離関数の経路も近似なので、回した形は rect だけを面積と比べる
            if pose == .tilted, isEllipse { continue }
            for length in lengths {
                for shift in shifts {
                    let shaded = try light(pose, length: length, shift: shift, shaded: true)
                    let label = "\(pose)・長さ \(length)・ずらし \(shift)"
                    if isEllipse || pose != .tilted {
                        let plain = try light(pose, length: length, shift: shift, shaded: false)
                        if abs(shaded - plain) > 0.1 * plain {
                            broken.append("\(label): \(shaded) (shader() 無し \(plain))")
                        }
                    }
                    if !isEllipse {
                        let area = Double(length * thin)
                        if abs(shaded - area) > 0.1 * area {
                            broken.append("\(label): \(shaded) (面積 \(area))")
                        }
                    }
                }
            }
        }
        #expect(
            broken.isEmpty,
            "\(isEllipse ? "楕円" : "rect"): \(broken.count) 件 — \(broken.prefix(8).joined(separator: " / "))")
    }

    /// **長い向きが 10 画素以上の細い塗りは、置く位置による揺れが 12% に収まる** (#1934 の 2 回目の
    /// 反証 2)。長い形は端の列 (楕円は中心の片) の数が置く位置で 1 つ振れるので、揺れは rect で
    /// 1 / 長さ、楕円で 4 / (π 長さ) ほど残る (長さ 10 で 10%・12.7% が上限)。`fill(_:)` の説明が
    /// 言う「1 割ほど」を、長さ 10 の少し上で縛る。
    @Test(
        "長い向きが 10 画素以上の細い shader() の塗りは、置く位置による揺れが 12% に収まる (#1934)",
        arguments: [false, true])
    func longThinFillsStayWithinTheirBound(_ isEllipse: Bool) throws {
        let lengths: [Float] = [10.01, 10.5, 11]
        let shifts: [Float] = [0, 0.1, 0.25, 0.4, 0.5, 0.75]
        let thin: Float = 0.5
        func light(tall: Bool, length: Float, shift: Float, shaded: Bool) throws -> Double {
            let canvas = try Self.makeCanvas(density: 1)
            try Self.draw(on: canvas) {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                if shaded {
                    canvas.shader(
                        try canvas.makeShader(
                            "float4 paint(Fragment in, Values values) { return in.color; }"))
                }
                let along = 40 + shift
                switch (tall, isEllipse) {
                case (false, false): canvas.rect(along, 30.25, length, thin)
                case (true, false): canvas.rect(30.25, along, thin, length)
                case (false, true): canvas.ellipse(along, 30.5, length, thin)
                case (true, true): canvas.ellipse(30.5, along, thin, length)
                }
            }
            return Self.totalSum(try canvas.target.readPixels())
        }
        var broken: [String] = []
        var worst = 0.0
        for tall in [false, true] {
            for length in lengths {
                for shift in shifts {
                    let shaded = try light(tall: tall, length: length, shift: shift, shaded: true)
                    // rect は面積と、楕円は同じ位置の距離関数の経路と比べる
                    let reference =
                        isEllipse
                        ? try light(tall: tall, length: length, shift: shift, shaded: false)
                        : Double(length * thin)
                    let deviation = abs(shaded - reference) / reference
                    worst = max(worst, deviation)
                    if deviation > 0.12 {
                        broken.append("\(tall ? "縦" : "横")・長さ \(length)・ずらし \(shift): \(shaded) (比べる相手 \(reference))")
                    }
                }
            }
        }
        #expect(
            broken.isEmpty,
            "\(isEllipse ? "楕円" : "rect") (最大のずれ \(worst)): \(broken.prefix(8).joined(separator: " / "))")
    }

    /// **どの向きも描く画素で細いが形としては長い `rect` と、剪断で弦が辺の隔たりに縛られる `rect` は
    /// 補わず、三角形のまま描く** (#1934 の 2 回目の反証 1)。回した後に縦横で倍率の違う拡大や剪断を
    /// 掛けると、2 組の辺の隔たりがどちらも 1 を割ったまま形は長くなる。そこへ「小さい形」や「帯」の
    /// 手当てを当てると形が壊れる — `scale(1, 0.05)` の下で 45° 回した 4×4 の `rect` (幅 5.66 の細い
    /// 菱形) が描く画素 1 つの正方形に潰れ、10×10 は幅 14.1 が 8 列に縮み、`scale(1, 0.02)` の
    /// 20×20 と `shearX(atan(20))` の 10×0.9 は弦が辺の隔たりに縛られて暗くなり、横へ伸びていた。
    /// 補いの手当てが正しいと言えない形は、補わない側へ倒す (直す前より悪くはしない)。
    ///
    /// 補わないことは、同じ 4 隅の `quad` (名指しの基本図形ではないので補わない・同じ割り方) と画素が
    /// 一致することで見る。あわせて、小さい形 (回した 0.8×0.8) はこれまでどおり面積で出ることを見る。
    @Test("どの向きも細い長い rect と剪断で弦が縛られる rect は補わず、三角形のまま描く (#1934)")
    func longRectsThinBothWaysAreNotCollapsed() throws {
        typealias Case = (label: String, place: (Canvas) -> Void, size: SIMD2<Float>)
        let cases: [Case] = [
            ("scale(1, 0.05)・rotate(π/4)・4×4", { $0.scale(1, 0.05); $0.rotate(Float.pi / 4) }, SIMD2(4, 4)),
            ("scale(1, 0.05)・rotate(π/4)・10×10", { $0.scale(1, 0.05); $0.rotate(Float.pi / 4) }, SIMD2(10, 10)),
            ("scale(1, 0.02)・rotate(π/4)・20×20", { $0.scale(1, 0.02); $0.rotate(Float.pi / 4) }, SIMD2(20, 20)),
            ("shearX(atan(20))・10×0.9", { $0.shearX(atan(Float(20))) }, SIMD2(10, 0.9)),
        ]
        func render(_ shape: Case, shift: Float, asQuad: Bool) throws -> PixelBuffer {
            let canvas = try Self.makeCanvas(density: 1)
            try Self.draw(on: canvas) {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                canvas.shader(
                    try canvas.makeShader(
                        "float4 paint(Fragment in, Values values) { return in.color; }"))
                canvas.translate(30 + shift, 60 + shift * 0.7)
                shape.place(canvas)
                let (w, h) = (shape.size.x, shape.size.y)
                if asQuad {
                    canvas.quad(0, 0, w, 0, w, h, 0, h)
                } else {
                    canvas.rect(0, 0, w, h)
                }
            }
            return try canvas.target.readPixels()
        }
        var broken: [String] = []
        for shape in cases {
            for shift: Float in [0, 0.3, 0.5] {
                let rect = try render(shape, shift: shift, asQuad: false)
                let quad = try render(shape, shift: shift, asQuad: true)
                var differing = 0
                for y in 0..<rect.height {
                    for x in 0..<rect.width where rect[x, y].red != quad[x, y].red { differing += 1 }
                }
                if differing > 0 { broken.append("\(shape.label)・ずらし \(shift): \(differing) 画素") }
            }
        }
        #expect(broken.isEmpty, "補ってしまった: \(broken.joined(separator: " / "))")
        // 小さい形は補い続ける: 回した 0.8×0.8 の正方形は面積 0.64 の光で出る
        var small: [String] = []
        for shift: Float in [0, 0.25, 0.3, 0.5] {
            let canvas = try Self.makeCanvas(density: 1)
            try Self.draw(on: canvas) {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                canvas.shader(
                    try canvas.makeShader(
                        "float4 paint(Fragment in, Values values) { return in.color; }"))
                canvas.translate(30 + shift, 30 + shift * 0.7)
                canvas.rotate(Float.pi / 4)
                canvas.rect(-0.4, -0.4, 0.8, 0.8)
            }
            let light = Self.totalSum(try canvas.target.readPixels())
            if abs(light - 0.64) > 0.064 { small.append("ずらし \(shift): \(light)") }
        }
        #expect(small.isEmpty, "回した小さい正方形 (期待 0.64): \(small.joined(separator: " / "))")
    }

    /// **寸法や置き方が極端な細い塗りでも落ちない** (#1934 の反証 1)。細長い楕円の片の数を
    /// 整数へ直す前に有限か確かめ、上限で切る。直径が数でない・無限の楕円は補わず、これまでどおり
    /// 周から三角形に割る (距離関数の経路も有限でない半径は置かずに断る)。直す前は、直径 1e20 の
    /// 楕円で片の数を `Int` へ直すところで実行時に落ちていた。
    @Test("寸法や置き方が極端な細い shader() の楕円でも落ちない (#1934)")
    func extremeThinEllipsesDoNotTrap() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let plain = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return in.color; }")
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(plain)
            canvas.ellipse(0, 0, 1e20, 0.5)
            canvas.ellipse(0, 0, Float.infinity, 0.5)
            // 同じ形を続けて置くと、2 つ目で雛形を組む (雛形の口も通す)
            canvas.ellipse(0, 0, 1e20, 0.5)
            canvas.ellipse(0, 0, 1e20, 0.5)
            // 保持した形を、極端な拡大で置く
            let shape = canvas.createShape { canvas.ellipse(0, 0, 40, 0.5) }
            canvas.pushMatrix()
            canvas.scale(1e19, 1)
            canvas.shape(shape)
            canvas.popMatrix()
        }
        // 落ちずに描き終え、面が読める
        let pixels = try canvas.target.readPixels()
        #expect(pixels.width == canvas.pixelWidth)
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
                // 置き場所ごとに回しても、大きさが同じなら同じ雛形に畳む
                for index in 0..<4 {
                    canvas.pushMatrix()
                    canvas.translate(16 + Float(index) * 20, 16)
                    canvas.rotate(Float(index) * 0.3)
                    canvas.rect(-6, -6, 12, 12)
                    canvas.popMatrix()
                }
                // 1 つ目は畳む相手を待って置き、2 つ目から雛形を開いて置き場所を足す
                #expect(canvas.openFlat != nil, "細い輪郭の rect が畳まれない")
                #expect(canvas.flatInstances.count == 5, "畳んだ置き場所の数: \(canvas.flatInstances.count)")
                canvas.resetShader()
                if frame == 0 { shape = canvas.createShape { canvas.quad(0, 0, 40, 0, 40, 20, 0, 20) } }
                // 回して置いても、組み直すのは大きさごとに 1 度
                for index in 0..<3 {
                    canvas.pushMatrix()
                    canvas.translate(10 + Float(index) * 30, 80)
                    canvas.rotate(Float(index + frame * 3) * 0.4)
                    canvas.scale(0.5, 0.5)
                    canvas.shape(shape)
                    canvas.popMatrix()
                }
            }
        }
        #expect(canvas.thinStrokesRebuilt == 1, "組み直した回数: \(canvas.thinStrokesRebuilt)")
    }

    /// **細い塗りを補っても、同じ 2x2 の置き場所どうしは畳み、保持した形は同じ大きさ・向きで
    /// 置き続けるかぎり 1 度しか組み直さない** (#1934)。細かさ 0.5 では高さ 1 の `rect` がいつも細い
    /// 側に入るので、補いが速い経路を外すと、`texture()` の小さな `rect` を並べる絵がかえって遅くなる。
    ///
    /// 細い塗りの広げ方は帯の向きで決まるので、線 (`thinStrokesKeepTheFastRoutes`) と違って、回転
    /// だけが違う置き場所は同じ雛形に畳まない。ここで見るのは平行移動だけが違う置き場所である。
    @Test("細かさ 0.5 の細い塗りも、畳み・組み直しの控えの速い経路を通る (#1934)")
    func thinFillsKeepTheFastRoutes() throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        let plain = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return in.color; }")
        var shape = Shape.empty
        for frame in 0..<2 {
            try canvas.draw {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                canvas.shader(plain)
                for index in 0..<4 { canvas.rect(16 + Float(index) * 20, 16, 12, 1) }
                // 1 つ目は畳む相手を待って置き、2 つ目から雛形を開いて置き場所を足す
                #expect(canvas.openFlat != nil, "細い塗りの rect が畳まれない")
                #expect(canvas.flatInstances.count == 5, "畳んだ置き場所の数: \(canvas.flatInstances.count)")
                if frame == 0 { shape = canvas.createShape { canvas.rect(0, 0, 40, 1) } }
                canvas.resetShader()
                for index in 0..<3 { canvas.shape(shape, 10 + Float(index) * 30, 80) }
            }
        }
        #expect(shape.thinCache.fillsThinned == 1, "組み直した回数: \(shape.thinCache.fillsThinned)")
    }

    /// **記録のときに周を落とした矩形の素材も、貼る絵の読み取り位置を矩形の箱から作る** (#1934 の
    /// 反証 7)。矩形の素材は細さを測る形だけを持ち、周の点を持たない。周の点から箱を作ると箱が
    /// 空になり、広げた片の読み取り位置がどれも 0 (絵の角の 1 画素) になる。
    @Test("周を落とした矩形の素材も、貼る絵の読み取り位置を矩形の箱から作る (#1934)")
    func slimRectRecipesKeepTheirPictureBox() throws {
        let named = Canvas.Outline.NamedFill(
            isEllipse: false, center: SIMD2(10, 20), half: SIMD2(8, 0.25))
        let recipe = RingFillRecipe(
            outline: Canvas.Outline(points: [], isClosed: true, namedFill: named),
            color: LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1), hasPicture: true,
            transform: .identity, uv: SIMD2(0, 0))
        let pieces = try #require(Canvas.thinFillPieces(named, by: matrix_identity_float2x2))
        let built = Canvas.thinFillVertices(pieces, recipe: recipe)
        let across = built.vertices.map(\.uv.x)
        let along = built.vertices.map(\.uv.y)
        #expect(across.min() == 0 && across.max() == 1, "横の読み取り位置: \(across)")
        #expect(along.min() == 0 && along.max() == 1, "縦の読み取り位置: \(along)")
    }

    /// **保持した形の細い塗りの控えは、頂点の総量の上限を越えず、古いものから捨てる** (#1934 の
    /// 反証 5)。鍵は描く画素へ写す 2x2 そのものなので、回して置き続ける形は塗りの数 × 置いた向きの
    /// 数だけ鍵が増え、細長い楕円は 1 件が数百頂点になる。件数では切れないので、刻み直した頂点の
    /// 控え (`rescaledCacheStaysWithinItsBudget`) と同じく頂点の総量で切る。
    @Test("保持した形の細い塗りの控えは、頂点の総量の上限を越えず、古いものから捨てる (#1934)")
    func thinFillCacheStaysWithinItsBudget() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let plain = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return in.color; }")
        var retained: Shape?
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(plain)
            // 長さ 40・高さ 0.5 の楕円は、片 40 個 (240 頂点) で組む
            retained = canvas.createShape {
                for index in 0..<4 { canvas.ellipse(Float(index) * 30, 0, 40, 0.5) }
            }
            canvas.resetShader()
        }
        let shape = try #require(retained)
        let budget = 2_000
        shape.thinCache.thinFillBudget = budget
        var largest = 0
        func place(angle: Float) throws {
            try canvas.draw {
                canvas.background(0)
                canvas.translate(64, 64)
                canvas.rotate(angle)
                canvas.shape(shape)
            }
            largest = max(largest, shape.thinCache.thinFillVertexTotal)
        }
        // 置くたびに向きを変える (回る形)。どの回でも、控えている頂点の数は予算に収まる
        let angles = (0..<30).map { Float($0) * 0.05 }
        for angle in angles { try place(angle: angle) }
        #expect(largest <= budget, "控えた頂点は最大 \(largest) 個 (予算 \(budget))")
        #expect(shape.thinCache.thinFillVertexTotal > 0)
        // 古いものは捨てられている — 最初の向きへ戻ると、組み直す
        let before = shape.thinCache.fillsThinned
        try place(angle: angles[0])
        #expect(shape.thinCache.fillsThinned > before, "古い控えが残っている")
        // 予算を広げれば、同じ向きへ戻っても組み直さない
        shape.thinCache.thinFillBudget = ThinStrokeCache.defaultScaledBudget
        try place(angle: angles[0])
        let settled = shape.thinCache.fillsThinned
        try place(angle: angles[0])
        #expect(shape.thinCache.fillsThinned == settled)
    }

    /// **細い線の端は、線に沿っては元の太さの半分だけ出る** (#1637)。
    ///
    /// 帯を描く画素 1 つへ広げても、端は広げない向き (線に沿う向き) に元の太さで出す。端まで
    /// 広げた幅で丸めると、端の光が元の 1 / 太さ 倍になる (細かさ 0.5 の太さ 1 で約 2 倍)。
    /// 短い横線を置く位置を描く画素の 1/16 ずつ 16 通りにずらし、描いた画素の和の平均を、描く
    /// 画素での元の面積 (帯 + 両端) と比べる。三角形の経路は縁に AA が無いので 1 回ごとの和は
    /// 画素の中心を拾う数で揺れるが、ずらして平均すると面積に近づく。
    @Test(
        "細い線の端は、置く位置を均すと描く画素での元の面積ぶんの光で出る (#1637)",
        arguments: [StrokeCap.round, .project], [(Float(0.5), Float(1)), (Float(1), Float(0.5))])
    func thinCapsKeepTheirArea(_ cap: StrokeCap, _ case: (density: Float, weight: Float)) throws {
        let (density, weight) = `case`
        let length: Float = 2
        var total = 0.0
        let steps = 16
        for step in 0..<steps {
            let shift = Float(step) / Float(steps) / density
            let canvas = try Self.makeCanvas(density: density)
            let plain = try canvas.makeShader(
                "float4 paint(Fragment in, Values values) { return in.color; }")
            try canvas.draw {
                canvas.background(0)
                canvas.stroke(255)
                canvas.strokeWeight(weight)
                canvas.strokeCap(cap)
                canvas.shader(plain)
                canvas.line(40 + shift, 40 + shift * 0.6, 40 + length + shift, 40 + shift * 0.6)
            }
            total += Self.totalSum(try canvas.target.readPixels())
        }
        let average = total / Double(steps)
        let drawn = Double(weight * density)
        let ends = cap == .round ? Double.pi * drawn * drawn / 4 : drawn * drawn
        let expected = drawn * Double(length * density) + ends
        #expect(
            abs(average - expected) <= 0.1 * expected,
            "細かさ \(density)・太さ \(weight)・\(cap) の短い線の光の平均: \(average) (期待 \(expected))")
    }

    /// **縦と横で倍率の違う変換で、細い辺に合わせた端と角が描く画素ではみ出さない** (#1637)。
    ///
    /// `scale(4, 0.25)` の `quad` の角は、縦の辺 (描く画素で太い) の外の縁より外へ出ない。
    /// `scale(1, 0.1)` の横の `line` の丸い端は、線の端から元の太さの半分より先へ出ない。
    /// 端と角の大きさを形自身の座標で等方的に決めていた頃は、角が横へ 8 画素、端が約 4.5 画素
    /// はみ出した。
    @Test("縦横で倍率の違う変換の細い線の端と角は、描く画素ではみ出さない (#1637)")
    func stretchedCapsAndJoinsStayInside() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let plain = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return in.color; }")
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(1)
            canvas.shader(plain)
            canvas.pushMatrix()
            canvas.translate(30, 20)
            canvas.scale(4, 0.25)
            canvas.quad(0, 0, 16, 0, 16, 120, 0, 120)
            canvas.popMatrix()
            canvas.pushMatrix()
            canvas.translate(30, 100)
            canvas.scale(1, 0.1)
            canvas.line(0, 0, 60, 0)
            canvas.popMatrix()
        }
        let pixels = try canvas.target.readPixels()
        func lit(_ columns: Range<Int>, _ rows: Range<Int>) -> Double {
            var sum = 0.0
            for y in rows { for x in columns { sum += Double(pixels[x, y].red) } }
            return sum
        }
        // quad: 左の縦の辺は描く画素で x = 30 ± 2 (+0.5 の寄せ)。その外 (x < 28) に光は無い
        #expect(lit(18..<28, 10..<60) == 0, "quad の角が縦の辺の外へはみ出した: \(lit(18..<28, 10..<60))")
        // line: 端は x = 30 と 90 (+0.5)。丸い端は元の太さの半分 (0.5) まで。その先 (x ≥ 92・x < 29) に光は無い
        #expect(lit(92..<100, 95..<106) == 0, "線の右の端がはみ出した: \(lit(92..<100, 95..<106))")
        #expect(lit(20..<29, 95..<106) == 0, "線の左の端がはみ出した: \(lit(20..<29, 95..<106))")
    }

    /// **置き換える混ぜ方でも、細い輪郭の帯の下の塗りは残る** (#1637)。
    ///
    /// 広げた帯は覆う割合 (被覆) だけを置き換え、残りは下地を残す (`S·c + D·(1 − c)`)。塗りの上に
    /// 置いた輪郭では、帯の下の塗りが見える — 距離関数の経路の置き換え (`S·s + F·(f − o)`・
    /// #1867 決定 1) と同じ向きである。被覆をそのまま置き換えていた頃は、帯の画素が `S·c` に
    /// 置き換わって塗りが消え、不透明度 `c` の穴になった。
    @Test("置き換える混ぜ方の細い輪郭は、帯の下の塗りを消さない (#1637)", arguments: [false, true])
    func replacingThinOutlinesKeepTheFillUnderneath(_ solid: Bool) throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        let plain = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return in.color; }")
        try canvas.draw {
            canvas.background(0)
            canvas.blendMode(.replace)
            canvas.fill(255)
            canvas.stroke(0)
            canvas.strokeWeight(1)
            canvas.shader(plain)
            if solid {
                canvas.beginShape()
                canvas.vertex(20, 20, 0)
                canvas.vertex(100, 20, 0)
                canvas.vertex(100, 100, 0)
                canvas.vertex(20, 100, 0)
                canvas.endShape(.close)
            } else {
                canvas.rect(20, 20, 80, 80)
            }
        }
        let pixels = try canvas.target.readPixels()
        // 不透明な塗りと不透明な輪郭なので、置いた所はどこも不透明のまま
        var holes = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].alpha < 0.99 { holes += 1 }
        }
        #expect(holes == 0, "\(solid ? "立体" : "平面")の置き換える輪郭が開けた穴: \(holes) 画素")
        // 上の辺の帯の行 (描く画素で y = 10) の真ん中は、塗りが半分透けて見える (帯の被覆 0.5)
        let band = pixels[30, 10].red
        #expect(band > 0.25, "帯の下の塗りが消えた: \(band)")
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
