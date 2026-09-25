// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 質感 4 つ・周囲からの光と映り込み・明るさを画面へ写す段。
///
/// **周囲が入れ替わる。** 金属は映り込む先が変わると見え方ごと変わるので、切り替わりを
/// 見ないと「映している」ことが読めない。
///
/// 下の段は**同じ球 1 つを、光の組と周囲だけ変えて**並べる — 既定の光の組 (`lights()`)・
/// 光を取り除いたもの (`noLights()`)・3 色から自作した周囲・いまの周囲を弱めたもの
/// (`scaled(by:)`)。光も周囲も置いた時点より後の形に効くので、1 つのフレームの中で置き直せる。
final class MaterialsAndSurroundings: Sketch {
    var settings = SketchSettings(width: 960, height: 680, title: "materials and surroundings")

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

    /// 3 色から自作した周囲 (夜の温室)。**組み込みの 3 つのどれとも違う色**にしてあるので、
    /// 映り込みがこちらから来ていることが一目で分かる。色は線形の明るさの倍率そのもの。
    private static let greenhouse = Surroundings(
        top: .display(red: 0.1, green: 0.35, blue: 0.2),
        horizon: .display(red: 0.85, green: 0.95, blue: 0.4),
        bottom: .display(red: 0.08, green: 0.1, blue: 0.06))

    /// 下の段。光の組か周囲を 1 つだけ置き直してから、同じ球を描く。
    private var variants: [(name: String, apply: (MaterialsAndSurroundings, Surroundings) -> Void)] {
        [
            // 置いた光をいったん取り除いてから、既定の組 (底上げ + 斜め上からの平行光) を置く
            ("lights()", { sketch, _ in
                sketch.noLights()
                sketch.lights()
            }),
            // 光を取り除く。**周囲は光ではない**ので、映り込みと周囲からの光は残る
            ("noLights()", { sketch, _ in sketch.noLights() }),
            ("Surroundings(top:…)", { sketch, _ in
                sketch.lights()
                sketch.surroundings(Self.greenhouse)
            }),
            // いまの周囲を弱める。**色が明るさそのもの**なので、掛けるのが強さの指定になる
            ("scaled(by: 0.25)", { sketch, place in sketch.surroundings(place.scaled(by: 0.25)) }),
        ]
    }

    func draw() {
        let place = places[Int(time / 2) % places.count]

        // **置くのと描くのは別。** 置いた周囲は面の向きで読まれ、背景は重ねて出す
        surroundings(place.surroundings)
        background(place.surroundings)

        // 底上げの光だけ足す。**金属は周囲を映す**ので、差す光が無くても形が出る
        ambientLight(.linear(red: 0.12, green: 0.12, blue: 0.14))
        directionalLight(.linear(red: 0.7, green: 0.68, blue: 0.62), -0.4, 0.8, -0.4)

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
                emissive(0, 0, 0)
                ambient(255, 255, 255)
                fill(184, 178, 173)
                knob.apply(self, amount)
                translate(200 + column * 140, 130 + row * 100, 0)
                sphere(42)
                pop()
            }
        }

        // 下の段。**置き直しは後の形にだけ効く** — 上の格子は置いた時点の光と周囲で描かれている
        for (slot, variant) in variants.enumerated() {
            variant.apply(self, place.surroundings)
            push()
            shininess(90)
            metalness(0.6)
            fill(184, 178, 173)
            translate(200 + slot * 140, 580, 0)
            sphere(42)
            pop()
        }

        // 見出し。**2D の文字はそのまま重ねられる**
        noStroke()
        fill(250, 250, 255)
        textSize(18)
        // **揃えはフレームを越える**ので、下の段の名前で中央へ寄せた分を毎フレーム戻す
        textAlign(.left)
        for (row, knob) in knobs.enumerated() {
            text(knob.name, 24, 138 + row * 100)
        }
        text("surroundings: \(place.name)", 24, 500)
        text("0", 200, 60)
        text("1", 760, 60)
        text("光と周囲", 24, 588)
        textSize(14)
        textAlign(.center)
        for (slot, variant) in variants.enumerated() {
            text(variant.name, 200 + slot * 140, 648)
        }
    }
}
