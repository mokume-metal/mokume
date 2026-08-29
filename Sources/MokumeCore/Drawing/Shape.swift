// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 組み立て終えた形。
///
/// 中身は**焼き付けた頂点の並び**である。子の一覧ではないので、組にしても畳む工程は
/// 要らない — 組にした時点で 1 本の並びになっている。使い方と、そう作った理由は
/// ``Sketch/createShape(_:)`` にある。
///
/// ## 畳めない構成が作れない
///
/// 「子を 1 つずつ描く」実装が生まれる余地を型から消してある。組にする操作
/// (``group(_:)`` と ``+(_:_:)``) は並びを繋ぐだけで、木を作らない。
///
/// ## 奥行きを持つ形
///
/// 穴・輪郭・頂点ごとの色は、この設計では**形の種類ではなく頂点の性質**である。
/// 奥行きで広がるのは頂点の中身であって、形の種類ごとの対応表ではない
/// ([ADR-0021] 決定 5)。「平面では効くが立体では黙って無視される」機能が生まれる
/// 場所が無い。奥行きを持つ頂点は並びが別なだけで、**区間が呼び出し順を持つ**ので
/// 平面と混ざった形もそのまま保持できる。
///
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
public struct Shape {
    /// 焼き付けた頂点。位置は**形自身の座標**で、置く場所の変換は描くときに掛かる。
    let vertices: [ShapeVertex]
    /// 焼き付けた立体の頂点。同じく形自身の座標で、面の向きも変換前のもの。
    let solidVertices: [SolidVertex]
    /// 頂点の並びを、面と混ぜ方の変わり目で区切ったもの。
    let runs: [Run]

    /// 同じ設定で続けて描ける区間。
    struct Run {
        var mode: BlendMode
        var texture: any MTLTexture
        var textureKind: TextureKind
        /// この区間を塗るもの。`nil` なら組み込みの塗り。
        var shader: Shader?
        /// 利用者が渡した値。**区間の先頭で取り込んだもの**を持ち歩く。
        var values: [Float]
        /// この区間の塗りが読む数の並び。`nil` なら読まない。
        var numbers: Numbers?
        /// どちらの並びから描くか。
        var source: Canvas.VertexSource
        var start: Int
        var count: Int
    }

    init(vertices: [ShapeVertex], solidVertices: [SolidVertex] = [], runs: [Run]) {
        self.vertices = vertices
        self.solidVertices = solidVertices
        self.runs = runs
    }

    /// 何も入っていない形。
    public static let empty = Shape(vertices: [], runs: [])

    /// 三角形を組み立てるのに使った頂点の数。
    public var vertexCount: Int { vertices.count + solidVertices.count }

    /// 何も入っていないか。
    public var isEmpty: Bool { vertices.isEmpty && solidVertices.isEmpty }

    /// この形を描くのに要する描画の回数。
    ///
    /// **組にしても増えないこと**をここで確かめられる。子を 1 つずつ描く作りでは
    /// 組にするたびにここが増えるので、「保持にしたのに速くならない」を絵ではなく
    /// 数で見つけられる。混ぜ方や読む面が形の中で変わるときだけ 2 以上になる。
    public var drawCallCount: Int { runs.count }

    // MARK: - 組にする

    /// 複数の形を 1 つに畳む。
    ///
    /// 繋ぎ目の前後で設定が同じなら区間も 1 つに畳まれるので、**組にしても描く回数は
    /// 増えない**。
    public static func group(_ shapes: [Shape]) -> Shape {
        var vertices: [ShapeVertex] = []
        var solidVertices: [SolidVertex] = []
        var runs: [Run] = []
        vertices.reserveCapacity(shapes.reduce(0) { $0 + $1.vertices.count })

        for shape in shapes {
            let flatOffset = vertices.count
            let solidOffset = solidVertices.count
            vertices.append(contentsOf: shape.vertices)
            solidVertices.append(contentsOf: shape.solidVertices)
            for var run in shape.runs {
                run.start += run.source == .flat ? flatOffset : solidOffset
                append(run, to: &runs)
            }
        }
        return Shape(vertices: vertices, solidVertices: solidVertices, runs: runs)
    }

    /// 2 つの形を 1 つに畳む。
    public static func + (lhs: Shape, rhs: Shape) -> Shape { group([lhs, rhs]) }

    /// 区間を足す。直前と設定が同じなら伸ばすだけにする。
    private static func append(_ run: Run, to runs: inout [Run]) {
        if var last = runs.last, last.mode == run.mode, last.texture === run.texture,
            last.textureKind == run.textureKind, last.shader === run.shader,
            last.values == run.values, last.numbers === run.numbers, last.source == run.source,
            last.start + last.count == run.start
        {
            last.count += run.count
            runs[runs.count - 1] = last
            return
        }
        runs.append(run)
    }
}
