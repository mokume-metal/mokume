// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 外で作って読み込んだ立体。
///
/// ## 既定は「置いたら見える」
///
/// 何も指定しなければ、読み込んだ形は**この面で見える大きさへ整えられる** — 中心が
/// 原点に来て、いちばん長い辺が面の短いほうの半分になる。単位の大きさ (最長辺 1 など)
/// へ収める作法もあるが、**この面の座標は画素**なので、そのままでは数画素の点に
/// なってしまう。しかもそれは失敗ではないので、利用者は読み込みを疑い、実装を疑い、
/// 原因に辿り着けない。整えない形が要るときは `normalize: false` を渡す。
///
/// ## 整えるときにすること
///
/// 1. 中心 (囲みの箱の中心) を原点へ移す
/// 2. いちばん長い辺を、面に合う長さへ**一様に**縮める (軸の比は変わらない)
/// 3. 縦軸を**この面の約束 (下向き)** へ合わせる — モデルの多くは上向きで書かれる。
///    縦だけの裏返しは**鏡映**なので、三角形の巻き方も一緒に戻す (#1473)
///
/// 3 つ目も整える側に入れてあるので、`normalize: false` では**ファイルの座標が
/// そのまま残る**。ただし**貼る絵の読み取り位置は整えの対象ではない** — 形の座標では
/// なく絵を読む位置なので、`normalize` の有無で値が変わらない (#406)。
public struct Model: Equatable, Sendable {
    /// 読み込んだ名前。
    public let name: String
    /// 三角形の枚数。
    public var triangleCount: Int { mesh.triangleCount }
    /// 面が 1 つも無いか。**読めたが見えない**状態がこれにあたる。
    public var isEmpty: Bool { mesh.points.isEmpty }
    /// 読み飛ばした行の数 (材質の指定など、いま読まないもの)。
    public let skippedLines: Int
    /// 囲みの箱の大きさ。整えたあとの値。
    public let size: SIMD3<Float>
    /// 囲みの箱の中心。整えていれば原点。
    public let center: SIMD3<Float>

    /// 置ける形。
    let mesh: SolidMesh
    /// 面の向きを**形から求めた**か。求めた向きは両面として扱う。
    let hasDerivedNormals: Bool
    /// 同じモデルを続けて置いたときにまとめるための番号。
    let identity: Int

    /// **同じ読み込みから来たものだけが等しい。** 中身をすべて比べる意味が無い
    /// (同じファイルを 2 度読めば、同じ形の別のものが返る) ので、番号で見る。
    public static func == (lhs: Model, rhs: Model) -> Bool { lhs.identity == rhs.identity }

    init(
        name: String, mesh: SolidMesh, hasDerivedNormals: Bool, skippedLines: Int,
        size: SIMD3<Float>, center: SIMD3<Float>, identity: Int
    ) {
        self.name = name
        self.mesh = mesh
        self.hasDerivedNormals = hasDerivedNormals
        self.skippedLines = skippedLines
        self.size = size
        self.center = center
        self.identity = identity
    }
}

extension Model {
    /// 読み取った並びを、置ける形へ整える。
    ///
    /// - Parameters:
    ///   - fitting: 整えるときに、いちばん長い辺を合わせる長さ。`nil` なら整えない。
    static func make(
        name: String, parsed: ModelFile.Parsed, fitting: Float?, identity: Int
    ) -> Model {
        var positions = parsed.positions
        var normals = parsed.normals
        var lowest = SIMD3<Float>(repeating: .infinity)
        var highest = SIMD3<Float>(repeating: -.infinity)
        for position in positions {
            lowest = simd_min(lowest, position)
            highest = simd_max(highest, position)
        }
        if positions.isEmpty {
            lowest = .zero
            highest = .zero
        }

        var center = (lowest + highest) / 2
        var size = highest - lowest

        if let fitting {
            let longest = max(size.x, max(size.y, size.z))
            // **一様に縮める。** 軸ごとに合わせると、読み込んだ形が潰れる
            let scale = longest > 0 ? fitting / longest : 1
            for index in positions.indices {
                let moved = (positions[index] - center) * scale
                // 縦軸はこの面の約束 (下向き) へ合わせる。**これは鏡映である** (行列式が -1)
                // — 三角形の巻き方も裏返るので、角を組んだあとで戻す (下の入れ替え)
                positions[index] = SIMD3(moved.x, -moved.y, moved.z)
                normals[index] = SIMD3(normals[index].x, -normals[index].y, normals[index].z)
            }
            size = SIMD3(size.x, size.y, size.z) * scale
            center = .zero
        }

        // **書かれた展開が無い角は、囲みの箱の横と縦を 0…1 に写した位置へ倒れる。**
        // 何も持たせないと、面を束ねた状態で置いたモデルが全面 1 画素の色で塗り潰され、
        // 利用者からは「貼れていない」としか見えない。奥行きの向きは畳まれるので、
        // 真横を向いた面では絵が伸びる — 作者の展開の代わりにはならない
        //
        // **ファイルの座標の x と -y から測る。** 縦を裏返すのは、この面の読み取り位置が
        // 上から下へ数えるためで、`vt` を読むときの裏返し (``ModelFile``) と同じ理由である。
        // 整えは一様な縮小と平行移動なので 0…1 に写した値は動かない — つまりこの位置は
        // **`normalize` の有無で変わらない** (整えたあとの座標から測っていた頃は、
        // `normalize: false` でだけ絵が上下逆に乗っていた。#406)
        var uvLowest = SIMD2<Float>(repeating: .infinity)
        var uvHighest = SIMD2<Float>(repeating: -.infinity)
        for position in parsed.positions {
            uvLowest = simd_min(uvLowest, SIMD2(position.x, -position.y))
            uvHighest = simd_max(uvHighest, SIMD2(position.x, -position.y))
        }
        let extent = uvHighest - uvLowest
        var points = (0..<positions.count).map { index in
            let source = parsed.positions[index]
            return SolidMesh.Point(
                position: positions[index], normal: normals[index],
                // 書かれた展開があればそれを使う。**角ごとに見る** — 混ざったモデルでも
                // 書かれた側は活きる
                uv: parsed.uvs[index]
                    ?? SIMD2(
                        extent.x > 0 ? (source.x - uvLowest.x) / extent.x : 0,
                        extent.y > 0 ? (-source.y - uvLowest.y) / extent.y : 0))
        }

        // **縦を裏返した形は、巻き方を戻す。** 縦だけの裏返しは鏡映なので、3 点の並びから
        // 求まる向きが、持っている向きと逆の側を指したまま残る。面の向きを書いていない
        // 形は、断片が巻き方で表裏を見分けて向きを裏返す (両面の扱い) ので、戻さないと
        // 見る側を向いた面が裏から光を受けて暗くなる (#1473)。書かれた向きは y を一緒に
        // 裏返してあるので、巻き方を戻すと両方が揃う
        //
        // **角ごと入れ替える** — 位置・向き・読み取り位置は角に付いたまま動く。入れ替えるのは
        // 2 点目と 3 点目で、鏡映した置き場所で焼いた頂点を戻すのと同じ (#1446)
        if fitting != nil {
            for start in stride(from: 0, to: points.count - 2, by: 3) {
                points.swapAt(start + 1, start + 2)
            }
        }
        return Model(
            name: name, mesh: SolidMesh(points: points),
            hasDerivedNormals: !parsed.hasWrittenNormals, skippedLines: parsed.skippedLines,
            size: size, center: center, identity: identity)
    }
}
