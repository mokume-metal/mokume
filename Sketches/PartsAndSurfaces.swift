// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 同じ部品を本体と別の描画面へ描き、更新される面を3つの読み手で比較する。
///
/// 上の部品は本体の寸法、下の3枚は240×140を名乗る。閉包後の右下の黄色い印は本体の
/// width/heightで置くので、描画先が戻らないと違う位置へ出る。
/// 下は左から image、textureを貼った矩形、setupで一度だけ作った保持した形。
/// vignetteを通した同じ面の番号・色・円の位置が揃い、一つだけ古い絵へ戻らないかを見る。
///
/// `--render /tmp/parts --frames 150` で更新→停止→再開を見る (全例の連番を出力する)。
/// 0始まりの60〜119フレームは面を描き直さず、59の内容を保つ。120で3枚とも更新へ戻る。
/// 本体の部品は停止中も動く。180フレーム周期で繰り返すので、窓でも追える。
/// 同じフレーム内の「置く→面を書き換える→別の位置へ置く」は EffectsAndCustom が担当する。
/// あちらの6枚は同じ面を再利用しても、先に置いた絵が後の効果へ変わらないことを示す。
final class PartsAndSurfaces: Sketch {
    private let part = SurfaceStamp()
    private var pad: Canvas!
    private var retained = Shape.empty
    private var sourceFrame = 0

    var settings: SketchSettings {
        SketchSettings(width: 960, height: 560, title: "parts and surfaces")
    }

    func setup() throws {
        pad = try createGraphics(240, 140)
        // 効果を通す前に一度だけ保持する。毎回作り直して参照の古さを隠さない。
        retained = createShape {
            noStroke()
            fill(255)
            texture(pad)
            rect(0, 0, 240, 140)
            noTexture()
        }
    }

    func draw() {
        background(18, 22, 30)
        noStroke()
        fill(230)
        textSize(16)
        text("SketchPart on main canvas", 20, 30)
        push()
        translate(20, 50)
        part.paint()
        pop()

        let step = (frameCount - 1) % 180
        let paused = (60..<120).contains(step)
        if !paused {
            sourceFrame = frameCount - 1
            // Canvas.draw は面のフレームを開くだけで、素の circle 等は本体へ行く。
            // draw(into:) は素の呼び出しと部品の読み取り先も pad へ向ける。
            draw(into: pad) {
                background(0)
                part.paint()
                effects([.vignette(amount: 0.6)])
            }
        }

        fill(230)
        text("back on main: \(Int(width)) x \(Int(height)) | \(paused ? "HOLD source frame \(sourceFrame)" : "UPDATE")", 20, 225)
        // この場所は閉包を抜けた後の width/height で決まる。
        fill(255, 220, 70)
        square(width - 24, height - 24, 12)

        noTint()
        fill(255)
        image(pad, 20, 290)
        push()
        translate(350, 290)
        texture(pad)
        rect(0, 0, 240, 140)
        noTexture()
        pop()
        shape(retained, 680, 290)

        fill(230)
        text("image(pad)", 20, 465)
        text("texture(pad) + rect", 350, 465)
        text("retained shape (built once)", 680, 465)
        text("Compare content and source frame, not edge interpolation. All three include vignette.", 20, 510)
    }
}

/// 呼んだ先の寸法と、スケッチ共通の時刻を読む小さな部品。
private struct SurfaceStamp: SketchPart {
    func paint() {
        let wide = min(width, 240)
        let tall = min(height, 140)
        noStroke()
        fill(60 + 90 * (0.5 + 0.5 * sin(time * 2)), 85, 145)
        rect(0, 0, wide, tall)
        fill(245)
        textSize(16)
        text("\(Int(width)) x \(Int(height))", 12, 25)
        text("source frame \(frameCount - 1)", 12, tall - 12)
        fill(255, 205, 65)
        circle(24 + (wide - 48) * (0.5 + 0.5 * sin(time * 2)), tall / 2, 28)
    }
}
