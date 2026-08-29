// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 表面の質感が絵に出ることの検査。GPU を要する。
///
/// 材質は**例外を出さずに壊れる** — 効いていない指定も、向きが逆の指定も、絵が
/// 少し違うだけである。だから**画素の意味**で確かめる ([ADR-0019] 決定 4)。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "表面の質感",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MaterialTests {
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.opaque(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 正面から見た球を 1 つ。材質だけを差し替えられる形にしてある。
    ///
    /// 光は**底上げ + 手前上から差す光**で固定する。艶は見る向きに依るので、
    /// 手前から差す光でないと画面の中に艶が出ない。
    private func sphere(
        _ canvas: Canvas, lights: ((Canvas) -> Void)? = nil, material: (Canvas) -> Void
    ) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(black)
            if let lights {
                lights(canvas)
            } else {
                canvas.ambientLight(.opaque(red: 0.15, green: 0.15, blue: 0.15))
                canvas.directionalLight(
                    .opaque(red: 0.55, green: 0.55, blue: 0.55), -0.3, 0.4, -0.85)
            }
            material(canvas)
            // **飽和した面の上には艶が乗らない。** 明るさに余地を残しておかないと、
            // 艶が出ているのに絵が変わらず、検査は「効いていない」と読めてしまう
            canvas.fill(.opaque(red: 0.45, green: 0.42, blue: 0.4))
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.sphere(24)
            canvas.pop()
        }
        return try canvas.target.encodeForDisplay()
    }

    /// 球の中で、いちばん明るかった画素の明るさ。
    private func peak(_ image: DisplayImage) -> Int {
        var best = 0
        for y in 0..<image.height {
            for x in 0..<image.width { best = max(best, Int(image[x, y].red)) }
        }
        return best
    }

    /// 指定した明るさ以上の画素の数。艶の広さを数えるのに使う。
    private func count(_ image: DisplayImage, brighterThan threshold: Int) -> Int {
        var total = 0
        for y in 0..<image.height {
            for x in 0..<image.width where Int(image[x, y].red) > threshold { total += 1 }
        }
        return total
    }

    /// 球の中の画素の明るさの合計。全体が明るいか暗いかを見る。
    private func total(_ image: DisplayImage) -> Int {
        var sum = 0
        for y in 0..<image.height {
            for x in 0..<image.width { sum += Int(image[x, y].red) }
        }
        return sum
    }

    // MARK: - 既定は何も変えない

    @Test("既定の材質を書いても、書かなかったときと 1 画素も変わらない")
    func defaultMaterialChangesNothing() throws {
        let plain = try sphere(try makeCanvas()) { _ in }
        let written = try sphere(try makeCanvas()) {
            $0.shininess(0)
            $0.metalness(0)
            $0.ambient(.opaque(red: 1, green: 1, blue: 1))
            $0.emissive(.opaque(red: 0, green: 0, blue: 0))
        }
        // 既定が「何も変えない」でなければ、材質を足すだけで既にある絵が動く
        #expect(plain.bytes == written.bytes)
    }

    // MARK: - 艶と粗さ

    @Test("艶を上げると、いちばん明るいところがさらに明るくなる")
    func shininessAddsAHighlight() throws {
        let dull = try sphere(try makeCanvas()) { _ in }
        let glossy = try sphere(try makeCanvas()) { $0.shininess(48) }
        #expect(peak(glossy) > peak(dull))
    }

    @Test("艶の鋭さを上げると、艶は狭くなる (粗い面ほど広くぼやける)")
    func higherShininessNarrowsTheHighlight() throws {
        // 手本の綴りをそのまま採ったので、**大きいほど鋭い**。向きを取り違えると
        // 「粗さ」を指定したつもりで滑らかになるが、例外は出ず絵が変わるだけである
        let base = try sphere(try makeCanvas()) { _ in }
        let rough = try sphere(try makeCanvas()) { $0.shininess(4) }
        let smooth = try sphere(try makeCanvas()) { $0.shininess(120) }

        // **明るさの絶対値では数えない。** 艶は広がるほど薄くなる (光の量は同じ)
        // ので、決め打ちの明るさで数えると鋭い艶しか拾えない。艶が乗った**面積**を
        // 見る
        let wide = area(of: rough, over: base)
        let narrow = area(of: smooth, over: base)
        #expect(wide > 0, "粗い面に艶が出ていない")
        #expect(narrow > 0, "滑らかな面に艶が出ていない")
        #expect(wide > narrow * 2)
    }

    /// 艶が乗った面積 — 艶なしの絵よりはっきり明るくなった画素の数。
    private func area(of image: DisplayImage, over base: DisplayImage) -> Int {
        var total = 0
        for y in 0..<image.height {
            for x in 0..<image.width
            where Int(image[x, y].red) > Int(base[x, y].red) + 2 { total += 1 }
        }
        return total
    }

    // MARK: - 金属

    @Test("金属にすると、拡散が消えて全体が暗くなる")
    func metalLosesDiffuse() throws {
        let plastic = try sphere(try makeCanvas()) { _ in }
        let metal = try sphere(try makeCanvas()) { $0.metalness(1) }
        #expect(total(metal) < total(plastic))
    }

    @Test("底上げの光があれば、金属は真っ黒にならない")
    func metalReflectsTheSurroundings() throws {
        // 金属は周りを映すことでしか見えない。映す先が無いと「壊れた」としか
        // 見えない絵になるので、底上げの光を一様な周りとして映す
        let image = try sphere(try makeCanvas()) { $0.metalness(1) }
        #expect(peak(image) > 20)
    }

    @Test("金属の艶は塗りの色に染まり、非金属の艶は光の色のまま出る")
    func metalTintsItsHighlight() throws {
        // 青い光を、赤い面へ当てる。艶そのものの色を見たいので、**艶を足したことに
        // よる増分**で比べる (面の色そのものは赤いままなので、絶対値では読めない)。
        // 増分は**作業空間の値**で見る — 表示へのエンコードは暗い成分ほど大きく
        // 持ち上げるので、成分どうしの比較はエンコード後には成り立たない
        func gain(metalness: Float) throws -> (red: Float, blue: Float) {
            func render(shininess: Float) throws -> PixelBuffer {
                let canvas = try makeCanvas()
                try canvas.draw {
                    canvas.background(black)
                    canvas.ambientLight(.opaque(red: 0.08, green: 0.08, blue: 0.08))
                    canvas.directionalLight(.opaque(red: 0.03, green: 0.03, blue: 0.5), 0, 0, -1)
                    canvas.shininess(shininess)
                    canvas.metalness(metalness)
                    canvas.fill(.opaque(red: 0.8, green: 0.02, blue: 0.02))
                    canvas.push()
                    canvas.translate(32, 32, 0)
                    canvas.sphere(24)
                    canvas.pop()
                }
                return try canvas.target.readPixels()
            }
            let dull = try render(shininess: 0)
            let glossy = try render(shininess: 8)
            return (
                glossy[32, 32].red - dull[32, 32].red,
                glossy[32, 32].blue - dull[32, 32].blue
            )
        }

        let plastic = try gain(metalness: 0)
        let metal = try gain(metalness: 1)
        #expect(plastic.blue > plastic.red * 4, "非金属の艶が光の色になっていない")
        #expect(metal.red > metal.blue * 1.5, "金属の艶が塗りの色に染まっていない")
    }

    // MARK: - 周りへの返しと自発光

    @Test("周りへの返しを下げると、底上げの光の分だけ暗くなる")
    func ambientResponseDarkensTheSurroundings() throws {
        let onlySurroundings: (Canvas) -> Void = {
            $0.ambientLight(.opaque(red: 0.6, green: 0.6, blue: 0.6))
        }
        let full = try sphere(try makeCanvas(), lights: onlySurroundings) { _ in }
        let occluded = try sphere(try makeCanvas(), lights: onlySurroundings) {
            $0.ambient(.opaque(red: 0.25, green: 0.25, blue: 0.25))
        }
        // 比べるのは**エンコードを経た値**なので、線形での 0.25 倍はここでは
        // 半分ほどにしか見えない。それでもはっきり暗いことは読める
        #expect(Int(occluded[32, 32].red) < Int(full[32, 32].red) * 3 / 5)
        #expect(occluded[32, 32].red > 0)
    }

    @Test("自ら出す光は、光の当たらない側にも出る")
    func emissiveShowsWhereNoLightReaches() throws {
        // 手前から当てる光だけを置き、光の当たらない縁を見る
        let lights: (Canvas) -> Void = { $0.directionalLight(white, 0, 0, -1) }
        let plain = try sphere(try makeCanvas(), lights: lights) { _ in }
        let glowing = try sphere(try makeCanvas(), lights: lights) {
            $0.emissive(.opaque(red: 0.5, green: 0.5, blue: 0.5))
        }
        // 球のいちばん暗いところ (光が斜めにしか当たらない縁) で比べる
        var darkest = (x: 0, y: 0, value: 256)
        for y in 0..<plain.height {
            for x in 0..<plain.width {
                let value = Int(plain[x, y].red)
                if value > 0, value < darkest.value { darkest = (x, y, value) }
            }
        }
        #expect(darkest.value < 120, "光の当たらない側が見つからない")
        #expect(Int(glowing[darkest.x, darkest.y].red) > darkest.value + 60)
    }

    // MARK: - 寿命と積み方

    @Test("材質はフレームを越えない")
    func materialDoesNotCrossFrames() throws {
        let canvas = try makeCanvas()
        _ = try sphere(canvas) { $0.metalness(1) }
        // 2 フレーム目は何も書かない。既定へ戻っていなければ金属のまま暗く出る
        let second = try sphere(canvas) { _ in }
        let reference = try sphere(try makeCanvas()) { _ in }
        #expect(second.bytes == reference.bytes)
    }

    @Test("初期化のときに書いた材質は、どのフレームにも属さないので無視される")
    func materialOutsideAFrameIsIgnored() throws {
        let canvas = try makeCanvas()
        // 描くところの外なので、警告を出して無視する (ADR-0021 決定 4)
        canvas.metalness(1)
        #expect(canvas.currentMaterial == .default)

        let image = try sphere(canvas) { _ in }
        let reference = try sphere(try makeCanvas()) { _ in }
        #expect(image.bytes == reference.bytes)
    }

    @Test("積んだスタイルへ戻すと、材質も戻る")
    func styleStackRestoresTheMaterial() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.shininess(10)
            canvas.pushStyle()
            canvas.shininess(90)
            canvas.metalness(1)
            canvas.popStyle()
        }
        // draw を抜けた後はフレームの外なので既定へ戻っている。中で確かめる
        var insideShininess: Float = -1
        var insideMetalness: Float = -1
        try canvas.draw {
            canvas.shininess(10)
            canvas.pushStyle()
            canvas.shininess(90)
            canvas.metalness(1)
            canvas.popStyle()
            insideShininess = canvas.currentMaterial.shininess
            insideMetalness = canvas.currentMaterial.metalness
        }
        #expect(insideShininess == 10)
        #expect(insideMetalness == 0)
    }

    @Test("材質を変えても、既に置いた立体は置いた時点の材質のまま")
    func placedSolidsKeepTheirMaterial() throws {
        // 記録した列だけで絵が決まる (ADR-0021 決定 2)。後から書いた材質が
        // 遡って効くと、置いた順に読めるという前提が崩れる
        let canvas = try makeCanvas(width: 96, height: 64)
        try canvas.draw {
            canvas.background(black)
            canvas.ambientLight(.opaque(red: 0.15, green: 0.15, blue: 0.15))
            canvas.directionalLight(
                .opaque(red: 0.55, green: 0.55, blue: 0.55), -0.3, 0.4, -0.85)
            canvas.fill(.opaque(red: 0.45, green: 0.42, blue: 0.4))
            canvas.push()
            canvas.translate(24, 32, 0)
            canvas.sphere(18)
            canvas.pop()
            canvas.metalness(1)
            canvas.push()
            canvas.translate(72, 32, 0)
            canvas.sphere(18)
            canvas.pop()
        }
        let image = try canvas.target.encodeForDisplay()
        var left = 0
        var right = 0
        for y in 0..<image.height {
            for x in 0..<48 { left += Int(image[x, y].red) }
            for x in 48..<96 { right += Int(image[x, y].red) }
        }
        #expect(left > right, "先に置いた球まで、後から書いた金属で描かれている")
    }

    // MARK: - 代表シーンの検出力

    @Test(
        "代表シーンが、質感の指定を写している",
        arguments: Scene.Ingredient.materialAspects)
    func theSceneShowsEveryMaterialSetting(_ aspect: Scene.Ingredient) throws {
        // **指定を潰して絵が動かなければ、その代表シーンはその質感を写していない。**
        // 台帳は「触っていない絵が動いていないか」しか見られないので、そもそも
        // 写っていない質感は、壊れても台帳に現れない
        let full = try picture(without: nil)
        let flattened = try picture(without: aspect)

        var moved = 0
        for y in 0..<full.height {
            for x in 0..<full.width {
                let a = full[x, y]
                let b = flattened[x, y]
                let difference = max(
                    abs(Int(a.red) - Int(b.red)),
                    max(abs(Int(a.green) - Int(b.green)), abs(Int(a.blue) - Int(b.blue))))
                if difference >= 8 { moved += 1 }
            }
        }
        let fraction = Double(moved) / Double(full.width * full.height)
        #expect(
            fraction > 0.01,
            "\(aspect) を潰しても絵が動かない (動いた画素 \(moved) / \(full.width * full.height))")
    }

    /// 質感の代表シーンを、指定を 1 つ潰して描く。
    private func picture(without aspect: Scene.Ingredient?) throws -> DisplayImage {
        let scene = Scene.materials
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: scene.size.width, height: scene.size.height)
        let canvas = try Canvas(target: target, gpu: gpu)
        try canvas.draw { scene.draw(on: canvas, without: aspect) }
        return try target.encodeForDisplay()
    }

    // MARK: - 効かない指定を黙らせない

    @Test("光が無いところで材質を書いたら、効かないと分かる")
    func materialWithoutLightIsReported() throws {
        var material = Material.default
        material.shininess = 30
        #expect(Material.unusableReason(material, lights: [], surroundings: nil) == .noLight)
        #expect(Material.unusableReason(.default, lights: [], surroundings: nil) == nil)
        // 周囲があれば、光が無くても材質は効く
        #expect(Material.unusableReason(material, lights: [], surroundings: .sky) == nil)
    }

    @Test("映す先が無いまま金属を上げたら、暗くなると分かる")
    func metalWithoutSurroundingsIsReported() throws {
        var metal = Material.default
        metal.metalness = 1
        let directional = Light(kind: .directional, color: .opaque(red: 1, green: 1, blue: 1))
        let ambient = Light(kind: .ambient, color: .opaque(red: 0.2, green: 0.2, blue: 0.2))
        #expect(
            Material.unusableReason(metal, lights: [directional], surroundings: nil)
                == .metalWithoutSurroundings)
        #expect(
            Material.unusableReason(metal, lights: [directional, ambient], surroundings: nil)
                == nil)
        // 周囲を置けば、それが映す先になる
        #expect(
            Material.unusableReason(metal, lights: [directional], surroundings: .sky) == nil)
    }

    // MARK: - 壊れた入力

    @Test("数でない値・範囲の外の値では、材質を変えない")
    func brokenInputLeavesTheMaterialAlone() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.shininess(30)
            canvas.shininess(.nan)
            canvas.shininess(-1)
            canvas.shininess(.infinity)
            canvas.metalness(2)
            canvas.metalness(-0.5)
            canvas.ambient(.opaque(red: -1, green: 0, blue: 0))
            canvas.emissive(.opaque(red: .nan, green: 0, blue: 0))
            #expect(canvas.currentMaterial.shininess == 30)
            #expect(canvas.currentMaterial.metalness == 0)
            #expect(canvas.currentMaterial.ambient == SIMD3(1, 1, 1))
            #expect(canvas.currentMaterial.emissive == SIMD3(0, 0, 0))
        }
    }
}
