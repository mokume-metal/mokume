// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeProbe
import MokumeTestSupport
import Testing
import simd

@testable import MokumeCore

/// **塗りの縁の被覆は、CPU で解析的に出した参照と画素ごとに一致する** ([#3217]・#3207 の提案 2)。GPU を要する。
///
/// 台帳 (`SceneLedgerTests`) は絵が**動いたか**しか見ない。ここは絵が**正しいか**を、遅くても明らかに
/// 正しい参照 (`CoverageReference`) と比べて判定する。置き方 (位置の小数・角度・大きさ) は
/// ``Probe`` が seed つきで生成し、**縁の画素の全部**を見る。固定の例 (`ExactEdgeCoverageTests` の 45° の
/// rect など) は 1 点しか見ない — 入力を生成すると、#2991 の型の「置く位置・角度で外れる」を探せる。
///
/// ## 見る図形と許容 (``CoverageTable``)
///
/// 軸に沿う rect (縁は線形の渡し = 面積・0.006)・回した rect (直線の斜めの縁・0.012)・円 (曲線の縁・0.02)
/// の塗り。許容は既存の検査の根拠のままで、**生成した置き方で越えたら許容を広げず Bug として起票する**。
/// 約束は経路で違い、ここで比べるのは距離関数の経路の「面積」だけである。三角形の経路 (立体・任意形状) の縁は
/// AA なしで、約束は 50% の白黒と重心まで (ADR-0039 決定 1・3)。表が拒む組は比べない。
///
/// 円の半径は 7 以上を生成する。曲線の縁は距離を直線とみなして数えるので面積より明るく出て、差は半径に
/// 反比例する (実測の最大: 半径 3 で 0.037・5 で 0.023・8 で 0.017・29 で 0.007)。**許容を広げずに、
/// 0.02 に収まる半径から探す** — それより小さい円の約束 (許容の置き方) は #3217 で人が決める。
///
/// ## 見ない画素
///
/// - **角の 1.5 画素**: 角の外の距離場は縁 1 本ではなく角までの距離で、被覆は面積の約束の外にある
///   (ADR-0039 決定 1 は縁の中間値の掛け方を射程の外に置き、一致を位置・大きさ・向きと読む。
///   `ExactEdgeCoverageTests.rotatedFillEdgeMatchesTheExactArea` も同じ範囲を除く)。形自身の座標で、
///   2 つの辺からどちらも 1.5 画素の内にある画素を除く
/// - それ以外は面の全画素を見る (縁から離れた画素は参照が 0 か 1 で、本体が縁の外へ滲ませていないことも見る)。
///   円には角が無いので、除く画素は無い
///
/// ## 赤の読み方
///
/// `[coverage seed=0x…] <座標>: <図形> pixel=(x,y) 値 … 参照 … (許容 …)`。同じ赤は
/// `MOKUME_PROBE_SEED=<その seed>` と `--filter` で、その 1 件だけを走らせて再現する。
///
/// [#3217]: https://github.com/mokume-metal/mokume/issues/3217
@Suite(
    "塗りの縁の被覆は CPU の参照と画素ごとに一致する",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FillCoverageTests {
    /// 出す面の大きさ (正方形)。
    static let size = 128

    /// 生成する置き方の件数。PR・queue の経路に足す所要を 20 秒以内に収める (#3207 の K4)。円は参照の
    /// 細分が重く、1 件が rect の 10 倍ほどかかるので、件数を分ける。
    static let rectCases = 150
    static let circleCases = 60

    /// 描いた面の赤を、行ごとに並べて返す。
    private static func draw(_ canvas: Canvas, _ body: () -> Void) throws -> PixelBuffer {
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            body()
        }
        return try canvas.target.readPixels()
    }

    /// 赤の文面の数 (4 桁)。
    private static func short(_ value: Double) -> String { String(format: "%.4g", value) }

    /// 全画素を参照と比べ、最初に許容を越えた画素 (最悪) を名乗る。`skipping` が真の画素は見ない。
    private static func compare(
        _ pixels: PixelBuffer, with reference: [Double], row: CoverageTable.Row, skipping: (Int, Int) -> Bool
    ) -> Probe.Outcome {
        var worst = 0.0
        var at = ""
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where !skipping(x, y) {
                let expected = reference[y * pixels.width + x]
                let measured = Double(pixels[x, y].red)
                let diff = abs(measured - expected)
                if diff > worst {
                    worst = diff
                    at = "pixel=(\(x),\(y)) 値 \(Self.short(measured)) 参照 \(Self.short(expected))"
                }
            }
        }
        return worst <= row.tolerance
            ? .pass : .fail("\(row.shape.rawValue) \(at) (差 \(Self.short(worst))・許容 \(Self.short(row.tolerance)))")
    }

    // MARK: - 軸に沿う rect

    static let axisAxes: [ProbeAxis] = [
        ProbeAxis("x", 8..<60, simplest: 10),
        ProbeAxis("y", 8..<60, simplest: 10),
        ProbeAxis("width", 4..<60, simplest: 20),
        ProbeAxis("height", 4..<60, simplest: 20),
        // 0°・90°・180°・270° (軸に沿ったまま向きだけ変える)
        ProbeAxis("quarter", 0..<4, simplest: 0, step: 1),
    ]

    @Test("軸に沿う rect の塗りは、位置の小数・大きさ・向きによらず、縁の画素が参照と 0.006 以内で一致する")
    func axisAlignedRectMatchesTheReference() throws {
        let row = try CoverageTable.row(.axisAlignedRect, on: .distanceField, comparing: .area)
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        let report = try Probe.run(
            "coverage", suite: "FillCoverageTests", key: "rect-axis", axes: Self.axisAxes, cases: Self.rectCases
        ) { input in
            let (x, y, w, h) = (input.float("x"), input.float("y"), input.float("width"), input.float("height"))
            let quarter = Int(input["quarter"])
            let pixels = try Self.draw(canvas) {
                // 中心を軸に、90° の倍数だけ向きを変える。縦横が入れ替わるので、置く箱も入れ替える
                canvas.translate(x + w / 2, y + h / 2)
                canvas.rotate(Float(quarter) * .pi / 2)
                canvas.rect(-w / 2, -h / 2, w, h)
            }
            let center = SIMD2(Double(x + w / 2), Double(y + h / 2))
            let half = SIMD2(Double(w) / 2, Double(h) / 2)
            let angle = Double(quarter) * .pi / 2
            let polygon = CoverageReference.rotatedRect(center: center, half: half, angle: angle)
            let reference = CoverageReference.polygonCoverage(polygon, width: Self.size, height: Self.size)
            return Self.compare(pixels, with: reference, row: row) { px, py in
                Self.nearCorner(center: center, half: half, angle: angle, px, py)
            }
        }
        #expect(report.failure == nil, "\(report.failure ?? "")")
        #expect(report.skipped == 0, "約束の外は無いはず: \(report.skipped) 件")
    }

    // MARK: - 回した rect

    static let rotatedAxes: [ProbeAxis] = [
        ProbeAxis("cx", 40..<88, simplest: 64),
        ProbeAxis("cy", 40..<88, simplest: 64),
        ProbeAxis("width", 4..<50, simplest: 20),
        ProbeAxis("height", 4..<50, simplest: 20),
        ProbeAxis("angle", 0..<(2 * Double.pi), simplest: 0),
    ]

    @Test("回した rect の塗りは、位置の小数・大きさ・角度によらず、縁の画素が参照と 0.012 以内で一致する")
    func rotatedRectMatchesTheReference() throws {
        let row = try CoverageTable.row(.rotatedRect, on: .distanceField, comparing: .area)
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        let report = try Probe.run(
            "coverage", suite: "FillCoverageTests", key: "rect-rotated", axes: Self.rotatedAxes,
            cases: Self.rectCases
        ) { input in
            let (cx, cy, w, h) = (input.float("cx"), input.float("cy"), input.float("width"), input.float("height"))
            let angle = input.float("angle")
            let pixels = try Self.draw(canvas) {
                canvas.translate(cx, cy)
                canvas.rotate(angle)
                canvas.rect(-w / 2, -h / 2, w, h)
            }
            // GPU が Float で回す角度と置く位置を、参照にも同じ値で渡す
            let center = SIMD2(Double(cx), Double(cy)), half = SIMD2(Double(w) / 2, Double(h) / 2)
            let polygon = CoverageReference.rotatedRect(center: center, half: half, angle: Double(angle))
            let reference = CoverageReference.polygonCoverage(polygon, width: Self.size, height: Self.size)
            return Self.compare(pixels, with: reference, row: row) { px, py in
                Self.nearCorner(center: center, half: half, angle: Double(angle), px, py)
            }
        }
        #expect(report.failure == nil, "\(report.failure ?? "")")
        #expect(report.skipped == 0, "約束の外は無いはず: \(report.skipped) 件")
    }

    // MARK: - 円

    static let circleAxes: [ProbeAxis] = [
        ProbeAxis("cx", 36..<92, simplest: 64),
        ProbeAxis("cy", 36..<92, simplest: 64),
        ProbeAxis("radius", 7..<30, simplest: 12),
    ]

    @Test("円の塗りは、位置の小数・半径によらず、縁の画素が参照と 0.02 以内で一致する")
    func circleMatchesTheReference() throws {
        let row = try CoverageTable.row(.circle, on: .distanceField, comparing: .area)
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        let report = try Probe.run(
            "coverage", suite: "FillCoverageTests", key: "circle", axes: Self.circleAxes, cases: Self.circleCases
        ) { input in
            let (cx, cy, r) = (input.float("cx"), input.float("cy"), input.float("radius"))
            let pixels = try Self.draw(canvas) { canvas.circle(cx, cy, 2 * r) }
            let reference = CoverageReference.circleCoverage(
                center: SIMD2(Double(cx), Double(cy)), radius: Double(r), width: Self.size, height: Self.size)
            // 円には角が無い
            return Self.compare(pixels, with: reference, row: row) { _, _ in false }
        }
        #expect(report.failure == nil, "\(report.failure ?? "")")
        #expect(report.skipped == 0, "約束の外は無いはず: \(report.skipped) 件")
    }

    // MARK: - 角

    /// 画素の中心が、長方形の角の 1.5 画素の内か。**形自身の座標** (逆に回した座標) で、辺から 1.5 画素
    /// 以内の帯が 2 方向とも重なる所 (`ExactEdgeCoverageTests.rotatedFillEdgeMatchesTheExactArea` と同じ範囲)。
    /// 角の外の距離場は縁 1 本ではなく角までの距離で、被覆は面積の約束の外 (ADR-0039 決定 1)。
    private static func nearCorner(
        center: SIMD2<Double>, half: SIMD2<Double>, angle: Double, _ x: Int, _ y: Int
    ) -> Bool {
        let d = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - center
        let (c, s) = (cos(angle), sin(angle))
        let local = SIMD2(c * d.x + s * d.y, -s * d.x + c * d.y)
        return abs(abs(local.x) - half.x) < 1.5 && abs(abs(local.y) - half.y) < 1.5
    }
}
