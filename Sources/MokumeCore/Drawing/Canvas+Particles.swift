// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

// 粒。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **専用の面を、計算の段の上に載せる。** 放出・力・寿命を利用者に断片で書かせるのは
// 「数行で書ける」から遠い一方、同期の話を 2 つ持つのは [ADR-0023] 決定 3 に反する。
// だから更新は普通の計算として `compute(_:over:reads:writes:)` へ積み、依存の宣言も
// 待つ仕掛けも既にあるものがそのまま効く。生存数を数える段も同じ形で積む — 前の計算が
// 書いた並びに触れる計算はそこで口が切れ、切れ目に待つ仕掛けが入る。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
extension Canvas {
    /// 粒の置き場所を誰が埋めるか。
    ///
    /// **2 本あるのは、速い側を照らす物差しが要るから**である。速い経路だけを持つと、
    /// 「置き場所の埋め方が正しいか」を確かめるものが何も無くなる。頂点も列も塗りも
    /// 同じで、違うのは置き場所の出どころだけなので、**同じ絵が出るはず**が言える。
    enum ParticleRoute {
        /// GPU が埋めて、GPU が個数を決める。読み戻しが要らない (既定)。
        case instanced
        /// CPU が読み戻して埋める。物差しとして検査が使う。
        case reference
    }

    /// 粒を用意する。
    public func makeParticles(count: Int) throws(RenderFailure) -> Particles {
        // 1 を割る数は断る。黙って 1 粒へ丸めない (ADR-0020 決定 5・#1642)
        guard count >= 1 else { throw .invalidCount(count) }
        let capacity = count
        let stateFloats = MemoryLayout<Particle>.stride / MemoryLayout<Float>.stride
        let placeFloats = MemoryLayout<SolidInstance>.stride / MemoryLayout<Float>.stride

        // **数え切れない指定は、確保の失敗として返す** (ADR-0020 決定 5 — 資源の生成は
        // 投げる)。掛け算が回り込むと、確保する前に別の壊れ方をする
        let (state, stateOverflowed) = capacity.multipliedReportingOverflow(by: stateFloats)
        let (places, placeOverflowed) = capacity.multipliedReportingOverflow(by: placeFloats)
        guard !stateOverflowed, !placeOverflowed else {
            throw .bufferUnavailable(byteCount: Int.max)
        }
        // 段の頭を渡せる数を超える容量も数え切れない (256^4 = 2^32 個より上)。置き場の
        // ほうが先に取れなくなるので普段は届かないが、届いても黙って壊れないようにする
        let lengths = Particles.levelLengths(capacity: capacity)
        guard lengths.count <= Particles.maximumLevels else {
            throw .bufferUnavailable(byteCount: Int.max)
        }

        let parameters = Particles.headerFloats + Particles.maximumForces * Force.slotCount
        let source = try gpu.shaders.bundledShaderSource(named: Self.particleShaderName)
        // **原文は 1 度だけ組む。** 3 つの入口は同じ原文にあるので、入口ごとに組むと
        // 同じものを 3 度組む (#728)
        let library = try gpu.shaders.makeComputeLibrary(
            named: Self.particleShaderName, body: source)
        var headers: [Numbers] = []
        for _ in 0..<(lengths.count - 1) { headers.append(try Numbers(gpu: gpu, count: 4)) }
        let particles = Particles(
            capacity: capacity,
            state: try Numbers(gpu: gpu, count: state),
            instances: try Numbers(gpu: gpu, count: places),
            parameters: try Numbers(gpu: gpu, count: parameters),
            levels: try Numbers(gpu: gpu, count: lengths.reduce(0, +)),
            levelHeaders: headers,
            arguments: try Numbers(gpu: gpu, count: Particles.argumentFloats),
            levelLengths: lengths,
            quad: particleQuad(),
            flag: try particleKernel(Self.particleFlagKernelName, in: library, from: source),
            scan: try particleKernel(Self.particleScanKernelName, in: library, from: source),
            update: try particleKernel(Self.particleKernelName, in: library, from: source))
        return particles
    }

