// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// **CPU で引いた揺らぎと、断片で引いた揺らぎが同じ値になる**ことを見る。
///
/// ## なぜ要るか
///
/// 揺らぎの式は 2 か所にある — Swift の ``ValueNoise`` と `Common.metal` の
/// `mokume_noise`。同じ内容の二重管理は [ADR-0001] 原則 9 が禁じているが、CPU と
/// GPU で同じ式を走らせるのに、1 本の原稿から両方を作る手立ては無い。
///
/// **だから食い違いを機械が見る。** 制作の側では実際にこれが起き、木目を面と立体で
/// 出そうとして 2 つの揺らぎが別物になっていた ([#366])。片方を直したらもう片方も
/// 直すことになる、という規律を文書ではなくこの検査に持たせている。
///
/// ## 読み戻す精度
///
/// 描き先は `rgba16Float` (半精度) なので、値をそのまま読むと 1e-3 くらいで丸まって
/// **実装の食い違いと区別できない**。そこで断片には**差そのもの**を返させる — 半精度
/// でも 0 の近くは 6e-8 ほどの刻みがあるので、増幅しなくても十分に細かく読める。
///
/// ## 許容
///
/// 格子点の値は整数演算だけで作るのでビット単位で一致する。差が出るのは繋ぎと
/// 重ね合わせの浮動小数だけで、Metal は既定で fast-math (融合・順序の入れ替えが
/// 起きうる) なので最下位ビットぶんは動く。
///
/// **実測の最大は 1.19e-7 (`Float` の 1 ulp) だった。** ``tolerance`` はその 8 倍に
/// 置いてある — 桁を余らせすぎると、式の食い違いを見逃す側の検査になる。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
/// [#366]: https://github.com/mokume-metal/mokume/issues/366
@Suite(
    "CPU と断片で同じ揺らぎが出る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct NoiseParityTests {
    /// 許される食い違い。
    nonisolated static let tolerance: Float = 1e-6

    /// 突き合わせる座標。**格子の上・格子の間・負の側・遠く**を並べる。
    ///
    /// 格子の上を入れるのは、繋ぎの重みが 0 と 1 のちょうどで一致するかを見るため。
    /// 負の側を入れるのは、切り下げと符号なしへの変換が両側で同じかを見るため
    /// (ここが食い違うと、原点の片側だけ模様が別物になる)。
    nonisolated static let places: [SIMD3<Float>] = [
        SIMD3(0, 0, 0),
        SIMD3(1, 2, 3),
        SIMD3(0.5, 0.5, 0.5),
        SIMD3(3.25, 7.75, 1.125),
        SIMD3(-1, -2, -3),
        SIMD3(-0.5, -0.25, -0.125),
        SIMD3(-12.3, 45.6, -78.9),
        SIMD3(1234.5, -6789.25, 42.0625),
        SIMD3(99999.5, 0, 0),
    ]

    /// 断片が返すのは**差そのもの**。塗りの色も光も混ぜないよう、置き換えて描く。
    private static let comparison = """
        float4 paint(Fragment in, Values values) {
            float mine = mokume_noise(in, float3(values.place, values.depth));
            return float4(abs(mine - values.expected), 0.0, 0.0, 1.0);
        }
        """

    /// その設定・その座標で、断片が出した値と CPU が出した値の差を読む。
    private func gap(
        seed: Int, octaves: Int, falloff: Float, at place: SIMD3<Float>
    ) throws -> Float {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        let canvas = try Canvas(target: target, gpu: gpu)

        canvas.noiseSeed(seed)
        canvas.noiseDetail(octaves, falloff)
        let expected = canvas.noise(place.x, place.y, place.z)

        let shader = try canvas.makeShader(
            Self.comparison,
            values: [
                "place": .pair(place.x, place.y),
                "depth": .number(place.z),
                "expected": .number(expected),
            ])

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.blendMode(.replace)
            canvas.noStroke()
            canvas.shader(shader)
            canvas.rect(0, 0, 8, 8)
        }
        return canvas.get(4, 4).red
    }

    @Test("既定の設定で、代表の座標がすべて一致する", arguments: NoiseParityTests.places)
    func theDefaultSettingsAgree(_ place: SIMD3<Float>) throws {
        let gap = try gap(seed: 0, octaves: 4, falloff: 0.5, at: place)
        #expect(gap < Self.tolerance, "\(place) で \(gap) ずれている")
    }

    @Test("種を変えても一致する", arguments: [1, 42, -7, 20260829, Int(Int32.max)])
    func everySeedAgrees(_ seed: Int) throws {
        for place in Self.places {
            let gap = try gap(seed: seed, octaves: 4, falloff: 0.5, at: place)
            #expect(gap < Self.tolerance, "種 \(seed) の \(place) で \(gap) ずれている")
        }
    }

    @Test("細かさを変えても一致する", arguments: [(1, Float(0.5)), (8, 0.25), (16, 1.0), (3, 0.0)])
    func everyDetailAgrees(_ detail: (octaves: Int, falloff: Float)) throws {
        for place in Self.places {
            let gap = try gap(
                seed: 5, octaves: detail.octaves, falloff: detail.falloff, at: place)
            #expect(
                gap < Self.tolerance,
                "\(detail.octaves) 枚 / 弱まり \(detail.falloff) の \(place) で \(gap) ずれている")
        }
    }

    @Test("種を決め直すと、断片の出す値も付いてくる")
    func theFragmentFollowsANewSeed() throws {
        // **利用者が値として配線していない**のに、断片の模様が種で変わることを見る。
        // uniforms へ詰め忘れると、ここだけが落ちる (差の検査は種 0 でも通ってしまう)
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        let canvas = try Canvas(target: target, gpu: gpu)
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return float4(mokume_noise(in, float2(0.5, 0.25)), 0.0, 0.0, 1.0);
            }
            """)

        func draw() -> Float {
            try? canvas.draw {
                canvas.blendMode(.replace)
                canvas.noStroke()
                canvas.shader(shader)
                canvas.rect(0, 0, 8, 8)
            }
            return canvas.get(4, 4).red
        }

        canvas.noiseSeed(1)
        let first = draw()
        canvas.noiseSeed(2)
        let second = draw()
        #expect(first != second, "種を変えても断片の値が動かない (uniforms へ届いていない)")
    }
}
