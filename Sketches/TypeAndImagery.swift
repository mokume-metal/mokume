// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 文字・画像・保持した形。
///
/// **下の段は、同じ 1 枚の絵を 3 つの道で持ち込んだもの。** 左から、画素の並びを
/// `Image.write` で直に書いた絵・その並びを PNG に書き出して `loadImage` で読んだ絵・
/// 別の PNG を `requestImage` で待たずに読んだ絵で、3 枚が同じ色で並べば読み込みの
/// 色の扱いが書き込みと揃っている。`requestImage` は届くまで `Image.fill` で埋めた
/// 仮の絵を置くので、届く前も後も段は崩れない。**書き出した絵は届く前の姿である** —
/// 書き出しはフレームを続けて進めるだけで、待っている仕事に番を回さないため。窓で
/// 走らせると 3 枚目も同じ絵に替わる。
///
/// その右は、`imageMode(.center)` で白い点を中心に置いた**左上の切り出し** (引数 9 つの
/// `image`)、`Image.get` で絵の 1 画素を読んだ色の円、`+` で葉と茎を 1 つに畳んだ形。
final class TypeAndImagery: Sketch {
    var settings = SketchSettings(width: 960, height: 720, title: "type and imagery")

    /// 毎フレーム組み立て直さない葉。色は形の中で決まる。
    private var leaf = Shape.empty
    /// 組にした一房。置くのは 1 回で済む。
    private var cluster = Shape.empty
    /// 自分で描いた絵。
    private var swatch: Image?
    /// 葉と茎を `+` で 1 つに畳んだ形。
    private var sprout = Shape.empty
    /// 画素の並びを直に書いた絵。
    private var written: Image?
    /// ファイルから、読み終わるまで待って読んだ絵。
    private var loaded: Image?
    /// ファイルから、待たずに読んだ絵。**届くまでは nil**
    private var requested: Image?
    /// 届くまで代わりに置く絵。
    private var pending: Image?

    func setup() {
        leaf = createShape {
            fill(115, 217, 128)
            stroke(31, 89, 56)
            strokeWeight(2)
            beginShape()
            vertex(0, -22)
            bezierVertex(16, -14, 16, 14, 0, 22)
            bezierVertex(-16, 14, -16, -14, 0, -22)
            endShape(.close)
        }
        cluster = Shape.group(
            (0..<9).map { index in
                createShape {
                    push()
                    translate(Float(index % 3) * 46, Float(index / 3) * 46)
                    rotate(Float(index) * 0.4)
                    shape(leaf)
                    pop()
                }
            })

        // 絵を自分で組み立てる。画素へ直に書ける
        let image = try? createImage(64, 64)
        for y in 0..<64 {
            for x in 0..<64 {
                let wave = 0.5 + 0.5 * sin(Float(x) * 0.2) * cos(Float(y) * 0.2)
                image?.set(x, y, .display(red: wave, green: 0.35, blue: 1 - wave))
            }
        }
        swatch = image

        // 茎を足して、2 つの形を 1 つに畳む。置くのは 1 回で済む
        let stem = createShape {
            stroke(31, 89, 56)
            strokeWeight(3)
            line(0, 22, 0, 54)
        }
        sprout = leaf + stem

        // 読み込む絵。**リポジトリには画像ファイルを置けない** (`scripts/check-no-binaries.sh`)
        // ので、画素の並びをここで組んで書き出してから読んでいる。**普通のスケッチに
        // 書き出しは要らない** — 手元にあるファイルの場所を渡すだけでよい
        let picture = Self.picture()
        written = try? createImage(picture.width, picture.height)
        written?.write(picture)
        let folder = FileManager.default.temporaryDirectory
        let loadedURL = folder.appendingPathComponent("mokume-reference-picture.png")
        try? PNGFile.write(picture, to: loadedURL)
        loaded = try? loadImage(loadedURL.path)

        // 待たずに読むほうは別のファイルにする — 同じファイルは控えに当たり、
        // 別の仕事を起こさずに返るため
        let requestedURL = folder.appendingPathComponent("mokume-reference-picture-requested.png")
        try? PNGFile.write(picture, to: requestedURL)
        pending = try? createImage(picture.width, picture.height)
        pending?.fill(color(64, 76, 102))
        // 待つのは Task の仕事。届くまでは下の draw() が仮の絵を置く
        Task {
            requested = try? await requestImage(requestedURL.path)
        }
    }