    /// 粒 1 つを描く形。**保持した形をそのまま使う**ので、粒だけ別の頂点経路を持たない。
    private func particleQuad() -> Shape {
        createShape {
            fill(.linear(red: 1, green: 1, blue: 1))
            // **粒は板の塗りだけで出す。** 線は既定で有効なので、止めないと板の縁が
            // 形に焼き付く (記録の中のスタイルは外へ漏れない — `createShape`)
            noStroke()
            plane(1, 1)
        }
    }

    /// 組み込みの計算。**同梱した断片から組む**ので、壊れていればビルド時のシェーダ検査
    /// (`scripts/check-shaders.sh`) で落ちる — 走らせるまで分からない形にしない。
    ///
    /// **組むのは呼ぶ側である。** ここは組んだものから入口を 1 本取り出すだけにして、
    /// 同じ原文を入口の数だけ組まない。
    private func particleKernel(
        _ entry: String, in library: any MTLLibrary, from source: String
    ) throws(RenderFailure) -> Computation {
        let computation = try Computation(
            name: entry, url: nil, body: source, values: [:], library: library,
            gpu: gpu, pipeline: try computePipeline())
        remember(computation)
        return computation
    }

    /// 同梱した断片の名前。**検査が配置を確かめるのに同じものを読む。**
    static let particleShaderName = "Particles"
    /// 生き残る粒に旗を立てる入口の名前。
    static let particleFlagKernelName = "mokume_particleFlags"
    /// 旗を数える 1 段ぶんの入口の名前。
    static let particleScanKernelName = "mokume_particleScan"
    /// 1 フレーム進めて置く入口の名前。
    static let particleKernelName = "mokume_particles"
    /// 自分が見ている配置を書き出す入口の名前。**検査だけが呼ぶ。**
    static let particleLayoutKernelName = "mokume_particleLayout"

    /// 粒を出す。
    ///
    /// `Randomness` が内部の型なので、ここは公開しない — 面に出せる形にすると乱数の
    /// 流れが 2 系統になり、`randomSeed(_:)` が粒に効かなくなる ([ADR-0020] 決定 6)。
    func emit(
        _ particles: Particles, from source: Emitter, rate: Float,
        speed: ClosedRange<Float>, angle: ClosedRange<Float>, life: ClosedRange<Float>,
        size: ClosedRange<Float>, color: LinearRGBA?, using randomness: inout Randomness
    ) {
        guard isDrawing else { return warnOutsideFrame(.particles) }
        // 繰り越しは、このフレームで何回目の呼び出しかで分けて引く (#1468)。フレームの
        // 境目は描き切りで進む番号で、焼き場の頁を替えたフレームの判定と同じ作法。
        // 刻みは秒に直さずに渡す。単精度の秒を足し合わせると、fps によって毎秒 1 個ずれる (#1640)。
        // 数でない値・無限は受け口 (`Particles.emit`) が検めて断る (#1623)
        particles.emit(
            rate: rate, over: frameStep, frame: framesDrawn, from: source, speed: speed,
            angle: angle, life: life, size: size, color: color, fill: style.fill,
            using: &randomness)
    }

    /// 力を積む。
    public func force(_ particles: Particles, _ forces: [Force]) {
        guard isDrawing else { return warnOutsideFrame(.particles) }
        // このフレームで最初に積む前の数を控える。フレームを描かずに捨てるとき、ここから後を
        // 落とす ([#1622]・``forcesThisFrame``)
        //
        // [#1622]: https://github.com/mokume-metal/mokume/issues/1622
        if !forcesThisFrame.contains(where: { $0.particles.value === particles }) {
            forcesThisFrame.append((Weak(particles), particles.pendingForceCount))
        }
        particles.add(forces)
    }

