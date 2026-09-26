// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 組み込みの立体 7 種・光 4 種・影・立体の輪郭線・立体に付いて回る名札。
///
/// 立体には線を引いてある — 線は**形の稜線** (面が折れているところと平らな面の縁) に
/// 引かれるので、箱なら 12 本で、球や楕円体は割った面の格子になる。円柱は一周を 8 つに
/// 割ってあり (`detail:`)、側面が 8 枚の平らな面として読める。名札は 2D の文字で、
/// 立体の画面上の位置 (`screenX` / `screenY`) へ置き、奥にある立体ほど淡くする (`screenZ`)。
///
/// **視点が回る。** 立体は静止画だと向きが読めないことがあるので、参照スケッチの側で
/// 回してある — 影がどの形から落ちているか、面のどちら側が光を受けているかは、
/// 動いて初めて読める。
final class SolidsAndLight: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "solids and light")

    /// 注視点。床も立体もこのまわりに固める。
    private var center: (x: Float, y: Float) { (width / 2, height / 2) }

    func draw() {
        background(15, 18, 23)

        // **注視点のまわりを回る。** 時計はフレーム番号から導かれるので、何度撮っても同じ動き
        let angle = time * 0.5
        let distance: Float = 470
        camera(
            center.x + sin(angle) * distance, center.y - 210, cos(angle) * distance,
            center.x, center.y + 110, 0,
            0, 1, 0)
        perspective(Float.pi / 3, width / height, 10, 2000)

        // 光を 4 種そろえて置く。縦軸は下向きなので、上から差す光の向きは +y
        //
        // **色の目盛りは渡し方で 2 つある。** 素の数値は塗りと同じ 0–255 で、`.linear(…)` は
        // 0…1 (1 を超えられる)。底上げの光だけ素の数値で書いてある — `.linear(red: 0.16,
        // green: 0.17, blue: 0.22)` と同じ明るさで、ここに `0.16` と書くとほぼ真っ黒になる
        ambientLight(111, 115, 129)
        directionalLight(.linear(red: 0.9, green: 0.86, blue: 0.78), -0.45, 0.85, -0.35)
        pointLight(.linear(red: 0.25, green: 0.45, blue: 0.95), center.x - 260, center.y - 60, 220)
        spotLight(
            .linear(red: 0.95, green: 0.35, blue: 0.4),
            center.x + 240, center.y - 300, 160,
            -0.35, 1, -0.25,
            angle: 0.5)

        shadows(true)
        // **影の細かさは 範囲 ÷ 画素数 で決まる。** 範囲を床が収まる長さまで狭め、画素数を
        // 倍にして縁を細かくする (既定は面の対角と 1024)。余裕は自分の影が縞になって浮くのを
        // 避ける量で、大きくするほど影が形から離れるので、既定 (0.0025) からわずかに広げるに留める
        shadowRange(900)
        shadowDetail(2048)
        shadowBias(0.003)
        noStroke()

        // 床。**受けるだけで落とさない** — 落とす側に入れると自分の影で暗くなる
        castShadow(false)
        fill(128, 128, 140)
        push()
        translate(center.x, center.y + 130, 0)
        rotateX(Float.pi / 2)
        plane(760, 760)
        pop()

        // 灯りの印。点の光とスポットの光が**どこから差しているか**を見せる。形の外の目印
        // なので、影を**落とさず受けもしない** — 受けると、光の真下に来た立体の影で印が消える
        // (落とす側からは、床のところで外したままになっている)
        receiveShadow(false)
        for lamp in lamps {
            push()
            emissive(lamp.color)
            fill(lamp.color)
            translate(lamp.x, lamp.y, lamp.z)
            sphere(9)
            pop()
        }
        receiveShadow(true)

        // 7 種を輪に並べる。**中心のまわりに固める** — 奥へ後退させると回したとき画面から溢れる
        //
        // **線は立体にも引ける。** 引かれるのは形の稜線 (面が折れているところと平らな面の縁)
        // だけで、面を三角形に割った対角線は出ない。曲面は割った面ごとに折れているので、
        // 緯線と経線の格子になる
        castShadow(true)
        stroke(24, 26, 32)
        strokeWeight(1)
        let radius: Float = 210
        var tags: [(name: String, x: Float, y: Float, depth: Float)] = []
        for (index, solid) in solids.enumerated() {
            let around = Float(index) / Float(solids.count) * 2 * .pi
            fill(solid.color)
            push()
            translate(center.x + cos(around) * radius, center.y + 55, sin(around) * radius)
            // 名札を置く位置は**回す前に**取る — 立体の真上 (縦軸は下向きなので -y) を、
            // いまの変換といまの視点で画面の座標へ落とす
            tags.append(
                (solid.name, screenX(0, -80, 0), screenY(0, -80, 0), screenZ(0, -80, 0)))
            // **視点から見て斜めを向かせる。** 正面を向いた箱や板は、静止画だと
            // ただの四角にしか見えず、輪の向こう側では真横になって消える
            rotateY(-around + solid.spin)
            rotateX(solid.tilt)
            solid.draw(self)
            pop()
        }

        // 名札。**2D の文字は視点を通らない**ので、上で落とした画面の座標へそのまま書く。
        // 奥行き (`screenZ`) は 0 が手前・1 が奥なので、並べた中での位置を `norm` で 0…1 に
        // してから淡さに写す
        noStroke()
        textSize(15)
        textAlign(.center)
        let depths = tags.map(\.depth)
        let nearest = depths.min() ?? 0
        let farthest = depths.max() ?? 1
        for tag in tags {
            let far = norm(tag.depth, nearest, farthest)
            fill(240, 240, 232, 255 - far * 170)
            text(tag.name, tag.x, tag.y)
        }
    }

    /// 灯りの印を置く場所と色。上で置いた点の光・スポットの光と同じ位置にする。
    private var lamps: [(x: Float, y: Float, z: Float, color: LinearRGBA)] {
        [
            (center.x - 260, center.y - 60, 220, .linear(red: 0.25, green: 0.45, blue: 0.95)),
            (center.x + 240, center.y - 300, 160, .linear(red: 0.95, green: 0.35, blue: 0.4)),
        ]
    }

    /// 並べる 7 種。**それぞれ違う色**にしてあるので、回っても見分けが付く。
    ///
    /// `spin` は輪の上での向き。**板だけ外を向かせる** (`.pi / 2`) — 他と同じ向きに
    /// すると、回っている間じゅう真横になって線に潰れる区間ができる。
    ///
    /// 楕円体は**縦に長い卵形**にしてある。3 つの半径が揃うと球と見分けが付かない。
    /// 円柱は一周を 8 つに割る (`detail:`・既定は 24) — 割り方を落とすと面が見えてくる。
    private var solids:
        [(name: String, color: LinearRGBA, tilt: Float, spin: Float, draw: (SolidsAndLight) -> Void)]
    {
        [
            ("box", color(242, 115, 76), 0.3, 0.6, { $0.box(90) }),
            ("sphere", color(102, 217, 128), 0, 0.6, { $0.sphere(52) }),
            ("ellipsoid", color(236, 228, 210), 0.2, 0.6, { $0.ellipsoid(34, 62, 34) }),
            ("plane", color(89, 153, 242), 0.5, .pi / 2, { $0.plane(120, 100) }),
            ("cylinder", color(230, 204, 51), 0.25, 0.6, { $0.cylinder(38, 96, detail: 8) }),
            ("cone", color(217, 102, 191), 0.25, 0.6, { $0.cone(44, 100) }),
            ("torus", color(102, 217, 230), 1.25, 0.6, { $0.torus(46, 17) }),
        ]
    }
}
