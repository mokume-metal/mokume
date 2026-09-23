// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 変換・投影・視点を、**仕様から導いた既知の値**と照合する検査 (#1382)。
///
/// 近くにある検査の多くは、同じ行列を読む 2 つの口 (`screenX` と画素など) を比べている。
/// それだと行列の符号や軸を取り違えても両側が揃って動き、緑のまま残る。ここでは期待値を
/// 実装の行列から写さず、空間の約束 ([ADR-0021] 決定 1: x は右・y は下・奥行きは見ている側
/// が正) と、作者向けのドキュメントが名乗る向きから書き起こす ([ADR-0019] 決定 4)。
///
/// 行列だけで閉じる照合はこの型に、面へ描いて画素で見るものは入れ子の ``OnCanvas`` に置く。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
@Suite("変換の式")
struct TransformFormulaTests {

    /// 回す軸。
    enum Axis: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case x, y, z
        var testDescription: String { "\(rawValue) 軸" }
    }

    /// 仕様から書き起こした回転。**行列ではなく、点を移す式として書く** — 実装の行列の
    /// 並び (列優先・掛ける向き) を写さないためである。
    ///
    /// 向きは作者向けのドキュメント (`Sketch.rotateX(_:)` など) が名乗るものに合わせる:
    ///
    /// - x 軸: 「正の角度は上の面が奥へ倒れる」— 上 (−y) が奥 (−z) へ、つまり +y が +z へ向かう
    /// - y 軸: 「正の角度は右の面が奥へ回る」— 右 (+x) が奥 (−z) へ、つまり +z が +x へ向かう
    /// - z 軸: 「正の角度は画面の上で時計回りに見える」— 縦軸が下向きなので、右 (+x) が下 (+y) へ向かう
    ///
    /// 回転は長さと向きの巡り (鏡に映さないこと) を保つので、回る平面の中で 1 本の向きの
    /// 行き先が決まれば、もう 1 本の行き先も決まる。倍精度で計算し、float の実装とは独立に置く。
    static func rotated(_ point: SIMD3<Double>, about axis: Axis, by angle: Double) -> SIMD3<Double> {
        let (c, s) = (cos(angle), sin(angle))
        switch axis {
        case .x: return SIMD3(point.x, c * point.y - s * point.z, s * point.y + c * point.z)
        case .y: return SIMD3(c * point.x + s * point.z, point.y, -s * point.x + c * point.z)
        case .z: return SIMD3(c * point.x - s * point.y, s * point.x + c * point.y, point.z)
        }
    }

    /// 1 本の軸まわりに回した変換を、公開の口 (`Transform.rotateX(by:)` など) で組む。
    static func transform(rotating axis: Axis, by angle: Float) -> Transform {
        var transform = Transform.identity
        switch axis {
        case .x: transform.rotateX(by: angle)
        case .y: transform.rotateY(by: angle)
        case .z: transform.rotateZ(by: angle)
        }
        return transform
    }

    /// 照合に使う点。軸の上の 3 点と、どの軸にも沿わない 2 点。
    static let probes: [SIMD3<Double>] = [
        SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
        SIMD3(30, -20, 15), SIMD3(-7, 11, -40),
    ]

    /// 照合の許容 (点の長さあたり)。float の sin / cos と積和の丸めは長さあたり 1e-6 に
    /// 届かない。符号や軸の取り違えは点の長さと同じ桁でずれるので、この幅で見逃すことはない。
    static let tolerance = 1e-5

    static func moved(_ point: SIMD3<Double>, by transform: Transform) -> SIMD3<Double> {
        let moved = transform.apply(x: Float(point.x), y: Float(point.y), z: Float(point.z))
        return SIMD3(Double(moved.x), Double(moved.y), Double(moved.z))
    }

    // MARK: - 条件 1: 回転の向き

    @Test(
        "1 本の軸まわりの回転が、仕様から書いた式と一致する",
        arguments: Axis.allCases, [0.3, 1.0, -0.7, Double.pi / 2, 2.5])
    func singleRotationMatchesTheFormula(axis: Axis, angle: Double) {
        let transform = Self.transform(rotating: axis, by: Float(angle))
        for probe in Self.probes {
            let expected = Self.rotated(probe, about: axis, by: angle)
            let actual = Self.moved(probe, by: transform)
            #expect(
                distance(actual, expected) <= Self.tolerance * max(1, length(probe)),
                "\(probe) を回した先: 実装 \(actual) / 式 \(expected)")
        }
    }

    @Test("正の角度で、ドキュメントが名乗る辺が奥へ (あるいは下へ) 動く")
    func positiveAnglesMoveTheDocumentedEdge() {
        // 式を経ずに、ドキュメントの文をそのまま読む。式のほうを実装に合わせて書き換えても、
        // ここは文と一緒でなければ動かせない
        let top = Self.transform(rotating: .x, by: 0.3).apply(x: 0, y: -10, z: 0)
        #expect(top.z < 0, "rotateX: 上の面が奥へ倒れていない (z = \(top.z))")
        let right = Self.transform(rotating: .y, by: 0.3).apply(x: 10, y: 0, z: 0)
        #expect(right.z < 0, "rotateY: 右の面が奥へ回っていない (z = \(right.z))")
        let turned = Self.transform(rotating: .z, by: 0.3).apply(x: 10, y: 0, z: 0)
        #expect(turned.y > 0, "rotateZ: 右が下へ動いていない = 時計回りでない (y = \(turned.y))")
    }

    @Test("重ねた変換は、あとから指定したものほど先に図形へ掛かる")
    func stackedRotationsApplyTheLaterOneFirst() {
        var transform = Transform.identity
        transform.translate(x: 12, y: -5, z: 8)
        transform.rotateX(by: 0.4)
        transform.rotateY(by: -1.1)
        transform.rotateZ(by: 0.7)

        for probe in Self.probes {
            // 図形に近い側 (あとから指定した rotateZ) から順に移す
            var expected = Self.rotated(probe, about: .z, by: Double(Float(0.7)))
            expected = Self.rotated(expected, about: .y, by: Double(Float(-1.1)))
            expected = Self.rotated(expected, about: .x, by: Double(Float(0.4)))
            expected += SIMD3(12, -5, 8)
            let actual = Self.moved(probe, by: transform)
            #expect(
                distance(actual, expected) <= Self.tolerance * max(1, length(probe) + length(expected)),
                "\(probe) を移した先: 実装 \(actual) / 式 \(expected)")
        }
    }

    // MARK: - 絵に出る

    /// 面へ描いて画素で見るもの。GPU を要するので、条件は置き場所で掛ける (`GPUGateTests`)。
    ///
    /// 目印は黒地に作業空間の赤 (`.linear`) で塗る。純色は 255 / 0 に出るので、塗られたかを
    /// 赤の成分だけで言える。
    @Suite(
        "絵に出る",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct OnCanvas {
        private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
        private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
        private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
        private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

        private func makeCanvas(width: Int, height: Int) throws -> Canvas {
            try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        }

        /// 黒地・輪郭なし・赤の塗りから始めて、渡した中身を描く。
        private func picture(
            _ canvas: Canvas, _ body: (Canvas) -> Void
        ) throws -> DisplayImage {
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(red)
                body(canvas)
            }
            return try canvas.target.encodeForDisplay()
        }

        private func picture(
            width: Int, height: Int, _ body: (Canvas) -> Void
        ) throws -> DisplayImage {
            try picture(makeCanvas(width: width, height: height), body)
        }

        /// 赤が半分より濃い画素を数える。
        private func paintedCount(
            _ image: DisplayImage, where included: (Int, Int) -> Bool = { _, _ in true }
        ) -> Int {
            var count = 0
            for y in 0..<image.height {
                for x in 0..<image.width where included(x, y) && image[x, y].red > 127 {
                    count += 1
                }
            }
            return count
        }

        private func rotate(_ canvas: Canvas, about axis: Axis, by angle: Float) {
            switch axis {
            case .x: canvas.rotateX(angle)
            case .y: canvas.rotateY(angle)
            case .z: canvas.rotateZ(angle)
            }
        }

        // MARK: - 条件 1: 回転の向きが絵に出る

        @Test("真横まで回した面は、1 画素も塗らない", arguments: [Axis.x, .y])
        func aPlaneTurnedEdgeOnPaintsNothing(axis: Axis) throws {
            func painted(_ angle: Float) throws -> Int {
                let image = try picture(width: 64, height: 64) { canvas in
                    canvas.translate(32, 32, 0)
                    rotate(canvas, about: axis, by: angle)
                    canvas.plane(40, 30)
                }
                return paintedCount(image)
            }
            // 対照: 回さなければ、奥行き 0 の面は画素の大きさでちょうど 40 × 30 を塗る
            // (ADR-0021 決定 1)。ここが 0 なら、下の 0 は何も確かめていない
            #expect(try painted(0) == 40 * 30)
            // 既定の視線は面の中心を通るので、真横まで回すと面は視線を含む平面に乗り、
            // 画面では線に潰れる。cos(π/2) は float で 0 にならないが、残る幅は 1e-6 画素に
            // 届かず、線は画素の境目 (x = 32 / y = 32) に乗るので、どの画素の中心も覆わない
            #expect(try painted(.pi / 2) == 0)
        }

        @Test(
            "正の角度で奥へ回った側は、遠近で小さく写る",
            arguments: [(Axis.x, Float(0.6)), (.x, -0.6), (.y, 0.6), (.y, -0.6)])
        func theSideThatTurnsAwayLooksSmaller(axis: Axis, angle: Float) throws {
            // 既定の視点は遠近が付くので、同じ面でも奥にある部分ほど小さく写る
            // (`translate(_:_:_:)` のドキュメント)。回した面を中央で 2 つに分け、塗った
            // 画素の数を比べる — 奥へ行った半分のほうが少ない
            let image = try picture(width: 96, height: 96) { canvas in
                canvas.translate(48, 48, 0)
                rotate(canvas, about: axis, by: angle)
                canvas.plane(48, 48)
            }
            // 回る向きに沿って測る (x 軸まわりなら縦、y 軸まわりなら横)
            let lowSide = paintedCount(image) { x, y in (axis == .y ? x : y) < 48 }
            let highSide = paintedCount(image) { x, y in (axis == .y ? x : y) >= 48 }
            // 正の角度で奥へ行くのは、x 軸なら上 (y の小さい側)、y 軸なら右 (x の大きい側)。
            // 負の角度では入れ替わる
            let awayIsLow = (axis == .x) == (angle > 0)
            let awaySide = awayIsLow ? lowSide : highSide
            let nearSide = awayIsLow ? highSide : lowSide
            #expect(nearSide > 0)
            // 角度 0.6 では、手前の半分がおよそ 1.6 倍に写る。符号を取り違えると大小が入れ替わる
            #expect(
                awaySide * 5 < nearSide * 4,
                "奥へ行くはずの側 \(awaySide) 画素 / 手前へ来るはずの側 \(nearSide) 画素")
        }

        // MARK: - 条件 2: applyMatrix

        /// applyMatrix で比べる場面。
        enum MatrixScene: String, CaseIterable, Sendable, CustomTestStringConvertible {
            /// 平面の `rect` を、平面の移動と回転で置く。
            case flat
            /// 立体の `box` を、奥行きを含む移動と横軸まわりの回転で置く。
            case solid
            var testDescription: String { rawValue }
        }

        @Test(
            "applyMatrix で重ねた移動と回転は、translate と rotate を並べた絵とバイト一致する",
            arguments: MatrixScene.allCases)
        func applyMatrixMatchesTheSteps(scene: MatrixScene) throws {
            func draw(_ canvas: Canvas, step: (Canvas) -> Void) {
                // **起点を単位行列から外しておく。** 単位行列の後ろに重ねるなら、掛ける順を
                // 取り違えても同じ絵になり、この検査は何も確かめない
                switch scene {
                case .flat:
                    canvas.translate(40, 30)
                    canvas.rotate(0.35)
                    step(canvas)
                    canvas.rect(-12, -7, 24, 14)
                case .solid:
                    canvas.lights()
                    canvas.fill(white)
                    canvas.translate(40, 30, 0)
                    canvas.rotateY(0.5)
                    step(canvas)
                    canvas.box(18)
                }
            }

            let applied = try picture(width: 128, height: 96) { canvas in
                draw(canvas) { canvas in
                    var step = Transform.identity
                    switch scene {
                    case .flat:
                        step.translate(x: 30, y: 8)
                        step.rotate(by: 0.6)
                    case .solid:
                        step.translate(x: 20, y: 10, z: -15)
                        step.rotateX(by: 0.7)
                    }
                    canvas.applyMatrix(step)
                }
            }
            let stepped = try picture(width: 128, height: 96) { canvas in
                draw(canvas) { canvas in
                    switch scene {
                    case .flat:
                        canvas.translate(30, 8)
                        canvas.rotate(0.6)
                    case .solid:
                        canvas.translate(20, 10, -15)
                        canvas.rotateX(0.7)
                    }
                }
            }

            // 何かが描かれていること (空どうしの一致で緑にしない)
            #expect(paintedCount(stepped) > 100)
            // 移動 + 回転の 2 段は、起点の行列の後ろに重ねても丸めの順が変わらない
            // (回転の行列の 4 行目と、移動の行列の左上が厳密に 0 と 1 だから)。だからバイトで比べる
            #expect(applied.bytes == stepped.bytes)
        }

        // MARK: - 条件 3: shearY

        @Test("shearY(π/4) の rect は、右へ行くほど同じだけ下へずれた位置を塗る")
        func shearYMovesTheRectDownInProportionToX() throws {
            // 角度は傾いた辺が水平と成す角である — 横の辺 (1, 0) は (1, tan θ) へ移る。
            // π/4 なら tan = 1 で、形の座標の (x, y) は (x, y + x) に写る (ドキュメントの
            // 「正の角度では右の辺ほど下へ動く」)
            let origin = SIMD2<Double>(20, 10)
            let size = SIMD2<Double>(40, 24)
            let image = try picture(width: 96, height: 96) { canvas in
                canvas.translate(Float(origin.x), Float(origin.y))
                canvas.shearY(Float.pi / 4)
                canvas.rect(0, 0, Float(size.x), Float(size.y))
            }

            // 縁の画素は判定に使わない。`rect` の縁は距離関数の被覆率で塗られ、傾いた辺では
            // 中間の値になる。縦の辺から 1.5 画素、傾いた辺から縦に 2 画素 (辺に垂直には
            // 1.4 画素) 離れた画素の中心なら、被覆率は 0 か 1 に決まる
            let (sideMargin, slopeMargin) = (1.5, 2.0)
            var inside = 0
            var outside = 0
            // 食い違いは数と最初の数個だけを名乗る (全部を並べると記録が画素の一覧で埋まる)
            var missCount = 0
            var misses: [String] = []
            func miss(_ message: String) {
                if misses.count < 8 { misses.append(message) }
                missCount += 1
            }
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let local = Double(x) + 0.5 - origin.x
                    let top = origin.y + local  // 左上の角の下がり方 = x
                    let centerY = Double(y) + 0.5
                    let painted = image[x, y].red > 127
                    let isInside =
                        local > sideMargin && local < size.x - sideMargin
                        && centerY > top + slopeMargin && centerY < top + size.y - slopeMargin
                    let isOutside =
                        local < -sideMargin || local > size.x + sideMargin
                        || centerY < top - slopeMargin || centerY > top + size.y + slopeMargin
                    if isInside {
                        inside += 1
                        if !painted { miss("(\(x), \(y)) が塗られていない") }
                    } else if isOutside {
                        outside += 1
                        if image[x, y].red != 0 { miss("(\(x), \(y)) が塗られている") }
                    }
                }
            }
            // 判定に使った画素が十分にあること (内側だけで 700 画素ほど)
            #expect(inside > 600)
            #expect(outside > 6000)
            #expect(missCount == 0, "\(missCount) 画素が式と違う。最初の数個: \(misses)")
        }

        // MARK: - 条件 4: perspective

        @Test(
            "透視投影で距離 d に置いた幅 w の面は、w·(h/2) / (d·tan(fov/2)) 画素の幅に写る",
            arguments: [
                // (tan(fov/2), 視点からの距離 d)
                (0.5, 200.0), (0.5, 320.0), (0.8, 250.0), (0.25, 200.0),
            ])
        func perspectiveWidthFollowsTheFormula(halfTangent: Double, viewDistance: Double) throws {
            // 面は横長にして aspect = 横 ÷ 縦 を 1 にしない。横と縦の取り違えが寸法に出る
            let (width, height) = (240, 160)
            let (planeWidth, planeHeight) = (100.0, 60.0)
            // 視点は明示する。距離 d を仕様どおりに決めるためで、既定の視点の位置には頼らない。
            // 目の奥行きは、面が目と奥行き 0 のちょうど中間に来ない値にする — 中間に来ると、
            // 見る位置と見ている先を取り違えても同じ距離から (裏から) 見ることになり、
            // 寸法が変わらず取り違えを見逃す
            let eyeZ = 450.0

            let image = try picture(width: width, height: height) { canvas in
                canvas.camera(
                    Float(width) / 2, Float(height) / 2, Float(eyeZ),
                    Float(width) / 2, Float(height) / 2, 0,
                    0, 1, 0)
                canvas.perspective(
                    Float(2 * atan(halfTangent)), Float(width) / Float(height), 10, 4000)
                canvas.translate(Float(width) / 2, Float(height) / 2, Float(eyeZ - viewDistance))
                canvas.plane(Float(planeWidth), Float(planeHeight))
            }

            // 縦の画角 fov で距離 d にある面は、縦に 2·d·tan(fov/2) の範囲が画面の高さ h に
            // 写る。1 単位は h / (2·d·tan(fov/2)) 画素で、aspect = 横 ÷ 縦 なら横も同じ倍率
            let expectedWidth = planeWidth * (Double(height) / 2) / (viewDistance * halfTangent)
            let expectedHeight = planeHeight * (Double(height) / 2) / (viewDistance * halfTangent)

            // **許す幅は 0 画素。** 引数は、式の値が偶数の画素になり、縁が面の中心から整数だけ
            // 離れる (= 画素の境目に乗る) ように選んである。`plane` は三角形の経路で縁の AA を
            // 持たず、画素の中心 (i + 0.5) を覆うかで塗る。float の丸めは縁を 1e-4 画素ほどしか
            // 動かさず、中心までの 0.5 画素に届かないので、塗られる数は式の値にちょうど一致する
            let rowCount = (0..<width).count { image[$0, height / 2].red > 127 }
            let columnCount = (0..<height).count { image[width / 2, $0].red > 127 }
            #expect(Double(rowCount) == expectedWidth, "横: \(rowCount) 画素 / 式 \(expectedWidth)")
            #expect(Double(columnCount) == expectedHeight, "縦: \(columnCount) 画素 / 式 \(expectedHeight)")
            // 中心に置いたものは中心に写る (左端と上端が式の位置にある)
            let left = (0..<width).first { image[$0, height / 2].red > 127 }
            let top = (0..<height).first { image[width / 2, $0].red > 127 }
            #expect(left.map(Double.init) == Double(width / 2) - expectedWidth / 2)
            #expect(top.map(Double.init) == Double(height / 2) - expectedHeight / 2)
        }

        // MARK: - 条件 5: camera

        /// 視点の検査に使う場面。**向きの分かる並び**にしてある — 左上に赤、右下に緑、
        /// 左下の奥に青。平面の縁は整数の座標 (画素の境目) に置く。
        private func cameraScene(_ canvas: Canvas) {
            canvas.fill(red)
            canvas.push()
            canvas.translate(24, 16, 0)
            canvas.plane(16, 12)
            canvas.pop()

            canvas.fill(green)
            canvas.push()
            canvas.translate(70, 44, 0)
            canvas.plane(20, 8)
            canvas.pop()

            // 奥行きを持つもの。縁は遠近で小数に落ちるが、画素の中心から 0.05 画素以上離れる
            canvas.fill(blue)
            canvas.push()
            canvas.translate(30, 44, -40)
            canvas.plane(10, 10)
            canvas.pop()
        }

        @Test("既定の目・中心・上を書いた視点は、何も書かない絵とバイト一致する")
        func writingTheDefaultCameraKeepsThePicture() throws {
            let (width, height) = (96, 64)
            func scene(_ canvas: Canvas) {
                cameraScene(canvas)
                // 光と回した立体も置く (艶は目の位置を読むので、目の取り違えが色に出る)
                canvas.lights()
                canvas.fill(white)
                canvas.push()
                canvas.translate(62, 20, 0)
                canvas.rotateX(0.5)
                canvas.rotateY(0.7)
                canvas.box(14)
                canvas.pop()
            }

            let untouched = try picture(width: width, height: height) { scene($0) }
            let written = try picture(width: width, height: height) { canvas in
                // 既定は「面がちょうど収まる位置から、面を正面に見る」視点で、既定の画角は π/3
                // (`camera()` と `perspective(_:_:_:_:)` のドキュメント)。縦に面の高さが
                // 収まる距離は (h/2) / tan(π/6)。上は `(0, 1, 0)` が普通の向き (縦軸が下向き)
                let eyeZ = (Float(height) / 2) / tan(Float.pi / 6)
                canvas.camera(
                    Float(width) / 2, Float(height) / 2, eyeZ,
                    Float(width) / 2, Float(height) / 2, 0,
                    0, 1, 0)
                scene(canvas)
            }

            #expect(paintedCount(untouched) > 100)
            #expect(written.bytes == untouched.bytes)
        }

        @Test("上向きを反転すると、絵は上下が反転する (左右もあわせて反転する)")
        func flippingUpTurnsThePictureUpsideDown() throws {
            let (width, height) = (96, 64)
            let eyeZ = (Float(height) / 2) / tan(Float.pi / 6)
            func shot(upY: Float) throws -> DisplayImage {
                try picture(width: width, height: height) { canvas in
                    canvas.camera(
                        Float(width) / 2, Float(height) / 2, eyeZ,
                        Float(width) / 2, Float(height) / 2, 0,
                        0, upY, 0)
                    cameraScene(canvas)
                }
            }
            let upright = try shot(upY: 1)
            let flipped = try shot(upY: -1)

            // 上向きを反転しても、視点の位置と視線は変わらない。変わるのは視線の軸まわりの
            // 向きだけで、半回転 (180°) になる — 回転なので鏡像にはならず、上下と一緒に左右も
            // 反転する。縁は画素の境目か、画素の中心から離れた位置に置いてあるので、境界の
            // 規則 (中心にちょうど乗った縁をどちらへ倒すか) の上下左右の差は出ない
            var mismatches = 0
            for y in 0..<height {
                for x in 0..<width
                where upright[x, y] != flipped[width - 1 - x, height - 1 - y] {
                    mismatches += 1
                }
            }
            #expect(mismatches == 0, "半回転した絵と \(mismatches) 画素が違う")
            // 上下が反転したことを、目印の位置でも言う: 左上 (16..<32, 10..<22) の赤は右下へ
            #expect(upright[20, 12].red == 255)
            #expect(flipped[width - 1 - 20, height - 1 - 12].red == 255)
            #expect(flipped[20, 12].red == 0)
        }

        // MARK: - 条件 6: shape(at:)

        /// 保持した形の中身。**経路ごとに 1 つ**置く — 置き場所の変換を掛ける場所が
        /// 経路ごとに別の関数にある (`Canvas.place(_:of:at:)` 系)。
        enum RetainedKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
            /// 立体 (`box`)。置き場所ごとの行列を列へ積む。
            case solid
            /// 頂点を並べた平面 (`beginShape`)。置き場所ごとに頂点を移す。
            case flat
            /// 基本図形 (`rect`)。距離関数の経路で、置き場所の行列を形へ渡す。
            case form
            var testDescription: String { rawValue }
        }

        @Test(
            "置き場所の scale と rotation.z は、translate / rotateZ / scale を並べた絵とバイト一致する",
            arguments: RetainedKind.allCases)
        func placementScaleAndTurnMatchTheSteps(kind: RetainedKind) throws {
            // 回すと見分けの付く形にする (正方形・円・立方体は回しても同じに見える)
            func make(_ canvas: Canvas) -> Shape {
                canvas.createShape {
                    switch kind {
                    case .solid:
                        canvas.box(10, 5, 4)
                    case .flat:
                        // L 字
                        canvas.beginShape()
                        canvas.vertex(-5, -5)
                        canvas.vertex(7, -5)
                        canvas.vertex(7, -1)
                        canvas.vertex(-1, -1)
                        canvas.vertex(-1, 6)
                        canvas.vertex(-5, 6)
                        canvas.endShape(.close)
                    case .form:
                        canvas.rect(-7, -3, 14, 6)
                    }
                }
            }
            func prepare(_ canvas: Canvas) {
                if kind == .solid { canvas.lights() }
            }
            let places = [
                Placement(x: 24, y: 24, scale: 1.7, rotation: SIMD3(0, 0, 0.4)),
                Placement(x: 70, y: 28, scale: 0.6, rotation: SIMD3(0, 0, -1.1)),
                Placement(x: 36, y: 70, scale: 2.3, rotation: SIMD3(0, 0, 2.0)),
                Placement(x: 75.5, y: 72.25, scale: 1.25, rotation: SIMD3(0, 0, 0.9)),
            ]

            let placedCanvas = try makeCanvas(width: 96, height: 96)
            let placed = try picture(placedCanvas) { canvas in
                prepare(canvas)
                canvas.shape(make(canvas), at: places)
            }
            // 狙った経路を踏んでいること。三角形を積むのは頂点を並べた平面だけである
            #expect((placedCanvas.flatVerticesInLastFrame > 0) == (kind == .flat))
            let stepped = try picture(width: 96, height: 96) { canvas in
                prepare(canvas)
                let shape = make(canvas)
                for place in places {
                    // Placement の説明が名乗る形: 掛かる順は大きさ → 回転 → 位置で、
                    // 呼ぶ順に直すと translate → rotateZ → scale になる
                    canvas.push()
                    canvas.translate(place.x, place.y, place.z)
                    canvas.rotateZ(place.rotation.z)
                    canvas.scale(place.scale, place.scale, place.scale)
                    canvas.shape(shape)
                    canvas.pop()
                }
            }

            #expect(paintedCount(stepped) > 100)
            #expect(placed.bytes == stepped.bytes)
        }
    }
}
