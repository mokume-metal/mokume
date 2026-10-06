// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 3D プリンタ向けの部品 (STL) を読み、同じ形の OBJ と並べて回す
/// ([#1966](https://github.com/mokume-metal/mokume/issues/1966))。
///
/// 歯車を三角形で組み、**同じ三角形を ASCII の STL と OBJ の 2 つで書き出して読む**。左が STL、
/// 右が OBJ で、どちらも同じ光の下でゆっくり回る。`loadModel` は拡張子で読み手を選ぶ — OBJ は
/// 自前の読み手、STL は Model I/O — が、届く形は同じなので**2 つは同じ絵になる**。OBJ には
/// 面ごとの向き (`vn`) を書いてある。STL は点を共有せず面ごとに平らに光るので、OBJ もそれに
/// 揃えた。左右で壁の明るさが少し違うのは、視点から見る向きが左右で違い、照り返しの乗り方が
/// 変わるためである (形と面の向きは同じ — 下の説明の数が揃う)。
///
/// **歯車は z を上に書いてある** — 3D プリンタ向けの STL の多くがそうである。STL には縦軸の
/// 約束が無く、読む側も変えないので、何もしなければ歯の並んだ面がこちらを向く。ここでは
/// `rotateX` で寝かせ、台の上で回るように見せている。
///
/// STL が読めなければ (読めない形式・壊れたファイル)、その説明を左に出す。
final class PartsAndFormats: Sketch {
    var settings = SketchSettings(width: 1200, height: 600, title: "parts and formats")

    /// 並べる 2 つ。読めたモデルか、読めなかった説明のどちらかを持つ。
    private var shelves: [(title: String, model: Model?, failure: String?)] = []

    func setup() {
        // **リポジトリには資材ファイルを置けない** (`scripts/check-no-binaries.sh` が `.stl` と
        // `.obj` を弾く) ので、検体をここで書き出してから読んでいる。**普通のスケッチにこの
        // 書き出しは要らない** — 手元にあるファイルの場所を `loadModel` へ渡すだけでよい
        let folder = FileManager.default.temporaryDirectory
        let stl = folder.appendingPathComponent("mokume-reference-gear.stl")
        let obj = folder.appendingPathComponent("mokume-reference-gear.obj")
        let triangles = Self.gear(teeth: 14)
        try? Self.stlSource(triangles).write(to: stl, atomically: true, encoding: .utf8)
        try? Self.objSource(triangles).write(to: obj, atomically: true, encoding: .utf8)

        for (title, url) in [("STL から", stl), ("OBJ から", obj)] {
            do {
                shelves.append((title, try loadModel(url.path), nil))
            } catch {
                // 説明には読んだ場所が載る。手元の一時の置き場は見せても意味が無いので名前だけにする
                let reason = error.description.replacingOccurrences(of: folder.path + "/", with: "")
                shelves.append((title, nil, reason))
            }
        }
    }

    func draw() {
        background(20, 22, 28)
        ambientLight(.linear(red: 0.16, green: 0.16, blue: 0.2))
        directionalLight(.linear(red: 0.85, green: 0.82, blue: 0.75), -0.4, 0.8, -0.35)
        noStroke()

        var captions: [(title: String, lines: [String], x: Float)] = []
        for (index, shelf) in shelves.enumerated() {
            let x = width * (index == 0 ? 0.28 : 0.72)
            guard let gear = shelf.model else {
                // 読めなかった説明は長いので、文ごとに折る
                let lines = (shelf.failure ?? "").components(separatedBy: ". ")
                captions.append((shelf.title, lines, x))
                continue
            }
            fill(214, 168, 96)
            push()
            translate(x, height / 2 - 20, 0)
            // **寝かせてから、歯車の軸のまわりに回す。** 台の上で回る部品の見え方になる
            rotateX(1.1)
            rotateZ(time * 0.5)
            model(gear)
            pop()
            captions.append((shelf.title, [Self.describe(gear)], x))
        }

        fill(225, 228, 238)
        textSize(14)
        textAlign(.center)
        for caption in captions {
            text(caption.title, caption.x, height - 110)
            for (index, line) in caption.lines.enumerated() {
                text(line, caption.x, height - 88 + Float(index) * 19)
            }
        }
    }

    /// モデルの値を 1 行の説明にする。2 つが同じ値になることが、同じ形が届いたことの印である。
    private static func describe(_ model: Model) -> String {
        let size = model.size
        return String(
            format: "三角形 %d · 大きさ %.1f×%.1f×%.1f · 読み飛ばし %d",
            model.triangleCount, size.x, size.y, size.z, model.skippedLines)
    }

