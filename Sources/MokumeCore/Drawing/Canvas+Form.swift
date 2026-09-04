// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 平面の基本図形を、1 インスタンス = 1 クアッド + 距離関数で描く経路 (#752)。
//
// 矩形・楕円・扇形・線・点は頂点を組み立てない。置き場所 (`FormInstance`) に寸法まで
// 載せて 1 つの列に並べ、断片関数が距離関数で形を出す。寸法違いでも種別違いでも列は
// 切れず、色の変化も変換 (push / rotate / translate) も置き場所が持つ。
//
// 三角形で組み立てる経路に残るのは、任意多角形 (`beginShape`)・三角形・四角形・字・
// 画像と、貼る絵 (`texture()`) か利用者の断片 (`shader()`) が効いている基本図形である
// (`formAllowed(fills:)`)。前者は距離関数で表せず、後者は断片が読む面・頂点の属性を
// 契約として持つので、そこへ距離関数の被覆を挟むと意味が変わる。
extension Canvas {
    /// 開いている基本図形の列ひとつぶん。
    struct OpenForm {
        /// 置き場所の並びの中で、この列が始まる位置。
        var instanceStart: Int
    }

    /// 基本図形をこの経路で描いてよいか。
    ///
    /// 貼る絵は**塗りにしか効かない**ので、塗りを持たない線と点は絵が束ねてあっても
    /// この経路でよい。利用者の断片は塗りも輪郭も塗るので、どちらも三角形の経路へ。
    func formAllowed(fills: Bool) -> Bool {
        currentShader == nil && !(fills && hasFill && currentPicture != nil)
    }

    /// 基本図形を溜める側へ移る。**開いている平面の列・立体の列はここで閉じる**
    /// (呼び出し順どおりに重ねる — ``beginFlat()`` と対)。
    ///
    /// 列に入る置き場所が上限 (``instanceCapacity``) に達したら閉じて開き直す。
    /// 描く回数が増えるだけで、絵は 1 ビットも変わらない。
    func beginForm() {
        if openSource != .form {
            closeBatch()
            openSource = .form
        }
        if let open = openForm, formInstances.count - open.instanceStart >= instanceCapacity {
            closeBatch()
        }
        if openForm == nil {
            openForm = OpenForm(instanceStart: formInstances.count)
        }
    }

    /// 開いている基本図形の列を閉じる。
    ///
    /// 光も材質も周囲も効かない (平面は光を受けない)。読む面も無いが、区間の形を
    /// 保持した形と揃えるため `texture` にはいまの面を入れておく。
    func closeFormBatch() {
        guard let open = openForm else { return }
        openForm = nil
        let count = formInstances.count - open.instanceStart
        guard count > 0 else { return }
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: currentBlendMode, texture: currentTexture,
                    shader: nil, values: [], surfaces: [], numbers: nil,
                    source: .form, start: open.instanceStart, count: count),
                clip: currentClip,
                matrix: jittered(projection),
                lightRange: 0..<0,
                material: .default,
                viewer: SIMD4(0, 0, -1, 0),
                surroundings: .none,
                castsShadow: false,
                instanceStart: open.instanceStart,
                instanceCount: count))
    }

    /// 基本図形を 1 つ置く。
    ///
    /// - Parameters:
    ///   - center: 形の中心 (変換を掛ける前の座標)。
    ///   - half: 半幅・半高 (楕円は半径。線は半分の長さと 0)。
    ///   - axis: 形自身の横軸の向き (長さ 1)。線だけが線の向きを渡す。
    ///   - arc: 扇形の開始角と掃引。
    ///   - fills: この形が塗りを持ちうるか (線と点は持たない)。
    ///   - cap: 端の形。渡さなければいまの設定。点は孤立した端として `square` を `project` に読み替える。
    func appendForm(
        _ kind: FormInstance.Kind, center: SIMD2<Float>, half: SIMD2<Float>,
        axis: SIMD2<Float> = SIMD2(1, 0), arc: SIMD2<Float> = .zero,
        fills: Bool, cap: StrokeCap? = nil
    ) {
        // **色は `Optional` にしない。** 持つかどうかは旗で渡す (``FormInstance/init``)
        let drawsFill = fills && hasFill
        let drawsStroke = hasStroke && currentStrokeWeight > 0
        guard drawsFill || drawsStroke else { return }

        // いまの変換の 2x2 に、形自身の横軸の向きを掛ける (線以外は単位)
        let columns = transform.matrix.columns
        let c0 = SIMD2(columns.0.x, columns.0.y)
        let c1 = SIMD2(columns.1.x, columns.1.y)
        let x = c0 * axis.x + c1 * axis.y
        let y = c0 * (-axis.y) + c1 * axis.x
        let instance = FormInstance(
            kind: kind, linear: SIMD4(x.x, x.y, y.x, y.y),
            offset: transform.apply(x: center.x, y: center.y), half: half, arc: arc,
            halfWeight: currentStrokeWeight / 2,
            fill: currentFill.components, stroke: currentStroke.components,
            fills: drawsFill, strokes: drawsStroke,
            cap: cap ?? currentStrokeCap, join: currentStrokeJoin)
        // 数でない値・潰れた変換は置かない。三角形のときも面積が無くて何も出なかった
        guard instance.isPlaceable, half.x.isFinite, half.y.isFinite,
            currentStrokeWeight.isFinite, arc.x.isFinite, arc.y.isFinite
        else { return }

        beginForm()
        formInstances.append(instance)
    }

    /// 線を基本図形として置く。長さが 0 でも端の形ぶんは出る (点と同じ規則)。
    func appendLineForm(_ a: SIMD2<Float>, _ b: SIMD2<Float>) {
        let delta = b - a
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length.isFinite else { return }
        // 長さちょうどで切る端は、長さ 0 の線では何も描かない (三角形のときと同じ)
        if length == 0, currentStrokeCap == .square { return }
        let axis = length > 0 ? delta / length : SIMD2(1, 0)
        appendForm(
            .line, center: (a + b) / 2, half: SIMD2(length / 2, 0), axis: axis, fills: false)
    }

    /// 点を基本図形として置く。大きさは線の太さ、形は端の形が決める。
    ///
    /// 孤立した端なので、長さちょうどで切る形 (`square`) も正方形として出る
    /// (``StrokeCap/square`` の「線の長さちょうど」は線が無いと決まらない)。
    func appendPointForm(_ point: SIMD2<Float>) {
        appendForm(
            .line, center: point, half: .zero, fills: false,
            cap: currentStrokeCap == .round ? .round : .project)
    }
}
