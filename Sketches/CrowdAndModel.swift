// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// まとめ描き・頂点を並べた自由な立体・番号で点を共有した立体・読み込んだモデル・
/// 引きずって回す視点。
///
/// **引きずると回り、スクロールで寄れる。** 書き出した絵では触れないが、始めの視点は
/// `setup()` で少し見下ろす位置へ置いてある (`orbit`) — 真横からだと渦が帯に潰れる。
/// 離すと慣性で流れる (`inertia`)。右上の小さな箱は**画面の同じ場所に留めた立体**で、
/// 画面の位置から空間の位置を引き戻して置く (`spacePosition`)。視点を回すと、その場で
/// 向きだけが変わる。
///
/// モデルは 3 つ — 既定の整え方で読んだもの・整えずにファイルの座標のまま読んだもの
/// (`normalize: false`。ファイルの縦軸は上向きなので、この面では上下が逆に出る)・
/// 読んでいる間フレームを止めない読み方で読んだ波打つ板 (`requestModel`。上のまん中)。
/// 下にそれぞれの `Model` の値 (三角形の枚数・囲みの箱の大きさと中心) を出す。
///
/// **波打つ板は書き出しの絵には出ない。** 書き出しはフレームを続けて進めるだけで、読み
/// 終わりを受け取る番が回らないので、届く前の姿 (「読み込み中…」の説明だけ) が撮れる。
/// 窓で走らせれば、起動して間もなく現れる。
///
/// **読み込んだモデルには、作者が書いた展開どおりに絵が乗る。** 検体は上下の錐を絵の
/// 上半分・下半分へ割り当ててあるので、面ごとに縦の帯が並ぶ — 囲みの箱から作る位置に
/// 倒れていれば、帯にはならず絵が 1 枚そのまま乗る ([#406](https://github.com/mokume-metal/mokume/issues/406))。
final class CrowdAndModel: Sketch {
    var settings = SketchSettings(width: 1200, height: 600, title: "crowd and model")

    /// まとめ描きに渡す形。**頂点は 1 組しか置かれない**
    private var grain: Shape?
    /// 読み込んだモデル。
    private var gem: Model?
    /// 同じ検体を、整えずに読んだもの。**ファイルの座標がそのまま**残る
    private var rawGem: Model?
    /// 読んでいる間フレームを止めずに読むモデル。**届くまでは `nil`**
    private var ripple: Model?
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
        // 整えない読み方。**同じファイルでも整え方が違えば別のモデル**として読まれる
        rawGem = try? loadModel(url.path, normalize: false)

        // 面の多いモデルは、読んでいる間フレームを止めない読み方で読む。解釈は別の仕事で
        // 回り、届いたら次のフレームから置かれる
        //
        // **描き場所を先に取ってから、その口を呼ぶ。** スケッチの `requestModel` を `Task`
        // から呼ぶと、その `Task` が走るのは `setup()` を抜けた後で、スケッチが走っている
        // 状態の外になるので落ちる (#1367)。描き場所そのものは走っている外でも読める
        let rippleURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mokume-reference-ripple.obj")
        try? Self.rippleSource(steps: 48).write(to: rippleURL, atomically: true, encoding: .utf8)
        let surface = canvas
        Task { ripple = try? await surface.requestModel(rippleURL.path) }

        // **始めの視点を手で置く。** 注視点のまわりを少し見下ろし、離したあとは 1 フレーム
        // ごとに速さを 9 割保って流れる (既定の 0 では、離したところで止まる)
        orbit.pitch = 0.3
        orbit.inertia = 0.9

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

        // **番号で点を共有した立体 (正二十面体)。** 12 の点を 1 度だけ置き、20 枚の面を
        // 番号で指す — 番号が無ければ 60 個置くことになる。**共有した点は向きも 1 つ**
        // なので、隣の面と向きが均され、角の立たない丸い形に光が乗る
        fill(120, 200, 170)
        push()
        translate(width / 2 - 400, height / 2 + 150, 0)
        rotateY(time * 0.5)
        rotateX(0.4)
        beginShape(.triangles)
        for point in Self.icosahedronPoints {
            vertex(point.x * 58, point.y * 58, point.z * 58)
        }
        for face in Self.icosahedronFaces {
            index(face.0)
            index(face.1)
            index(face.2)
        }
        endShape()
        pop()

        // **頂点を並べた自由な立体。** 穴も向きも立体で効く
        fill(242, 153, 71)
        push()
        translate(width / 2 - 400, height / 2 - 110, 0)
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

        // モデルの説明を置く場所。立体の下の点を画面の座標へ落として集め、最後に 2D で書く
        var captions: [(title: String, detail: String, x: Float, y: Float)] = []

        // **読み込んだモデル。** 既定の整え方で、この面に見える大きさへ揃う
        if let gem {
            // **貼る絵は塗りに掛かる**ので、模様をそのまま見せるために白で塗る
            fill(255, 255, 255)
            push()
            // **貼る絵は描き方なので push / pop で積める。** ここを抜ければ元へ戻る
            if let pattern { texture(pattern) }
            translate(width / 2 + 360, height / 2 - 110, 0)
            captions.append(
                ("loadModel", Self.describe(gem), screenX(0, 125, 0), screenY(0, 125, 0)))
            // **傾けてから回す。** 真横から見ると上下の錐が重なって板に見える
            rotateZ(0.25)
            rotateX(0.3)
            rotateY(time * 0.9)
            scale(0.6, 0.6, 0.6)
            model(gem)
            pop()
        }