    /// 1 フレーム進めて、生きている粒を描く。
    ///
    /// **呼ぶたびに進めて、呼んだ時点の変換で描く** ([#1651])。同じ描き切りの中で同じ群を
    /// 2 回目以降に置くときは、指定・置き場所・描く引数を呼び出しごとの組へ分ける
    /// (`Particles.claimDraw(by:)`)。途中の描き切りを挟む形は採らない — 途中の描き切りには
    /// 既知の破れがある (#1656・#1657)。
    ///
    /// **刻みの順は、呼んだ順である** ([#1870])。面ごとの描き切りに任せると、本体で先に呼んだ刻みより
    /// 描き場所で後に呼んだ刻みのほうが先に進むので、計算を頼む口が、別の面が先に頼んだ
    /// ぶつかる計算を先に投入する (``compute(_:over:by:reads:writes:)``)。
    ///
    /// [#1651]: https://github.com/mokume-metal/mokume/issues/1651
    /// [#1870]: https://github.com/mokume-metal/mokume/issues/1870
    public func particles(_ particles: Particles) {
        guard isDrawing else { return warnOutsideFrame(.particles) }
        // 組を選べなければ、力を取り出さずに帰る。積んだ力は次の呼び出しに効く
        let draw: Particles.Draw
        do {
            draw = try particles.claimDraw(by: self)
        } catch {
            return particles.warnDrawUnavailable(error)
        }
        // **速い経路は列を先に開く。** 描く引数 (頂点の頭と数) を GPU が書くので、
        // 四角をどこへ置いたかを計算へ渡す前に知っておく必要がある。列は閉じた時点の
        // 混ぜ方と変換で描かれるので、順序を入れ替えても絵は変わらない
        let placed = particleRoute == .instanced ? placeFromGPU(particles, draw) : nil
        particles.write(
            into: draw, transform: transform.matrix, basis: currentCamera.basis, step: frameStep,
            frame: particleFrame,
            forces: particles.takeForces(),
            vertexStart: placed?.start ?? 0, vertexCount: placed?.count ?? 0)
        // 取り出したので、控えた数はもう指す先が無い。この後に積む力は 0 個から数え直す
        forcesThisFrame.removeAll { $0.particles.value === particles }
        schedule(particles, draw)
        if particleRoute == .reference { placeFromCPU(particles) }
    }

    /// ``particles(_:)`` が GPU へ渡すフレーム番号。**時刻の置き場の持ち主 (本体) が閉じたフレームの
    /// 数** (``Timebase/mainFramesDrawn``) で、置き場を共有する面はどれも同じ番号を読む ([#1909])。
    /// `wander` の揺れは粒の番号とこの番号で決まるので、呼んだ面の数 (``framesDrawn``) を渡すと、
    /// 描き場所の描き歴 (遅れて描き始めた・描かなかったフレームがある) で同じ本体のフレームの揺れが
    /// 食い違う。
    ///
    /// 持ち主を弱く辿って読む形は採らない。持ち主を手放した瞬間に面ごとの数へ跳び、同じ置き場の
    /// 描き場所 2 枚の間で同じ食い違いが戻る。置き場に持たせた値は、持ち主を手放した後は進まない —
    /// 時刻と刻みも、持ち主のフレームでランタイムが渡すときにしか変わらないのと揃う。
    ///
    /// ``Timebase/frame`` は使わない。開いている間は本体の ``framesDrawn`` より 1 大きいので、
    /// 本体だけで描くスケッチの揺れまで変わる。本体のフレームの外 (`setup()`・止まっている間) で
    /// 描き場所が呼ぶと、次に描く本体のフレームの番号になる — そこで置いたものを次のフレームへ
    /// 持ち越すのと同じ向き (ADR-0021 決定 4 の追補 (2026-09-27))。
    ///
    /// `emit` の繰り越しは面ごとの数のままにしてある。公開の入口 (`Sketch.emit`) は本体の面から
    /// しか呼ばないので、混ざらない。
    ///
    /// [#1909]: https://github.com/mokume-metal/mokume/issues/1909
    var particleFrame: Int { timebase.mainFramesDrawn }

