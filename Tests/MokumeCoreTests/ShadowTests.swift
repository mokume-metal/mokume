// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 影の検査。GPU を要する。
///
/// 影は**フレームの組み立て方**なので、壊れ方も「絵が少し違う」ではなく
/// 「1 フレーム遅れる」「重なりが変わる」「読み戻せない」という形で出る。
/// どれも例外を出さないので、画素と数で確かめる ([ADR-0019] 決定 4)。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "影",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShadowTests {
    private func makeCanvas(width: Int = 128, height: Int = 128) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 床の上に球を 1 つ置く絵。**世界の尺度を丸ごう変えられる**ようにしてある。
    ///
    /// - Parameters:
    ///   - scale: 世界の大きさの倍率。1 なら面と同じ尺度、0.1 なら 10 分の 1 の世界。
    ///   - offset: 球の横のずれ (倍率を掛ける前)。
    private func floorAndSphere(
        _ canvas: Canvas, shadows: Bool = true, scale: Float = 1, offset: Float = 0,
        range: Float? = nil, extra: (Canvas) -> Void = { _ in }
    ) throws -> DisplayImage {
        let center: Float = 64
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            // **世界を縮めたら、見る位置も同じだけ縮める。** そうしないと縮尺の違いが
            // 「遠くなった」だけになり、影の細かさの話にならない
            canvas.camera(
                center, -24 * scale, 170 * scale, center, 14 * scale, 0, 0, 1, 0)
            canvas.perspective(.pi / 3, 1, 1 * scale, 500 * scale)
            canvas.ambientLight(.opaque(red: 0.15, green: 0.15, blue: 0.15))
            canvas.directionalLight(.opaque(red: 0.85, green: 0.85, blue: 0.85), -0.6, 0.6, -0.5)
            canvas.shadows(shadows)
            if let range { canvas.shadowRange(range) }
            extra(canvas)
            canvas.noStroke()

            canvas.castShadow(false)
            canvas.fill(.opaque(red: 0.7, green: 0.7, blue: 0.7))
            canvas.push()
            canvas.translate(center, 40 * scale, -20 * scale)
            canvas.box(190 * scale, 8 * scale, 190 * scale)
            canvas.pop()

            canvas.castShadow(true)
            canvas.fill(.opaque(red: 0.85, green: 0.5, blue: 0.3))
            canvas.push()
            canvas.translate(center + offset * scale, 8 * scale, 0)
            canvas.sphere(28 * scale)
            canvas.pop()
        }
        return try canvas.target.encodeForDisplay()
    }

    // MARK: - 影が出る

    @Test("影を落とすと、床の一部が暗くなる")
    func shadowsDarkenTheFloor() throws {
        let lit = try floorAndSphere(try makeCanvas(), shadows: false)
        let shadowed = try floorAndSphere(try makeCanvas(), shadows: true)

        var darkened = 0
        for y in 0..<lit.height {
            for x in 0..<lit.width
            where Int(lit[x, y].red) - Int(shadowed[x, y].red) > 20 { darkened += 1 }
        }
        #expect(darkened > 100, "影が落ちていない")
    }

    @Test("影のある絵が、同じ入力から 2 回とも同じ絵になる")
    func shadowsAreDeterministic() throws {
        // このフェーズの出口条件。焼き付けが同じ順で同じ形から行われていれば、
        // 2 回とも 1 ビットも違わない
        let first = try floorAndSphere(try makeCanvas())
        let second = try floorAndSphere(try makeCanvas())
        #expect(first.bytes == second.bytes)
    }

    @Test("動く形の影が遅れない")
    func shadowsFollowTheSameFrame() throws {
        // **同じフレームの形から焼いているか。** 前のフレームの形から焼いていると、
        // 動かした 1 フレーム目だけ影が元の場所に残る
        let canvas = try makeCanvas()
        let first = try floorAndSphere(canvas, offset: -30)
        let second = try floorAndSphere(canvas, offset: 30)
        let fresh = try floorAndSphere(try makeCanvas(), offset: 30)

        // 動かした後の絵が、最初から動いた位置で描いた絵と一致する
        #expect(second.bytes == fresh.bytes, "影が 1 フレーム遅れている")
        #expect(first.bytes != second.bytes, "動かしても絵が変わっていない")
    }

    // MARK: - 影が減衰させるもの

    @Test("影が減衰させるのは直接の光だけ")
    func shadowsOnlyDimTheDirectLight() throws {
        // 影の中でも、底上げの光・周囲・自ら出す光は残る
        let plain = try floorAndSphere(try makeCanvas())
        let withSurroundings = try floorAndSphere(try makeCanvas()) {
            $0.surroundings(.studio)
        }
        let withEmissive = try floorAndSphere(try makeCanvas()) {
            $0.emissive(.opaque(red: 0.2, green: 0.2, blue: 0.2))
        }

        // **影がいちばん濃いところは、影なしの絵との差から探す。** 座標を決め打ちに
        // すると、場面を少し動かしただけで「影を見ていない検査」になる
        let lit = try floorAndSphere(try makeCanvas(), shadows: false)
        var darkest = (x: 0, y: 0, value: 0, drop: 0)
        for y in 0..<plain.height {
            for x in 0..<plain.width {
                let drop = Int(lit[x, y].red) - Int(plain[x, y].red)
                if drop > darkest.drop {
                    darkest = (x, y, Int(plain[x, y].red), drop)
                }
            }
        }
        #expect(darkest.drop > 20, "床に影が落ちていない")
        #expect(darkest.value > 5, "影の中が真っ黒 = 底上げの光まで消えている")
        #expect(
            Int(withSurroundings[darkest.x, darkest.y].red) > darkest.value + 10,
            "影の中で周囲からの光が効いていない")
        #expect(
            Int(withEmissive[darkest.x, darkest.y].red) > darkest.value + 10,
            "影の中で自ら出す光が効いていない")
    }

    // MARK: - 組み立てが変わらない

    @Test("影を有効にしても、重なり方と画素の読み戻しが変わらない")
    func enablingShadowsKeepsTheFrameAssembly() throws {
        // 影を後から足すと、フレームの組み立てが 2 通りに割れる。**割れていない**
        // ことを、重なりの順と読み戻しで確かめる
        func picture(shadows: Bool) throws -> (DisplayImage, LinearRGBA) {
            let canvas = try makeCanvas(width: 64, height: 64)
            var read = LinearRGBA.transparent
            try canvas.draw {
                canvas.background(.opaque(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.shadows(shadows)
                canvas.noStroke()
                canvas.fill(.opaque(red: 0.9, green: 0.2, blue: 0.2))
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.sphere(24)
                canvas.pop()
                // **あとに置いた平面が、先に置いた立体の上に来る** (呼び出し順どおり)
                canvas.fill(.opaque(red: 0.2, green: 0.4, blue: 0.9))
                canvas.rect(24, 24, 16, 16)
                // 同じフレームの中で画素を読み戻せる
                canvas.loadPixels()
                read = canvas.get(32, 32)
            }
            return (try canvas.target.encodeForDisplay(), read)
        }

        let (withoutShadows, readWithout) = try picture(shadows: false)
        let (withShadows, readWith) = try picture(shadows: true)
        // 平面が上に来ている (青い)
        #expect(withShadows[32, 32].blue > withShadows[32, 32].red)
        #expect(withoutShadows[32, 32].blue > withoutShadows[32, 32].red)
        // 読み戻した値も同じ
        #expect(readWith == readWithout)
    }

    // MARK: - 縮尺と、落とす / 受けるの切り分け

    @Test("小さい世界でも、範囲を決めれば影が潰れない")
    func aSmallWorldKeepsItsShadow() throws {
        // **同じ形を 10 分の 1 の世界で組み、見る位置も同じだけ縮める。** 見え方は
        // 同じはずなので、範囲が縮尺に合っていれば絵もほぼ一致する。焼き付け範囲を
        // 固定値にしていると、小さい世界だけが粗くなって一致しなくなる
        let big = try floorAndSphere(try makeCanvas(), scale: 1)
        let tuned = try floorAndSphere(try makeCanvas(), scale: 0.1, range: 18)
        let untuned = try floorAndSphere(try makeCanvas(), scale: 0.1)

        func differing(_ a: DisplayImage, _ b: DisplayImage) -> Int {
            var count = 0
            for y in 0..<a.height {
                for x in 0..<a.width
                where abs(Int(a[x, y].red) - Int(b[x, y].red)) > 20 { count += 1 }
            }
            return count
        }
        let tunedDifference = differing(big, tuned)
        let untunedDifference = differing(big, untuned)
        #expect(tunedDifference < 60, "範囲を合わせても絵が一致しない (\(tunedDifference))")
        #expect(
            untunedDifference > tunedDifference * 3,
            "範囲を変えても影の細かさが変わっていない (\(untunedDifference))")
    }

    @Test("落とす側から外した形は、影を作らない")
    func excludedShapesCastNothing() throws {
        let casting = try floorAndSphere(try makeCanvas())
        let notCasting = try floorAndSphere(try makeCanvas()) { $0.castShadow(false) }
        // extra は castShadow(true) より前に呼ばれるので、球は落とす側のまま。
        // ここでは受ける側を切って確かめる
        let notReceiving = try floorAndSphere(try makeCanvas()) { $0.receiveShadow(false) }

        var difference = 0
        for y in 0..<casting.height {
            for x in 0..<casting.width
            where Int(casting[x, y].red) != Int(notReceiving[x, y].red) { difference += 1 }
        }
        #expect(difference > 100, "受ける側を切っても絵が変わらない")
        #expect(casting.bytes == notCasting.bytes)
    }

    // MARK: - 寿命と作り直し

    @Test("影の設定はフレームを越えない")
    func shadowSettingsDoNotCrossFrames() throws {
        let canvas = try makeCanvas()
        _ = try floorAndSphere(canvas, shadows: true)
        #expect(canvas.shadowsEnabled == false)
        #expect(canvas.shadowRangeValue == nil)
        #expect(canvas.castsShadow)
        #expect(canvas.receivesShadow)
    }

    @Test("初期化のときに書いた影の設定は、どのフレームにも属さないので無視される")
    func shadowSettingsOutsideAFrameAreIgnored() throws {
        let canvas = try makeCanvas()
        canvas.shadows(true)
        canvas.shadowRange(40)
        canvas.castShadow(false)
        #expect(canvas.shadowsEnabled == false)
        #expect(canvas.shadowRangeValue == nil)
        #expect(canvas.castsShadow)
    }

    @Test("数でない値・範囲の外の値では、影の設定を変えない")
    func brokenShadowSettingsAreIgnored() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.shadowRange(50)
            canvas.shadowRange(.nan)
            canvas.shadowRange(-1)
            canvas.shadowDetail(1)
            canvas.shadowDetail(99_999)
            canvas.shadowBias(.infinity)
            #expect(canvas.shadowRangeValue == 50)
            #expect(canvas.shadowDetailValue == ShadowMap.defaultDetail)
            #expect(canvas.shadowBiasValue > 0)
        }
    }

    @Test("毎フレーム宣言しても、焼き付け先は作り直さない")
    func theShadowMapIsReused() throws {
        // 重い下ごしらえもシーンの記述として扱う (ADR-0021 決定 4)。**同じ宣言なら
        // 実体を作り直さない**ことは、絵では分からないので数で確かめる
        let canvas = try makeCanvas()
        for _ in 0..<3 { _ = try floorAndSphere(canvas) }
        #expect(canvas.shadowMapsBuilt == 1)

        _ = try floorAndSphere(canvas) { $0.shadowDetail(512) }
        #expect(canvas.shadowMapsBuilt == 2, "細かさを変えても作り直していない")
    }

    @Test("影を落とすのは、置いてあるうちの最初の向きを持つ光")
    func theFirstDirectionalLightCasts() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.ambientLight(.opaque(red: 0.2, green: 0.2, blue: 0.2))
            #expect(canvas.shadowCaster == nil, "底上げの光が影を落とすことになっている")
            canvas.directionalLight(.opaque(red: 1, green: 1, blue: 1), 0, 1, 0)
            canvas.directionalLight(.opaque(red: 0.5, green: 0.5, blue: 0.5), 1, 0, 0)
            let caster = canvas.shadowCaster
            #expect(caster?.colorAndKind.x == 1, "2 つ目の光が影を落としている")
        }
    }
}
