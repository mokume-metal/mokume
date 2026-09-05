// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 保持した形。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// 組み立ては**いつもの描画をそのまま記録する**形で行う。図形の三角形分割も輪郭の生成も
// 経路が 1 つしかないので、保持した形と即時に描いた形が食い違わない。奥行きを持つ頂点も
// 同じ経路を通るので、**立体だけ保持できないということが起きない** ([ADR-0021] 決定 5)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {
    /// 形を組み立てて保持する。
    public func createShape(_ body: () -> Void) -> Shape {
        closeBatch()
        let vertexStart = vertices.count
        let solidStart = solidVertices.count
        let formStart = formInstances.count
        let instanceStart = solidInstances.count
        let runStart = batches.count

        // 記録の間に触った状態は外へ出さない。**形自身の座標で記録する**ので、
        // 変換も畳んでおく — そうしないと、組み立てた場所でしか置けない形になる
        pushStyle()
        pushMatrix()
        resetMatrix()
        let savedTexture = currentTexture
        currentClip = nil
        // **記録の間は畳まない。** 畳むと置き場所が溜め場の側に残り、記録した頂点からは
        // どこへ置くかが落ちる (`Canvas.recordingShape`)
        let savedRecording = recordingShape
        recordingShape = true

        body()

        recordingShape = savedRecording
        closeBatch()
        let recorded = Array(vertices[vertexStart...])
        let recordedSolid = Array(solidVertices[solidStart...])
        let recordedForms = Array(formInstances[formStart...])
        let runs = batches[runStart...].map {
            var run = $0.run
            switch run.source {
            case .flat: run.start -= vertexStart
            case .solid: run.start -= solidStart
            case .form: run.start -= formStart
            }
            return run
        }

        // 記録したぶんを溜め場から抜く。**抜いてから状態を戻す** — 先に戻すと、
        // 記録した頂点が戻したあとの設定で閉じられる
        vertices.removeLast(vertices.count - vertexStart)
        solidVertices.removeLast(solidVertices.count - solidStart)
        formInstances.removeLast(formInstances.count - formStart)
        // 記録の間に開いた置き場所も抜く。**形は何も動かさない置き場所で置き直される**
        // ので、記録側で持ち歩く必要が無い
        solidInstances.removeLast(solidInstances.count - instanceStart)
        batches.removeLast(batches.count - runStart)
        currentTexture = savedTexture
        popMatrix()
        popStyle()

        return Shape(
            vertices: recorded, solidVertices: recordedSolid, forms: recordedForms,
            runs: Array(runs))
    }

    // 保持した形を置く。
    public func shape(_ shape: Shape, _ x: Float = 0, _ y: Float = 0) {
        place(shape, at: [Placement(x: x, y: y)])
    }

    // 保持した形を、置き場所ぶんだけまとめて置く。
    public func shape(_ shape: Shape, at placements: [Placement]) {
        place(shape, at: placements)
    }

    /// 保持した形を、渡した置き場所ぶんだけ置く。
    ///
    /// **立体の区間は、頂点を 1 度だけ置いて置き場所を並べる。** 基本図形の区間も
    /// 置き場所に変換を掛けるだけで、頂点は触らない。三角形で組み立てた平面の区間だけは
    /// 置き場所ごとに頂点を展開する (その区間には置き場所の仕組みが無い)。どれも、同じ
    /// 置き場所を 1 つずつ書いたときと同じ絵になる。
    private func place(_ shape: Shape, at placements: [Placement]) {
        guard !shape.isEmpty else { return }
        let usable = placements.filter(\.isUsable)
        if usable.count != placements.count { warnBadPlacement() }
        guard !usable.isEmpty else { return }

        let savedMode = currentBlendMode
        let savedTexture = currentTexture

        for run in shape.runs {
            // 区間の設定へ移る。**同じなら列は閉じない**ので、続けて置いた形は
            // 前の形と同じ列に並び、描く回数は増えない
            blendMode(run.mode)
            useTexture(run.texture)
            // **塗りも記録したものへ戻す。** 置く時点の shader() で塗ると、組み立てる
            // コードを読んでも何色になるかが分からない形になる (#788)
            usePaint(run.paint)
            switch run.source {
            case .flat:
                for placement in usable { place(run, of: shape, at: placement) }
            case .solid:
                // **立体は区間を先に開いてから、記録した面を束ね直す。**
                // `beginSolids` は `useFillTexture()` を通るので、**置く側の**
                // `currentPicture` で面を選び直してしまう — 置く側は普通 `texture()` を
                // 呼んでいないので焼き場へ倒れ、記録した面が捨てられる ([#914])。
                //
                // 直後に置くと描かれていたのは、`createShape` が `openSource` を
                // `.solid` のまま抜けて `beginSolids` が早期 return するからで、
                // **フレームをまたぐと上書きされる**という非対称になっていた。
                //
                // `beginSolids` の側は触らない。あちらの `useFillTexture()` は
                // その場で並べる頂点 (`inSolidBatch`) にとっては正しい振る舞いである。
                //
                // [#914]: https://github.com/mokume-metal/mokume/issues/914
                beginSolids()
                useTexture(run.texture)
                placeSolid(run, of: shape, at: usable)
            case .form:
                for placement in usable { placeForms(run, of: shape, at: placement) }
            }
        }

        // 記録した設定を外へ漏らさない。**戻す操作が列を閉じる**ので、いま置いた
        // 頂点は区間の設定で描かれる
        blendMode(savedMode)
        useTexture(savedTexture)
        stopReplayingPaint()
    }

    /// 平面の区間を置く。**立体の列が開いていれば閉じる** (呼び出し順どおりに重ねる)。
    private func place(_ run: Shape.Run, of shape: Shape, at placement: Placement) {
        // **まとめて写してから、その場で移す。** 1 頂点ずつ足すと、置くたびに
        // 溜め場の伸長判定を通ることになる — 保持の速さはここで決まる
        let base = vertices.count
        beginFlat()
        vertices.append(contentsOf: shape.vertices[run.start..<(run.start + run.count)])
        let matrix = transform.matrix * placement.transform.matrix
        let tint = placement.fill
        vertices.withUnsafeMutableBufferPointer { buffer in
            for index in base..<(base + run.count) {
                let point = SIMD4<Float>(
                    buffer[index].position.x, buffer[index].position.y, 0, 1)
                let moved = matrix * point
                buffer[index].position = SIMD2<Float>(moved.x, moved.y)
                // 置き場所の色は**掛かる**。渡さなければ何も掛からない
                if let tint {
                    let color = buffer[index].color
                    buffer[index].color = SIMD4<Float>(
                        color.x * tint.red, color.y * tint.green, color.z * tint.blue,
                        color.w * tint.alpha)
                }
            }
        }
    }

    /// 基本図形の区間を置く。**開いている平面・立体の列は閉じる** (呼び出し順どおりに重ねる)。
    ///
    /// 記録した置き場所は形自身の座標なので、いまの変換と置き場所の変換を合成して
    /// 掛ける。頂点を 1 つも触らないので、**円を含む形も、頂点を並べた形と同じ速さで置ける**。
    private func placeForms(_ run: Shape.Run, of shape: Shape, at placement: Placement) {
        let matrix = transform.matrix * placement.transform.matrix
        for form in shape.forms[run.start..<(run.start + run.count)] {
            let moved = form.placed(by: matrix, tint: placement.fill)
            // 潰れた変換で置いた形は面積を持たない (直に描いたときと同じく何も出ない)
            guard moved.isPlaceable else { continue }
            beginForm(flags: moved.meta.w)
            formInstances.append(moved)
        }
    }

    /// 立体の区間を置く。
    ///
    /// 位置と一緒に**面の向きも移す** — 移さないと、回して置いた形だけ光が付いて
    /// 回らない。位置と違って向きには軸ごとの倍率が逆に効くので、専用の行列を使う。
    private func placeSolid(_ run: Shape.Run, of shape: Shape, at placements: [Placement]) {
        beginSolids()
        var placed = 0
        while placed < placements.count {
            // **頂点は 1 度だけ置く。** 上限に達したら列を閉じて置き直す — 描く
            // 回数が増えるだけで、絵は 1 ビットも変わらない
            closeBatch()
            let start = solidVertices.count
            solidVertices.append(
                contentsOf: shape.solidVertices[run.start..<(run.start + run.count)])
            retainedSerial += 1
            openSolid = OpenSolid(
                source: .retained(serial: retainedSerial), vertexStart: start,
                vertexCount: run.count, instanceStart: solidInstances.count)

            let room = min(instanceCapacity, placements.count - placed)
            for placement in placements[placed..<(placed + room)] {
                let combined = Transform(
                    matrix: transform.matrix * placement.transform.matrix)
                solidInstances.append(
                    SolidInstance(
                        matrix: combined.matrix, normalMatrix: combined.normalMatrix,
                        // 記録した頂点が色を持つので、置き場所は**白** (掛けても
                        // 変わらない)。渡された色があればそれを掛ける
                        color: placement.fill
                            ?? LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1)))
            }
            placed += room
        }
    }

    /// 置けない置き場所を、初回だけ知らせる。
    private func warnBadPlacement() {
        warnOnce(
            .badPlacement,
            "shape(at:): 数でない値・無限を含む置き場所があったので、その分は置きませんでした")
    }
}
