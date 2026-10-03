// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 閉じた形の三角形が、外へ向いて巻いてあるか内へ向いて巻いてあるか。
///
/// 裏面が絵に出うる形を裏 → 表の順で描くとき (``Canvas/SolidPart``)、どちらが裏かは巻き方で
/// 決まる。**組み込みの形は必ず外向きに巻いてある** (`SolidMeshBuilder`) が、読み込んだモデルは
/// 巻き方が逆のことがある (``ModelFile/Parsed/hasWrittenNormals``)。内向きの形を外向きと思って
/// 裏 → 表で描くと、手前の面が先に奥行きを書き、奥の面がどの向きでも捨てられる (1 回で描く
/// より悪い)。そこで読み込んだモデルは形から向きを求め、内向きなら表 → 裏の順に入れ替え、
/// **求まらないもの (閉じていない・巻き方が揃っていない) は部品にしない** — 1 回で描く、直す
/// 前の描き方のまま残す ([#1549])。
///
/// [#1549]: https://github.com/mokume-metal/mokume/issues/1549
nonisolated enum SolidWinding: Equatable, Sendable {
    /// 外向き (組み込みの形と同じ)。表の面が外を向く。
    case outward
    /// 内向き。表の面が内を向くので、裏 → 表を入れ替えて描く。
    case inward
    /// 求まらない。裏 → 表で描かない。
    case unknown

    /// 三角形の並び (3 点で 1 枚) の向きを求める。
    ///
    /// **閉じていて巻き方が揃っている**ことを先に確かめる。同じ位置の点を 1 つの点とみなし
    /// (ビットで比べる。読み込んだモデルは同じ番号の点を同じ値で並べるので、隣り合う面の角は
    /// ビットまで一致する)、どの向き付きの辺もちょうど 1 度ずつ、その逆向きの辺もちょうど 1 度ずつ
    /// 現れることを見る。面積の無い三角形 (2 点が重なる) は数えない。
    ///
    /// 揃っていれば、**繋がった成分ごとに**符号付きの体積の符号で外向きか内向きかを決める。
    /// 成分どうしで向きが食い違う形 (1 つの成分だけ巻き方が逆なモデル・外殻と内殻を持つ中空の形) は
    /// 求まらない側に置く — 向きは形全体で 1 つしか持てない (``SolidPart/insideOut``) ので、どちらに
    /// 決めても食い違った成分の奥の面がどの向きでも捨てられ、1 回で描くより悪くなる。
    ///
    /// 体積がほとんど 0 の成分 (表と裏が重なった板) も求まらない側に置く。「ほとんど 0」は、
    /// 成分の囲みの箱の大きさの 3 乗に比べて測る。体積は平行移動で変わらないので、原点からの
    /// 距離では測らない (原点から遠くに置いた小さな形が、閉じていても求まらなくなる)。積む前に
    /// 囲みの箱の中心を引いて、遠い座標どうしの打ち消しで桁を落とさないようにする。
    static func of(_ positions: [SIMD3<Float>]) -> SolidWinding {
        guard positions.count >= 12, positions.count % 3 == 0 else { return .unknown }
        var ids: [SIMD3<UInt32>: UInt32] = [:]
        ids.reserveCapacity(positions.count / 2)
        var welded: [UInt32] = []
        welded.reserveCapacity(positions.count)
        for position in positions {
            // -0 と +0 は同じ点 (0 を足すと +0 へ揃う)
            let same = position + SIMD3<Float>(repeating: 0)
            let key = SIMD3(same.x.bitPattern, same.y.bitPattern, same.z.bitPattern)
            if let id = ids[key] {
                welded.append(id)
            } else {
                let id = UInt32(ids.count)
                ids[key] = id
                welded.append(id)
            }
        }
        // 繋がった成分 (三角形が点を共有する集まり) を、根を辿る合併で求める
        var parent = Array(0..<UInt32(ids.count))
        func root(_ id: UInt32) -> UInt32 {
            var node = id
            while parent[Int(node)] != node {
                parent[Int(node)] = parent[Int(parent[Int(node)])]
                node = parent[Int(node)]
            }
            return node
        }
        func join(_ a: UInt32, _ b: UInt32) {
            let (ra, rb) = (root(a), root(b))
            if ra != rb { parent[Int(ra)] = rb }
        }
        var edges: [UInt64: Int] = [:]
        edges.reserveCapacity(positions.count)
        var first = 0
        while first + 2 < welded.count {
            let (a, b, c) = (welded[first], welded[first + 1], welded[first + 2])
            if a != b, b != c, c != a {
                edges[UInt64(a) << 32 | UInt64(b), default: 0] += 1
                edges[UInt64(b) << 32 | UInt64(c), default: 0] += 1
                edges[UInt64(c) << 32 | UInt64(a), default: 0] += 1
                join(a, b)
                join(b, c)
            }
            first += 3
        }
        guard !edges.isEmpty else { return .unknown }
        for (edge, count) in edges {
            let reversed = (edge << 32) | (edge >> 32)
            guard count == 1, edges[reversed] == 1 else { return .unknown }
        }
        // 成分ごとの囲みの箱 → 中心を引いた符号付きの体積 (6 倍の値)
        struct Component {
            var lowest = SIMD3<Double>(repeating: .infinity)
            var highest = SIMD3<Double>(repeating: -.infinity)
            var volume: Double = 0
        }
        var components: [UInt32: Component] = [:]
        first = 0
        while first + 2 < welded.count {
            let (a, b, c) = (welded[first], welded[first + 1], welded[first + 2])
            if a != b, b != c, c != a {
                let key = root(a)
                var component = components[key] ?? Component()
                for offset in 0..<3 {
                    let point = SIMD3<Double>(positions[first + offset])
                    component.lowest = simd_min(component.lowest, point)
                    component.highest = simd_max(component.highest, point)
                }
                components[key] = component
            }
            first += 3
        }
        first = 0
        while first + 2 < welded.count {
            let (a, b, c) = (welded[first], welded[first + 1], welded[first + 2])
            if a != b, b != c, c != a {
                let key = root(a)
                guard var component = components[key] else { return .unknown }
                let center = (component.lowest + component.highest) / 2
                let p = SIMD3<Double>(positions[first]) - center
                let q = SIMD3<Double>(positions[first + 1]) - center
                let r = SIMD3<Double>(positions[first + 2]) - center
                component.volume += simd_dot(p, simd_cross(q, r))
                components[key] = component
            }
            first += 3
        }
        var found: SolidWinding?
        for component in components.values {
            let size = component.highest - component.lowest
            let extent = max(size.x, max(size.y, size.z))
            guard component.volume.isFinite, extent > 0,
                abs(component.volume) > 1e-6 * extent * extent * extent
            else { return .unknown }
            let winding: SolidWinding = component.volume * outwardSign > 0 ? .outward : .inward
            if let found, found != winding { return .unknown }
            found = winding
        }
        return found ?? .unknown
    }

    /// 外向きの形の符号付き体積の符号。この面の座標 (縦軸が下向き) で、組み込みの形がどれも
    /// ``outward`` に判じられることを検査 (`SolidBackFaceOrderTests`) が確かめる。
    static let outwardSign: Double = 1
}