    /// 1 フレームぶんの計算を積む。
    ///
    /// **普通の計算として積む。** 依存の宣言 (読むもの・書くもの) から口の切れ目が
    /// 導かれ、描画との同期も既にある仕掛けが入れる。旗 → 段 → 進めて置く の順で、
    /// どれも前の計算が書いた段の並びに触れるので、1 つずつ口が切れて待つ仕掛けが入る
    /// (#341 — この世代のコマンド構造は口をまたぐ依存を自動では張らない)。
    private func schedule(_ particles: Particles, _ draw: Particles.Draw) {
        compute(
            particles.flag, over: particles.capacity,
            reads: [draw.parameters, particles.state],
            writes: [particles.levels])
        for level in 0..<particles.scanCount {
            compute(
                particles.scan, over: particles.levelLengths[level + 1],
                reads: [particles.levelHeaders[level]],
                writes: [particles.levels])
        }
        compute(
            particles.update, over: particles.capacity,
            reads: [draw.parameters, particles.levels],
            writes: [particles.state, draw.instances, draw.arguments])
        // 進めた量は、この計算を投入したときに数える (``particleAdvancesThisFrame``・#1710)
        particleAdvancesThisFrame.append(
            (Weak(particles), Double(Particles.lifeStep(of: frameStep))))
    }

    /// 投入した粒の進めを、寿命を減らした量として粒へ数える ([#1710])。**溜めた計算を投入した
    /// 所で呼ぶ** — 描き切りと、溜めた計算を描き切りより先に流す口 (読み戻し・面をまたぐ順)。
    ///
    /// [#1710]: https://github.com/mokume-metal/mokume/issues/1710
    func commitParticleAdvances() {
        for (particles, amount) in particleAdvancesThisFrame {
            particles.value?.noteSubmittedAdvance(amount)
        }
        particleAdvancesThisFrame.removeAll(keepingCapacity: true)
    }

    /// GPU が埋めた置き場所で描く列を開く。**読み戻しが無い。** 返すのは四角の頂点の
    /// 区間 (描く引数として GPU へ渡す)。形を持たなければ `nil`。
    ///
    /// 区間の設定は、記録した区間を置き直す口 (``replaying(_:_:)``) が当てる。粒の板は保持した
    /// 形なので、置く時点の `texture()` / `shader()` ではなく、作った時点に記録した面と塗りで
    /// 描く — 参照の経路と同じ絵になる ([#1649])。
    ///
    /// [#1649]: https://github.com/mokume-metal/mokume/issues/1649
    private func placeFromGPU(
        _ particles: Particles, _ draw: Particles.Draw
    ) -> (start: Int, count: Int)? {
        guard let run = particles.quad.runs.first, run.source == .solid else { return nil }
        var start = 0
        replaying(CollectionOfOne(run)) { run in
            start = solidVertices.count
            // 頂点の積み直しは保持した形と同じ手順を通す。置き場所の行列は GPU が組むので、
            // 鏡映の符号は CPU では決まらず、列は鏡映しないものとして開く (前からこの扱い)
            openRetainedSolid(
                run, of: particles.quad, mirrored: false,
                external: ExternalInstances(
                    instances: draw.instances, count: particles.capacity,
                    arguments: draw.arguments))
            closeBatch()
        }
        return (start, run.count)
    }

    /// CPU が読み戻して埋めた置き場所で描く。**速い側を照らす物差し。**
    ///
    /// 読み戻し (``read(_:)``) は溜まっている計算をその場で走らせて待つので、ここで
    /// 読める並びは**このフレームの結果**である。
    ///
    /// ``shape(_:at:)`` を通さないのは、板を視点へ向けた行列を ``Placement`` では表せない
    /// ためである。区間の設定は ``shape(_:at:)`` と同じ口 (``replaying(_:_:)``) が当てる。
    private func placeFromCPU(_ particles: Particles) {
        guard let run = particles.quad.runs.first, run.source == .solid else { return }
        let places = particles.living(
            from: read(particles.state), transform: transform.matrix,
            basis: currentCamera.basis)
        guard !places.isEmpty else { return }
        replaying(CollectionOfOne(run)) { run in
            placeSolid(run, of: particles.quad, instances: places)
        }
    }

}
