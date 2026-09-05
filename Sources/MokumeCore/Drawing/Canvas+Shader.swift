// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// 利用者が書いた塗り。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、
// ここは受け口である ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Canvas {
    /// 断片を読み込む。
    public func loadShader(
        _ path: String, values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(ShaderFailure) -> Shader {
        let candidates = ImageFile.candidates(for: path)
        guard
            let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let body = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw .notFound(path: path, searched: candidates.map(\.path))
        }

        try Self.checkValuesFit(values, path: path)
        try Self.checkSurfacesFit(surfaces, path: path)

        let name = url.deletingPathExtension().lastPathComponent
        let shader: Shader
        do {
            shader = try Shader(
                name: name, url: url, body: body, values: values, surfaces: surfaces,
                gpu: gpu, pipeline: pipeline)
        } catch {
            throw .notCompilable(path: path, reason: "\(error)")
        }
        shader.canvas = self
        remember(shader)
        return shader
    }

    /// 文字列から作る。
    public func makeShader(
        _ body: String, name: String = "shader", values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(ShaderFailure) -> Shader {
        try Self.checkValuesFit(values, path: name)
        try Self.checkSurfacesFit(surfaces, path: name)

        let shader: Shader
        do {
            shader = try Shader(
                name: name, url: nil, body: body, values: values, surfaces: surfaces,
                gpu: gpu, pipeline: pipeline)
        } catch {
            throw .notCompilable(path: name, reason: "\(error)")
        }
        shader.canvas = self
        remember(shader)
        return shader
    }

    /// 渡す値が列 1 つぶんの区画に収まるかを見る ([#348](https://github.com/mokume-metal/mokume/issues/348))。
    ///
    /// **警告して切り詰めるのではなく、ここで断る。** 値の数は宣言した時点で決まり、
    /// ``Shader/set(_:_:)-(_,ShaderValue)`` は宣言済みの名前しか受け付けないので**後から直せない** —
    /// フレームごとに置き直すもの (視点・周囲・材質) が黙って無視されても次のフレームで
    /// 直せるのとは違う。切り詰めれば、断片の `Values` に一度も書かれない欄が残ったまま
    /// 絵が出続ける。
    ///
    /// 見るのは**詰め物込みの長さ** — そのまま区画へ書き込む長さになる。
    private static func checkValuesFit(
        _ values: [String: ShaderValue], path: String
    ) throws(ShaderFailure) {
        let count = ShaderSource.pack(values).count
        guard count > Canvas.valueSlotCapacity else { return }
        throw .tooManyValues(path: path, count: count, capacity: Canvas.valueSlotCapacity)
    }

    /// 渡す面が口の数に収まるかを見る ([#407](https://github.com/mokume-metal/mokume/issues/407))。
    ///
    /// **値と同じく、ここで断る。** 面の名前は宣言した時点で決まり、``Shader/set(_:_:)-(_,ShaderSurface)``
    /// は宣言済みの名前しか受け付けないので後から直せない。切り詰めれば、断片の
    /// `Surfaces` に一度も束ねられない欄が残ったまま絵が出続ける。
    private static func checkSurfacesFit(
        _ surfaces: [String: ShaderSurface], path: String
    ) throws(ShaderFailure) {
        guard surfaces.count > ShapePipeline.surfaceCapacity else { return }
        throw .tooManySurfaces(
            path: path, count: surfaces.count, capacity: ShapePipeline.surfaceCapacity)
    }

    /// これから描くものを、この断片で塗る。**溜めている列をその場で閉じる。**
    public func shader(_ shader: Shader) {
        guard shader !== currentShader else { return }
        closeBatch()
        currentShader = shader
    }

    public func resetShader() {
        guard currentShader != nil else { return }
        closeBatch()
        currentShader = nil
    }

    /// 組み立てに失敗している断片の理由。観測に載せる。
    ///
    /// **塗りと効果と計算をまとめて返す。** 呼ぶ側 (観測) が「どの種類の断片が壊れて
    /// いるか」で経路を分けることはないので、分けると呼び忘れる側ができるだけになる。
    /// 実際に効果がその「呼び忘れられた側」だった ([#787])。
    ///
    /// [#787]: https://github.com/mokume-metal/mokume/issues/787
    var shaderFailures: [String] {
        shaders.compactMap { held in
            guard let shader = held.value else { return nil }
            return shader.failure.map { "shader \(shader.name): \($0)" }
        }
            + effectShaders.compactMap { held in
                guard let effect = held.value else { return nil }
                return effect.failure.map { "effect \(effect.name): \($0)" }
            } + computationFailures
    }

    /// 作ったものを控えへ足す。**足すついでに、死んだ入れ物を落とす。**
    ///
    /// 入れ物そのものは弱く持っても残るので、足す契機で掃く。作るのは組み立てを伴う
    /// 稀な操作なので、ここで一舐めする費用は問題にならない ([#738])。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    func remember(_ shader: Shader) {
        shaders.removeAll { $0.value == nil }
        shaders.append(Weak(shader))
    }

    func remember(_ computation: Computation) {
        computations.removeAll { $0.value == nil }
        computations.append(Weak(computation))
    }

    func remember(_ effect: EffectShader) {
        effectShaders.removeAll { $0.value == nil }
        effectShaders.append(Weak(effect))
    }

    /// 渡す値が変わった。**列を閉じてから変える** — そうしないと、既に置いた図形まで
    /// 後の値で描かれる。
    func shaderValuesWillChange() { closeBatch() }
}