/// 裏面が絵に出うるかを判じる単位 — 組み込みの形 1 つ・読み込んだモデル 1 つ。
///
/// **裏 → 表の順で描くのは、部品の中だけである** ([#1549]・[#1565])。1 つの列に複数の部品が
/// 並ぶとき (保持した形に記録した複数の形・置き場所ごとに焼いた頂点)、部品どうしは呼び出し順の
/// まま描く。全部の部品の裏面 → 全部の部品の表面の順にすると、作品側が奥から並べた部品で、
/// 手前の部品の裏面が奥の部品の表面より先に奥行きを書き、奥の部品の表面が捨てられる
/// (ADR-0021 決定 2 の追補 (2026-10-02))。
///
/// 区間は列の**描く単位**で数える — 添字で読む列なら読む順の並び (`solidIndices`) の番号、
/// そうでなければ頂点の並び (`solidVertices`) の番号である。保持した形 (``Shape/solidParts``)
/// では形自身の並びの番号で持つ。
///
/// **巻き方の向きが分かる部品だけを持つ。** 組み込みの形は外向き、読み込んだモデルは形から
/// 求めた向き (``SolidWinding``) で、求まらないモデルと自分で並べた頂点 (`beginShape`) は部品を
/// 持たない。部品を持たない区間は今までどおり 1 回で描く。
///
/// [#1549]: https://github.com/mokume-metal/mokume/issues/1549
/// [#1565]: https://github.com/mokume-metal/mokume/issues/1565
nonisolated struct SolidPart: Equatable, Sendable {
    /// 描く単位での区間。
    var range: Range<Int>
    /// 区間が読む順の並び (`solidIndices`) の番号か。偽なら頂点の並びの番号。
    var isIndexed: Bool
    /// 裏面が絵に出うるスタイルで置いた部品か (``Canvas/placementMayShowBackFaces``)。立っている
    /// 部品だけを、置き場所ごとに裏 → 表の 2 回で描く。保持した形を半透明の色で置くと、立って
    /// いない部品も立つ。
    var showsBackFaces: Bool
    /// 巻き方が内向きか (``SolidWinding/inward``)。内向きなら表 → 裏の順に描く (巻き方で言う
    /// 表が、形の内側を向いているため)。
    var insideOut: Bool

    /// 区間をずらした部品。
    func shifted(by offset: Int) -> SolidPart {
        var moved = self
        moved.range = (range.lowerBound + offset)..<(range.upperBound + offset)
        return moved
    }
}
