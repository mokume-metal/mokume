// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// まとめ描き・頂点を並べた自由な立体・読み込んだモデル・引きずって回す視点。
///
/// **引きずると回り、スクロールで寄れる。** 書き出した絵では触れないので既定の視点の
/// ままだが、窓で走らせると `orbitControl()` が効く。
///
/// **読み込んだモデルには、作者が書いた展開どおりに絵が乗る。** 検体は上下の錐を絵の
/// 上半分・下半分へ割り当ててあるので、面ごとに縦の帯が並ぶ — 囲みの箱から作る位置に
/// 倒れていれば、帯にはならず絵が 1 枚そのまま乗る ([#406](https://github.com/mokume-metal/mokume/issues/406))。
final class CrowdAndModel: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "crowd and model")

    /// まとめ描きに渡す形。**頂点は 1 組しか置かれない**
    private var grain: Shape?
    /// 読み込んだモデル。
    private var gem: Model?
    /// 貼る絵。**1 度だけ焼く。** 上端を明るく・左端を赤くしてあるので、展開が
    /// どこを読んでいるかが絵から分かる
    private var pattern: Image?

    func setup() {
        // **リポジトリには資材ファイルを置けない** (`scripts/check-no-binaries.sh` が
        // `.obj` を弾く) ので、検体をここで書き出してから読んでいる。**普通のスケッチに
        // この 2 行は要らない** — 手元にあるファイルの場所を `loadModel` へ渡すだけでよい
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mokume-reference-gem.obj")
        try? Self.gemSource.write(to: url, atomically: true, encoding: .utf8)
        gem = try? loadModel(url.path)

        let image = try? createImage(128, 128)
        for y in 0..<128 {
            for x in 0..<128 {
                // 縞に加えて、**上端を白く・左端を赤く**する。展開がどこを読んで
                // いるかが色で分かる (帯の向きと継ぎ目の位置が絵から読める)
                let ring: Float = sin(Float(x) * 0.5) > 0 ? 0.85 : 0.25
                let top = y < 12
                let left = x < 12
                image?.set(
                    x, y,
                    .display(
                        red: top ? 1 : (left ? 0.95 : ring * 0.5),
                        green: top ? 1 : (left ? 0.2 : ring),
                        blue: top ? 1 : (left ? 0.25 : ring * 0.85)))
            }
        }
        pattern = image
    }

    func draw() {
        background(15, 18, 26)
        orbitControl()

        ambientLight(.linear(red: 0.16, green: 0.16, blue: 0.2))
        directionalLight(.linear(red: 0.85, green: 0.82, blue: 0.75), -0.4, 0.8, -0.35)
        noStroke()

        // **まとめ描き。** 2400 個置いても、頂点は 1 組・描く回数は 1 回
        let crowd = grain ?? createShape { box(11) }
        grain = crowd
        var places: [Placement] = []
        for index in 0..<1800 {
            let around = Float(index) * 0.11
            let radius = 70 + Float(index) * 0.075
            let lift = sin(Float(index) * 0.05 + time * 1.4) * 34
            places.append(
                Placement(
                    x: width / 2 + cos(around) * radius,
                    y: height / 2 + 95 + lift,
                    z: sin(around) * radius,
                    scale: 1,
                    rotation: SIMD3(0, around, 0),
                    fill: .display(
                        red: 0.4 + Float(index % 7) * 0.08, green: 0.55, blue: 0.9)))
        }
        shape(crowd, at: places)

        // **頂点を並べた自由な立体。** 穴も向きも立体で効く
        fill(242, 153, 71)
        push()
        translate(width / 2 - 250, height / 2 - 110, 0)
        rotateY(time * 0.6)
        normal(0, 0, 1)
        beginShape()
        for step in 0..<6 {
            let around = Float(step) / 6 * 2 * .pi
            vertex(cos(around) * 84, sin(around) * 84, 0)
        }
        beginContour()
        for step in 0..<6 {
            let around = -Float(step) / 6 * 2 * .pi
            vertex(cos(around) * 37, sin(around) * 37, 0)
        }
        endContour()
        endShape(.close)
        pop()

        // **読み込んだモデル。** 既定の整え方で、この面に見える大きさへ揃う
        if let gem {
            // **貼る絵は塗りに掛かる**ので、模様をそのまま見せるために白で塗る
            fill(255, 255, 255)
            push()
            // **貼る絵は描き方なので push / pop で積める。** ここを抜ければ元へ戻る
            if let pattern { texture(pattern) }
            translate(width / 2 + 250, height / 2 - 110, 0)
            // **傾けてから回す。** 真横から見ると上下の錐が重なって板に見える
            rotateZ(0.25)
            rotateX(0.3)
            rotateY(time * 0.9)
            scale(0.6, 0.6, 0.6)
            model(gem)
            pop()
        }
    }

    /// 読み込ませる検体 (八面体)。**中身が読める形で持つ** — 資材を置けない代わり。
    ///
    /// **作者の展開 (`vt`) を書いてある。** 上下の錐を絵の上半分・下半分に割り当て、
    /// 面ごとに縦の帯を取る — 囲みの箱から作る位置とは明らかに違う乗り方になるので、
    /// 展開に従っているかが 1 枚で読める ([#406](https://github.com/mokume-metal/mokume/issues/406))。
    private static let gemSource = """
        v 0 1.5 0
        v 0.92 0.35 0.38
        v 0.38 0.35 0.92
        v -0.38 0.35 0.92
        v -0.92 0.35 0.38
        v -0.92 0.35 -0.38
        v -0.38 0.35 -0.92
        v 0.38 0.35 -0.92
        v 0.92 0.35 -0.38
        v 0 -1.1 0
        vt 0 0.5
        vt 0.125 0.5
        vt 0.25 0.5
        vt 0.375 0.5
        vt 0.5 0.5
        vt 0.625 0.5
        vt 0.75 0.5
        vt 0.875 0.5
        vt 1 0.5
        vt 0.0625 1
        vt 0.1875 1
        vt 0.3125 1
        vt 0.4375 1
        vt 0.5625 1
        vt 0.6875 1
        vt 0.8125 1
        vt 0.9375 1
        vt 0.0625 0
        vt 0.1875 0
        vt 0.3125 0
        vt 0.4375 0
        vt 0.5625 0
        vt 0.6875 0
        vt 0.8125 0
        vt 0.9375 0
        f 1/10 2/1 3/2
        f 1/11 3/2 4/3
        f 1/12 4/3 5/4
        f 1/13 5/4 6/5
        f 1/14 6/5 7/6
        f 1/15 7/6 8/7
        f 1/16 8/7 9/8
        f 1/17 9/8 2/9
        f 10/18 3/2 2/1
        f 10/19 4/3 3/2
        f 10/20 5/4 4/3
        f 10/21 6/5 5/4
        f 10/22 7/6 6/5
        f 10/23 8/7 7/6
        f 10/24 9/8 8/7
        f 10/25 2/9 9/8
        """
}