        // **整えずに読んだモデル。** 大きさはファイルの単位のまま (高さ 2.6) なので、画素へ
        // 広げてから置く。縦軸もファイルのまま上向きなので、上の整えたものとは上下が逆に出る
        // (錐の長いほうが上を向く)。
        // 貼る絵の読み取り位置は整え方に依らないので、帯は上と同じに乗る
        if let rawGem {
            fill(255, 255, 255)
            push()
            if let pattern { texture(pattern) }
            translate(width / 2 + 360, height / 2 + 150, 0)
            captions.append(
                ("loadModel(…, normalize: false)", Self.describe(rawGem), screenX(0, 100, 0),
                 screenY(0, 100, 0)))
            rotateZ(0.25)
            rotateX(0.3)
            rotateY(time * 0.9)
            scale(55, 55, 55)
            model(rawGem)
            pop()
        }

        // **止めずに読んだモデル。** 届くまでは何も置かず、説明だけ「読み込み中」を出す
        push()
        translate(width / 2, height / 2 - 170, 0)
        let rippleAt = (x: screenX(0, 90, 0), y: screenY(0, 90, 0))
        if let ripple {
            fill(170, 150, 235)
            rotateX(0.5)
            rotateY(time * 0.4)
            scale(0.55, 0.55, 0.55)
            model(ripple)
            captions.append(("requestModel", Self.describe(ripple), rippleAt.x, rippleAt.y))
        } else {
            captions.append(("requestModel", "読み込み中…", rippleAt.x, rippleAt.y))
        }
        pop()

        // **画面の同じ場所に留めた立体。** 画面の右上の点を、注視点と同じ奥行きの面へ
        // 引き戻して置く。奥行きは `screenZ` で取った値をそのまま渡す (0 が手前・1 が奥)
        let focus = orbit.center
        let depth = screenZ(focus.x, focus.y, focus.z)
        let pinned = spacePosition(screenX: width - 70, screenY: 70, depth: depth)
        fill(230, 230, 220)
        stroke(40, 44, 56)
        strokeWeight(1)
        push()
        translate(pinned.x, pinned.y, pinned.z)
        box(44)
        pop()
        noStroke()

        // 説明。**2D の文字は視点を通らない**ので、落とした画面の座標へそのまま書く
        fill(225, 228, 238)
        textSize(13)
        textAlign(.center)
        for caption in captions {
            text(caption.title, caption.x, caption.y)
            text(caption.detail, caption.x, caption.y + 17)
        }
    }

    /// モデルの値を 2 行目の説明にする。`size` と `center` は**整えたあとの値** (整え
    /// なければファイルの単位のまま) なので、2 つの読み方の違いがここに出る。
    private static func describe(_ model: Model) -> String {
        let size = model.size
        let center = model.center
        return String(
            format: "三角形 %d · 大きさ %.1f×%.1f×%.1f · 中心 (%.1f, %.1f, %.1f)",
            model.triangleCount, size.x, size.y, size.z, center.x, center.y, center.z)
    }

    /// 正二十面体の 12 の点 (外接球の半径 1)。
    private static let icosahedronPoints: [SIMD3<Float>] = {
        let golden = (1 + Float(5).squareRoot()) / 2
        let points: [SIMD3<Float>] = [
            SIMD3(-1, golden, 0), SIMD3(1, golden, 0), SIMD3(-1, -golden, 0), SIMD3(1, -golden, 0),
            SIMD3(0, -1, golden), SIMD3(0, 1, golden), SIMD3(0, -1, -golden), SIMD3(0, 1, -golden),
            SIMD3(golden, 0, -1), SIMD3(golden, 0, 1), SIMD3(-golden, 0, -1), SIMD3(-golden, 0, 1),
        ]
        return points.map { $0 / (1 + golden * golden).squareRoot() }
    }()

    /// 正二十面体の 20 枚の面。**点の番号で書く** — どの点も 5 枚の面に共有される。
    private static let icosahedronFaces: [(Int, Int, Int)] = [
        (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
        (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
        (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
        (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
    ]

    /// 読ませる波打つ板 (OBJ)。**面の数が多い**ので、止めずに読む口の検体にする。
    ///
    /// 横と奥行きに `steps` ずつ割った格子で、三角形は `2 × steps × steps` 枚になる。
    private static func rippleSource(steps: Int) -> String {
        var lines: [String] = []
        for row in 0...steps {
            for column in 0...steps {
                let x = Float(column) / Float(steps) * 2 - 1
                let z = Float(row) / Float(steps) * 2 - 1
                lines.append("v \(x) \(0.18 * sin(x * 5) * cos(z * 5)) \(z)")
            }
        }
        for row in 0..<steps {
            for column in 0..<steps {
                // OBJ の番号は 1 から数える
                let corner = row * (steps + 1) + column + 1
                let below = corner + steps + 1
                lines.append("f \(corner) \(below) \(corner + 1)")
                lines.append("f \(corner + 1) \(below) \(below + 1)")
            }
        }
        return lines.joined(separator: "\n")
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
