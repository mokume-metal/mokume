// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// まとめ描き・頂点を並べた自由な立体・読み込んだモデル・引きずって回す視点。
///
/// **引きずると回り、スクロールで寄れる。** 書き出した絵では触れないので既定の視点の
/// ままだが、窓で走らせると `orbitControl()` が効く。
final class CrowdAndModel: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "crowd and model")

    /// まとめ描きに渡す形。**頂点は 1 組しか置かれない**
    private var grain: Shape?
    /// 読み込んだモデル。
    private var gem: Model?

    func setup() {
        // **リポジトリには資材ファイルを置けない** (`scripts/check-no-binaries.sh` が
        // `.obj` を弾く) ので、検体をここで書き出してから読んでいる。**普通のスケッチに
        // この 2 行は要らない** — 手元にあるファイルの場所を `loadModel` へ渡すだけでよい
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mokume-reference-gem.obj")
        try? Self.gemSource.write(to: url, atomically: true, encoding: .utf8)
        gem = try? loadModel(url.path)
    }

    func draw() {
        background(.display(red: 0.06, green: 0.07, blue: 0.10))
        orbitControl()

        ambientLight(.opaque(red: 0.16, green: 0.16, blue: 0.2))
        directionalLight(.opaque(red: 0.85, green: 0.82, blue: 0.75), -0.4, 0.8, -0.35)
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
        fill(.display(red: 0.95, green: 0.6, blue: 0.28))
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
            fill(.display(red: 0.55, green: 0.9, blue: 0.75))
            push()
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
        f 1 2 3
        f 1 3 4
        f 1 4 5
        f 1 5 6
        f 1 6 7
        f 1 7 8
        f 1 8 9
        f 1 9 2
        f 10 3 2
        f 10 4 3
        f 10 5 4
        f 10 6 5
        f 10 7 6
        f 10 8 7
        f 10 9 8
        f 10 2 9
        """
}
