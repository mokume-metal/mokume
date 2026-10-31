// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

// 計算が書いた数の並びを置き場所として読み、保持した形を読み戻しなしで置く
// (``Canvas/shape(_:at:layout:)``)。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **粒の速い経路と同じ道に載せる。** 粒は GPU が置き場所を埋めて個数も GPU が決める
// (``Canvas/placeFromGPU``)。ここも、位置の並びから「置ける位置だけを並びの順に詰める」計算を
// 普通の計算として積み (旗 → scan → 詰める)、詰めた置き場所を外の置き場として読む列を開く。
// **読み戻しも CPU の待ちも無い** — 計算の投入と描画の同期は計算の段の仕掛けがそのまま持つ
// ([ADR-0023] 決定 3)。
//
// **載る形は粒の板と同じ範囲だけ**で、立体の区間が 1 つ・添字なし・立体の線なし・裏 → 表に描き分ける
// 部品なしの形である。`[Placement]` の道が置き場所ごとに CPU で頂点へ入れる手入れ
// (線の組み直し・部品の写し・区間ごとの置き直し) は GPU に写さない — 規模が数倍になる。載らない形を
// 読み戻して置くことも採らない (費用が見えなくなる)。載らない形は 1 度知らせて描かない
// ([ADR-0020] 決定 5)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
extension Canvas {
    /// 位置の並びごとの常駐の置き場と、その計算の入口。**面が 1 つ持つ。**
    ///
    /// 計算の入口は初めて使うときに 1 度だけ組む — 使わない面は組む費用も払わない。置き場は並び
    /// (``Numbers``) ごとで、並びを手放したら次の呼び出しで畳む。際限なく増えない
    /// ([ADR-0023] 決定 5)。
    ///
    /// **組み立てに失敗したら、失敗を覚えて同じものを組み直さない。** 失敗は 1 度しか知らせないので、
    /// 覚えないと、見えないまま毎フレーム原文を組み直し、置き場を確保し直して重くなる
    /// (描き切りの失敗を同じ番号のうちは繰り返さない ``Canvas`` の `framesDrawn` の扱いと同じ考え)。
    /// 覚えるのは計算の入口が面ごとに 1 つ、置き場が並びごとに 1 つ。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    final class PositionLayouts {
        /// 組んだ計算の入口。
        var kernels: PositionKernels?
        /// 計算の入口の組み立てが失敗した理由。あれば、組み直さずにこれを投げる。
        var kernelsFailure: RenderFailure?
        private var placers: [ObjectIdentifier: PositionPlacer] = [:]
        private var placerFailures: [ObjectIdentifier: PlacerFailure] = [:]

        /// 置き場の組み立てが失敗した並びと、その理由。
        private struct PlacerFailure {
            let source: Weak<Numbers>
            let capacity: Int
            let failure: RenderFailure
        }

        /// 計算の入口・置き場を組もうとした回数。**検査が読む** (失敗の後に組み直していないことを見る)。
        private(set) var kernelBuildAttempts = 0
        private(set) var placerBuildAttempts = 0
        /// 次に組むときに投げる失敗。**検査が差し替える** (組み立ての失敗は検査の中で起こせない)。
        var kernelFailureForTesting: RenderFailure?
        var placerFailureForTesting: RenderFailure?

        /// 計算の入口を組もうとする回を数え、検査が差し替えた失敗があれば投げる。
        func beginKernelBuild() throws(RenderFailure) {
            kernelBuildAttempts += 1
            if let kernelFailureForTesting { throw kernelFailureForTesting }
        }

        /// `positions` の置き場。無ければ作る。
        ///
        /// **手放された並びの置き場は、呼び出しのたびに畳む。** 作るときだけ畳むと、新しい並びを
        /// 使わない間は手放した並びの置き場が残る。並びの識別子は手放した後に別の並びが使い回しうるので、
        /// 同じ識別子でも読み元が同じ並びかを確かめる。
        func placer(
            for positions: Numbers, capacity: Int, gpu: RenderDevice
        ) throws(RenderFailure) -> PositionPlacer {
            foldReleased()
            let key = ObjectIdentifier(positions)
            if let existing = placers[key], existing.source === positions,
                existing.capacity == capacity
            {
                return existing
            }
            if let failed = placerFailures[key], failed.source.value === positions,
                failed.capacity == capacity
            {
                throw failed.failure
            }
            placerBuildAttempts += 1
            do throws(RenderFailure) {
                if let placerFailureForTesting { throw placerFailureForTesting }
                let made = try PositionPlacer(source: positions, capacity: capacity, gpu: gpu)
                placers[key] = made
                placerFailures[key] = nil
                return made
            } catch {
                placerFailures[key] = PlacerFailure(
                    source: Weak(positions), capacity: capacity, failure: error)
                throw error
            }
        }