    /// 歯車の三角形。**外から見て反時計回りに巻く** (STL の約束)。
    ///
    /// 軸は z で、厚みは z の ±0.15。歯は 1 枚ごとに根元 → 先 → 先 → 根元の 4 点で輪郭を取り、
    /// 中心に穴を開ける。輪郭の 1 区切りごとに上の面・下の面・外の壁・穴の壁を 2 枚ずつ張る。
    private static func gear(teeth: Int) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        let tip: Float = 1
        let root: Float = 0.82
        let hole: Float = 0.3
        let half: Float = 0.15
        // 歯 1 枚の中での位置 (0…1) と、そこでの半径
        let profile: [(at: Float, radius: Float)] = [(0, root), (0.2, tip), (0.5, tip), (0.7, root)]

        var outline: [(angle: Float, radius: Float)] = []
        for tooth in 0..<teeth {
            for point in profile {
                outline.append(((Float(tooth) + point.at) / Float(teeth) * 2 * .pi, point.radius))
            }
        }
        func corner(_ index: Int, radius: Float? = nil, z: Float) -> SIMD3<Float> {
            let point = outline[index % outline.count]
            let r = radius ?? point.radius
            return SIMD3(cos(point.angle) * r, sin(point.angle) * r, z)
        }

        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for index in outline.indices {
            let next = index + 1
            // 上の面 (+z) と下の面 (−z)。穴の縁から歯の縁へ張る
            let innerTop = corner(index, radius: hole, z: half)
            let innerTopNext = corner(next, radius: hole, z: half)
            let outerTop = corner(index, z: half)
            let outerTopNext = corner(next, z: half)
            let innerBottom = corner(index, radius: hole, z: -half)
            let innerBottomNext = corner(next, radius: hole, z: -half)
            let outerBottom = corner(index, z: -half)
            let outerBottomNext = corner(next, z: -half)

            triangles.append((innerTop, outerTop, outerTopNext))
            triangles.append((innerTop, outerTopNext, innerTopNext))
            triangles.append((innerBottom, outerBottomNext, outerBottom))
            triangles.append((innerBottom, innerBottomNext, outerBottomNext))
            // 外の壁 (外向き) と穴の壁 (軸へ向く)
            triangles.append((outerBottom, outerBottomNext, outerTopNext))
            triangles.append((outerBottom, outerTopNext, outerTop))
            triangles.append((innerBottom, innerTopNext, innerBottomNext))
            triangles.append((innerBottom, innerTop, innerTopNext))
        }
        return triangles
    }

    /// 三角形の面の向き (巻き方から求めた、長さ 1 の向き)。
    private static func facing(_ triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) -> SIMD3<Float> {
        let (a, b) = (triangle.1 - triangle.0, triangle.2 - triangle.0)
        let wound = SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        return wound / (wound * wound).sum().squareRoot()
    }

    private static func numbers(_ value: SIMD3<Float>) -> String {
        String(format: "%.6f %.6f %.6f", value.x, value.y, value.z)
    }

    /// 三角形を ASCII の STL に書く。面の向きも書く (CAD の書き出しはふつう書く)。
    private static func stlSource(_ triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]) -> String {
        var lines = ["solid gear"]
        for triangle in triangles {
            lines.append("  facet normal \(numbers(facing(triangle)))")
            lines.append("    outer loop")
            for corner in [triangle.0, triangle.1, triangle.2] {
                lines.append("      vertex \(numbers(corner))")
            }
            lines.append("    endloop")
            lines.append("  endfacet")
        }
        lines.append("endsolid gear")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 同じ三角形を OBJ に書く。**STL に合わせて点を共有せず、面ごとに向き (`vn`) を 1 つ書く。**
    /// 点を共有して向きを書かないと、OBJ の読み手は隣の面と向きを均す (なめらかに光る) ので、
    /// 角の立った部品が丸く見える。
    private static func objSource(_ triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]) -> String {
        var lines = ["# 参照スケッチの歯車 (STL と同じ三角形)"]
        for (index, triangle) in triangles.enumerated() {
            for corner in [triangle.0, triangle.1, triangle.2] {
                lines.append("v \(numbers(corner))")
            }
            lines.append("vn \(numbers(facing(triangle)))")
            // OBJ の番号は 1 から数える
            let first = index * 3 + 1
            let normal = index + 1
            lines.append("f \(first)//\(normal) \(first + 1)//\(normal) \(first + 2)//\(normal)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
