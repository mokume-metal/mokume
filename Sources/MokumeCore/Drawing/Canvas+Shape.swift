// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 保持した形。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// 組み立ては**いつもの描画をそのまま記録する**形で行う。図形の三角形分割も輪郭の生成も
// 経路が 1 つしかないので、保持した形と即時に描いた形が食い違わない。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Canvas {
    /// 形を組み立てて保持する。
    public func createShape(_ body: () -> Void) -> Shape {
        closeBatch()
        let vertexStart = vertices.count
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
        let runs = batches[runStart...].map {
            var run = $0.run
            run.start -= vertexStart
            return run
        }

        // 記録したぶんを溜め場から抜く。**抜いてから状態を戻す** — 先に戻すと、
        // 記録した頂点が戻したあとの設定で閉じられる
        vertices.removeLast(vertices.count - vertexStart)
        batches.removeLast(batches.count - runStart)
        currentTexture = savedTexture
        currentTextureKind = savedTextureKind
        popMatrix()
        popStyle()

        return Shape(vertices: recorded, runs: Array(runs))
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

        // 記録した設定を外へ漏らさない。**戻す操作が列を閉じる**ので、いま置いた
        // 頂点は区間の設定で描かれる
        blendMode(savedMode)
        useTexture(savedTexture, kind: savedTextureKind)
    }
}
