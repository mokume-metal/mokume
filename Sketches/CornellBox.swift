// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// Cornell box — 左が赤・右が緑・ほかが白の箱の部屋に、高さの違う箱を 2 つ置き、天井の灯りで照らす。
///
/// 組むのは立体 (`plane` と `box`)・光 (`ambientLight` / `directionalLight` / `pointLight`)・
/// 影 (`shadows`) だけで、どれも `SolidsAndLight` と同じ口である。違うのは、**閉じた部屋の
/// 中で光と影がどう落ちるか**を見せること。
///
/// **本物の Cornell box とは見え方が違う。** mokume は面ごとに光を計算する (ラスタライズ) ので、
/// 光線を追う絵で見どころになる 2 つが出ない:
///
/// - **間接光** — 赤と緑の壁で跳ね返った光が、白い床や箱の側面を色付けする「にじみ」は出ない。
///   面が受けるのは置いた光から直接届く分と、底上げの光 (`ambientLight`) だけである
/// - **柔らかい影** — 影を落とすのは**置いた中で最初の平行光** (`directionalLight`) だけで、
///   天井の灯りから放射状に伸びる影にはならない。縁のぼけた影も出ず、平行光の向きへ真っ直ぐ落ちる
///
/// 天井の光る板は**印**で、光そのものではない (`emissive` は自分を光って見せるだけで、
/// まわりを照らさない)。部屋を照らすのは、板の真下に置いた点の光と、上から差す平行光である。
///
/// 視点は回さない — 正面から覗く構図そのものが Cornell box の約束で、静止画で読める。
final class CornellBox: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 640, height: 640, title: "cornell box")
    }

    /// 部屋の一辺。中心は窓の真ん中にあり、壁は中心から半辺ずつ離れる。
    private let side: Float = 300

    /// 白い面の色。奥・床・天井と 2 つの箱で同じものを使う。
    private let white = (red: Float(220), green: Float(220), blue: Float(214))

    func draw() {
        background(0)

        let center = (x: width / 2, y: height / 2)
        let half = side / 2

        // 開いた手前の面から正面に覗く。画角は部屋が窓の 7 割ほどに収まる大きさ
        camera(center.x, center.y, 760, center.x, center.y, 0, 0, 1, 0)
        perspective(Float.pi / 4.6, width / height, 10, 3000)

        // 縦軸は下向きなので、上から差す光の向きは +y。奥 (-z) へ少し傾けると、
        // 箱の正面が光を受けたまま、影が床の上で手前右へ伸びて見える
        ambientLight(40, 40, 40)
        directionalLight(.linear(red: 0.5, green: 0.48, blue: 0.43), 0.35, 1, -0.45)
        pointLight(.linear(red: 0.9, green: 0.85, blue: 0.75), center.x, center.y - half + 20, 0)

        // **影の細かさは 範囲 ÷ 画素数 で決まる。** 範囲を部屋が収まる長さまで狭める
        shadows(true)
        shadowRange(600)
        shadowDetail(2048)
        noStroke()

        // 壁。**受けるだけで落とさない** — 天井が影を落とすと、上から差す平行光が部屋の中へ届かない
        castShadow(false)
        fill(white.red, white.green, white.blue)
        wall(center.x, center.y, -half) { _ in }  // 奥
        wall(center.x, center.y + half, 0) { $0.rotateX(Float.pi / 2) }  // 床
        wall(center.x, center.y - half, 0) { $0.rotateX(Float.pi / 2) }  // 天井
        // 側壁は**部屋の内側へ表を向ける** — 向きを揃えると片方が裏から光を受けて真っ暗になる
        fill(190, 40, 35)
        wall(center.x - half, center.y, 0) { $0.rotateY(Float.pi / 2) }
        fill(45, 160, 60)
        wall(center.x + half, center.y, 0) { $0.rotateY(-Float.pi / 2) }

        // 天井の灯りの印。天井の面にわずかに埋めて、上から見ても浮かないようにする
        push()
        emissive(.linear(red: 1, green: 0.95, blue: 0.85))
        fill(255)
        translate(center.x, center.y - half + 1, 0)
        box(80, 2, 80)
        emissive(.linear(red: 0, green: 0, blue: 0))
        pop()

        // 箱 2 つ。床 (`center.y + half`) に底を付けるので、中心は高さの半分だけ上へ上げる
        castShadow(true)
        fill(white.red, white.green, white.blue)
        push()
        translate(center.x + 55, center.y + half - 45, 40)
        rotateY(-0.3)
        box(90, 90, 90)
        pop()
        push()
        translate(center.x - 50, center.y + half - 90, -50)
        rotateY(0.3)
        box(90, 180, 90)
        pop()
    }

    /// 部屋の一辺の正方形の壁を 1 枚、`(x, y, z)` を中心に置く。`orient` で向きを変える。
    private func wall(_ x: Float, _ y: Float, _ z: Float, orient: (CornellBox) -> Void) {
        push()
        translate(x, y, z)
        orient(self)
        plane(side, side)
        pop()
    }
}
