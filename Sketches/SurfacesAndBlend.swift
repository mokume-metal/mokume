// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 名前で渡した面を、断片の中で掛け合わせる。
///
/// **1 度だけ焼いた絵を、断片から名前で読む。** 木目は動かないので毎フレーム作り直す
/// 必要が無く、焼いた 1 枚をそのまま渡せばよい ([#407](https://github.com/mokume-metal/mokume/issues/407))。
///
/// 左の板は木目だけ、右の板は**木目と汚しを掛け合わせたもの**。汚しは自分で描いた面で、
/// 読み込んだ絵と同じように渡せる。**同じ形・同じ回し方で、渡した面の数だけが違う。**
///
/// **汚しは 1 秒ごとに差し替わる。** 断片は組み直さず、名前で渡した面だけを
/// ``Shader/set(_:_:)-(_,ShaderSurface)`` で取り替える — 面の宣言は作るときに決まって
/// いるので、変えられるのは中身だけである。下に並べた 2 枚が差し替える候補で、枠の付いた
/// ほうがいま右の板に掛かっている (描いた面を `image(_:_:_:_:_:)` でそのまま置く)。
/// 真ん中上の小さな箱は、同じ面を断片を使わずに `texture(_:)` で貼ったもの。
/// **名前で渡しても、貼っても、描いた面は読み込んだ絵と同じに扱える。**
final class SurfacesAndBlend: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "surfaces and blend")

    /// 焼いた木目。**1 度だけ作る** — 板は動かないので、断片の中で作り直す理由が無い。
    private var grain: Image?
    /// 描いた汚し。**自分で描いた面も、読み込んだ絵と同じ渡し方で渡せる。**
    private var smudge: Canvas?
    /// もう 1 枚の汚し。**右の板の面を後から差し替える先**になる。
    private var scuff: Canvas?
    /// いま右の板に掛けている汚し (0 が `smudge`・1 が `scuff`)。
    private var showing = 0

    /// 木目だけを読む塗り。渡す面は 1 枚。
    private var plain: Shader?
    /// 木目と汚しを掛け合わせる塗り。渡す面は 2 枚。
    private var blended: Shader?

    /// 板の寸法。読み取り位置をここから作るので、形と塗りで同じ数を使う。
    private static let board = (width: Float(300), depth: Float(190))

    func setup() {
        guard let grain = bakeGrain(), let smudge = paintSmudge() else { return }
        self.grain = grain
        self.smudge = smudge
        scuff = paintScuff()

        // **形自身の座標から読む位置を作る** ので、板を回しても模様は面に留まる
        let place = """
            float2 spot = in.shapePosition.xz * values.scale + 0.5;
            """
        plain = try? makeShader(
            """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                \(place)
                float4 wood = mokume_sample(surfaces.grain, spot);
                return float4(wood.rgb * in.color.rgb, in.color.a);
            }
            """,
            name: "plain", values: settingsForBoard, surfaces: ["grain": .image(grain)])
        blended = try? makeShader(
            """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                \(place)
                float4 wood = mokume_sample(surfaces.grain, spot);
                // 汚しは濃さとして効かせる。**2 枚が別の役目を持つ**ので、
                // 片方だけ届かなくなったときに絵の変わり方で読み分けられる
                float dirt = mokume_sample(surfaces.smudge, spot).r;
                return float4(
                    wood.rgb * mix(1.0, dirt, values.amount) * in.color.rgb, in.color.a);
            }
            """,
            name: "blended", values: settingsForBoard,
            surfaces: ["grain": .image(grain), "smudge": .graphics(smudge)])
    }

    private var settingsForBoard: [String: ShaderValue] {
        [
            "scale": .pair(1 / Self.board.width, 1 / Self.board.depth),
            "amount": 0.85,
        ]
    }

    func draw() {
        background(.studio)
        surroundings(.studio)
        ambientLight(.linear(red: 0.10, green: 0.10, blue: 0.12))
        directionalLight(color(255, 242, 224), -0.4, 0.7, -0.6)
        noStroke()

        // **面だけを差し替える。** 断片は組み直さない。変わったときだけ渡し直す
        let candidates = [smudge, scuff]
        let choice = Int(time) % 2
        if choice != showing, let next = candidates[choice] {
            blended?.set("smudge", .graphics(next))
            showing = choice
        }

        // **同じ姿勢で 2 枚**。時計はフレーム番号から導かれるので、何度撮っても同じ動き
        let spin = time * 0.55
        for (index, painted) in [plain, blended].enumerated() {
            push()
            translate(width * 0.28 + Float(index) * width * 0.44, height * 0.52, 0)
            rotateX(-0.45)
            rotateY(spin)
            if let painted { shader(painted) }
            // 断片は `in.color` を掛けて使う。白で塗っておくと、そこに光の強さだけが載る
            fill(255, 255, 255)
            box(Self.board.width, 18, Self.board.depth)
            resetShader()
            pop()
        }

        // 同じ面を、断片を使わずに貼る。**貼る絵はフレームを越える**ので、置いたら外す
        if let current = candidates[showing] {
            push()
            translate(width / 2, height * 0.2, 0)
            rotateX(-0.5)
            rotateY(spin * 1.3)
            fill(255, 255, 255)
            texture(current)
            box(64)
            noTexture()
            pop()
        }

        // 差し替える候補。**描いた面をそのまま絵として置き**、いま掛けているほうに枠を付ける
        let thumb = Float(88)
        for (index, candidate) in candidates.enumerated() {
            guard let candidate else { continue }
            let x = width / 2 - thumb - 6 + Float(index) * (thumb + 12)
            let y = height * 0.8
            image(candidate, x, y, thumb, thumb)
            if index == showing {
                noFill()
                stroke(255, 214, 140)
                strokeWeight(2)
                rect(x - 4, y - 4, thumb + 8, thumb + 8)
                noStroke()
            }
        }
    }

    /// 木目を焼く。**断片の中で作り直さない** — これを渡せることが #407 の要点である。
    private func bakeGrain() -> Image? {
        guard let image = try? createImage(256, 256) else { return nil }
        for y in 0..<256 {
            for x in 0..<256 {
                // 年輪の中心を板の外に置くと、弧が横切る挽いた板らしい面になる
                let across = SIMD2(Float(x) * 0.34 - 150, Float(y))
                let drift = sin(Float(y) * 0.05) * 7
                let rings = 0.5 + 0.5 * sin((across.length + drift) * 0.26)
                image.set(
                    x, y,
                    .display(
                        red: 0.45 + rings * 0.37,
                        green: 0.29 + rings * 0.35,
                        blue: 0.17 + rings * 0.27))
            }
        }
        return image
    }

    /// 汚しを描く。**描いた面をそのまま渡す**ので、書き出して読み直す手間が要らない。
    private func paintSmudge() -> Canvas? {
        guard let canvas = try? createGraphics(256, 256) else { return nil }
        canvas.beginDraw()
        canvas.background(255, 255, 255)
        canvas.noStroke()
        // 濃さの違う染みを重ねる。**位置は式で決める** — 何度描いても同じ絵になる
        for index in 0..<48 {
            let step = Float(index)
            let x = 128 + cos(step * 2.4) * (30 + step * 2.1)
            let y = 128 + sin(step * 1.7) * (26 + step * 2.3)
            let shade = 0.35 + 0.5 * abs(sin(step * 0.9))
            canvas.fill(.display(red: shade, green: shade, blue: shade, alpha: 0.5))
            canvas.circle(x, y, 18 + 26 * abs(cos(step * 0.6)))
        }
        canvas.endDraw()
        return canvas
    }

    /// もう 1 枚の汚しを描く。**斜めの擦り傷**で、染みとは違う向きの模様にする —
    /// 差し替えたことが板の上で読めるように。
    private func paintScuff() -> Canvas? {
        guard let canvas = try? createGraphics(256, 256) else { return nil }
        canvas.beginDraw()
        canvas.background(255, 255, 255)
        canvas.strokeWeight(5)
        for index in 0..<28 {
            let step = Float(index)
            let shade = 0.3 + 0.45 * abs(sin(step * 1.3))
            canvas.stroke(.display(red: shade, green: shade, blue: shade, alpha: 0.7))
            let start = -40 + step * 12
            canvas.line(start, 0, start + 110 + 30 * sin(step), 256)
        }
        canvas.endDraw()
        return canvas
    }
}

extension SIMD2 where Scalar == Float {
    fileprivate var length: Float { (x * x + y * y).squareRoot() }
}