        /// 手放された並びの置き場と、その失敗の記録を畳む。
        private func foldReleased() {
            if placers.values.contains(where: { $0.source == nil }) {
                placers = placers.filter { $0.value.source != nil }
            }
            if placerFailures.values.contains(where: { $0.source.value == nil }) {
                placerFailures = placerFailures.filter { $0.value.source.value != nil }
            }
        }

        /// 持っている置き場の数。**手放された並びのものも数える** — 畳んだかを検査が読む。
        var placerCount: Int { placers.count }

        /// 作ってあれば `positions` の置き場。**検査が読む。**
        func existingPlacer(for positions: Numbers) -> PositionPlacer? {
            guard let found = placers[ObjectIdentifier(positions)], found.source === positions else {
                return nil
            }
            return found
        }
    }

    /// 数の並びで置ける形かを調べた結果。
    enum PositionLayoutEligibility {
        /// 置ける。置く区間を返す。
        case placeable(Shape.Run)
        /// 置けない。理由を並べる (英語。注意の文面にそのまま入る)。
        case refused([String])
    }

    /// `shape` が、数の並びで置ける形か。**粒の板と同じ道に載る形だけ**を通す。
    ///
    /// 見るのは、置き場所を外の置き場から取る列が描けない・描き分けが要る形である:
    ///
    /// - 区間が 1 つで、立体であること。平面の区間・基本図形の区間は置き場所に載らない
    ///   (区間が複数の形の置き方は別の話で、置き場所ごとに区間を一巡する)
    /// - 添字を持たないこと。外の置き場から置き場所を取る列は、描く引数の構造体が添字の版と違うので
    ///   添字を持てない (``Canvas/closeSolidBatch()`` の前提)
    /// - 立体の線を持たないこと。線の帯は視点に合わせて置き場所ごとに組み直す
    /// - 裏 → 表に描き分ける部品を持たないこと。描き分けは置き場所ごとに描くので、描く個数を GPU が決める列には
    ///   載らない
    static func positionLayoutEligibility(of shape: Shape) -> PositionLayoutEligibility {
        var reasons: [String] = []
        guard shape.runs.count == 1, let run = shape.runs.first else {
            reasons.append("it is made of \(shape.runs.count) pieces and only one is allowed")
            return .refused(reasons)
        }
        if run.source != .solid {
            reasons.append("its piece is not a 3D solid")
        }
        if run.isIndexed {
            reasons.append("its solid piece reads its vertices by index")
        }
        if !shape.solidStrokes.isEmpty || !shape.gpuStrokes.isEmpty {
            reasons.append("it has 3D outlines (call noStroke() before building it)")
        }
        if shape.solidParts(in: run).contains(where: \.showsBackFaces) {
            reasons.append(
                "it has parts drawn back faces first (a translucent colour, a texture, a "
                    + "blend mode other than the normal one, or a shader)")
        }
        return reasons.isEmpty ? .placeable(run) : .refused(reasons)
    }

    // 計算が書いた数の並びを置き場所として読み、保持した形をまとめて置く。
    public func shape(_ shape: Shape, at positions: Numbers, layout: Placement.Layout) {
        placeAtPositions(shape, positions, layout: layout)
    }

    private func placeAtPositions(_ shape: Shape, _ positions: Numbers, layout: Placement.Layout) {
        // 置く口の関所と、計算を頼む口の関所を、副作用より前に通す。**組み立ての中では断る** — 組み立ては
        // 置き場所を頂点へ焼くが (`place(_:at:)`)、GPU の置き場所は CPU の手元に無いので焼けない
        guard canPlace else { return warnOutsideFrame(.placing) }
        guard !recordingShape else { return warnInsideShape(.positionLayout) }
        // 計算は描くところの外からは効かない (ADR-0023 決定 3)。外では頼まれない計算の結果を読む列を開かない
        guard isDrawing else { return warnPositionLayoutOutsideFrame() }
        guard !shape.isEmpty else { return }

        switch layout {
        case .position:
            break
        }
        let capacity = positions.count / 3
        if positions.count % 3 != 0 { warnPositionRemainder(count: positions.count) }
        guard capacity > 0 else { return }

        let run: Shape.Run
        switch Self.positionLayoutEligibility(of: shape) {
        case .placeable(let eligible):
            run = eligible
        case .refused(let reasons):
            return warnPositionLayoutShape(reasons)
        }

        let kernels: PositionKernels
        let placer: PositionPlacer
        let draw: PositionPlacer.Draw
        do {
            kernels = try positionKernels()
            placer = try positionLayouts.placer(for: positions, capacity: capacity, gpu: gpu)
            draw = try placer.claimDraw(by: self)
        } catch {
            return warnPositionLayoutUnavailable(error)
        }
        // 保持した形はベクターへ書けない (#3139)。何個置かれるかは GPU が決めるので、呼び出しごとに 1 回数える
        noteVectorDrop(.retainedShape)

        let world = transform.matrix
        placer.write(
            into: draw, world: world, normal: transform.normalMatrix, vertexCount: run.count)
        schedule(positions, placer, draw, kernels)

        // 鏡映の符号は画面の変換から CPU で決まる。位置だけを動かすので、置き場所は鏡映を作らない
        let mirrored = SolidInstance(
            matrix: world, normalMatrix: transform.normalMatrix, color: LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1)
        ).isMirrored
        replaying(CollectionOfOne(run)) { run in
            openRetainedSolid(
                run, of: shape, mirrored: mirrored,
                external: ExternalInstances(
                    instances: draw.instances, count: capacity, arguments: draw.arguments))
            closeBatch()
        }
    }

    /// 旗 → scan → 詰める を普通の計算として積む。依存の宣言から口の切れ目が導かれ、描画との同期も
    /// 既にある仕掛けが入れる。
    private func schedule(
        _ positions: Numbers, _ placer: PositionPlacer, _ draw: PositionPlacer.Draw,
        _ kernels: PositionKernels
    ) {
        compute(
            kernels.flag, over: placer.capacity,
            reads: [draw.parameters, positions], writes: [placer.levels])
        for level in 0..<placer.scanCount {
            compute(
                kernels.scan, over: placer.levelLengths[level + 1],
                reads: [placer.levelHeaders[level]], writes: [placer.levels])
        }
        compute(
            kernels.place, over: placer.capacity,
            reads: [draw.parameters, positions, placer.levels],
            writes: [draw.instances, draw.arguments])
    }

    /// 計算の入口。**初めて使うときに 1 度だけ組む。** 粒と同じ原文から取る。失敗したらそれを覚え、
    /// 次からは組み直さずに同じ失敗を投げる (``PositionLayouts``)。
    private func positionKernels() throws(RenderFailure) -> PositionKernels {
        if let kernels = positionLayouts.kernels { return kernels }
        if let failure = positionLayouts.kernelsFailure { throw failure }
        do throws(RenderFailure) {
            try positionLayouts.beginKernelBuild()
            let name = Self.particleShaderName
            let source = try gpu.shaders.bundledShaderSource(named: name)
            let library = try gpu.shaders.makeComputeLibrary(
                named: name, body: source, bodyName: ShaderLibraries.bundledName(name))
            let kernels = PositionKernels(
                flag: try particleKernel(PositionKernels.flagName, in: library, from: source),
                scan: try particleKernel(Self.particleScanKernelName, in: library, from: source),
                place: try particleKernel(PositionKernels.placeName, in: library, from: source))
            positionLayouts.kernels = kernels
            return kernels
        } catch {
            positionLayouts.kernelsFailure = error
            throw error
        }
    }

    // MARK: - 知らせる

    /// フレームの外で呼ばれた。**この口の名前で言う** — 計算を頼む口 (`compute`) の注意の鍵と文面を
    /// 借りると、`setup()` で `shape(at:layout:)` を呼んだ人に「計算は draw() から頼め」と言い、先に
    /// `compute` が同じ鍵で言っていればこちらは黙る。直す先は同じ (draw() の中) でも、何が断られたかが違う。
    private func warnPositionLayoutOutsideFrame() {
        warnOnce(
            .positionLayoutOutsideFrame,
            "shape(at:layout:) places shapes at positions that a computation wrote, and a "
                + "computation runs only while a frame is drawn, so call it from draw() (on a surface you "
                + "open yourself, between beginDraw() and endDraw()). This was called outside a frame, so "
                + "it belongs to no frame, and was ignored")
    }

    /// 並びの長さが 3 で割り切れない。端数は置かない。
    private func warnPositionRemainder(count: Int) {
        warnOnce(
            .positionLayoutRemainder,
            "shape(at:layout:): the array holds \(count) numbers, which is not a multiple of 3, so "
                + "\(count / 3) positions were placed and the last \(count % 3) number(s) were ignored")
    }

    /// 載らない形を渡された。**文面は載る形の範囲も言う** — 直す先が分かるように。
    private func warnPositionLayoutShape(_ reasons: [String]) {
        warnOnce(
            .positionLayoutShape,
            "shape(at:layout:): this shape cannot be placed from an array of numbers because "
                + reasons.joined(separator: "; ") + ", so it was not drawn. Only a shape made of one "
                + "3D solid piece with no outlines can be (for example createShape { noStroke(); "
                + "box(10) }), because the positions stay on the GPU and are never read back")
    }

    /// 計算の入口か置き場を用意できなかった。この呼び出しは描かない。
    private func warnPositionLayoutUnavailable(_ failure: RenderFailure) {
        warnOnce(
            .positionLayoutUnavailable,
            "shape(at:layout:): the computation that places the shapes could not be prepared "
                + "(\(failure.headline)), so this call was not drawn")
    }
}
