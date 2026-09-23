// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 太い線で引いた曲線の、刻みの継ぎ目の埋め方 ([#1409])。GPU を要する。
///
/// 曲線は刻みの数だけの折れ線で引かれ、刻みどうしの継ぎ目にも帯の隙間が空く。
/// **継ぎ目は角ではない**ので、折れ目の形 (``StrokeJoin``) ではなく円板で埋める —
/// 線は刻みの折れ線から太さの半分の内側をちょうど塗る。かつては角と同じく軸に沿った
/// 正方形で埋めていたため、線が斜めに走る区間で正方形の角が帯の外へ出て、縁が
/// 鋸の歯のように太っていた。
///
/// 期待値は保存した画像ではなく次の 2 つから導く ([ADR-0019] 決定 4):
///
/// - **「同じ絵になるはず」の約束は、2 経路で描いてバイトで比べる** (弦の上の曲線と直線・
///   曲線の終点の角と `vertex` の角)
/// - **線の広がりは、CPU で式から出した刻みの折れ線との距離で見る。** 刻みの点は
///   Bernstein 多項式で求める。実装 (``Canvas/cubicPoint(_:_:_:_:_:)``) の写しではない
///
/// ## 画素と距離の対応
///
/// 線の頂点は画面で半画素寄せられる ([ADR-0039] 決定 2) ので、画素 (x, y) の中心は
/// 形の座標の (x, y) に当たる。三角形の経路は縁の AA を持たない ([ADR-0039] 決定 3) —
/// 画素は、その点が帯か円板の内側にあれば線の色になり、外なら下地のまま残る。だから
/// 「塗られた画素の点」と「折れ線からの距離」をそのまま突き合わせられる。
///
/// [#1409]: https://github.com/mokume-metal/mokume/issues/1409
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
/// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
@Suite(
    "曲線の刻みの継ぎ目",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CurveJoinTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 1 枚の面に描いて、表示の形で読む。**比べる 2 経路は毎回新しい面に描く。**
    private func render(width: Int = 64, height: Int = 64, _ body: (Canvas) -> Void) throws
        -> DisplayImage
    {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            body(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    private func isInked(_ image: DisplayImage, _ x: Int, _ y: Int) -> Bool {
        image[x, y] != (0, 0, 0, 255)
    }

    /// 背景 (黒) でない画素の数。**比べる前に、比べる絵に何か出ていることを確かめる。**
    private func inkedPixels(_ image: DisplayImage) -> Int {
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where isInked(image, x, y) { count += 1 }
        }
        return count
    }

    private func differingPixels(_ a: DisplayImage, _ b: DisplayImage) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in 0..<a.width where a[x, y] != b[x, y] { count += 1 }
        }
        return count
    }

    // MARK: - 式 (CPU)

    /// 3 次のベジェの点。**Bernstein 多項式** B(t) = Σ C(3, i) (1 − t)^(3 − i) t^i P_i で求める。
    private static func bezierPoint(_ points: [SIMD2<Double>], _ t: Double) -> SIMD2<Double> {
        let binomial: [Double] = [1, 3, 3, 1]
        var point = SIMD2<Double>(0, 0)
        for (i, control) in points.enumerated() {
            point += control * (binomial[i] * pow(1 - t, Double(3 - i)) * pow(t, Double(i)))
        }
        return point
    }

    /// 曲線を引く折れ線 (刻みの点を始点から順に)。刻みは既定の 20。
    private static func steps(of points: [SIMD2<Double>], detail: Int = 20) -> [SIMD2<Double>] {
        (0...detail).map { bezierPoint(points, Double($0) / Double(detail)) }
    }

    /// 点から折れ線までの距離。
    private static func distance(from point: SIMD2<Double>, to polyline: [SIMD2<Double>])
        -> Double
    {
        zip(polyline, polyline.dropFirst()).map { a, b in
            let along = b - a
            let length = (along * along).sum()
            let s = length > 0 ? min(1, max(0, ((point - a) * along).sum() / length)) : 0
            let offset = point - (a + along * s)
            return (offset * offset).sum().squareRoot()
        }.min() ?? .infinity
    }

    // MARK: - 弦の上の曲線

    /// 完了条件 1。制御点は弦を 3 等分する点なので、曲線は弦そのものになる。
    ///
    /// **45° に走らせる。** 刻みの継ぎ目に軸に沿った正方形を置くと、正方形の角が帯の外へ
    /// 最大 (√2 − 1) × 太さ / 2 はみ出すのは、線が斜めのときである (軸に沿った線では
    /// 正方形が帯の中に収まり、違いが絵に出ない)。
    @Test("制御点を弦の上に置いた曲線は、同じ端点を vertex で結んだ直線と同じ絵になる")
    func chordCurveMatchesTheStraightLine() throws {
        let curved = try render { canvas in
            canvas.strokeWeight(10)
            canvas.beginShape()
            canvas.vertex(8, 8)
            canvas.bezierVertex(24, 24, 40, 40, 56, 56)
            canvas.endShape()
        }
        let straight = try render { canvas in
            canvas.strokeWeight(10)
            canvas.beginShape()
            canvas.vertex(8, 8)
            canvas.vertex(56, 56)
            canvas.endShape()
        }
        #expect(inkedPixels(straight) > 0)
        #expect(differingPixels(curved, straight) == 0)
    }

    /// 奥行きを持つ形は立体の経路で線を引く (``Canvas/strokeSolidRing(_:shapePoints:isClosed:)``)。
    /// 端と折れ目の規則は平面と同じ骨を通るので、同じ約束が立つ。
    @Test("奥行きを持つ曲線も、制御点が弦の上なら直線と同じ絵になる")
    func chordCurveWithDepthMatchesTheStraightLine() throws {
        let curved = try render { canvas in
            canvas.strokeWeight(10)
            canvas.beginShape()
            canvas.vertex(8, 8, 0)
            canvas.bezierVertex(24, 24, 40, 40, 56, 56)
            canvas.endShape()
        }
        let straight = try render { canvas in
            canvas.strokeWeight(10)
            canvas.beginShape()
            canvas.vertex(8, 8, 0)
            canvas.vertex(56, 56, 0)
            canvas.endShape()
        }
        #expect(inkedPixels(straight) > 0)
        #expect(differingPixels(curved, straight) == 0)
    }

    // MARK: - 置いた点は角のまま

    /// 曲線の**終点**は利用者が置いた点なので、そこで折れれば角である。折れ目の形は
    /// そこには効き続ける — `vertex` だけで置いた同じ折れ線と同じ絵になる。
    ///
    /// **辺を軸に沿わせ、太さを奇数 (9) にする。** 帯の縁が画素の境目に乗り、どの画素の
    /// 中心も縁の上に来ないので、経路の違う 2 つの絵が縁の判定で割れない。
    @Test("曲線の終点で折れる角は、vertex で置いた同じ角と同じ絵になる", arguments: [
        StrokeJoin.miter, .bevel, .round,
    ])
    func cornerAtTheEndOfACurveKeepsTheJoin(_ join: StrokeJoin) throws {
        func style(_ canvas: Canvas) {
            canvas.strokeWeight(9)
            canvas.strokeJoin(join)
        }
        let curved = try render { canvas in
            style(canvas)
            canvas.beginShape()
            canvas.vertex(10, 14)
            canvas.bezierVertex(24, 14, 38, 14, 52, 14)  // 弦の上。終点 (52, 14) で直角に折れる
            canvas.vertex(52, 50)
            canvas.endShape()
        }
        let straight = try render { canvas in
            style(canvas)
            canvas.beginShape()
            canvas.vertex(10, 14)
            canvas.vertex(52, 14)
            canvas.vertex(52, 50)
            canvas.endShape()
        }
        #expect(inkedPixels(straight) > 0)
        #expect(differingPixels(curved, straight) == 0)
    }

    // MARK: - 急に曲がる曲線

    /// 先端で刻み 1 つぶん 107° 折れ返る曲線。脚は斜めに走る。
    private static let hairpin: [SIMD2<Double>] = [
        SIMD2(10, 54), SIMD2(58, 4), SIMD2(6, 4), SIMD2(54, 54),
    ]

    private func renderHairpin() throws -> DisplayImage {
        let points = Self.hairpin
        return try render { canvas in
            canvas.strokeWeight(12)
            canvas.beginShape()
            canvas.vertex(points[0].x, points[0].y)
            canvas.bezierVertex(
                points[1].x, points[1].y, points[2].x, points[2].y, points[3].x, points[3].y)
            canvas.endShape()
        }
    }

    /// **急に曲がる継ぎ目では、帯と帯の間に本当に楔形の隙間が空く** (先端の刻みで 107°)。
    /// 継ぎ目を何も埋めなければ、刻みの折れ線から太さの半分の内側に塗られない画素が出る。
    ///
    /// 内側の余白 0.5 画素は円板の近似の分である。円板は半径に応じた多角形で、真円との
    /// 隔たりは 0.25 画素以下に収めてある (``Canvas/segmentCount(forRadius:)``)。
    @Test("太い線で引いた急な曲線は、刻みの折れ線から太さの半分の内側を隙間なく塗る")
    func sharpCurveLeavesNoGap() throws {
        let image = try renderHairpin()
        let polyline = Self.steps(of: Self.hairpin)
        let half = 6.0
        var missing: [(Int, Int)] = []
        for y in 0..<image.height {
            for x in 0..<image.width where !isInked(image, x, y) {
                if Self.distance(from: SIMD2(Double(x), Double(y)), to: polyline) <= half - 0.5 {
                    missing.append((x, y))
                }
            }
        }
        #expect(missing.isEmpty, "\(missing.count) 画素が塗られていない (最初は \(missing.first.map { "\($0)" } ?? ""))")
    }

    /// 線は刻みの折れ線から太さの半分より外を塗らない。**刻みの継ぎ目に正方形を置くと、
    /// 斜めに走る脚で正方形の角が帯の外へ出る** (#1409 の鋸の歯)。
    ///
    /// 外側の余白 0.01 画素は、帯の縁が画素の中心をちょうど通るときの判定の揺れの分である。
    @Test("太い線で引いた曲線は、刻みの折れ線から太さの半分より外へはみ出さない")
    func curveStaysWithinHalfTheWeight() throws {
        let image = try renderHairpin()
        let polyline = Self.steps(of: Self.hairpin)
        let half = 6.0
        #expect(inkedPixels(image) > 0)
        var outside: [(Int, Int)] = []
        for y in 0..<image.height {
            for x in 0..<image.width where isInked(image, x, y) {
                if Self.distance(from: SIMD2(Double(x), Double(y)), to: polyline) > half + 0.01 {
                    outside.append((x, y))
                }
            }
        }
        #expect(outside.isEmpty, "\(outside.count) 画素がはみ出している (最初は \(outside.first.map { "\($0)" } ?? ""))")
    }

    // MARK: - 輪郭の経路で描く円と円弧 (#1423)

    /// 絵を貼って塗る円と円弧は、距離関数の経路 (``Canvas/formAllowed(fills:)``) に乗れず、
    /// 周の点を結んだ折れ線として輪郭を引く。**周の点も曲線の刻みで、角ではない。**
    private func renderTextured(join: StrokeJoin, _ place: (Canvas) -> Void) throws
        -> DisplayImage
    {
        try render { canvas in
            // 絵の中身は問わない。塗りに絵が付いていることだけが経路を決める
            guard let picture = try? canvas.createImage(1, 1) else { return }
            canvas.texture(picture)
            canvas.fill(black)
            canvas.strokeWeight(10)
            canvas.strokeJoin(join)
            place(canvas)
        }
    }

    /// 周の多角形は円に内接するので、帯と円板は中心から「半径 + 太さの半分」の内側に
    /// 収まる。周の点に正方形を置くと、周が斜めを向くところで角がその外へ出る。
    @Test("絵を貼って塗る円の輪郭は、半径と太さの半分の外へはみ出さない")
    func texturedCircleStaysWithinHalfTheWeight() throws {
        let image = try renderTextured(join: .miter) { $0.circle(32, 32, 36) }
        #expect(inkedPixels(image) > 0)
        var outside = 0
        for y in 0..<image.height {
            for x in 0..<image.width where isInked(image, x, y) {
                let offset = SIMD2(Double(x) - 32, Double(y) - 32)
                if (offset * offset).sum().squareRoot() > 18 + 5 + 0.01 { outside += 1 }
            }
        }
        #expect(outside == 0, "\(outside) 画素がはみ出している")
    }

    @Test("絵を貼って塗る円の輪郭は、折れ目の形によらず同じ絵になる")
    func texturedCircleIgnoresTheJoin() throws {
        let mitered = try renderTextured(join: .miter) { $0.circle(32, 32, 36) }
        let rounded = try renderTextured(join: .round) { $0.circle(32, 32, 36) }
        #expect(inkedPixels(rounded) > 0)
        #expect(differingPixels(mitered, rounded) == 0)
    }

    /// 扇は中心と弧の両端の 3 点が本当の角である。**折れ目の形の違いは、その 3 点の
    /// 近くにしか出ない** — 角を埋める正方形は、角から (太さの半分) × √2 の内側に収まる。
    @Test("絵を貼って塗る扇の折れ目の形は、中心と弧の両端の角にだけ効く")
    func texturedPieJoinsOnlyAtItsCorners() throws {
        let (start, stop): (Float, Float) = (0.3, 2.2)
        func pie(_ canvas: Canvas) { canvas.arc(32, 32, 44, 44, start, stop) }
        let mitered = try renderTextured(join: .miter, pie)
        let rounded = try renderTextured(join: .round, pie)

        let corners: [SIMD2<Double>] = [
            SIMD2(32, 32),
            SIMD2(32 + 22 * cos(Double(start)), 32 + 22 * sin(Double(start))),
            SIMD2(32 + 22 * cos(Double(stop)), 32 + 22 * sin(Double(stop))),
        ]
        let reach = 5 * 2.0.squareRoot() + 0.01
        var differing = 0
        var awayFromCorners: [(Int, Int)] = []
        for y in 0..<mitered.height {
            for x in 0..<mitered.width where mitered[x, y] != rounded[x, y] {
                differing += 1
                let point = SIMD2(Double(x), Double(y))
                let nearest = corners.map { corner -> Double in
                    let offset = point - corner
                    return (offset * offset).sum().squareRoot()
                }.min() ?? .infinity
                if nearest > reach { awayFromCorners.append((x, y)) }
            }
        }
        // 角では違いが出ている — 出ていなければ、折れ目の形を見ていない
        #expect(differing > 0)
        #expect(awayFromCorners.isEmpty, "角から離れた \(awayFromCorners.count) 画素が違う (最初は \(awayFromCorners.first.map { "\($0)" } ?? ""))")
    }
}
