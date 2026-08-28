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
        let runStart = batches.count

        // 記録の間に触った状態は外へ出さない。**形自身の座標で記録する**ので、
        // 変換も畳んでおく — そうしないと、組み立てた場所でしか置けない形になる
        pushStyle()
        pushMatrix()
        resetMatrix()
        let savedTexture = currentTexture
        let savedTextureKind = currentTextureKind
        currentClip = nil

        body()

        closeBatch()
        let recorded = Array(vertices[vertexStart...])
        let recordedSolid = Array(solidVertices[solidStart...])
        let runs = batches[runStart...].map {
            var run = $0.run
            run.start -= run.source == .flat ? vertexStart : solidStart
            return run
        }

        // 記録したぶんを溜め場から抜く。**抜いてから状態を戻す** — 先に戻すと、
        // 記録した頂点が戻したあとの設定で閉じられる
        vertices.removeLast(vertices.count - vertexStart)
        solidVertices.removeLast(solidVertices.count - solidStart)
        batches.removeLast(batches.count - runStart)
        currentTexture = savedTexture
        currentTextureKind = savedTextureKind
        popMatrix()
        popStyle()

        return Shape(vertices: recorded, solidVertices: recordedSolid, runs: Array(runs))
    }

    /// 保持した形を置く。
    public func shape(_ shape: Shape, _ x: Float = 0, _ y: Float = 0) {
        guard !shape.isEmpty else { return }
        let savedMode = currentBlendMode
        let savedTexture = currentTexture
        let savedTextureKind = currentTextureKind

        for run in shape.runs {
            // 区間の設定へ移る。**同じなら列は閉じない**ので、続けて置いた形は
            // 前の形と同じ列に並び、描く回数は増えない
            blendMode(run.mode)
            useTexture(run.texture, kind: run.textureKind)
            switch run.source {
            case .flat: place(run, of: shape, at: x, y)
            case .solid: inSolidBatch { placeSolid(run, of: shape, at: x, y) }
            }
        }

        // 記録した設定を外へ漏らさない。**戻す操作が列を閉じる**ので、いま置いた
        // 頂点は区間の設定で描かれる
        blendMode(savedMode)
        useTexture(savedTexture, kind: savedTextureKind)
    }

    /// 平面の区間を置く。
    private func place(_ run: Shape.Run, of shape: Shape, at x: Float, _ y: Float) {
        // **まとめて写してから、その場で移す。** 1 頂点ずつ足すと、置くたびに
        // 溜め場の伸長判定を通ることになる — 保持の速さはここで決まる
        let base = vertices.count
        vertices.append(contentsOf: shape.vertices[run.start..<(run.start + run.count)])
        let matrix = transform.matrix
        vertices.withUnsafeMutableBufferPointer { buffer in
            for index in base..<(base + run.count) {
                let point = SIMD4<Float>(
                    buffer[index].position.x + x, buffer[index].position.y + y, 0, 1)
                let moved = matrix * point
                buffer[index].position = SIMD2<Float>(moved.x, moved.y)
            }
        }
    }

    /// 立体の区間を置く。
    ///
    /// 位置と一緒に**面の向きも移す** — 移さないと、回して置いた形だけ光が付いて
    /// 回らない。位置と違って向きには軸ごとの倍率が逆に効くので、専用の行列を使う。
    private func placeSolid(_ run: Shape.Run, of shape: Shape, at x: Float, _ y: Float) {
        let base = solidVertices.count
        solidVertices.append(
            contentsOf: shape.solidVertices[run.start..<(run.start + run.count)])
        let matrix = transform.matrix
        let normalMatrix = transform.normalMatrix
        solidVertices.withUnsafeMutableBufferPointer { buffer in
            for index in base..<(base + run.count) {
                let position = buffer[index].position
                let moved =
                    matrix * SIMD4<Float>(position.x + x, position.y + y, position.z, 1)
                buffer[index].position = SIMD3<Float>(moved.x, moved.y, moved.z)
                let normal = normalMatrix * SIMD3<Float>(buffer[index].normal.x,
                    buffer[index].normal.y, buffer[index].normal.z)
                // 4 つ目は「形から求めた向きか」なので、移さずそのまま残す
                buffer[index].normal = SIMD4<Float>(normal, buffer[index].normal.w)
            }
        }
    }
}