    /// 読み込む絵の中身。表示できる形 (8 bit・アルファは乗算しない) の並びで組む。
    ///
    /// 左上の 32×24 だけを黄色の縞にしてあるので、切り出しがどこを読んでいるかが絵から分かる。
    private static func picture() -> DisplayImage {
        let (wide, tall) = (96, 64)
        var bytes = [UInt8](repeating: 255, count: wide * tall * 4)
        for y in 0..<tall {
            for x in 0..<wide {
                let index = (y * wide + x) * 4
                let stripe = (x + y) % 8 < 4
                if x < 32, y < 24 {
                    bytes[index] = stripe ? 242 : 120
                    bytes[index + 1] = stripe ? 204 : 90
                    bytes[index + 2] = stripe ? 64 : 30
                } else {
                    bytes[index] = UInt8(40 + x * 2)
                    bytes[index + 1] = stripe ? 150 : 110
                    bytes[index + 2] = UInt8(230 - y * 2)
                }
            }
        }
        return DisplayImage(width: wide, height: tall, bytes: bytes)
    }

    func draw() {
        background(18, 20, 28)
        textFont("Helvetica")

        // 見出しと、揃え方
        noStroke()
        fill(242, 235, 217)
        textSize(46)
        text("mokume", 48, 90)
        textSize(18)
        fill(153, 166, 191)
        textAlign(.left)
        text("左に揃える", 48, 130)
        textAlign(.center)
        text("中央に揃える", 300, 130)
        textAlign(.right)
        text("右に揃える", 560, 130)
        textAlign(.left)

        // 矩形へ流し込む
        stroke(64, 76, 102)
        strokeWeight(1)
        noFill()
        rect(48, 160, 380, 150)
        noStroke()
        fill(217, 224, 242)
        textSize(17)
        textLeading(26)
        _ = text(
            "文字は矩形へ流し込める。折り返しは幅を測ってから決まり、"
                + "入り切らなかったぶんは返ってくるので、続きを別の場所へ置ける。",
            56, 170, 364, 130)

        // 字の輪郭を図形として扱う
        push()
        translate(48, 380)
        stroke(242, 153, 76)
        strokeWeight(2)
        noFill()
        textSize(72)
        for contour in textOutline("outline", 0, 60) {
            beginShape()
            for point in contour.points { vertex(point.x, point.y) }
            endShape(.close)
        }
        pop()

        // 自分の色を持つ字形。**塗りの色は掛からない** ので、同じ 1 行の中で
        // 単色の字は塗りの色で出て、絵文字だけが自分の色で出る
        textSize(30)
        fill(153, 166, 191)
        text("色を持つ字形 🔴 🙂 🌿", 48, 500)

        // 絵を置く — 等倍・引き伸ばし・色掛け
        if let swatch {
            image(swatch, 480, 170)
            image(swatch, 560, 170, 128, 128)
            tint(255, 140, 51)
            image(swatch, 704, 170, 128, 128)
            noTint()
        }

        // 保持した形 — 1 枚ずつと、組にしたもの
        push()
        translate(560, 360)
        for index in 0..<4 {
            shape(leaf, index * 52, 0)
        }
        pop()
        shape(cluster, 790, 340)

        // 同じ絵を 3 つの道で — 直に書いた・読み終わるまで待って読んだ・待たずに読んだ
        textSize(13)
        fill(153, 166, 191)
        for (index, entry) in [
            (written, "write"), (loaded, "loadImage"),
            (requested ?? pending, requested == nil ? "requestImage (届く前)" : "requestImage"),
        ].enumerated() {
            let x = 48 + Float(index) * 130
            if let picture = entry.0 { image(picture, x, 580) }
            text(entry.1, x, 690)
        }

        guard let loaded else { return }
        // 左上の 32×24 だけを切り出して引き伸ばす。**中心で置く** — 白い点が置いた位置
        imageMode(.center)
        image(loaded, 530, 612, 128, 96, 0, 0, 32, 24)
        imageMode(.corner)
        fill(242, 242, 242)
        circle(530, 612, 8)
        fill(153, 166, 191)
        text("切り出し・中央基準", 466, 690)

        // 絵の 1 画素を読んで、その色で塗る (右下の、赤みの強い側)
        fill(loaded.get(80, 50))
        circle(680, 612, 64)
        fill(153, 166, 191)
        text("get(80, 50)", 648, 690)

        // 葉と茎を畳んだ形
        for index in 0..<3 {
            shape(sprout, 790 + index * 50, 590)
        }
        text("leaf + stem", 790, 690)
    }
}
