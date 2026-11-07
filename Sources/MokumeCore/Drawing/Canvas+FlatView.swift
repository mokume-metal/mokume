// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 平面の図形 (`rect`・`circle`・`text`・`image` など) を、いまの視点と変換の 3 成分に通す ([#3830])。
//
// **2D の図形も立体と同じ空間に置かれる** ([ADR-0021] 決定 1 の改訂 2026-11-07)。奥行き 0 に置いた立体と同じ座標の
// 平面の図形は、視点によらず一致する。重なりは呼び出し順のまま (同 決定 2) で、平面は奥行きを読みも書きもしない。
//
// ## 2 つの場合
//
// - **素の場合**: 視点が既定とビット列まで同じ (指定しない・`camera()` で戻した後) で、変換が平面を奥行き 0 の面に
//   保つ (行列の z の行の x・y・平行移動が 0)。平面の図形は**いままでと 1 ビットも同じ経路**を通る — 置き方は
//   ``Canvas/transform`` の x・y、列の行列は ``Canvas/projection``。
// - **空間の場合**: それ以外。平面の図形の載る面 (変換が写す平面) を、画面に平行になる**最小の回転**で寝かせた
//   座標 (平面の座標) に置き、列の行列を「視点の行列 × 寝かせた座標を空間へ戻す行列」にする。
//   面が既に画面に平行 (2D の変換と z の平行移動だけ) なら回転は要らず、置き方は変換そのもので、戻す行列は z の
//   平行移動だけになる。同じ奥行きに置いた図形は 1 つの列に並び、畳みもそのまま効く。
//
// **寝かせた座標は空間の面と等長である。** 真横を向いた面 (`rotateY(HALF_PI)` の壁) でも、線の太さや曲線の刻みが
// 面の上の長さのまま決まる。平面の座標 (x・y) から逆行列で奥行きを復元する形は、置き方を変えずに済むが、真横を
// 向いた面で潰れて消え、斜めの面では線が伸びるので採らない (#3830 のプラン)。
//
// ## 列
//
// 列は行列を 1 つ持つので、**行列が変わるところで列を閉じる** (``enterFlatView(_:)``)。閉じた列は、開いたときの
// 行列を持っていく — 後で視点や変換を書き換えても、先に置いた図形は動かない ([ADR-0021] 決定 2 の「記録した列
// だけで絵が決まる」)。
//
// [#3830]: https://github.com/mokume-metal/mokume/issues/3830
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {
    /// 平面の図形をどう置き、どの行列で画面へ落とすか。
    struct FlatView {
        /// 平面の頂点を置く変換。**平面の経路はこの x・y だけを読む** (奥行きは列の行列が持つ)。
        var placing: Transform
        /// 列の行列。`nil` は素の場合で、列は ``Canvas/projection`` を持つ。
        var clip: simd_float4x4?
    }

    /// 平面の図形を置く変換。素の場合は ``transform`` そのもの。**平面の経路は変換をこれで読む。**
    var flatTransform: Transform { currentFlatView.placing }

    /// いまの変換と視点での置き方。控え (``flatViewMemo``) は変換・視点・形の組み立ての旗を書くたびに外れ、読むときに作り直す。
    var currentFlatView: FlatView {
        if let flatViewMemo { return flatViewMemo }
        let view = flatView(of: transform.matrix)
        flatViewMemo = view
        return view
    }

    /// 視点が既定とビット列まで同じか。`camera()` で戻した視点も既定と同じなら素の場合に入る。
    var cameraIsPlain: Bool {
        if let cameraPlainMemo { return cameraPlainMemo }
        let plain = cameraStorage.map { $0.isBitwiseEqual(to: defaultCamera) } ?? true
        cameraPlainMemo = plain
        return plain
    }

    /// 視点の行列の控え (``viewProjection`` と同じ値)。平面の図形は変換を書き換えるたびに置き方を作り直すので、
    /// 視点の行列 (三角関数と正規化を含む) を毎回組まない。視点を書き換えると外れる。
    var flatViewProjection: simd_float4x4 {
        if let viewProjectionMemo { return viewProjectionMemo }
        let matrix = viewProjection
        viewProjectionMemo = matrix
        return matrix
    }

    /// 変換 `matrix` で置く平面の図形の置き方。
    ///
    /// **形の組み立ての中は素の置き方を返す。** 記録した頂点は形自身の座標で、置くとき (``shape(_:at:)``) に置き場所の
    /// 変換と合わせて改めて求める。形の切り抜き (`clip { }`) も組み立ての中で記録するので、切り抜きは面の上で読む
    /// まま変わらない (視点の下の切り抜きの意味は #3841 で決める)。
    func flatView(of matrix: simd_float4x4) -> FlatView {
        let columns = matrix.columns
        // 数でない・無限の変換で置いた図形は、どちらの経路でも描かれない。素の経路へ倒し、ベクターの書き出しでも
        // 「視点を通る」と名乗らない (画面にも出ない図形は名乗らない・#3318)
        let isFinite =
            Self.isFinite(columns.0) && Self.isFinite(columns.1) && Self.isFinite(columns.3)
        let staysOnSurface = columns.0.z == 0 && columns.1.z == 0 && columns.3.z == 0
        if recordingShape || !isFinite || (staysOnSurface && cameraIsPlain) {
            return FlatView(placing: Transform(matrix: matrix), clip: nil)
        }
        let (placing, world) = Self.laidFlat(matrix)
        return FlatView(placing: Transform(matrix: placing), clip: flatViewProjection * world)
    }

    /// 列の x・y・z が全部有限か。
    private static func isFinite(_ column: SIMD4<Float>) -> Bool {
        column.x.isFinite && column.y.isFinite && column.z.isFinite
    }

    /// 変換 `matrix` が写す面を、画面に平行になる最小の回転で寝かせる。返すのは、寝かせた座標へ置く行列と、
    /// 寝かせた座標を空間へ戻す行列。
    ///
    /// 面の法線 `n` (変換の 1 列目と 2 列目の外積) を、`n` に近い側の奥行きの軸 (±z) へ回す。回す角は 90 度以下で、
    /// 回転の式 (ロドリゲス) の分母 `1 + cos` は 1 以上になるので、真横を向いた面でも数が暴れない。面が既に画面に
    /// 平行なとき (法線の x・y が 0。2D の変換と z の平行移動だけ) は回さず、置き方は `matrix` そのものを返す —
    /// x・y は 1 ビットも変わらない。
    ///
    /// 寝かせる軸は面の原点 (変換の平行移動) を通す。寝かせた座標の x・y は、回さないときの x・y と原点で一致する。
    static func laidFlat(_ matrix: simd_float4x4) -> (placing: simd_float4x4, world: simd_float4x4) {
        let columns = matrix.columns
        let origin = SIMD3(columns.3.x, columns.3.y, columns.3.z)
        let normal = simd_cross(
            SIMD3(columns.0.x, columns.0.y, columns.0.z), SIMD3(columns.1.x, columns.1.y, columns.1.z))
        let length = simd_length(normal)
        guard normal.x != 0 || normal.y != 0, length.isNormal else {
            // 画面に平行な面 (と、面積の無い・数でない変換)。奥行きを平行移動として戻すだけ
            return (matrix, Transform.translation(x: 0, y: 0, z: origin.z))
        }
        let unit = normal / length
        let target = SIMD3<Float>(0, 0, unit.z < 0 ? -1 : 1)
        let axis = simd_cross(unit, target)
        let cosine = simd_dot(unit, target)
        let skew = simd_float3x3(
            SIMD3(0, axis.z, -axis.y), SIMD3(-axis.z, 0, axis.x), SIMD3(axis.y, -axis.x, 0))
        let rotation = matrix_identity_float3x3 + skew + skew * skew * (1 / (1 + cosine))
        let turn = simd_float4x4(
            SIMD4(rotation.columns.0, 0), SIMD4(rotation.columns.1, 0), SIMD4(rotation.columns.2, 0),
            SIMD4(0, 0, 0, 1))
        let toOrigin = Transform.translation(x: -origin.x, y: -origin.y, z: -origin.z)
        let onSurface = Transform.translation(x: origin.x, y: origin.y, z: 0)
        let placing = onSurface * turn * toOrigin * matrix
        let world =
            Transform.translation(x: origin.x, y: origin.y, z: origin.z) * turn.transpose
            * Transform.translation(x: -origin.x, y: -origin.y, z: 0)
        return (placing, world)
    }

    /// これから積む平面の図形の列の行列を `clip` にする。**開いている列の行列と違えば、列を閉じる。**
    ///
    /// 呼ぶのは平面の列を開く口 (``beginFlat(view:)``・``beginForm(flags:thinFill:obliqueEdge:)``) と、畳む口の入口。
    /// 雛形を組み立てている間 (``buildingFlatTemplate``) は呼ばない — 雛形は変換を単位にして組むが、置くのは
    /// 開いたときの行列の列である。形の組み立ての中では置き方が素 (`nil`) なので閉じない。
    func enterFlatView(_ clip: simd_float4x4?) {
        guard !buildingFlatTemplate else { return }
        if !Self.sameFlatClip(openFlatClip, clip) { closeBatch() }
        openFlatClip = clip
    }

    /// 2 つの列の行列が同じか (ビット列で比べる)。
    static func sameFlatClip(_ a: simd_float4x4?, _ b: simd_float4x4?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return Transform(matrix: a).isBitwiseEqual(to: Transform(matrix: b))
        default: return false
        }
    }
}
