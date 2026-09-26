// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// **断片の `mokume_noiseGradient` が、`mokume_noise` の返す値そのものの傾きになっている**
/// ことを見る ([#1141])。
///
/// ## 照合相手は独立した経路に置く
///
/// 傾きの式と比べる相手を同じ `Common.metal` の中に置くと、同じ式どうしの比較になる
/// ([#1388] と同じ罠)。ここでは CPU の揺らぎを**作者が呼ぶ口** (``Canvas/noise(_:_:_:)``)
/// から引き、差分で傾きを作って比べる。CPU と断片の値が一致することは `NoiseParityTests`
/// が見ているので、ここで一致すれば、断片の傾きは断片の値の傾きでもある。
///
/// ## 差分は 5 点で取る — 刻みによる誤差が 0 になる
///
/// 1 枚ぶんの揺らぎは、格子の 1 マスの中で 1 つの軸に沿って見ると **3 次式**である
/// (繋ぎの重み `3t² − 2t³` が 3 次で、残りの軸の重みは定数)。重ねた揺らぎも、**どの枚でも
/// 同じマスの中に留まる**なら 3 次式の和なので 3 次式のままである。5 点の中心差分は 4 次式
/// まで厳密なので、刻みによる誤差 (打ち切り誤差) は消え、残るのは値の丸めだけになる。
///
/// 丸めは刻みで割られて効くので、刻みは広いほど細かく比べられる。いちばん細かい枚の
/// 1 マスの 1/8 に取る (``step(octaves:)``)。比べる座標は、どの枚でもマスの縁から離れた所に
/// 選んである (``places``)。差分がマスを跨いでいないかは、比べる前に毎回確かめる
/// (``staysInOneCell(_:octaves:)``) — 跨ぐと 3 次式でなくなり、照合相手のほうが狂う。
///
/// ## 読み戻す精度
///
/// `NoiseParityTests` と同じく、描き先は半精度なので断片には**差そのもの**を返させる。
///
/// ## 許容
///
/// 残る誤差は CPU の値の丸め (最下位ビット数個) を刻みで割ったものなので、**いちばん細かい
/// 枚の倍率に比例して広がる** (刻みが倍率に反比例するため)。だから許容も倍率に比例させる
/// (``tolerance(octaves:)``)。
///
/// 実測の最大は、1 枚で 4.2e-7、6 枚 (いちばん細かい枚の倍率が 32) で 2.1e-5 だった。
/// 倍率あたりに直すと 6.6e-7 で、``tolerancePerFrequency`` はそのおよそ 8 倍に置いてある。
///
/// 見逃したくない食い違いはこれより桁が大きい。式を 1 か所ずつ壊して測ると、「層ごとに倍率を
/// 掛けない」で 0.1〜0.26、「重ねた合計で割らない」で 0.3〜0.4、「枚ごとの種のずらし方が値と
/// 食い違う」で 0.6〜0.8、1 枚の設定で「x の差を混ぜる重みを取り違える」で 1.7e-4〜2.9e-2
/// ずれた。**最初の 2 つは 1 枚では見えない** (倍率も合計も 1) ので、複数枚の設定を並べてある。
///
/// [#1141]: https://github.com/mokume-metal/mokume/issues/1141
/// [#1388]: https://github.com/mokume-metal/mokume/issues/1388
@Suite(
    "断片で引く揺らぎの傾き",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct NoiseGradientTests {
    /// いちばん細かい枚の倍率 1 あたりの許容。
    nonisolated static let tolerancePerFrequency: Float = 5e-6

    /// その枚数での許容。**細かい枚の倍率に比例させる** (冒頭の「許容」)。
    nonisolated static func tolerance(octaves: Int) -> Float {
        tolerancePerFrequency * finestFrequency(octaves: octaves)
    }

    /// いちばん細かい枚の倍率。
    nonisolated static func finestFrequency(octaves: Int) -> Float {
        Float(1 << (max(octaves, 1) - 1))
    }

    /// 差分の刻み。いちばん細かい枚の 1 マスの 1/8 (2 の冪なので、座標に足しても丸まらない)。
    nonisolated static func step(octaves: Int) -> Float {
        1 / (8 * finestFrequency(octaves: octaves))
    }

    /// 比べる座標。**原点の近く・負の側・遠く**を並べる。
    ///
    /// どの成分も、倍率 1・4・8・32 のどれで見てもマスの内側 0.3…0.7 に来るよう選んだ
    /// (刻みの 2 倍ぶん外へ出ても、マスを跨がない)。
    nonisolated static let places: [SIMD3<Float>] = [
        SIMD3(0.33, 0.42, 0.58),
        SIMD3(1.67, 2.33, 3.42),
        SIMD3(-0.42, -1.33, -2.67),
        SIMD3(-12.58, 45.33, -78.42),
        SIMD3(1234.42, -6789.58, 42.67),
    ]

    /// 重ねる枚数と弱まり。**1 枚と、複数枚 (弱まり 0 でない) の両方**を並べる。
    nonisolated static let details: [(octaves: Int, falloff: Float)] = [
        (1, 0.5), (4, 0.5), (3, 0.8), (6, 0.35),
    ]

    /// 断片が返すのは、CPU から作った傾きとの**差そのもの**。
    private static let comparison = """
        float4 paint(Fragment in, Values values) {
            float3 mine = mokume_noiseGradient(in, float3(values.place, values.depth));
            float3 expected = float3(values.dx, values.dy, values.dz);
            return float4(abs(mine - expected), 1.0);
        }
        """

    /// 断片が返す傾きの大きさ (符号は落とす)。
    private static let magnitude = """
        float4 paint(Fragment in, Values values) {
            return float4(abs(mokume_noiseGradient(in, float3(values.place, values.depth))), 1.0);
        }
        """

    /// 差分の 5 点が、どの枚でも同じマスに収まるか。
    static func staysInOneCell(_ place: SIMD3<Float>, octaves: Int) -> Bool {
        let reach = 2 * step(octaves: octaves)
        for octave in 0..<octaves {
            let frequency = Float(1 << octave)
            for axis in 0..<3 {
                let low = ((place[axis] - reach) * frequency).rounded(.down)
                let high = ((place[axis] + reach) * frequency).rounded(.down)
                if low != high { return false }
            }
        }
        return true
    }

    /// CPU の `noise()` を作者の口から引き、5 点の中心差分で作った傾き。
    private static func difference(
        of canvas: Canvas, at place: SIMD3<Float>, octaves: Int
    ) -> SIMD3<Float> {
        let h = step(octaves: octaves)
        var slope = SIMD3<Float>()
        for axis in 0..<3 {
            func noise(_ offset: Float) -> Float {
                var moved = place
                moved[axis] += offset
                return canvas.noise(moved.x, moved.y, moved.z)
            }
            let far = noise(-2 * h) - noise(2 * h)
            let near = noise(h) - noise(-h)
            slope[axis] = (far + 8 * near) / (12 * h)
        }
        return slope
    }

    /// 描いて、真ん中の画素の 3 成分を読む。
    private static func read(_ canvas: Canvas, with shader: Shader) throws -> SIMD3<Float> {
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.blendMode(.replace)
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 8, 8)
        }
        let pixel = canvas.get(4, 4)
        return SIMD3(pixel.red, pixel.green, pixel.blue)
    }

    private static func makeCanvas(seed: Int, octaves: Int, falloff: Float) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        canvas.noiseSeed(seed)
        canvas.noiseDetail(octaves, falloff)
        return canvas
    }

    @Test(
        "傾きが、CPU の揺らぎの差分と一致する",
        arguments: NoiseGradientTests.details, [0, 5, 20260829])
    func theGradientMatchesTheDifference(
        _ detail: (octaves: Int, falloff: Float), _ seed: Int
    ) throws {
        let canvas = try Self.makeCanvas(seed: seed, octaves: detail.octaves, falloff: detail.falloff)
        let shader = try canvas.makeShader(
            Self.comparison,
            values: [
                "place": .pair(0, 0), "depth": .number(0),
                "dx": .number(0), "dy": .number(0), "dz": .number(0),
            ])
        let tolerance = Self.tolerance(octaves: detail.octaves)

        for place in Self.places {
            try #require(
                Self.staysInOneCell(place, octaves: detail.octaves),
                "\(place) は差分が格子のマスを跨ぐ (照合相手が 3 次式でなくなる)")
            let expected = Self.difference(of: canvas, at: place, octaves: detail.octaves)
            shader.set("place", .pair(place.x, place.y))
            shader.set("depth", .number(place.z))
            shader.set("dx", .number(expected.x))
            shader.set("dy", .number(expected.y))
            shader.set("dz", .number(expected.z))

            let gap = try Self.read(canvas, with: shader)
            #expect(
                gap.max() < tolerance,
                "\(detail.octaves) 枚 / 弱まり \(detail.falloff) / 種 \(seed) の \(place) で \(gap) ずれている (差分は \(expected))")
        }
    }

    @Test("整数の座標では、その軸の傾きがちょうど 0 になる", arguments: [1, 4, 6])
    func integerPlacesAreFlatAlongThatAxis(_ octaves: Int) throws {
        // 層の倍率は 2 の冪なので、整数の座標はどの枚でも格子の上にあり、繋ぎの重みの
        // 傾きがそこで 0 になる
        let canvas = try Self.makeCanvas(seed: 3, octaves: octaves, falloff: 0.5)
        let shader = try canvas.makeShader(
            Self.magnitude, values: ["place": .pair(0, 0), "depth": .number(0)])

        let places: [SIMD3<Float>] = [SIMD3(3, 0.42, 0.58), SIMD3(-7, 45.33, -2.67)]
        for place in places {
            shader.set("place", .pair(place.x, place.y))
            shader.set("depth", .number(place.z))
            let slope = try Self.read(canvas, with: shader)
            #expect(slope.x == 0, "\(octaves) 枚の \(place) で ∂/∂x が \(slope.x)")
            #expect(slope.y != 0, "\(octaves) 枚の \(place) で ∂/∂y まで 0 になった")
        }
    }

    @Test("扱える範囲の外に張り付いた軸は、傾きが 0 になる")
    func placesBeyondTheLimitAreFlat() throws {
        // 外では値が端に張り付いて動かないので、傾きも 0 でなければ値と食い違う。
        // 座標は格子の間に置く (整数だと、張り付かなくても繋ぎの重みの傾きが 0 になる)
        let canvas = try Self.makeCanvas(seed: 3, octaves: 4, falloff: 0.5)
        let shader = try canvas.makeShader(
            Self.magnitude,
            values: ["place": .pair(2_500_000.25, -3_000_000.75), "depth": .number(0.58)])
        let slope = try Self.read(canvas, with: shader)
        #expect(slope.x == 0 && slope.y == 0, "範囲の外の軸で傾きが \(slope)")
        #expect(slope.z != 0, "範囲の内側の軸まで傾きが 0 になった")
    }

    @Test("2 次元・1 次元の口は、3 次元の口で省いた軸を 0 にしたものと一致する")
    func lowerDimensionsProjectTheFullGradient() throws {
        let canvas = try Self.makeCanvas(seed: 9, octaves: 4, falloff: 0.5)
        let flat = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                float2 mine = mokume_noiseGradient(in, values.place);
                float2 full = mokume_noiseGradient(in, float3(values.place, values.depth)).xy;
                return float4(abs(mine - full), 0.0, 1.0);
            }
            """,
            values: ["place": .pair(0, 0), "depth": .number(0)])
        let line = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                float mine = mokume_noiseGradient(in, values.place.x);
                float full = mokume_noiseGradient(in, float3(values.place.x, values.rest)).x;
                return float4(abs(mine - full), 0.0, 0.0, 1.0);
            }
            """,
            values: ["place": .pair(0, 0), "rest": .pair(0, 0)])
        let tolerance = Self.tolerance(octaves: 4)

        for place in Self.places {
            flat.set("place", .pair(place.x, place.y))
            line.set("place", .pair(place.x, place.y))

            flat.set("depth", .number(0))
            line.set("rest", .pair(0, 0))
            #expect(try Self.read(canvas, with: flat).max() < tolerance, "2 次元の \(place)")
            #expect(try Self.read(canvas, with: line).max() < tolerance, "1 次元の \(place)")

            // **比べた座標が、省いた軸を 0 以外で埋めたら見分けのつく場所であること。**
            // 軸を動かしても傾きが変わらない座標では、埋め方が壊れても上の一致は崩れない
            // (#1402 が `omittedAxesAreZero` に入れたのと同じ手当て)
            flat.set("depth", .number(1))
            #expect(
                try Self.read(canvas, with: flat).max() > tolerance,
                "2 次元の \(place) は z を 1 で埋めても傾きが変わらない")
            for rest in [SIMD2<Float>(1, 0), SIMD2(0, 1)] {
                line.set("rest", .pair(rest.x, rest.y))
                #expect(
                    try Self.read(canvas, with: line).max() > tolerance,
                    "1 次元の \(place) は残りの軸を \(rest) で埋めても傾きが変わらない")
            }
        }
    }
}
