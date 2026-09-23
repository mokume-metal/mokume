// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 光と材質と影が、**doc に書かれた式どおりの値**を作業空間に残すことの検査 ([#1381])。
/// GPU を要する。
///
/// 式は `Material.swift` と `Common.metal` (`mokume_shade`) の doc にある:
///
/// ```text
/// 出る色 = 自発光
///        + 周りへの返し · 塗り · (底上げの光の合計)
///        + (1 − 金属らしさ) · 塗り · (向きを持つ光の Lambert 合計)
///        + 艶
/// ```
///
/// 以前は幅 (150–210) か大小の比較しか見ていなかったので、式が別の式へ崩れても、向きさえ
/// 合っていれば緑のままだった。ここでは期待値を**この式から CPU で導き**、描いた値と比べる
/// ([ADR-0019] 決定 4)。実装 (`mokume_shade`) の綴りは写さない — 写すと、実装が誤っていても
/// 検査が一致してしまう。
///
/// ## 量子化の段と、完全一致で比べられる値の選び方
///
/// 読むのは描画先の値そのもの (`RenderTarget.pixelFormat` = `.rgba16Float`) で、sRGB の
/// エンコードも 8 bit の書き出しも通らない。間にある量子化は **Float16 へ書く 1 段だけ**である。
///
/// 色と光は ``LinearRGBA/linear(red:green:blue:)`` (作業空間の値そのもの) で、成分を 2 進の
/// 短い小数に取る。式が足し算と掛け算だけになる場面 — 底上げの光・正面から差す光・裏から
/// 差す光・自発光・周りへの返し・金属らしさ・影の芯 — では厳密な値が Float16 で表せるので、
/// **許す幅を置かずに完全一致で比べる**。前提 (期待値が Float16 で表せる) は照合の前に検査
/// 自身が確かめる ([#1380] と同じ作り)。前提の崩れた値を足したら、照合より先にそちらが落ちる。
///
/// ## 許す幅を置くところ
///
/// **斜めから差す光は、完全一致が原理的に取れない。** 軸に沿わない単位ベクトルは成分が 2 進の
/// 有限小数にならない (2 進小数 3 つの 2 乗の和が 1 になるのは軸の向きだけ) ので、向きの
/// 正規化 (CPU と GPU で 1 回ずつ) と N·L の内積に float32 の丸めが数 ulp 入る。点光源では、
/// 補間した世界の位置 (float32) から向きを作るぶんも入る。どれも相対で 1e−6 に届かず、
/// Float16 の 1 段 (相対でおよそ 5e−4 〜 1e−3) より 2 桁以上小さい。だから残る自由は
/// **Float16 へ書く段が、厳密な値を挟む 2 つのどちらへ落とすか**だけで、許すのは
/// 「厳密な値に最も近い Float16 から 1 段まで」(``Tolerance/oneStep``) とする。GPU の丸めが
/// 最寄りとは限らないので、最寄りだけには絞らない。
///
/// 位置で照合するもの (艶の山・影) の許し方は、それぞれの検査の説明に書く。
///
/// ## 場面
///
/// ほとんどの検査は、**面いっぱいの平らな面を奥行き 0 に置いた絵**を使う。既定の視点では
/// 奥行き 0 の面が平面の図形とぴったり重なる (`SolidTests.planeAtZeroDepthMatchesRect`) ので、
/// 画素 (x, y) の中心は世界の (x + 0.5, y + 0.5, 0) にあり、面の向きは (0, 0, 1) — 見ている
/// 側を向く。向きが画素によらず厳密に (0, 0, 1) なので、N·L は光の向きだけで決まる。
///
/// [#1380]: https://github.com/mokume-metal/mokume/issues/1380
/// [#1381]: https://github.com/mokume-metal/mokume/issues/1381
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "光と材質の式",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LightFormulaTests {
    /// 面の一辺 (画素)。
    private static let side = 64

    /// 塗りの色。成分を 3 つとも違えて、成分の取り違えも見えるようにする。
    private static let paint = RGB(0.5, 0.25, 0.75)

    // MARK: - 底上げの光と平行光

    @Test("底上げの光: 面の値が「塗り × 光」に一致する")
    func ambientLightMultipliesThePaint() throws {
        let light = RGB(1, 0.5, 0.25)
        let image = try planeImage { $0.ambientLight(light.linear) }
        try expectEverywhere(image, .exact, "塗り × 光") { _, _ in Self.paint * light }
    }

    /// 平行光の当て方。
    nonisolated struct Beam: CustomTestStringConvertible, Sendable {
        let name: String
        /// 光が**進む**向き (`directionalLight` へ渡す数)。長さ 1 でなくてよい。
        let direction: SIMD3<Double>
        let tolerance: Tolerance

        var testDescription: String { name }

        /// 面の向き (0, 0, 1) との Lambert の係数 `max(N·L, 0)`。L は面から光へ向かう向き。
        var lambert: Double { max(-normalize(direction).z, 0) }

        static let all = [
            Beam(name: "正面から (N·L = 1)", direction: SIMD3(0, 0, -1), tolerance: .exact),
            // 60° から当てる。向きを 2 通りに振り、横の成分の取り違えも見る
            Beam(
                name: "横から 60° (N·L = 0.5)", direction: SIMD3(-3.0.squareRoot() / 2, 0, -0.5),
                tolerance: .oneStep),
            Beam(
                name: "斜め上から 60° (N·L = 0.5)",
                direction: SIMD3(6.0.squareRoot() / 4, -6.0.squareRoot() / 4, -0.5),
                tolerance: .oneStep),
            // **面の裏から差す光は当たらない** (N·L が負なら 0)。負のまま足すと面が暗く沈む
            Beam(name: "裏から (N·L = −1 → 0)", direction: SIMD3(0, 0, 1), tolerance: .exact),
        ]
    }

    @Test("平行光: 面の値が「塗り × 光 × max(N·L, 0)」に一致する", arguments: Beam.all)
    func directionalLightFollowsLambert(_ beam: Beam) throws {
        // 青は 1 を超える光にしてある — **作業空間は 1.0 超を切り捨てない** (ADR-0011 決定 1)
        let light = RGB(1, 0.5, 2)
        let d = SIMD3<Float>(beam.direction)
        let image = try planeImage { $0.directionalLight(light.linear, d.x, d.y, d.z) }
        try expectEverywhere(image, beam.tolerance, "塗り × 光 × N·L (\(beam.lambert))") { _, _ in
            Self.paint * light * beam.lambert
        }
    }

    // MARK: - 点光源とスポット

    @Test("点光源: 真下の画素は「塗り × 光」、斜めの画素は N·L 倍になる")
    func pointLightFollowsLambert() throws {
        // 光源は画素 (20, 40) の中心の真上 20 に置く。面の中心からずらして、位置の取り違え
        // (縦横・符号) が対称性に隠れないようにする
        let light = RGB(1, 0.5, 2)
        let source = SIMD3<Double>(20.5, 40.5, 20)
        let image = try planeImage {
            $0.pointLight(light.linear, Float(source.x), Float(source.y), Float(source.z))
        }

        // 真下は L = (0, 0, 1) で N·L が厳密に 1 なので、完全一致で比べる
        try expectEverywhere(image, .exact, "真下: 塗り × 光", where: { $0 == 20 && $1 == 40 }) {
            _, _ in Self.paint * light
        }
        // **距離では弱めない** — 色そのものが明るさの倍率で (`Light` の doc)、Lambert の
        // 係数だけが掛かる
        let lambert: (Int, Int) -> Double = { x, y in
            let toLight = source - SIMD3(Double(x) + 0.5, Double(y) + 0.5, 0)
            return normalize(toLight).z
        }
        #expect(lambert(63, 0) < 0.5, "斜めの画素が、N·L の小さいところまで届いていない")
        try expectEverywhere(image, .oneStep, "塗り × 光 × N·L") { x, y in
            Self.paint * light * lambert(x, y)
        }
    }

    /// スポットの場面。光源は画素 (16, 32) の中心の上 24 に置き、面を 45° で斜めに照らす。
    /// 軸が面に当たるのは画素 (40, 32) の中心 (光源の真下ではない)。
    private enum Spot {
        static let position = SIMD3<Double>(16.5, 32.5, 24)
        static let direction = SIMD3<Double>(1, 0, -1)
        /// 広がりの半分の角。
        static let angle = Double.pi / 12
        static let axisPixel = (x: 40, y: 32)

        /// 画素の中心を、軸から何ラジアン外れた向きに見るか。
        static func offAxis(_ x: Int, _ y: Int) -> Double {
            let toPixel = SIMD3(Double(x) + 0.5, Double(y) + 0.5, 0) - position
            return acos(min(1, dot(normalize(toPixel), normalize(direction))))
        }
    }

    @Test("スポット: 軸の近くは同じ位置の点光源と一致し、広がりの外は 0")
    func spotLightMatchesPointLightOnItsAxis() throws {
        let light = RGB(1, 0.5, 2)
        let (p, d) = (SIMD3<Float>(Spot.position), SIMD3<Float>(Spot.direction))
        let spot = try planeImage {
            $0.spotLight(light.linear, p.x, p.y, p.z, d.x, d.y, d.z, angle: Float(Spot.angle))
        }
        let point = try planeImage { $0.pointLight(light.linear, p.x, p.y, p.z) }

        #expect(Spot.offAxis(Spot.axisPixel.x, Spot.axisPixel.y) < 1e-9)
        // **軸の近く = 広がりの半分の角の 5 分の 1 以内。** 縁は少しなめらかにする
        // (`Common.metal`) ので、縁の近くは点光源より暗くてよい。その幅は仕様に無いので、
        // 軸から十分内側だけを見る
        let (checked, differing) = differingPixels(spot, point) { x, y in
            Spot.offAxis(x, y) <= Spot.angle / 5
        }
        try #require(checked >= 1, "軸の近くの画素が 1 つも無い")
        #expect(differing.isEmpty, "軸の近くで、点光源と違う画素がある: \(differing.prefix(3))")

        // **広がりの外 = 半分の角より 0.5° 以上外。** 境目の画素は丸めでどちらにも転ぶ
        let outside: (Int, Int) -> Bool = { x, y in
            Spot.offAxis(x, y) >= Spot.angle + 0.5 * .pi / 180
        }
        // 検出力: 同じ画素を点光源は照らしている (0 なのは N·L のせいではない)
        let pointLit = pixels(where: outside).allSatisfy { point[$0.x, $0.y].red > 0 }
        try #require(pointLit, "広がりの外の画素を、点光源も照らしていない")
        try expectEverywhere(spot, .exact, "広がりの外は 0", where: outside) { _, _ in .black }
    }

    // MARK: - ひととおりの光

    @Test("lights(): 説明にある 2 つの光を手で並べた絵と、バイト単位で一致する")
    func lightsIsTheDocumentedPair() throws {
        // **比べる相手は `Sketch.lights()` の説明** — 底上げが線形で 0.35、平行光が線形で
        // 0.85、向きが (−0.35, 0.75, −0.55)。球に当てて、向きが絵に出るようにする
        func sphere(_ lights: (Canvas) -> Void) throws -> [UInt16] {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.side, height: Self.side)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                lights(canvas)
                canvas.fill(Self.paint.linear)
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.sphere(26)
                canvas.pop()
            }
            return try canvas.target.readPixels().components.map(\.bitPattern)
        }
        func byHand(_ z: Float) -> (Canvas) -> Void {
            {
                $0.ambientLight(.linear(red: 0.35, green: 0.35, blue: 0.35))
                $0.directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.35, 0.75, z)
            }
        }

        let builtIn = try sphere { $0.lights() }
        let documented = try sphere(byHand(-0.55))
        #expect(builtIn == documented, "lights() が説明の組と違う絵を出す")
        // 検出力: 向きを 1 成分だけ変えた組とは一致しない (一致するなら、この場面は向きを写していない)
        let nudged = try sphere(byHand(-0.5))
        try #require(nudged != documented, "向きを変えても絵が動かない")
    }

    // MARK: - 材質

    @Test("自発光: 光の当たらない面は emissive そのもの、当たる面では「塗り × 光」に足される")
    func emissiveIsAddedAsIs() throws {
        let glow = RGB(0.25, 0.5, 0.125)
        // **光は置くが、面の裏から差す。** 光も周囲も置かないと材質は効かない
        // (面は塗りのまま出る・`Material.unusableReason` の `.noLight`)
        let unlit = try planeImage {
            $0.directionalLight(.linear(red: 1, green: 1, blue: 1), 0, 0, 1)
            $0.emissive(glow.linear)
        }
        try expectEverywhere(unlit, .exact, "光の当たらない面 = 自発光") { _, _ in glow }

        let light = RGB(0.5, 0.5, 0.5)
        let lit = try planeImage {
            $0.directionalLight(light.linear, 0, 0, -1)
            $0.emissive(glow.linear)
        }
        try expectEverywhere(lit, .exact, "自発光 + 塗り × 光") { _, _ in glow + Self.paint * light }
    }

    @Test("周りへの返しを線形で 0.5 にすると、底上げの光の寄与だけがちょうど半分になる")
    func ambientResponseHalvesOnlyTheAmbientLight() throws {
        let surroundings = RGB(1, 0.5, 0.25)
        let direct = RGB(0.25, 0.25, 0.25)
        func image(response: RGB?) throws -> PixelBuffer {
            try planeImage {
                $0.ambientLight(surroundings.linear)
                $0.directionalLight(direct.linear, 0, 0, -1)
                if let response { $0.ambient(response.linear) }
            }
        }
        // 既定 (白) は全部返す
        try expectEverywhere(try image(response: nil), .exact, "塗り × (底上げ + 直接)") { _, _ in
            Self.paint * (surroundings + direct)
        }
        // **直接の光は半分にならない** — 周りへの返しが掛かるのは底上げの光だけ
        let half = RGB(0.5, 0.5, 0.5)
        try expectEverywhere(
            try image(response: half), .exact, "塗り × (0.5 · 底上げ + 直接)"
        ) { _, _ in Self.paint * (surroundings * 0.5 + direct) }
    }

    @Test("金属らしさ: shininess(0) のとき、直接の光の寄与が (1 − m) 倍になる", arguments: [0, 0.25, 0.5, 1])
    func metalnessScalesOnlyTheDirectLight(_ metalness: Double) throws {
        let surroundings = RGB(0.25, 0.25, 0.25)
        let direct = RGB(1, 1, 1)
        let image = try planeImage {
            $0.ambientLight(surroundings.linear)
            $0.directionalLight(direct.linear, 0, 0, -1)
            $0.shininess(0)
            $0.metalness(Float(metalness))
        }
        // **底上げの光は (1 − m) 倍にならない** — 一様な周りを拡散するのと映すのは同じ式に
        // なるので、金属でも塗りの色で返る (`Material` の doc の「金属が映すもの」)
        try expectEverywhere(image, .exact, "塗り × (底上げ + (1 − \(metalness)) · 直接)") { _, _ in
            Self.paint * (surroundings + direct * (1 - metalness))
        }
    }

    // MARK: - 艶の山の位置

    /// 艶を見る点光源の置き場所。
    nonisolated struct Glint: CustomTestStringConvertible, Sendable {
        let source: SIMD3<Double>
        var testDescription: String { "光源 (\(source.x), \(source.y), \(source.z))" }

        static let all = [
            Glint(source: SIMD3(8, 50, 30)),
            Glint(source: SIMD3(10, 14, 24)),
            Glint(source: SIMD3(56, 16, 30)),
        ]
    }

    /// 艶の山は、**視点と光源を面で折り返した点**に立つ。
    ///
    /// 面を鏡とみなせば、視点から見て光源が映る点は、視点と「面で折り返した光源」を結ぶ線が
    /// 面を横切る点である (鏡面反射の向き)。そこで面の向きと半分の向き (光へ向かう向きと
    /// 目へ向かう向きの和) が重なり、分布 (GGX) が最大になる。これを CPU で求め、描いた絵の
    /// いちばん明るい画素と比べる。
    ///
    /// **塗りは黒にする。** 拡散が 0 になり、絵に残るのは艶だけになる (非金属の映り込みの色は
    /// 塗りによらない)。拡散の山は光源の真下に立つので、塗りがあると山の位置が混ざる。
    ///
    /// ## 許す幅
    ///
    /// 比べるのは画素の番号で、**折り返した点を含む画素が、いちばん明るい画素であること**を
    /// 求める。山の位置を動かしうるのは、分布の外で緩やかに変わる因子 (遮り合い・見る角での
    /// 映り込みの強さ・`1 / N·V`) だけで、`shininess(50)` の山の鋭さに対してはずれが 0.01 画素に
    /// 届かない (式を CPU で 0.01 画素刻みに評価して確かめた)。そこで光源は、折り返した点が画素の
    /// 縁から 0.25 画素以上内側に落ちる位置を選び、その前提を検査自身が確かめる。
    ///
    /// **艶の鋭さは 50 に留める。** およそ 80 を超えると、分布の分母の下限 (`Common.metal` の
    /// `max(…, 1e-6)`) が山の頂を平らに削り、頂の中の最大が緩やかな因子に引かれて 1 画素ほど
    /// ずれる ([#1407])。
    ///
    /// [#1407]: https://github.com/mokume-metal/mokume/issues/1407
    @Test("艶の山は、視点と光源を面で折り返した点に立つ", arguments: Glint.all)
    func highlightSitsAtTheMirrorPoint(_ glint: Glint) throws {
        let eye = SIMD3<Double>(Camera.fitting(width: Float(Self.side), height: Float(Self.side)).eye)
        let source = glint.source
        // 面 z = 0 で折り返した光源と視点を結ぶ線が、面を横切る点
        let mirrored = SIMD3(source.x, source.y, -source.z)
        let t = eye.z / (eye.z - mirrored.z)
        let mirror = eye + (mirrored - eye) * t
        let expected = (x: Int(mirror.x.rounded(.down)), y: Int(mirror.y.rounded(.down)))

        let inset = min(
            mirror.x - Double(expected.x), Double(expected.x + 1) - mirror.x,
            mirror.y - Double(expected.y), Double(expected.y + 1) - mirror.y)
        try #require(inset >= 0.25, "折り返した点 \(mirror) が画素の縁に近すぎる")
        // 検出力: 光源の真下 (半分の向きを光の向きで代えた式の山) からも、視点の真下
        // (目の向きで代えた式の山) からも 3 画素以上離れている
        func apart(_ a: (x: Int, y: Int), _ b: SIMD3<Double>) -> Int {
            max(abs(a.x - Int(b.x.rounded(.down))), abs(a.y - Int(b.y.rounded(.down))))
        }
        try #require(apart(expected, source) >= 3, "折り返した点が光源の真下に近すぎる")
        try #require(apart(expected, eye) >= 3, "折り返した点が視点の真下に近すぎる")

        let s = SIMD3<Float>(source)
        let image = try planeImage(paint: .black) {
            $0.shininess(50)
            $0.pointLight(.linear(red: 1, green: 1, blue: 1), s.x, s.y, s.z)
        }
        var brightest = (x: -1, y: -1, value: -Float.infinity)
        for (x, y) in pixels(where: { _, _ in true }) where image[x, y].red > brightest.value {
            brightest = (x, y, image[x, y].red)
        }
        #expect(brightest.value > 0, "艶が出ていない")
        #expect(
            brightest.x == expected.x && brightest.y == expected.y,
            "いちばん明るい画素が (\(brightest.x), \(brightest.y)) — 折り返した点 (\(mirror.x), \(mirror.y)) の画素は (\(expected.x), \(expected.y))"
        )
    }

    // MARK: - 影

    /// 影の場面。影を受ける床 (奥行き 0 の面) の上に、影を落とす板を 1 枚浮かせる。
    ///
    /// 視点は平行投影にする — 浮かせた板が画面のどこを隠すかが板の縦横そのままになり、
    /// 床の画素と世界の位置の対応 (画素の中心 = (x + 0.5, y + 0.5, 0)) も透視と変わらない。
    private enum ShadowScene {
        /// 光が**進む**向き。面の向きとの N·L は 2/3。
        static let direction = SIMD3<Double>(1, 0.5, -1)
        /// 板の中心 (x, y)・半分の幅・床からの高さ。
        static let occluderCenter = SIMD2<Double>(12, 14)
        static let occluderHalf = 10.0
        static let occluderHeight = 24.0
        /// 焼き付ける範囲の一辺。**明示して**、焼き付けの 1 画素の大きさを検査が知る。
        static let range = 96.0
        static let surroundings = RGB(0.25, 0.25, 0.25)
        static let direct = RGB(1, 1, 1)
        static let floorPaint = RGB(0.5, 0.75, 1)

        static var toLight: SIMD3<Double> { -normalize(direction) }

        /// 床の点 (x, y, 0) から光へ向かう線が、板の高さで**板の内側をどれだけ通るか**
        /// (床の長さ・縦横それぞれの縁までの近いほう)。正なら影の中、負なら外。
        ///
        /// **光線を CPU で床へ投影した位置**を、逆向きに辿って求めている。
        static func depthInShadow(_ x: Double, _ y: Double) -> Double {
            let reach = occluderHeight / toLight.z
            let crossing = SIMD2(x, y) + SIMD2(toLight.x, toLight.y) * reach
            let offset = abs(crossing - occluderCenter)
            return occluderHalf - max(offset.x, offset.y)
        }

        /// 影の縁が、投影した縁からどれだけ滲みうるか (床の長さ)。
        ///
        /// 読む側は半画素ずらした 4 点を bilinear で比べる (`mokume_shadowFactor`) ので、
        /// 1 点の結果には焼き付けの画素で **±1.5 画素**の範囲が混ざる。焼いた縁そのものも
        /// 画素の中心で切れるので **±0.5 画素**ずれる。焼き付けは光に垂直な面なので、床の上では
        /// 最大 `1 / N·L` 倍に伸びる。画面の画素の中心の取り方の分として 1 画素を足す。
        static func margin(detail: Int) -> Double {
            let texel = range / Double(detail)
            return 2 * texel / toLight.z + 1
        }

        /// 板が画面で隠す画素か (平行投影なので、板の縦横そのまま。縁に 1 画素の余裕を取る)。
        static func hiddenByOccluder(_ x: Int, _ y: Int) -> Bool {
            let offset = abs(SIMD2(Double(x) + 0.5, Double(y) + 0.5) - occluderCenter)
            return max(offset.x, offset.y) <= occluderHalf + 1
        }
    }

    /// 影の場面を描く。
    private func shadowImage(
        shadows: Bool, detail: Int? = nil, occluder: Bool = true, floorCasts: Bool = false
    ) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.side, height: Self.side)
        let d = SIMD3<Float>(ShadowScene.direction)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.ortho()
            canvas.ambientLight(ShadowScene.surroundings.linear)
            canvas.directionalLight(ShadowScene.direct.linear, d.x, d.y, d.z)
            canvas.shadows(shadows)
            canvas.shadowRange(Float(ShadowScene.range))
            if let detail { canvas.shadowDetail(detail) }

            canvas.castShadow(floorCasts)
            canvas.fill(ShadowScene.floorPaint.linear)
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.plane(64, 64)
            canvas.pop()

            if occluder {
                canvas.castShadow(true)
                canvas.fill(.linear(red: 0.5, green: 0.5, blue: 0.5))
                canvas.push()
                let center = SIMD2<Float>(ShadowScene.occluderCenter)
                canvas.translate(center.x, center.y, Float(ShadowScene.occluderHeight))
                let width = Float(ShadowScene.occluderHalf * 2)
                canvas.plane(width, width)
                canvas.pop()
            }
        }
        return try canvas.target.readPixels()
    }

    /// 影の芯 = 投影した影の縁から、滲みうる幅より内側にある床の画素。
    private static func isCore(detail: Int) -> (Int, Int) -> Bool {
        { x, y in
            ShadowScene.depthInShadow(Double(x) + 0.5, Double(y) + 0.5)
                >= ShadowScene.margin(detail: detail)
        }
    }

    /// 影の外 = 投影した影の縁から、滲みうる幅より外にあり、板にも隠れていない床の画素。
    private static func isOutside(detail: Int) -> (Int, Int) -> Bool {
        { x, y in
            ShadowScene.depthInShadow(Double(x) + 0.5, Double(y) + 0.5)
                <= -ShadowScene.margin(detail: detail) && !ShadowScene.hiddenByOccluder(x, y)
        }
    }

    @Test("影の芯は「底上げだけの値」に一致する")
    func shadowCoreKeepsOnlyTheAmbientLight() throws {
        // **影が減衰させるのは直接の光だけ** (`mokume_shade` の doc)。芯では直接の光が 0 に
        // なるので、残るのは 塗り × 底上げ の光で、足し算と掛け算だけの値になる
        let image = try shadowImage(shadows: true)
        let core = Self.isCore(detail: ShadowMap.defaultDetail)
        try #require(pixels(where: core).count >= 100, "影の芯の画素が少なすぎる")
        try expectEverywhere(image, .exact, "塗り × 底上げ", where: core) { _, _ in
            ShadowScene.floorPaint * ShadowScene.surroundings
        }
    }

    @Test("影は、光線を床へ投影した位置に落ちる")
    func shadowFallsWhereTheLightIsBlocked() throws {
        let lit = try shadowImage(shadows: false)
        let shadowed = try shadowImage(shadows: true)
        let detail = ShadowMap.defaultDetail

        // 芯はすべて影に入っている (影なしの絵より暗い)
        let core = pixels(where: Self.isCore(detail: detail))
        let unshadowedCore = core.filter { shadowed[$0.x, $0.y].red >= lit[$0.x, $0.y].red }
        #expect(unshadowedCore.isEmpty, "投影した影の中なのに暗くない画素: \(unshadowedCore.prefix(3))")

        // 外はすべて影なしの絵と同じ
        let (checked, differing) = differingPixels(shadowed, lit, where: Self.isOutside(detail: detail))
        try #require(checked >= 1000, "影の外の画素が少なすぎる")
        #expect(differing.isEmpty, "投影した影の外なのに、影なしの絵と違う画素: \(differing.prefix(3))")
    }

    @Test("遮るものが無ければ、影の有無で絵が変わらない (自分の影の縞が出ない)")
    func aLoneFloorCastsNoStripesOnItself() throws {
        // **床自身も影を落とす側に入れる。** 自分の影の縞は、焼いた奥行きと自分の奥行きを
        // 比べる丸めから出る — 落とす側に入っていなければ比べる相手が無く、何も見ていない。
        // 縞を抑えるのは `shadowBias` (既定の量) と、斜めの面ほど足す余裕である
        let without = try shadowImage(shadows: false, occluder: false, floorCasts: true)
        let with = try shadowImage(shadows: true, occluder: false, floorCasts: true)
        let (checked, differing) = differingPixels(with, without) { _, _ in true }
        #expect(checked == Self.side * Self.side)
        #expect(differing.isEmpty, "遮るものが無いのに影の有無で違う画素 \(differing.count) 個: \(differing.prefix(3))")
    }

    @Test("影の細かさを変えても、影の芯と外の画素は変わらない", arguments: [64, 256, 4096])
    func shadowDetailOnlyMovesTheEdge(_ detail: Int) throws {
        // 細かさが変えるのは縁の滲み方だけ。**芯と外は細かさによらない** — 縁の幅は粗いほうで
        // 見積もるので、比べる画素はどちらの細かさでも芯か外に入っている
        let reference = try shadowImage(shadows: true)
        let changed = try shadowImage(shadows: true, detail: detail)
        let coarsest = min(detail, ShadowMap.defaultDetail)

        let core = Self.isCore(detail: coarsest)
        let outside = Self.isOutside(detail: coarsest)
        let coreResult = differingPixels(changed, reference, where: core)
        let outsideResult = differingPixels(changed, reference, where: outside)
        try #require(coreResult.checked >= 16, "粗いほうでも芯と言える画素が少なすぎる")
        try #require(outsideResult.checked >= 1000)
        #expect(coreResult.differing.isEmpty, "芯の画素が動いた: \(coreResult.differing.prefix(3))")
        #expect(outsideResult.differing.isEmpty, "外の画素が動いた: \(outsideResult.differing.prefix(3))")
    }

    // MARK: - 道具

    /// 面いっぱいの平らな面を 1 枚、奥行き 0 に置いた絵の、作業空間の値。
    private func planeImage(paint: RGB = LightFormulaTests.paint, _ scene: (Canvas) -> Void) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.side, height: Self.side)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()  // 面の値だけを見る (線は既定で有効なので止める)
            scene(canvas)
            canvas.fill(paint.linear)
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.plane(64, 64)
            canvas.pop()
        }
        return try canvas.target.readPixels()
    }

    /// 期待値との比べ方。
    nonisolated enum Tolerance: Sendable {
        /// 許す幅を置かない。期待値は Float16 で表せなければならない。
        case exact
        /// 期待値に最も近い Float16 から 1 段まで (型の説明の「許す幅を置くところ」)。
        case oneStep
    }

    /// 絵のうち `region` の画素を、期待値と成分ごとに比べる。不透明度は 1 でなければならない。
    private func expectEverywhere(
        _ image: PixelBuffer, _ tolerance: Tolerance, _ what: String,
        where region: (Int, Int) -> Bool = { _, _ in true },
        sourceLocation: SourceLocation = #_sourceLocation,
        expected: (Int, Int) -> RGB
    ) throws {
        var checked = 0
        var failures: [String] = []
        for (x, y) in pixels(where: region) {
            let want = expected(x, y)
            let pixel = image[x, y]
            checked += 1
            let drawn = [pixel.red, pixel.green, pixel.blue]
            if tolerance == .exact {
                // **前提: 式の厳密な値が Float16 で表せる。** 表せない値では描画先へ書くときに
                // 丸めが入り、完全一致で比べる根拠が無くなる
                for value in want.components {
                    try #require(
                        Double(Float16(value)) == value,
                        "期待値 \(value) が Float16 で表せない — 値の選び方の前提が崩れている",
                        sourceLocation: sourceLocation)
                }
            }
            let fits = zip(drawn, want.components).allSatisfy { Self.fits($0, $1, tolerance) }
            if !fits || pixel.alpha != 1 {
                failures.append("(\(x), \(y)) が \(drawn) / \(pixel.alpha) — 式からは \(want.components)")
            }
        }
        try #require(checked > 0, "比べる画素が 1 つも無い", sourceLocation: sourceLocation)
        #expect(
            failures.isEmpty,
            "\(what): \(checked) 画素のうち \(failures.count) 画素が合わない。\(failures.prefix(3))",
            sourceLocation: sourceLocation)
    }

    private static func fits(_ drawn: Float, _ expected: Double, _ tolerance: Tolerance) -> Bool {
        switch tolerance {
        case .exact:
            return Double(drawn) == expected
        case .oneStep:
            let nearest = Float16(expected)
            let value = Float16(drawn)
            return value == nearest || value == nearest.nextUp || value == nearest.nextDown
        }
    }

    /// 2 枚の絵のうち `region` の画素を、**ビット単位で**比べる。
    private func differingPixels(
        _ a: PixelBuffer, _ b: PixelBuffer, where region: (Int, Int) -> Bool
    ) -> (checked: Int, differing: [String]) {
        var checked = 0
        var differing: [String] = []
        for (x, y) in pixels(where: region) {
            checked += 1
            let base = (y * a.width + x) * 4
            let left = a.components[base..<base + 4].map(\.bitPattern)
            let right = b.components[base..<base + 4].map(\.bitPattern)
            if left != right {
                differing.append("(\(x), \(y)): \(a[x, y]) と \(b[x, y])")
            }
        }
        return (checked, differing)
    }

    /// 面の画素のうち `region` に入るもの。
    private func pixels(where region: (Int, Int) -> Bool) -> [(x: Int, y: Int)] {
        var found: [(x: Int, y: Int)] = []
        for y in 0..<Self.side {
            for x in 0..<Self.side where region(x, y) { found.append((x, y)) }
        }
        return found
    }

    /// 期待値を組むための色。**倍精度で持つ** — 期待値の計算そのものに丸めを持ち込まない。
    nonisolated struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            (self.red, self.green, self.blue) = (red, green, blue)
        }

        static let black = RGB(0, 0, 0)

        var components: [Double] { [red, green, blue] }

        /// 作業空間の値そのものとして渡す色。
        @MainActor var linear: LinearRGBA {
            .linear(red: Float(red), green: Float(green), blue: Float(blue))
        }

        static func * (a: RGB, b: RGB) -> RGB { RGB(a.red * b.red, a.green * b.green, a.blue * b.blue) }
        static func * (a: RGB, s: Double) -> RGB { RGB(a.red * s, a.green * s, a.blue * s) }
        static func + (a: RGB, b: RGB) -> RGB { RGB(a.red + b.red, a.green + b.green, a.blue + b.blue) }
    }
}
