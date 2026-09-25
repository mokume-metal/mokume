// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 立体を組み立てる頂点。
///
/// 並びは `Drawing/Shaders/Shapes.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由・同じ手当て — `ShaderInterfaceTests` が反射と突き合わせる)。
///
/// `float3` は 16 バイト境界に揃うので、位置・形自身の座標・向き・形自身の向きで
/// 64 バイト、読み取り位置が 8 バイト、色が 16 バイト境界へ揃うため 8 バイトの
/// 詰め物が入って 96 バイトになる。
/// (向きの 4 つ目の成分は、`float3` に元から入っていた詰め物に収まる。)
struct SolidVertex {
    /// 描画先の座標 (変換を適用済み・奥行きを持つ)。
    var position: SIMD3<Float>
    /// **形自身の座標** — 利用者の断片へ渡すもの (``Fragment`` の `shapePosition`)。
    ///
    /// 置き場所が変換を持つ形 (組み込みの立体・読み込んだモデル) では ``position``
    /// と同じ値で、変換は置き場所の側が持つ。**頂点を並べて作った形では違う** —
    /// あちらは変換を頂点に焼き込むので、書かれたときの座標をここに控える。
    /// 保持する形の記録の中で置いた組み込みの立体も、置き場所を頂点へ焼くので違う
    /// (``SolidInstance/placing(_:)``)。
    /// 控えないと「同じ形なのに、通した道具で模様の留まり方が変わる」ことになる
    /// ([ADR-0021] 決定 5)。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    var shapePosition: SIMD3<Float>
    /// 面の向き (変換を適用済み) と、**その向きを形から求めたか**。
    ///
    /// `xyz` が向き、`w` が 1 なら形から求めた向きである。求めた向きは、その面が
    /// 裏を向いていれば見えている側へ裏返して光を当てる (両面) — 頂点を並べる向き
    /// (巻き方) で絵が真っ黒になるのを避けるためである。`w` が 0 なら**書かれた
    /// 向き**なので、裏返さずそのまま使う。書いた指定が黙って覆されない。
    ///
    /// 長さを持たない向き (ゼロ) は「光を受けない」という意味で、立体の線と点が
    /// これに当たる。
    var normal: SIMD4<Float>
    /// 形自身の座標での面の向き — 利用者の断片へ渡すもの (``Fragment`` の `shapeNormal`)。
    ///
    /// ``shapePosition`` と同じ理由で控える。長さを持たない向き (線と点) は 0 のまま。
    var shapeNormal: SIMD3<Float>
    /// 字形を焼いた面の中で、どこを読むか。
    ///
    /// 立体は面の**白い区画**を指す — 白を掛けても色は変わらないので、平面と同じ
    /// 塗りをそのまま通せる (``GlyphAtlas``)。
    var uv: SIMD2<Float>
    /// 1 なら**輪郭の頂点**、0 なら塗りの頂点。
    ///
    /// 輪郭は画面で半画素寄せる ([ADR-0039] 決定 2) が、立体の輪郭は塗りと同じ列に
    /// 呼び出し順で交互に積まれるので、区切りの番号では分けられない。頂点が名乗り、
    /// 頂点関数が投影の後で寄せる (`Canvas.solidStrokeShift`)。**大きさは増えない** —
    /// `uv` と `color` の間の詰め物に置いている。
    ///
    /// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
    var stroke: Float
    /// 色 — 線形・アルファ乗算済み ([ADR-0011] 決定 4)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    var color: SIMD4<Float>

    /// 形自身の座標を**書かなければ、置いた座標がそのまま**入る。
    ///
    /// 変換を置き場所の側が持つ形 (組み込みの立体・読み込んだモデル) がこれに当たる。
    /// 変換を頂点へ焼き込む形だけが、焼き込む前の座標を明示して渡す。
    init(
        position: SIMD3<Float>, shapePosition: SIMD3<Float>? = nil,
        normal: SIMD3<Float>, shapeNormal: SIMD3<Float>? = nil, isDerived: Bool = false,
        uv: SIMD2<Float>, isStroke: Bool = false, color: LinearRGBA
    ) {
        self.position = position
        self.shapePosition = shapePosition ?? position
        self.normal = SIMD4<Float>(normal, isDerived ? 1 : 0)
        self.shapeNormal = shapeNormal ?? normal
        self.uv = uv
        self.stroke = isStroke ? 1 : 0
        self.color = SIMD4<Float>(color.red, color.green, color.blue, color.alpha)
    }
}
