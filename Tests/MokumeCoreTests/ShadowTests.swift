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
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
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
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            // **世界を縮めたら、見る位置も同じだけ縮める。** そうしないと縮尺の違いが
            // 「遠くなった」だけになり、影の細かさの話にならない
            canvas.camera(
                center, -24 * scale, 170 * scale, center, 14 * scale, 0, 0, 1, 0)
            canvas.perspective(.pi / 3, 1, 1 * scale, 500 * scale)
            canvas.ambientLight(.linear(red: 0.15, green: 0.15, blue: 0.15))
            canvas.directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.6, 0.6, -0.5)
            canvas.shadows(shadows)
            if let range { canvas.shadowRange(range) }
            extra(canvas)
            canvas.noStroke()

            canvas.castShadow(false)
            canvas.fill(.linear(red: 0.7, green: 0.7, blue: 0.7))
            canvas.push()
            canvas.translate(center, 40 * scale, -20 * scale)
            canvas.box(190 * scale, 8 * scale, 190 * scale)
            canvas.pop()

            canvas.castShadow(true)
            canvas.fill(.linear(red: 0.85, green: 0.5, blue: 0.3))
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

    @Test("影の縁は 1 画素で切れず、なめらかに移る")
    func shadowEdgesAreSoft() throws {
        // **縁の柔らかさは PCF が作る。** 読む側を 1 点にすると縁は 1 画素で明暗が
        // 切り替わり、中間の明るさが消える。焼き方・読み方を差し替えたときに
        // 柔らかさが落ちていないことを、「影なしとの差が最大の 2〜8 割に収まる画素」
        // の数で見る ([#757])
        //
        // [#757]: https://github.com/mokume-metal/mokume/issues/757
        // 焼き付け先を粗くして、読む 1 画素の footprint が画面の画素より大きくなるように
        // する。既定の細かさでは footprint が画面の 1 画素に収まり、縁の移りが見えない
        let coarse: (Canvas) -> Void = { $0.shadowDetail(64) }
        let lit = try floorAndSphere(try makeCanvas(), shadows: false, extra: coarse)
        let shadowed = try floorAndSphere(try makeCanvas(), shadows: true, extra: coarse)
        var drops: [Int] = []
        for y in 0..<lit.height {
            for x in 0..<lit.width {
                drops.append(Int(lit[x, y].red) - Int(shadowed[x, y].red))
            }
        }
        let deepest = drops.max() ?? 0
        #expect(deepest > 20, "床に影が落ちていない")
        let partial = drops.filter { $0 > deepest / 5 && $0 < deepest * 4 / 5 }.count
        #expect(partial > 20, "影の縁に中間の明るさが無い (\(partial) 画素) — PCF が効いていない")
    }

    // MARK: - 焼き方と読み方

    @Test("焼き付け先は奥行きの面 1 枚で、パスに色の面が無い")
    func theShadowMapIsDepthOnly() throws {
        // 奥行きは色の面に数として書くのではなく、**奥行きの面そのものを読む**。色の面を
        // 持つと 1 画素 4 バイトの書き込みと、それを書く断片の実行が余計にかかる ([#757])
        //
        // [#757]: https://github.com/mokume-metal/mokume/issues/757
        let gpu = try RenderDevice()
        let map = try ShadowMap(gpu: gpu, detail: 128)
        #expect(map.texture.pixelFormat == .depth32Float)
        #expect(map.texture.usage.contains(.shaderRead), "焼いた奥行きを読めない")
        let pass = map.makeRenderPass()
        #expect(pass.colorAttachments[0]?.texture == nil, "色の面が付いている")
        #expect(pass.depthAttachment?.texture === map.texture)
        #expect(pass.depthAttachment?.storeAction == .store, "焼いた奥行きを捨てている")
    }

    @Test("影は奥行きの面を compare sampler で読み、焼く側に断片は無い")
    func shadowsAreReadWithACompareSampler() throws {
        // パイプラインの中身は組んだ後からは見えないので、組む前の原稿で見る。
        // 読む側は `depth2d` + `sample_compare` (比較と補間を採取器が行う HW PCF)、
        // 焼く側は頂点だけで断片を持たない ([#757])
        //
        // [#757]: https://github.com/mokume-metal/mokume/issues/757
        let gpu = try RenderDevice()
        let common = try gpu.bundledShaderSource(named: "Common")
        #expect(common.contains("depth2d<float> shadow_texture"), "影の口が奥行きの面ではない")
        #expect(common.contains("sample_compare("), "影を compare sampler で読んでいない")
        #expect(!common.contains("texture2d<float> shadow_texture"))
        let shapes = try gpu.bundledShaderSource(named: "Shapes")
        #expect(!shapes.contains("mokume_shadowFragment"), "焼く側に断片が残っている")
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
            $0.emissive(.linear(red: 0.2, green: 0.2, blue: 0.2))
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
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.shadows(shadows)
                canvas.noStroke()
                canvas.fill(.linear(red: 0.9, green: 0.2, blue: 0.2))
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.sphere(24)
                canvas.pop()
                // **あとに置いた平面が、先に置いた立体の上に来る** (呼び出し順どおり)
                canvas.fill(.linear(red: 0.2, green: 0.4, blue: 0.9))
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

    // MARK: - 焼き付けと画面が重ならない

    @Test("焼いたフレームには、焼き上がりを待つ仕掛けが 1 つ積まれる")
    func theShadowBakeIsFencedOffFromTheScreenPass() throws {
        // **仕掛けが抜けても絵は普段どおり出る。** この世代のコマンド構造は encoder を
        // またぐ依存を自動では張らないので、抜けると焼き付けと画面が重なりうるが、
        // 重なるのは GPU が混んだときだけで、しかも稀にしか現れない ([#341] の実測で
        // 720 回中 11 回)。**絵で守れないので数で守る** — 積む 1 行と同じ場所で
        // 数えているので、その行を消せばここが赤くなる。
        //
        // ここが見るのは**仕掛けが入っていること**だけで、実行順そのものは見ていない
        // (見る方法は下の「混ませて繰り返す」に書いた)。
        //
        // [#341]: https://github.com/mokume-metal/mokume/issues/341
        // 形を動かして、3 フレームとも焼き直させる (同じ形なら焼かないので — 下の
        // 「焼き直さない」)。**焼いた回数と仕掛けの数が一致する**ことを見る
        let canvas = try makeCanvas()
        for offset in [-30, 0, 30] as [Float] { _ = try floorAndSphere(canvas, offset: offset) }
        #expect(canvas.shadowBakesEncoded == 3)
        #expect(canvas.shadowBarriersEncoded == 3, "焼いたのに、待つ仕掛けが積まれていない")

        _ = try floorAndSphere(canvas, shadows: false)
        #expect(canvas.shadowBarriersEncoded == 3, "焼いていないフレームにまで積んでいる")
    }

    // MARK: - 焼き直さない

    @Test("同じ形と光を続けて描いたら、焼くのは最初の 1 回で、絵は毎回焼いたときと同じ")
    func anUnchangedSceneIsBakedOnce() throws {
        // **同じ宣言なら実体を作り直さない** (ADR-0021 決定 4) の焼き付け側。光の行列・
        // 細かさ・落とす列の形と置き場所が前のフレームと同じなら、焼いた面をそのまま
        // 読む。**絵は焼き直したときと 1 ビットも違わない**ことも見る — 違えば省略では
        // なく別の絵になる ([#757])
        //
        // [#757]: https://github.com/mokume-metal/mokume/issues/757
        let canvas = try makeCanvas()
        var pictures: [DisplayImage] = []
        for _ in 0..<3 { pictures.append(try floorAndSphere(canvas)) }
        #expect(canvas.shadowBakesEncoded == 1, "同じ形なのに焼き直している")
        #expect(canvas.shadowBakesReused == 2)
        let fresh = try floorAndSphere(try makeCanvas())
        #expect(pictures[2].bytes == fresh.bytes, "焼き直さなかったフレームの絵が違う")
        #expect(pictures[1].bytes == pictures[0].bytes)
    }

    @Test("形・光・細かさのどれかが動いたら焼き直す")
    func changesForceARebake() throws {
        let canvas = try makeCanvas()
        _ = try floorAndSphere(canvas)
        #expect(canvas.shadowBakesEncoded == 1)
        _ = try floorAndSphere(canvas, offset: 10)
        #expect(canvas.shadowBakesEncoded == 2, "形を動かしたのに焼き直していない")
        _ = try floorAndSphere(canvas, offset: 10) {
            $0.directionalLight(.linear(red: 0.5, green: 0.5, blue: 0.5), 0.6, 0.6, -0.5)
        }
        // extra は floorAndSphere 自身の光の**後**に置くので、落とす光 (最初の向きを
        // 持つ光) は変わらない — 焼き直さないのが正しい
        #expect(canvas.shadowBakesEncoded == 2, "落とす光が変わっていないのに焼き直した")
        _ = try floorAndSphere(canvas, offset: 10) { $0.shadowDetail(512) }
        #expect(canvas.shadowBakesEncoded == 3, "細かさを変えたのに焼き直していない")
        _ = try floorAndSphere(canvas, offset: 10, range: 300)
        #expect(canvas.shadowBakesEncoded == 4, "範囲を変えたのに焼き直していない")
    }

    @Test("落とす側の切り替えと、影を切った後の復帰でも正しく焼く")
    func castingChangesAndResumingAreHandled() throws {
        let canvas = try makeCanvas()
        let casting = try floorAndSphere(canvas)
        // 落とす形を 1 つ足す — 落とす列が増えるので焼き直す (extra は床より先に
        // 置かれ、落とす側の既定 true のまま列になる)
        _ = try floorAndSphere(canvas) { canvas in
            canvas.push()
            canvas.translate(100, 8, 30)
            canvas.sphere(6)
            canvas.pop()
        }
        #expect(canvas.shadowBakesEncoded == 2, "落とす列が変わったのに焼き直していない")
        // 影を切ったフレームは焼かない。戻したら、前に焼いたものと同じ形なら焼き直さなくてよいが、
        // 絵は焼いたときと同じでなければならない
        _ = try floorAndSphere(canvas, shadows: false)
        let resumed = try floorAndSphere(canvas)
        #expect(resumed.bytes == casting.bytes, "影を戻したフレームの絵が違う")
    }

    @Test("GPU が埋める置き場所 (粒) を落とす側に含む列は、毎フレーム焼く")
    func externallyPlacedInstancesAlwaysRebake() throws {
        // 粒の置き場所は GPU が書くので、CPU からは前のフレームと同じかどうかが分からない。
        // 分からないものは焼く側に倒す (遅くなるだけで絵を間違えない)
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 64)
        var randomness = Randomness(seed: 7)
        for _ in 0..<3 {
            _ = try floorAndSphere(canvas) { canvas in
                canvas.emit(
                    dust, from: .point(64, 0), rate: 300, speed: 20...45,
                    angle: 0...(2 * Float.pi), life: 0.4...1.2, size: 3...6,
                    color: .linear(red: 1, green: 0.6, blue: 0.2), using: &randomness)
                canvas.particles(dust)
            }
        }
        #expect(canvas.shadowBakesEncoded == 3, "粒を含むのに焼き直していない")
    }

    /// 焼き付けと画面が重なっていないことを、繰り返して確かめる。
    ///
    /// **通っても何も証明しない検査。** 重なりは GPU が混んだときにしか現れず、
    /// しかも**現れ方が偏っている**。仕掛けを外した状態での実測は次のとおり:
    ///
    /// - 6 プロセス同時 × 120 回 = 720 回中 **11 回** (別の設定でも 720 回中 12 回)
    /// - 同じ状態でも、時間を置いて走らせた 6 プロセス同時 × 400 回 = 2400 回では **0 回**
    /// - 1 プロセスだけで 200 回 × 2 回 → **0 回**
    ///
    /// 仕掛けを入れると 720 回中 0 回。つまり**落ちたら本物**だが、通ったことは
    /// 「今日は出なかった」以上を意味しない。だから既定では走らせない。
    /// フレームの組み立てを触ったときに、次の形で走らせる:
    ///
    /// ```
    /// for i in 1 2 3 4 5 6; do MOKUME_SHADOW_STRESS=120 swift test --filter 影 & done; wait
    /// ```
    ///
    /// 焼き付け先をわざと細かくして (2048)、焼くのにかかる時間を伸ばしてある。
    /// 既定の細かさでは窓が狭く、混ませても現れにくい。
    @Test(
        "動く形の影が遅れない (混ませて繰り返す)",
        .enabled(if: shadowStressRounds > 0, "MOKUME_SHADOW_STRESS に回数を入れたときだけ走らせる"))
    func shadowsFollowTheSameFrameUnderLoad() throws {
        let canvas = try makeCanvas()
        var late = 0
        for round in 0..<shadowStressRounds {
            let heavy: (Canvas) -> Void = { $0.shadowDetail(2048) }
            _ = try floorAndSphere(canvas, offset: -30, extra: heavy)
            let second = try floorAndSphere(canvas, offset: 30, extra: heavy)
            let fresh = try floorAndSphere(try makeCanvas(), offset: 30, extra: heavy)
            if second.bytes != fresh.bytes {
                late += 1
                print("影が 1 フレーム遅れた (\(round) 回目)")
            }
        }
        #expect(late == 0, "\(shadowStressRounds) 回中 \(late) 回、影が 1 フレーム遅れた")
    }

    @Test("影を落とすのは、置いてあるうちの最初の向きを持つ光")
    func theFirstDirectionalLightCasts() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.ambientLight(.linear(red: 0.2, green: 0.2, blue: 0.2))
            #expect(canvas.shadowCaster == nil, "底上げの光が影を落とすことになっている")
            canvas.directionalLight(.linear(red: 1, green: 1, blue: 1), 0, 1, 0)
            canvas.directionalLight(.linear(red: 0.5, green: 0.5, blue: 0.5), 1, 0, 0)
            let caster = canvas.shadowCaster
            #expect(caster?.colorAndKind.x == 1, "2 つ目の光が影を落としている")
        }
    }
}

/// 混ませて繰り返す回数。`MOKUME_SHADOW_STRESS` に入れた数だけ回す。
///
/// 走らせるかどうかは検査の外で決まるので、隔離の外に置く。
nonisolated let shadowStressRounds =
    Int(ProcessInfo.processInfo.environment["MOKUME_SHADOW_STRESS"] ?? "") ?? 0
