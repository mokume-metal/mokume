// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import simd

// 粒。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **専用の面を、計算の段の上に載せる。** 放出・力・寿命を利用者に断片で書かせるのは
// 「数行で書ける」から遠い一方、同期の話を 2 つ持つのは [ADR-0023] 決定 3 に反する。
// だから更新は普通の計算として `compute(_:over:reads:writes:)` へ積み、依存の宣言も
// 待つ仕掛けも既にあるものがそのまま効く。
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
        /// GPU が埋める。読み戻しが要らない (既定)。
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

        let parameters = Particles.headerFloats + Particles.maximumForces * Force.slotCount
        let particles = Particles(
            capacity: capacity,
            state: try Numbers(gpu: gpu, count: state),
            instances: try Numbers(gpu: gpu, count: places),
            parameters: try Numbers(gpu: gpu, count: parameters),
            quad: particleQuad(),
            update: try particleKernel())
        return particles
    }

    /// 粒 1 つを描く形。**保持した形をそのまま使う**ので、粒だけ別の頂点経路を持たない。
    private func particleQuad() -> Shape {
        createShape {
            fill(.opaque(red: 1, green: 1, blue: 1))
            plane(1, 1)
        }
    }

    /// 組み込みの計算。**同梱した断片から組む**ので、壊れていればビルド時のシェーダ検査
    /// (`scripts/check-shaders.sh`) で落ちる — 走らせるまで分からない形にしない。
    private func particleKernel() throws(RenderFailure) -> Computation {
        let source = try gpu.bundledShaderSource(named: Self.particleShaderName)
        let computation = try Computation(
            name: Self.particleKernelName, url: nil, body: source, values: [:],
            gpu: gpu, pipeline: try computePipeline())
        computations.append(computation)
        return computation
    }

    /// 同梱した断片の名前。**検査が配置を確かめるのに同じものを読む。**
    static let particleShaderName = "Particles"
    /// 1 フレーム進める入口の名前。
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
        particles.write(
            transform: transform.matrix, step: deltaTime, frame: framesDrawn,
            forces: particles.takeForces())
        // **普通の計算として積む。** 依存の宣言 (読むもの・書くもの) から口の切れ目が
        // 導かれ、描画との同期も既にある仕掛けが入れる
        compute(
            particles.update, over: particles.capacity,
            reads: [particles.parameters],
            writes: [particles.state, particles.instances])

        switch particleRoute {
        case .instanced: placeFromGPU(particles)
        case .reference: placeFromCPU(particles)
        }
    }

    /// GPU が埋めた置き場所で描く。**読み戻しが無い。**
    private func placeFromGPU(_ particles: Particles) {
        guard let run = particles.quad.runs.first, run.source == .solid else { return }
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
                buffer: particles.instances.storage, count: particles.capacity))
        closeBatch()

        blendMode(savedMode)
        useTexture(savedTexture)
    }

    /// CPU が読み戻して埋めた置き場所で描く。**速い側を照らす物差し。**
    ///
    /// 読み戻し (``read(_:)``) は溜まっている計算をその場で走らせて待つので、ここで
    /// 読める並びは**このフレームの結果**である。
    private func placeFromCPU(_ particles: Particles) {
        shape(particles.quad, at: particles.living(from: read(particles.state)))
    }

    private func warnParticlesOutsideFrame() {
        guard !warnedParticlesOutsideFrame else { return }
        warnedParticlesOutsideFrame = true
        Diagnostics.warn(
            "粒は描くところ (draw) で扱います。初期化のときに出した粒はどのフレームにも"
                + "属さないため、無視しました")
    }
}
