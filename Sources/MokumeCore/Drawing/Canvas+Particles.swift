// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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
        let capacity = max(1, count)
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
        let source = try gpu.bundledShaderSource(named: Self.particleShaderName)
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
            flag: try particleKernel(Self.particleFlagKernelName, from: source),
            scan: try particleKernel(Self.particleScanKernelName, from: source),
            update: try particleKernel(Self.particleKernelName, from: source))
        return particles
    }

    /// 粒 1 つを描く形。**保持した形をそのまま使う**ので、粒だけ別の頂点経路を持たない。
    private func particleQuad() -> Shape {
        createShape {
            fill(.linear(red: 1, green: 1, blue: 1))
            plane(1, 1)
        }
    }

    /// 組み込みの計算。**同梱した断片から組む**ので、壊れていればビルド時のシェーダ検査
    /// (`scripts/check-shaders.sh`) で落ちる — 走らせるまで分からない形にしない。
    private func particleKernel(
        _ entry: String, from source: String
    ) throws(RenderFailure) -> Computation {
        let computation = try Computation(
            name: entry, url: nil, body: source, values: [:],
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
        guard isDrawing else { return warnParticlesOutsideFrame() }
        let count = particles.count(rate: rate, over: deltaTime)
        particles.emit(
            count, from: source, speed: speed, angle: angle, life: life, size: size,
            color: color ?? currentFill, at: time, using: &randomness)
    }

    /// 力を積む。
    public func force(_ particles: Particles, _ forces: [Force]) {
        guard isDrawing else { return warnParticlesOutsideFrame() }
        particles.add(forces)
    }

    /// 1 フレーム進めて、生きている粒を描く。
    public func particles(_ particles: Particles) {
        guard isDrawing else { return warnParticlesOutsideFrame() }
        // **速い経路は列を先に開く。** 描く引数 (頂点の頭と数) を GPU が書くので、
        // 四角をどこへ置いたかを計算へ渡す前に知っておく必要がある。列は閉じた時点の
        // 混ぜ方と変換で描かれるので、順序を入れ替えても絵は変わらない
        let placed = particleRoute == .instanced ? placeFromGPU(particles) : nil
        particles.write(
            transform: transform.matrix, step: deltaTime, frame: framesDrawn,
            forces: particles.takeForces(),
            vertexStart: placed?.start ?? 0, vertexCount: placed?.count ?? 0)
        schedule(particles)
        if particleRoute == .reference { placeFromCPU(particles) }
    }

    /// 1 フレームぶんの計算を積む。
    ///
    /// **普通の計算として積む。** 依存の宣言 (読むもの・書くもの) から口の切れ目が
    /// 導かれ、描画との同期も既にある仕掛けが入れる。旗 → 段 → 進めて置く の順で、
    /// どれも前の計算が書いた段の並びに触れるので、1 つずつ口が切れて待つ仕掛けが入る
    /// (#341 — この世代のコマンド構造は口をまたぐ依存を自動では張らない)。
    private func schedule(_ particles: Particles) {
        compute(
            particles.flag, over: particles.capacity,
            reads: [particles.parameters, particles.state],
            writes: [particles.levels])
        for level in 0..<particles.scanCount {
            compute(
                particles.scan, over: particles.levelLengths[level + 1],
                reads: [particles.levelHeaders[level]],
                writes: [particles.levels])
        }
        compute(
            particles.update, over: particles.capacity,
            reads: [particles.parameters, particles.levels],
            writes: [particles.state, particles.instances, particles.arguments])
    }

    /// GPU が埋めた置き場所で描く列を開く。**読み戻しが無い。** 返すのは四角の頂点の
    /// 区間 (描く引数として GPU へ渡す)。形を持たなければ `nil`。
    private func placeFromGPU(_ particles: Particles) -> (start: Int, count: Int)? {
        guard let run = particles.quad.runs.first, run.source == .solid else { return nil }
        let savedMode = currentBlendMode
        let savedTexture = currentTexture
        blendMode(run.mode)
        useTexture(run.texture)

        beginSolids()
        closeBatch()
        let start = solidVertices.count
        solidVertices.append(
            contentsOf: particles.quad.solidVertices[run.start..<(run.start + run.count)])
        retainedSerial += 1
        openSolid = OpenSolid(
            source: .retained(serial: retainedSerial), vertexStart: start,
            vertexCount: run.count, instanceStart: solidInstances.count,
            external: ExternalInstances(
                buffer: particles.instances.storage, count: particles.capacity,
                arguments: particles.arguments.storage))
        closeBatch()

        blendMode(savedMode)
        useTexture(savedTexture)
        return (start, run.count)
    }

    /// CPU が読み戻して埋めた置き場所で描く。**速い側を照らす物差し。**
    ///
    /// 読み戻し (``read(_:)``) は溜まっている計算をその場で走らせて待つので、ここで
    /// 読める並びは**このフレームの結果**である。
    private func placeFromCPU(_ particles: Particles) {
        shape(particles.quad, at: particles.living(from: read(particles.state)))
    }

    private func warnParticlesOutsideFrame() {
        warnOnce(
            .particlesOutsideFrame,
            "粒は描くところ (draw) で扱います。初期化のときに出した粒はどのフレームにも"
                + "属さないため、無視しました")
    }
}
