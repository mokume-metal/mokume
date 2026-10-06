// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
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
        try drawFloorAndSphere(
            canvas, shadows: shadows, scale: scale, offset: offset, range: range, extra: extra)
        return try canvas.target.encodeForDisplay()
    }

    /// ``floorAndSphere(_:shadows:scale:offset:range:extra:)`` の描く部分だけ。**読み出さない**
    /// — 描き切りで投げたかどうかを、読み出しの待ちと分けて見るため ([#1868])。
    ///
    /// [#1868]: https://github.com/mokume-metal/mokume/issues/1868
    private func drawFloorAndSphere(
        _ canvas: Canvas, shadows: Bool = true, scale: Float = 1, offset: Float = 0,
        range: Float? = nil, extra: (Canvas) -> Void = { _ in }
    ) throws {
        let center: Float = 64
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            // **世界を縮めたら、見る位置も同じだけ縮める。** そうしないと縮尺の違いが
            // 「遠くなった」だけになり、影の細かさの話にならない
            canvas.camera(
                center, -24 * scale, 170 * scale, center, 14 * scale, 0, 0, 1, 0)
            canvas.perspective(Float.pi / 3, 1, 1 * scale, 500 * scale)
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
        let common = try gpu.shaders.bundledShaderSource(named: "Common")
        #expect(common.contains("depth2d<float> shadow_texture"), "影の口が奥行きの面ではない")
        #expect(common.contains("sample_compare("), "影を compare sampler で読んでいない")
        #expect(!common.contains("texture2d<float> shadow_texture"))
        let shapes = try gpu.shaders.bundledShaderSource(named: "Shapes")
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
        // **6 つとも、フレームの中で既定から動かしてから見る。** 動かさずに見ると
        // 「戻った」と「もともと既定だった」が区別できない — ここは以前 `floorAndSphere`
        // を 1 フレーム回すだけだったので、そのヘルパが呼ばない `shadowDetail` /
        // `shadowBias` は**越えていても緑のまま**だった ([#940])。フレームの中での
        // 検査は、動かせていることの確認である (動いていなければ下は何も見ていない)
        //
        // [#940]: https://github.com/mokume-metal/mokume/issues/940
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.shadows(true)
            canvas.shadowRange(40)
            canvas.shadowDetail(512)
            canvas.shadowBias(0.01)
            canvas.castShadow(false)
            canvas.receiveShadow(false)
            #expect(canvas.shadowsEnabled)
            #expect(canvas.shadowRangeValue == 40)
            #expect(canvas.shadowDetailValue == 512)
            #expect(canvas.shadowBiasValue == 0.01)
            #expect(canvas.style.castsShadow == false)
            #expect(canvas.style.receivesShadow == false)
        }
        #expect(canvas.shadowsEnabled == false)
        #expect(canvas.shadowRangeValue == nil)
        #expect(canvas.shadowDetailValue == ShadowMap.defaultDetail)
        #expect(canvas.shadowBiasValue == ShadowMap.defaultBias)
        #expect(canvas.style.castsShadow)
        #expect(canvas.style.receivesShadow)
    }

    @Test("初期化のときに書いた影の設定は、どのフレームにも属さないので無視される")
    func shadowSettingsOutsideAFrameAreIgnored() throws {
        // 上と同じく**6 つとも**見る。入口は 6 本とも同じ `guard isDrawing` で
        // 塞がれているので、1 本だけ抜けても他の 5 本からは見えない ([#940])
        //
        // [#940]: https://github.com/mokume-metal/mokume/issues/940
        let canvas = try makeCanvas()
        canvas.shadows(true)
        canvas.shadowRange(40)
        canvas.shadowDetail(512)
        canvas.shadowBias(0.01)
        canvas.castShadow(false)
        canvas.receiveShadow(false)
        #expect(canvas.shadowsEnabled == false)
        #expect(canvas.shadowRangeValue == nil)
        #expect(canvas.shadowDetailValue == ShadowMap.defaultDetail)
        #expect(canvas.shadowBiasValue == ShadowMap.defaultBias)
        #expect(canvas.style.castsShadow)
        #expect(canvas.style.receivesShadow)
    }

    @Test("数でない値・範囲の外の値では、影の設定を変えない")
    func brokenShadowSettingsAreIgnored() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.shadowRange(50)
            canvas.shadowRange(Float.nan)
            canvas.shadowRange(-1)
            canvas.shadowDetail(1)
            canvas.shadowDetail(99_999)
            canvas.shadowBias(Float.infinity)
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

        // **ここが決定 4 の釣り合いの本体である。** 細かさもフレームを越えないので
        // ([#940])、既定でない細かさを使い続けるスケッチは毎フレーム宣言し直すことに
        // なる。そのたびに焼き付け先を作り直していたら、越えないことの代償が重すぎて
        // 「重いから越える」という例外に戻ってしまう
        //
        // **形は毎フレーム動かす。** 止めると `bakeShadow` が焼き直しごと省くので
        // (下の「焼き直さない」)、焼き付け先を取りに行く経路を 1 度も通らない —
        // 動かさない形で書くと、再利用を壊しても緑のままになる
        //
        // [#940]: https://github.com/mokume-metal/mokume/issues/940
        for offset in [-20, 0, 20, 40] as [Float] {
            _ = try floorAndSphere(canvas, offset: offset) { $0.shadowDetail(512) }
        }
        #expect(canvas.shadowBakesEncoded >= 4, "形を動かしたのに焼き直していない")
        #expect(canvas.shadowMapsBuilt == 2, "毎フレーム同じ細かさを宣言したら作り直した")
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

    // MARK: - 投入されなかった焼き付け (#1183)

    /// **焼き付けを積んだ後で投げたフレームの指紋を覚えない。** 覚えると、次のフレームが
    /// 同じ形を置いたときに「焼いた」と読んで使い回し、**投入されなかった焼き付けの面**
    /// (= その前に焼いた別の形の影) を読む ([#1183])。
    ///
    /// 投げさせる場所は焼き付けの**後**でなければ意味が無い — 焼き付けの中で投げる経路は
    /// 前から守られていた。だから影の側の置き場は伸ばさず、形の置き場だけを伸ばして
    /// その取り直しの待ちで投げさせる (`encodeBatches` は焼き付けの後に置き場を取る)。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    @Test("焼き付けを積んだ後で投げたフレームの影は、次のフレームで焼き直す")
    func aFrameThatThrowsAfterBakingIsBakedAgain() throws {
        let canvas = try makeCanvas()
        // 形の置き場を 1 度取らせる (1 度目の取り直しは外す古い置き場が無いので待たない)。
        // **面の外に置く** — 塗りはフレームを越えて残るので、見える所に置くと新しい面と色が違う
        let dot: (Canvas) -> Void = { $0.rect(1000, 1000, 1, 1) }
        _ = try floorAndSphere(canvas, offset: -30, extra: dot)

        let baked = canvas.shadowBakesEncoded
        canvas.gpu.failSettleForTesting = .timedOut(seconds: RenderDevice.waitLimitSeconds)
        // **囲むのは描き切りだけで、読み出しは含めない** ([#1868])。差し込みを残したまま
        // 読み出すと、その待ちも投げる — 描き切りが投げなくなっても、ここが満たされてしまう
        //
        // [#1868]: https://github.com/mokume-metal/mokume/issues/1868
        #expect(
            throws: RenderFailure.timedOut(seconds: RenderDevice.waitLimitSeconds),
            "描き切りが投げていない — この検査は焼き付けの後で投げる経路を見ていない"
        ) {
            try self.drawFloorAndSphere(canvas, offset: 30) { canvas in
                for index in 0..<5000 { canvas.rect(1000 + index % 16, 1000, 1, 1) }
            }
        }
        canvas.gpu.failSettleForTesting = nil
        #expect(
            canvas.shadowBakesEncoded == baked + 1,
            "焼き付けを積む前に投げている — この検査は焼き付けの後で投げる経路を見ていない")

        let after = try floorAndSphere(canvas, offset: 30, extra: dot)
        let fresh = try floorAndSphere(try makeCanvas(), offset: 30, extra: dot)
        #expect(
            after.bytes == fresh.bytes,
            "投入されなかった焼き付けを「焼いた」と覚え、前の形の影を読んでいる")
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

    @Test("頂点を 1 つも動かさず、番号だけ変えても焼き直す")
    func changingOnlyTheIndicesForcesARebake() throws {
        // **`index(_:)` がまさに誘う書き方である。** 点を置き直さずに読む順だけを
        // 組み替えるフレーム (面の張り替え・粗さの切り替え) では、頂点のバイト列が
        // 1 バイトも動かない。焼き付けの指紋が番号を見ていないと「同じ入力」と読んで
        // 焼き直しを省き、**前のフレームの影が居座る**
        // **2 つの順は、同じ 4 点を同じ順で初めて参照する。** そうしないと積まれる頂点の
        // 中身まで変わり、番号を見ない指紋でも見分けられてしまう (この検査が守りたいのは
        // 「頂点が 1 バイトも動かないのに絵が変わる」場合である)。張る面だけが違うので、
        // 落ちる影は 4 隅の四角と、その 4 分の 3 になる
        let canvas = try makeCanvas()
        let first = try floorAndIndexedCaster(canvas, order: [0, 1, 2, 1, 2, 3])
        #expect(canvas.shadowBakesEncoded == 1)

        let second = try floorAndIndexedCaster(canvas, order: [0, 1, 2, 0, 2, 3])
        #expect(canvas.shadowBakesEncoded == 2, "番号を変えたのに焼き直していない")

        // 影の形が変われば絵も変わる。同じままなら、焼き直しを省いた証拠になる
        var differing = 0
        for y in 0..<first.height {
            for x in 0..<first.width where first[x, y] != second[x, y] { differing += 1 }
        }
        #expect(differing > 100, "番号を変えたのに影が追随していない")
    }

    @Test("番号で指した形の影は、点を書き出した形の影と同じ")
    func indexedCasterCastsTheSameShadow() throws {
        // **影は別のエンコーダで同じ列を描く。** 片方だけ非添字のまま残すと、影だけが
        // 頂点を 3 つずつ束ねた別の形で焼かれる — 画面の側は正しいままなので、
        // 「影の形がおかしい」としか見えない
        let order = [0, 1, 2, 0, 2, 3]
        let indexed = try floorAndIndexedCaster(try makeCanvas(), order: order)
        let expanded = try floorAndIndexedCaster(try makeCanvas(), order: order, indexed: false)
        #expect(indexed.bytes == expanded.bytes)
    }

    /// 床の上に、四角い面を 1 枚だけ浮かせる絵。
    ///
    /// **置く点は `order` によらず同じ 4 つ**にしてある (番号で指す側)。動くのは読む順
    /// だけなので、頂点の中身しか見ない指紋はこの 2 フレームを見分けられない。
    /// `indexed: false` は同じ面を、点を書き出して置く。
    private func floorAndIndexedCaster(
        _ canvas: Canvas, order: [Int], indexed: Bool = true
    ) throws -> DisplayImage {
        let center: Float = 64
        let corners: [SIMD2<Float>] = [
            SIMD2(center - 40, -30), SIMD2(center + 40, -30),
            SIMD2(center + 40, 40), SIMD2(center - 40, 40),
        ]
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.camera(center, -24, 170, center, 14, 0, 0, 1, 0)
            canvas.perspective(Float.pi / 3, 1, 1, 500)
            canvas.ambientLight(.linear(red: 0.15, green: 0.15, blue: 0.15))
            canvas.directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.6, 0.6, -0.5)
            canvas.shadows(true)
            canvas.noStroke()

            canvas.castShadow(false)
            canvas.fill(.linear(red: 0.7, green: 0.7, blue: 0.7))
            canvas.push()
            canvas.translate(center, 40, -20)
            canvas.box(190, 8, 190)
            canvas.pop()

            canvas.castShadow(true)
            canvas.fill(.linear(red: 0.85, green: 0.5, blue: 0.3))
            canvas.beginShape(.triangles)
            canvas.normal(0, -1, 0)
            if indexed {
                for corner in corners { canvas.vertex(corner.x, corner.y, 30) }
                for number in order { canvas.index(number) }
            } else {
                for number in order { canvas.vertex(corners[number].x, corners[number].y, 30) }
            }
            canvas.endShape()
        }
        return try canvas.target.encodeForDisplay()
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
        // **細かさも宣言し直す。** フレームを越えないので ([#940])、書かないと既定へ
        // 戻り、下の行が「範囲を変えたから」ではなく「細かさが戻ったから」でも通る
        //
        // [#940]: https://github.com/mokume-metal/mokume/issues/940
        _ = try floorAndSphere(canvas, offset: 10, range: 300) { $0.shadowDetail(512) }
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
                    dust, from: .point(64, 0), toward: .plane(0...(2 * Float.pi)), rate: 300,
                    speed: 20...45, life: 0.4...1.2, size: 3...6,
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
    ///
    /// **この手順は、gpu-slot の枠 (GPU の検査の同時は 3 本まで) の外で、わざと 6 本を重ねる**
    /// ([#2004](https://github.com/mokume-metal/mokume/issues/2004))。重ねることが検出の仕組みなので、
    /// `scripts/gpu-slot.py` を前置すると 3 本ずつに下がり、検出力だけが落ちる。代わりに、
    /// 他のセッションの GPU の検査が走っていないときだけ走らせる (`pgrep -fl swiftpm-testing-helper`
    /// が空であること)。枠の規則の例外は、ここ 1 か所に置く。
    ///
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

    // MARK: - 光を向いた面を焼く (#1474)

    /// 焼き付け先の奥行きを、CPU から読める並びへ写して返す。**焼いたフレームを描き終えてから呼ぶ。**
    ///
    /// 焼き付け先は GPU だけが触る奥行きの面 (`private`・``ShadowMap/descriptor(side:)``) なので、
    /// 読める置き場へ写す 1 本を積んで終わるまで待つ。
    private func bakedDepths(of canvas: Canvas) throws -> [Float] {
        let gpu = canvas.gpu
        try gpu.settle()
        let map = try #require(canvas.shadowMap, "影を焼いていない")
        let side = map.detail
        let bytesPerRow = side * MemoryLayout<Float>.stride
        let buffer = try gpu.makeReadableBuffer(byteCount: bytesPerRow * side)
        defer { gpu.retire(buffer) }
        try gpu.withCommands { commands throws(RenderFailure) in
            guard let encoder = commands.makeComputeCommandEncoder() else {
                throw .encoderUnavailable
            }
            encoder.copy(
                sourceTexture: map.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: side, height: side, depth: 1),
                destinationBuffer: buffer, destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: 0)
            encoder.endEncoding()
            try gpu.commitAndWait(commands)
        }
        let values = buffer.contents().bindMemory(to: Float.self, capacity: side * side)
        return Array(UnsafeBufferPointer(start: values, count: side * side))
    }

    /// 宙に浮かせた箱を 1 つ焼き、焼き付いた奥行きを返す。`twoSided` なら同じ `box(40)` を
    /// `createShape` で保持して置く — 保持した形は両面で焼く列になる (`cullMode(for:)`)。
    private func bakedBox(mirrored: Bool, twoSided: Bool) throws -> [Float] {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.camera(64, -24, 170, 64, 14, 0, 0, 1, 0)
            canvas.perspective(Float.pi / 3, 1, 1, 500)
            canvas.directionalLight(.linear(red: 1, green: 1, blue: 1), -0.6, 0.6, -0.5)
            canvas.shadows(true)
            canvas.shadowDetail(256)
            canvas.noStroke()
            let retained = canvas.createShape { canvas.box(40) }
            canvas.push()
            canvas.translate(64, 0, 0)
            if mirrored { canvas.scale(-1, 1, 1) }
            canvas.rotateY(-0.6)
            canvas.rotateX(0.5)
            if twoSided { canvas.shape(retained) } else { canvas.box(40) }
            canvas.pop()
        }
        return try bakedDepths(of: canvas)
    }

    @Test("閉じた組み込みの形は、両面で焼いたときと同じ奥行き (光を向いた面) を焼く", arguments: [false, true])
    func aClosedSolidBakesItsLitFaces(mirrored: Bool) throws {
        // 組み込みの箱は裏面を捨てて焼く (`.back`)。光から見る行列は画面の縦の補正を通らない
        // ので、表の巻き方を画面から写すと光を向いた面が捨てられ、奥の面が焼き付く。
        // 両面で焼けば最も近い面 (光を向いた面) が残るので、奥行きを直に比べる
        let culled = try bakedBox(mirrored: mirrored, twoSided: false)
        let twoSided = try bakedBox(mirrored: mirrored, twoSided: true)
        #expect(culled.count == twoSided.count)
        var covered = 0
        var differing = 0
        var fartherWhenCulled = 0
        for (a, b) in zip(culled, twoSided) where a < 1 || b < 1 {
            covered += 1
            guard abs(a - b) > 1e-5 else { continue }
            differing += 1
            if a > b { fartherWhenCulled += 1 }
        }
        #expect(covered > 1000, "箱が焼き付いていない (\(covered) texel)")
        #expect(
            differing * 100 <= covered,
            "裏面を捨てて焼いた箱の奥行きが両面で焼いたときと食い違う (\(differing) / \(covered) texel。うち捨てたほうが遠い \(fartherWhenCulled))"
        )
    }

    /// 箱の置き方 (``floorAndGroundedBox(_:_:shadows:)``)。
    private enum GroundedBox {
        /// 組み込みの `box(40)`。裏面を捨てて焼く列になる
        case builtIn
        /// 組み込みの `box(40)` を横に鏡映してから逆に回す (箱は横の鏡映で自分に重なるので、
        /// ``builtIn`` と同じ形になる)
        case mirrored
        /// `createShape` で保持した `box(40)`。両面で焼く列になる
        case retained
    }

    /// 受けるだけの床に、箱を 1 つ**接して**置く絵 (箱の底面と床の上面がどちらも y = 36)。
    ///
    /// 影は手前へ落とす。奥へ落とすと、接した縁の影の側が箱自身に隠れて写らない。
    private func floorAndGroundedBox(
        _ canvas: Canvas, _ variant: GroundedBox, shadows: Bool = true
    ) throws -> DisplayImage {
        let center: Float = 64
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.camera(center, -24, 170, center, 14, 0, 0, 1, 0)
            canvas.perspective(Float.pi / 3, 1, 1, 500)
            canvas.ambientLight(.linear(red: 0.15, green: 0.15, blue: 0.15))
            canvas.directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.6, 0.6, 0.5)
            canvas.shadows(shadows)
            // **焼く範囲を広げる。** 奥の面を焼いたときに接した縁へ漏れる光の幅は、縁の余裕
            // (既定のまま) と範囲の積に比例する。既定の範囲 (面の対角) では 1 画素に満たない
            canvas.shadowRange(720)
            canvas.noStroke()

            canvas.castShadow(false)
            canvas.fill(.linear(red: 0.7, green: 0.7, blue: 0.7))
            canvas.push()
            canvas.translate(center, 40, -20)
            canvas.box(190, 8, 190)
            canvas.pop()

            canvas.castShadow(true)
            canvas.fill(.linear(red: 0.85, green: 0.5, blue: 0.3))
            let retained = canvas.createShape { canvas.box(40) }
            canvas.push()
            canvas.translate(center, 16, 0)
            switch variant {
            case .builtIn:
                canvas.rotateY(-0.6)
                canvas.box(40)
            case .mirrored:
                canvas.scale(-1, 1, 1)
                canvas.rotateY(0.6)
                canvas.box(40)
            case .retained:
                canvas.rotateY(-0.6)
                canvas.shape(retained)
            }
            canvas.pop()
        }
        return try canvas.target.encodeForDisplay()
    }

    @Test("床に接した組み込みの箱は、同じ頂点を両面で焼いた箱と同じ影を落とす")
    func aGroundedBoxCastsTheSameShadowAsItsTwoSidedCopy() throws {
        // 奥の面 (光に背を向けた面) を焼くと、接した縁の近くで焼き付いた奥行きと床の奥行きの
        // 差が縁の余裕より小さくなり、影の側の縁に沿って光が漏れる。両面で焼く保持した形は
        // 光を向いた面を焼くので漏れない
        let builtIn = try floorAndGroundedBox(try makeCanvas(), .builtIn)
        let retained = try floorAndGroundedBox(try makeCanvas(), .retained)
        let unshadowed = try floorAndGroundedBox(try makeCanvas(), .retained, shadows: false)
        let shadow = PictureDifference.between(retained, unshadowed)
        #expect(shadow.differing > 100, "比べる相手に影が落ちていない (\(shadow))")
        let difference = PictureDifference.between(builtIn, retained)
        #expect(
            difference.differing * 50 <= shadow.differing,
            "組み込みの箱の影が両面で焼いた箱の影と食い違う (\(difference) / 影 \(shadow))")
    }

    // MARK: - 鏡映した形の影 (#1446)

    @Test("鏡映した箱の影は、同じ形になる回転の箱の影と同じ")
    func aMirroredBoxCastsTheSameShadow() throws {
        // 焼き付けも画面と同じ捨て方で描き、表の巻き方は置き場所の鏡映で裏返す (#1446)。
        // 鏡映した列だけ巻き方を裏返さずに焼くと、鏡映した箱だけ光に背を向けた面が
        // 焼き付き、床に接した縁に沿って光が漏れる (#1474 と同じ場面)
        let mirrored = try floorAndGroundedBox(try makeCanvas(), .mirrored)
        let rotated = try floorAndGroundedBox(try makeCanvas(), .builtIn)
        let unshadowed = try floorAndGroundedBox(try makeCanvas(), .builtIn, shadows: false)
        // 比べ合わせる相手が影を持っていること (影の無い絵と比べて床が暗くなっている)
        let shadow = PictureDifference.between(rotated, unshadowed)
        #expect(shadow.differing > 100, "比べる相手に影が落ちていない (\(shadow))")
        let difference = PictureDifference.between(mirrored, rotated)
        #expect(difference.differing * 50 <= shadow.differing, "鏡映した箱の影が食い違う (\(difference) / 影 \(shadow))")
    }

    // MARK: - 落とす光が無いまま終えたフレーム (#1151)

    /// 影と光を置いて立体を描き、手元の表示の前置きとして末尾で光を取り除くフレーム。
    private func drawThenRemoveLights(_ canvas: Canvas) throws {
        try canvas.draw {
            canvas.directionalLight(.linear(red: 1, green: 1, blue: 1), -0.6, 0.6, -0.5)
            canvas.shadows(true)
            canvas.sphere(20)
            #expect(canvas.shadowMatrix != nil, "光を置いたのに影を焼く行列が無い")
            canvas.noLights()
            #expect(canvas.shadowMatrix == nil, "光を取り除いた後も影を焼く行列が残っている")
        }
    }

    @Test("末尾で光を取り除くと、焼き付けが読む行列が無くなる")
    func removingLightsAtTheEndLeavesNoShadowMatrix() throws {
        // 焼き付けはフレームの終わりに 1 度だけ `shadowMatrix` を読むので、末尾の
        // `noLights()` はそれより前に置いた立体の影まで消す
        try drawThenRemoveLights(try makeCanvas())
    }

    @Test("落とす光が無いままフレームを終えると、1 度だけ知らせる")
    func endingAFrameWithoutACasterWarns() throws {
        let canvas = try makeCanvas()
        try drawThenRemoveLights(canvas)
        #expect(canvas.warnings.hasWarned(.shadowWithoutCaster), "影が黙って消えている")
        let first = canvas.warnings.message(for: .shadowWithoutCaster)
        #expect(first?.hasPrefix("shadows()") == true)

        try drawThenRemoveLights(canvas)
        #expect(canvas.warnings.message(for: .shadowWithoutCaster) == first)
    }

    @Test("落とす光が残っているフレームと、影を切ったフレームでは知らせない")
    func framesWithACasterOrWithoutShadowsDoNotWarn() throws {
        let lit = try makeCanvas()
        _ = try floorAndSphere(lit)
        #expect(!lit.warnings.hasWarned(.shadowWithoutCaster), "光が残っているのに知らせている")

        let unshadowed = try makeCanvas()
        try unshadowed.draw {
            unshadowed.directionalLight(.linear(red: 1, green: 1, blue: 1), -0.6, 0.6, -0.5)
            unshadowed.shadows(false)
            unshadowed.sphere(20)
            unshadowed.noLights()
        }
        #expect(!unshadowed.warnings.hasWarned(.shadowWithoutCaster), "影を切ったのに知らせている")
    }

    // MARK: - 写しは 1 度 (#1790)

    /// **焼き直すフレームでも、立体の頂点は 1 度だけ写す** ([#1790])。
    ///
    /// 焼き付けと画面は同じ置き場を読むので、両方がそれぞれ写すと同じ中身を 2 度写す。
    /// 回すたびに光を動かして、毎フレーム焼き直させる。
    ///
    /// [#1790]: https://github.com/mokume-metal/mokume/issues/1790
    @Test("影を焼き直すフレームでも、立体の頂点を写すのは 1 度だけ")
    func rebakingFramesUploadSolidVerticesOnce() throws {
        let canvas = try makeCanvas()
        var perFrame: [Int] = []
        for frame in 0..<3 {
            let before = canvas.solidVertexStorage.writes
            let bakesBefore = canvas.shadowBakesEncoded
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.shadows(true)
                canvas.directionalLight(
                    .linear(red: 1, green: 1, blue: 1), 0.3 + Float(frame) * 0.1, 1, -0.5)
                canvas.box(40)
            }
            #expect(
                canvas.shadowBakesEncoded == bakesBefore + 1,
                "検査の前提: \(frame) 枚目で焼き直していない")
            perFrame.append(canvas.solidVertexStorage.writes - before)
        }
        #expect(perFrame == [1, 1, 1])
    }

    // MARK: - 持ち越した列の粒 (#2023)

    /// 粒の板を溜め場の先頭から離す立体。**どちらも影を落とさない。**
    ///
    /// 離さない (置き直す前の位置が 0) と、詰め直した区画の頭と位置が重なって、置き直す前の位置で
    /// 読んでも割れない。立体は形ごとに頂点を置くので、寸法を変えて数を稼ぐ。落とさない
    /// (`castShadow(false)`) のは、持ち越す落とす列を粒の 1 列だけにして、床の影が粒のものだと
    /// 言えるようにするため。
    enum Decoy: String, CaseIterable, CustomTestStringConvertible {
        /// 頂点 108 個 (約 10 KiB)。持ち越した区画 (最小 64 KiB) の中を指すので、読み違えても
        /// 区画の中の空きを読む。
        case boxes
        /// 頂点 4800 個 (約 450 KiB)。区画の最小を越えるので、読み違えると区画の外を読む。
        case sphere

        var testDescription: String { rawValue }
    }

    /// 粒を落とす側に含む場面を、途中の描き切りを入れて (`cut`)・入れずに描く。GPU は呼び手が
    /// 渡す — 場面ごとに作って捨てる回数を増やさない (全検査の負荷の下で GPU の仕事が打ち切られる
    /// 形が、GPU を作っては捨てる経路に出ると調べている最中である・
    /// [#2007](https://github.com/mokume-metal/mokume/issues/2007))。
    ///
    /// `decoysFirst` を偽にすると、立体を粒の後に置く (粒の板が溜め場の先頭に来る)。立体は隅の
    /// 小さな形で粒と重ならないので、置く順を入れ替えても、頂点を正しく読めていれば絵は変わらない。
    ///
    /// - Returns: 絵と、粒の板を置く直前の溜め場の頂点の数 (置き直す前の位置)・GPU が書いた
    ///   描き引数の `vertexStart`。
    private func carriedParticleScene(
        _ decoy: Decoy, on gpu: RenderDevice, shadows: Bool = true, cut: Bool = false,
        decoysFirst: Bool = true
    ) throws -> (image: DisplayImage, start: Int, argumentStart: Int) {
        let canvas = try CanvasFixture.make(gpu: gpu, width: 96, height: 96)
        let dust = try canvas.makeParticles(count: 64)
        var randomness = Randomness(seed: 2023)
        var start = 0
        func placeDecoys() {
            canvas.castShadow(false)
            canvas.fill(.linear(red: 0.4, green: 0.4, blue: 0.4))
            canvas.push()
            canvas.translate(8, 8, 0)
            switch decoy {
            case .boxes:
                for size: Float in [2, 3, 4] { canvas.box(size) }
            case .sphere:
                canvas.sphere(3, detail: 40)
            }
            canvas.pop()
        }
        func placeParticles() {
            canvas.castShadow(true)
            canvas.emit(
                dust, from: .point(36, 36), toward: .plane(0...0), rate: 600, speed: 0...0,
                life: 5...5, size: 24...24, color: .linear(red: 0.9, green: 0.9, blue: 0.9),
                using: &randomness)
            start = canvas.solidVertices.count
            canvas.particles(dust)
            if cut { canvas.loadPixels() }
        }
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.camera(48, -36, 120, 48, 48, 0, 0, 1, 0)
            canvas.lights()
            canvas.shadows(shadows)
            canvas.noStroke()
            if decoysFirst {
                placeDecoys()
                placeParticles()
            } else {
                placeParticles()
                placeDecoys()
            }
            canvas.castShadow(false)
            canvas.fill(.linear(red: 0.8, green: 0.8, blue: 0.8))
            canvas.push()
            canvas.translate(48, 72, 0)
            canvas.box(96, 4, 96)
            canvas.pop()
        }
        let image = try canvas.target.encodeForDisplay()
        let arguments = canvas.read(dust.arguments)
        return (image, start, Int(arguments[2].bitPattern))
    }

    /// **持ち越した粒の影は、区切らずに焼いた影と同じ所に落ちる** ([#2023])。
    ///
    /// 持ち越した落とす列は頂点を区画の頭へ詰め直す (``Canvas/frameCasters``) が、粒の列が読む位置は
    /// GPU が書いた描き引数が決める。引数が置き直す前の位置を指していると、持ち越した列だけが
    /// ずれた所を読んで、後に置いた床に粒の影が落ちない。
    ///
    /// [#2023]: https://github.com/mokume-metal/mokume/issues/2023
    @Test("持ち越した粒の影は、区切らずに描いた影と同じ絵になる", arguments: Decoy.allCases)
    func carriedParticlesCastTheSameShadowAsUncutOnes(decoy: Decoy) throws {
        let gpu = try RenderDevice()
        let plain = try carriedParticleScene(decoy, on: gpu, cut: false)
        let cut = try carriedParticleScene(decoy, on: gpu, cut: true)
        let unshadowed = try carriedParticleScene(decoy, on: gpu, shadows: false, cut: false)
        // **この検査が見ている場面であることを先に言う。** 粒の板が溜め場の先頭に無く、
        // 区切らなくても床に粒の影が落ちている
        #expect(plain.start > 0, "検査の前提: 粒の板が溜め場の先頭に無い (置き直す前の位置が 0)")
        var darker = 0
        for y in 0..<plain.image.height {
            for x in 0..<plain.image.width
            where Int(unshadowed.image[x, y].red) - Int(plain.image[x, y].red) > 20 { darker += 1 }
        }
        #expect(darker > 50, "検査の前提: 区切らなくても床に影が落ちている (\(darker) 画素)")

        var gap = 0
        for y in 0..<plain.image.height {
            for x in 0..<plain.image.width where plain.image[x, y] != cut.image[x, y] { gap += 1 }
        }
        #expect(gap == 0, "区切ると持ち越した粒の影が \(gap) 画素違う")
    }

    /// **粒は、溜め場のどこに置いても同じ絵で出る** ([#2023])。画面と影 (区切らない焼き付け) の両方。
    ///
    /// 粒の板の頂点を読む位置は、頂点の置き場へ束ねる番地 (``Canvas/Batch/vertexBaseShift``) が
    /// 決める。**番地を足し忘れると、描き引数の頭は 0 なので溜め場の先頭 (別の立体の頂点) を
    /// 読む** — 粒の板が先頭にあるときだけは合うので、先頭に置いた絵と、立体を先に置いて先頭から
    /// 離した絵を比べる。持ち越した列の検査 (上の 2 本) は、区切った絵と区切らない絵が同じ行を
    /// 通るので、この足し忘れでは割れない。
    ///
    /// [#2023]: https://github.com/mokume-metal/mokume/issues/2023
    @Test("粒の板が溜め場の先頭になくても、粒と粒の影は先頭にあるときと同じ絵になる", arguments: Decoy.allCases)
    func particlesDrawTheSameWhereverTheirQuadSits(decoy: Decoy) throws {
        let gpu = try RenderDevice()
        let first = try carriedParticleScene(decoy, on: gpu, decoysFirst: false)
        let behind = try carriedParticleScene(decoy, on: gpu)
        let unshadowed = try carriedParticleScene(decoy, on: gpu, shadows: false)
        // **この検査が見ている場面であることを先に言う。** 板の位置が先頭と先頭でない所に分かれ、
        // 粒が見えていて、床に粒の影が落ちている
        #expect(first.start == 0, "検査の前提: 比べる側の板が溜め場の先頭にある (\(first.start))")
        #expect(behind.start > 0, "検査の前提: 粒の板が溜め場の先頭に無い (置き直す前の位置が 0)")
        #expect(behind.image[40, 42].red > 200, "検査の前提: 粒が見えている")
        var darker = 0
        for y in 0..<behind.image.height {
            for x in 0..<behind.image.width
            where Int(unshadowed.image[x, y].red) - Int(behind.image[x, y].red) > 20 { darker += 1 }
        }
        #expect(darker > 50, "検査の前提: 床に粒の影が落ちている (\(darker) 画素)")

        var gap = 0
        for y in 0..<first.image.height {
            for x in 0..<first.image.width where first.image[x, y] != behind.image[x, y] { gap += 1 }
        }
        #expect(gap == 0, "粒の板の位置が先頭でないと、絵が \(gap) 画素違う")
    }

    /// **粒の列の描き引数は、頂点の頭から数える** ([#2023])。
    ///
    /// 粒の板の位置を引数に書くと、置き直した後の列 (詰め直した区画) が同じ位置を指さない。
    /// 引数の `vertexStart` は 0 に置き、頂点の置き場へ束ねる番地を列の頭へ進める
    /// (``Canvas/Batch/vertexBaseShift``)。
    ///
    /// [#2023]: https://github.com/mokume-metal/mokume/issues/2023
    @Test("粒の描き引数は、頂点の置き場の頭から数える", arguments: Decoy.allCases)
    func particleDrawArgumentsCountFromTheVertexBase(decoy: Decoy) throws {
        let scene = try carriedParticleScene(decoy, on: RenderDevice(), cut: true)
        #expect(scene.start > 0, "検査の前提: 粒の板が溜め場の先頭に無い")
        #expect(
            scene.argumentStart == 0,
            "描き引数の vertexStart が \(scene.argumentStart) (置き直す前の位置は \(scene.start))")
    }

    // MARK: - 持ち越した列の位置から導く値 (#2043)

    /// 列が描く単位 (添字の列なら読む順の並び、そうでなければ頂点の並び) での区間。
    private func drawnRange(of run: Shape.Run) -> Range<Int> {
        run.isIndexed
            ? run.indexStart..<(run.indexStart + run.indexCount) : run.start..<(run.start + run.count)
    }

    /// **持ち越した列は、粒の列も含めて、束ねる番地へ下駄を足さない** ([#2043])。
    ///
    /// 詰め直すときに頭を 0 へ置き直す条件 (``Canvas/Batch/readsPooledVertices``) と、番地へ頭を
    /// 足す条件 (``Canvas/Batch/addressesVertexHead``) が食い違うと、持ち越した粒の列が置き直す前の
    /// 頭のぶん区画の先を読む。粒の板を溜め場の先頭から離して (先に立体を置いて) 持ち越し、
    /// 持ち越した列の下駄がどれも 0 であることを見る。
    ///
    /// [#2043]: https://github.com/mokume-metal/mokume/issues/2043
    @Test("持ち越した列は、粒の列も含めて束ねる番地へ下駄を足さない")
    func carriedRunsAddNoVertexBaseShift() throws {
        let canvas = try makeCanvas(width: 64, height: 64)
        let dust = try canvas.makeParticles(count: 16)
        var randomness = Randomness(seed: 2043)
        var start = 0
        var carried: [Canvas.Batch] = []
        try canvas.draw {
            canvas.lights()
            canvas.shadows(true)
            canvas.noStroke()
            canvas.fill(.linear(red: 0.4, green: 0.4, blue: 0.4))
            for size: Float in [2, 3, 4] { canvas.box(size) }
            canvas.emit(
                dust, from: .point(32, 32), toward: .plane(0...0), rate: 600, speed: 0...0,
                life: 5...5, size: 8...8, color: .linear(red: 0.9, green: 0.9, blue: 0.9),
                using: &randomness)
            start = canvas.solidVertices.count
            canvas.particles(dust)
            canvas.loadPixels()
            carried = canvas.frameCasters.casters.map(\.batch)
        }
        // **この検査が見ている場面であることを先に言う。** 粒の列を持ち越していて、その板は
        // 溜め場の先頭に無い (置き直さなければ下駄が 0 にならない)
        #expect(start > 0, "検査の前提: 粒の板が溜め場の先頭に無い")
        #expect(
            carried.contains { $0.indirectArguments != nil }, "検査の前提: 粒の列を持ち越している")
        for batch in carried {
            #expect(
                batch.vertexBaseShift == 0,
                "持ち越した列の下駄が \(batch.vertexBaseShift) B (頭 \(batch.run.start))")
        }
    }

    /// **持ち越した列の、裏 → 表で描く部品は、置き直した列の区間の中に同じ位置で残る** ([#2043])。
    ///
    /// 部品の区間 (``Canvas/Batch/backFaceParts``) は溜め場の中の位置で持つ。詰め直すときに列の
    /// 位置だけを置き直して部品をずらさないと、部品が列の区間の外を指し、裏 → 表で描く側
    /// (`encodeBackThenFront`) が黙って読み飛ばす。持ち越した列の焼き付けは今は裏 → 表に
    /// 分けないので絵には出ない — 分ける口を足した日に壊れないことを、列の値で見る。
    ///
    /// [#2043]: https://github.com/mokume-metal/mokume/issues/2043
    @Test("持ち越した列の、裏 → 表で描く部品は、置き直した列の区間の中に同じ位置で残る")
    func carriedBackFacePartsFollowTheRelocatedRun() throws {
        let canvas = try makeCanvas(width: 64, height: 64)
        var before: [Canvas.Batch] = []
        var carried: [Canvas.Batch] = []
        try canvas.draw {
            canvas.lights()
            canvas.shadows(true)
            canvas.noStroke()
            // 落とさない立体を先に置いて、半透明の箱の列を溜め場の先頭から離す
            canvas.castShadow(false)
            canvas.fill(.linear(red: 0.4, green: 0.4, blue: 0.4))
            canvas.box(4)
            canvas.castShadow(true)
            canvas.fill(255, 255, 255, 128)
            canvas.translate(32, 32, 0)
            canvas.box(20)
            canvas.closeBatch()
            before = canvas.batches.filter(\.castsShadow)
            canvas.loadPixels()
            carried = canvas.frameCasters.casters.map(\.batch)
        }
        // **この検査が見ている場面であることを先に言う。** 裏 → 表で描く列を 1 つだけ持ち越し、
        // その列は溜め場の先頭に無い (置き直すと位置が動く)
        try #require(before.count == 1 && carried.count == 1, "検査の前提: 落とす列が 1 つ")
        let (original, moved) = (before[0], carried[0])
        #expect(original.drawsBackThenFront, "検査の前提: 裏 → 表で描く列")
        let from = drawnRange(of: original.run)
        let to = drawnRange(of: moved.run)
        #expect(from.lowerBound > 0, "検査の前提: 列が溜め場の先頭に無い (\(from))")
        #expect(to.lowerBound == 0, "検査の前提: 持ち越した列は区画の頭へ置き直される (\(to))")

        #expect(moved.drawsBackThenFront, "持ち越した列が裏 → 表で描く部品を失った")
        #expect(moved.backFaceParts.count == original.backFaceParts.count)
        for (part, source) in zip(moved.backFaceParts, original.backFaceParts) {
            #expect(
                part.range.lowerBound - to.lowerBound == source.range.lowerBound - from.lowerBound
                    && part.range.count == source.range.count,
                "部品 \(source.range) (列 \(from)) が、置き直した列 \(to) で \(part.range) を指す")
            #expect(
                to.contains(part.range.lowerBound) && part.range.upperBound <= to.upperBound,
                "部品 \(part.range) が置き直した列 \(to) の外にある")
        }
    }
}

/// 混ませて繰り返す回数。`MOKUME_SHADOW_STRESS` に入れた数だけ回す。
///
/// 走らせるかどうかは検査の外で決まるので、隔離の外に置く。
nonisolated let shadowStressRounds =
    Int(ProcessInfo.processInfo.environment["MOKUME_SHADOW_STRESS"] ?? "") ?? 0
