// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 質感 4 つ・周囲からの光と映り込み・明るさを画面へ写す段。
///
/// **周囲が入れ替わる。** 金属は映り込む先が変わると見え方ごと変わるので、切り替わりを
/// 見ないと「映している」ことが読めない。
final class MaterialsAndSurroundings: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "materials and surroundings")

    /// 並べる質感。**同じ 1 本の式に入る 4 つの指定**で、それぞれ効き方が違う。
    private var knobs: [(name: String, apply: (MaterialsAndSurroundings, Float) -> Void)] {
        [
            ("shininess", { $0.shininess($1 * 220) }),
            ("metalness", { $0.metalness($1) }),
            ("emissive", { $0.emissive(.display(red: $1 * 0.5, green: $1 * 0.2, blue: $1 * 0.05)) }),
            ("ambient", { $0.ambient(.display(red: 1 - $1, green: 1 - $1 * 0.6, blue: 1)) }),
        ]
    }

    /// 順に出す周囲。2 秒ずつで入れ替わる。
    private var places: [(name: String, surroundings: Surroundings)] {
        [("sky", .sky), ("studio", .studio), ("sunset", .sunset)]
    }

    func draw() {
        let place = places[Int(time / 2) % places.count]

        // **置くのと描くのは別。** 置いた周囲は面の向きで読まれ、背景は重ねて出す
        surroundings(place.surroundings)
        background(place.surroundings)

        // 底上げの光だけ足す。**金属は周囲を映す**ので、差す光が無くても形が出る
        ambientLight(.opaque(red: 0.12, green: 0.12, blue: 0.14))
        directionalLight(.opaque(red: 0.7, green: 0.68, blue: 0.62), -0.4, 0.8, -0.4)

        // 明るさを画面へ写す段。**丸め方を折り返しにすると、明るいところが白へ飛ばずに色を残す**
        exposure(1.15)
        toneMapping(.roll)

        noStroke()
        let columns = 5
        for (row, knob) in knobs.enumerated() {
            for column in 0..<columns {
                let amount = Float(column) / Float(columns - 1)
                push()
                // 4 つとも既定へ戻してから 1 つだけ動かす — 混ざると何が効いたか読めない
                shininess(0)
                metalness(0)
                emissive(.display(red: 0, green: 0, blue: 0))
                ambient(.display(red: 1, green: 1, blue: 1))
                fill(.display(red: 0.72, green: 0.7, blue: 0.68))
                knob.apply(self, amount)
                translate(200 + Float(column) * 140, 130 + Float(row) * 100, 0)
                sphere(42)
                pop()
            }
        }

        // 見出し。**2D の文字はそのまま重ねられる**
        noStroke()
        fill(.display(red: 0.98, green: 0.98, blue: 1))
        textSize(18)
        for (row, knob) in knobs.enumerated() {
            text(knob.name, 24, 138 + Float(row) * 100)
        }
        text("surroundings: \(place.name)", 24, 500)
        text("0", 200, 60)
        text("1", 760, 60)
    }
}
