// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics

/// 1 回ぶんの計算の頼み。
///
/// 頼まれた順に溜め、描く前にまとめて流す。
struct ComputeDispatch {
    let computation: Computation
    /// 走らせる格子。1 次元なら高さが 1。
    let width: Int
    let height: Int
    /// 束ねる並び。**読むものが先、書くものが後**で、この並びがそのまま口の番号になる。
    let buffers: [Numbers]
    /// 末尾から何本が書く先か。
    let writeCount: Int

    var reads: [ObjectIdentifier] {
        buffers.prefix(buffers.count - writeCount).map(ObjectIdentifier.init)
    }
    var writes: [ObjectIdentifier] {
        buffers.suffix(writeCount).map(ObjectIdentifier.init)
    }
}

// 利用者が頼む計算。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、
// ここは受け口である ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Canvas {
    /// 数の並びを用意する。
    public func makeNumbers(count: Int) throws(RenderFailure) -> Numbers {
        try Numbers(gpu: gpu, count: count)
    }

    /// 文字列から計算を作る。
    public func makeComputation(
        _ body: String, name: String = "computation", values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Computation {
        try makeComputation(name: name, url: nil, body: body, values: values)
    }

    /// ファイルから計算を読み込む。**入口の関数の名前はファイル名**になる。
    public func loadComputation(
        _ path: String, values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Computation {
        let candidates = ImageFile.candidates(for: path)
        guard
            let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let body = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw .notFound(path: path, searched: candidates.map(\.path))
        }
        let name = url.deletingPathExtension().lastPathComponent
        return try makeComputation(name: name, url: url, body: body, values: values)
    }

    private func makeComputation(
        name: String, url: URL?, body: String, values: [String: ShaderValue]
    ) throws(ShaderFailure) -> Computation {
        // **入口の関数の名前になるので、名乗れない名前は断る。** 断らないと、組み立ての
        // 失敗として「そんな関数は無い」という遠い形で出る
        guard Self.isUsableComputationName(name) else {
            throw .notCompilable(
                path: name,
                reason: "計算の名前は断片の中の入口の関数の名前にもなるので、"
                    + "英字か下線で始まり、英数字と下線だけでできている必要があります")
        }
        do {
            let pipeline = try computePipeline()
            let computation = try Computation(
                name: name, url: url, body: body, values: values, gpu: gpu, pipeline: pipeline)
            computations.append(computation)
            return computation
        } catch {
            throw .notCompilable(path: url?.path ?? name, reason: "\(error)")
        }
    }

    static func isUsableComputationName(_ name: String) -> Bool {
        guard let first = name.first, first == "_" || first.isLetter, first.isASCII else {
            return false
        }
        return name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    /// 1 次元で走らせる。
    public func compute(
        _ computation: Computation, over count: Int,
        reads: [Numbers] = [], writes: [Numbers] = []
    ) {
        compute(computation, over: count, by: 1, reads: reads, writes: writes)
    }

    /// 2 次元で走らせる。
    public func compute(
        _ computation: Computation, over width: Int, by height: Int,
        reads: [Numbers] = [], writes: [Numbers] = []
    ) {
        // **描くところの外からは効かない** (ADR-0023 決定 3)。黙って何も起きるのでは
        // なく、初回に理由を知らせる
        guard isDrawing else { return warnComputeOutsideFrame() }
        guard width > 0, height > 0 else { return }
        let buffers = reads + writes
        guard buffers.count <= ComputePipeline.maximumBufferCount else {
            return warnTooManyBuffers(buffers.count)
        }
        pendingComputations.append(
            ComputeDispatch(
                computation: computation, width: width, height: height,
                buffers: buffers, writeCount: writes.count))
    }

    // MARK: - 流す

    /// 溜めた計算を、描く前に流す。
    ///
    /// **口を開くのは頼まれたときだけ。** 1 つも頼まれていなければ口も仕掛けも作らず、
    /// 計算を使わないスケッチは計算の段の重さを一切払わない。
    ///
    /// 口を閉じる直前に、**次の段が待つ仕掛け**を積む。この世代のコマンド構造は口を
    /// またぐ依存を自動では張らないので、積まなければ描画が書き終わる前の並びを読む
    /// ([#341] で影の焼き付けと画面のパスが実際にそうなった)。
    ///
    /// [#341]: https://github.com/mokume-metal/mokume/issues/341
    func encodeComputations(into commands: any MTL4CommandBuffer) throws(RenderFailure) {
        guard !pendingComputations.isEmpty else { return }
        // **流したものは溜め場から降ろす。** 読み戻し (`read(_:)`) がフレームの途中で
        // ここを通るので、降ろさないとフレーム末尾の描き切りが同じ計算をもう一度走らせる。
        // 描き切りだけを通る経路では `discardFrame()` が同じことをするので、挙動は変わらない
        defer { pendingComputations.removeAll(keepingCapacity: true) }
        let pipeline = try computePipeline()
        let groups = Self.groups(
            of: pendingComputations.map { (reads: $0.reads, writes: $0.writes) })

        for (order, group) in groups.enumerated() {
            guard let encoder = commands.makeComputeCommandEncoder() else {
                throw .encoderUnavailable
            }
            computeEncodersOpened += 1
            for index in group {
                try encode(pendingComputations[index], at: index, on: encoder, using: pipeline)
            }
            encodeComputeBarrier(on: encoder, isLast: order == groups.count - 1)
            encoder.endEncoding()
            computeEncodersClosed += 1
        }
    }

    /// 次の段が待つ仕掛けを積む。
    ///
    /// - `afterStages`: 書いたのは計算の段
    /// - `beforeQueueStages`: 待つのは、途中なら次の計算・最後なら描画の両段
    /// - `visibilityOptions`: `.device` を渡す。既定の「流さない」側にすると実行順だけ
    ///   揃えて**中身が見えない** ([#341] で実測)
    ///
    /// [#341]: https://github.com/mokume-metal/mokume/issues/341
    private func encodeComputeBarrier(on encoder: any MTL4ComputeCommandEncoder, isLast: Bool) {
        encoder.barrier(
            afterStages: .dispatch,
            beforeQueueStages: isLast ? [.vertex, .fragment] : .dispatch,
            visibilityOptions: .device)
        computeBarriersEncoded += 1
    }

    private func encode(
        _ dispatch: ComputeDispatch, at index: Int,
        on encoder: any MTL4ComputeCommandEncoder, using pipeline: ComputePipeline
    ) throws(RenderFailure) {
        let state = dispatch.computation.state
        // **頼みごとに別のテーブルを使う。** 同じ口に載った計算は並行に走りうるので、
        // 1 枚を使い回して番地を書き換えると、走っている計算の足元で束ね先が変わる。
        // テーブルは使い回されるので、フレームごとに確保することにはならない
        // (ADR-0023 決定 5)
        let table = try pipeline.table(at: index)
        for (slot, numbers) in dispatch.buffers.enumerated() {
            table.setAddress(numbers.storage.gpuAddress, index: slot)
        }
        table.setAddress(
            dispatch.computation.valuesBuffer.gpuAddress, index: ComputePipeline.valuesBufferIndex)

        encoder.setComputePipelineState(state)
        encoder.setArgumentTable(table)
        encoder.dispatchThreads(
            threadsPerGrid: MTLSize(width: dispatch.width, height: dispatch.height, depth: 1),
            threadsPerThreadgroup: Self.threadgroup(for: state, isFlat: dispatch.height == 1))
    }

    /// 1 組の大きさ。**GPU が受け取れる上限に収める。**
    static func threadgroup(
        for state: any MTLComputePipelineState, isFlat: Bool
    ) -> MTLSize {
        let total = max(1, state.maxTotalThreadsPerThreadgroup)
        let lane = max(1, min(state.threadExecutionWidth, total))
        guard !isFlat else { return MTLSize(width: lane, height: 1, depth: 1) }
        return MTLSize(width: lane, height: max(1, total / lane), depth: 1)
    }

    // MARK: - 読み戻す

    /// 計算が書いた値を読む。意味の説明は `Sketch` が正本。
    ///
    /// **溜めている図形には触らない。** 画素の読み戻し (`loadPixels()`) は描き切りを
    /// 呼ぶのでフレームの構造が変わるが、ここは計算だけを別のコマンドに載せて流す。
    /// だから図形を 1 つも置いていないフレームでも読めるし、読んだあとに描いたものが
    /// 消えることもない ([#389] の完了条件 — 副作用として同期している経路に頼らせない)。
    ///
    /// [#389]: https://github.com/mokume-metal/mokume/issues/389
    public func read(_ numbers: Numbers) -> [Float] {
        runPendingComputations()
        return numbers.snapshot()
    }

    /// 溜まっている計算を、その場で走らせて待つ。
    ///
    /// **残っていなければ何もしない。** 走らせたものはコマンドの完了まで待ってから
    /// 返っている (描き切りの末尾も、ここも) ので、溜め場が空なら「走らせたものは
    /// 全部終わっている」が成り立つ。待つ必要があるのは、まだ走っていないものが
    /// 残っているときだけである。
    private func runPendingComputations() {
        guard !pendingComputations.isEmpty else { return }
        do {
            let commands = try gpu.beginCommands()
            try encodeComputations(into: commands)
            try gpu.commitAndWait(commands)
        } catch {
            // 読み取りは落とさない (ADR-0020 決定 5)。次のフレームの描き切りが同じ理由で
            // 失敗し、そちらから外へ出る
            Diagnostics.warn("計算の完了を待てませんでした: \(error.headline)")
        }
    }

    // MARK: - 依存から口の切れ目を導く

    /// 頼まれた並びを、同じ口へ載せてよいまとまりに切る。
    ///
    /// **前の計算が書いたものに触れる計算が来たら、そこで切る。** 触れるとは読むことも
    /// 書くことも含む — 2 つの計算が同じ並びへ同時に書くのも、読み書きが重なるのと
    /// 同じく順序が要る。ぶつからない計算は同じ口に残り、並行に走る。
    ///
    /// 新しいコマンド構造には**同じ口の中で待つ手段が無い**ので、依存は口を分けること
    /// でしか表せない。だから「どこで切るか」がそのまま依存の宣言の効き目になる。
    ///
    /// 識別子だけを見るので、GPU を持ち出さずに検査できる。
    static func groups<ID: Hashable>(
        of accesses: [(reads: [ID], writes: [ID])]
    ) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var start = 0
        var written: Set<ID> = []
        for (index, access) in accesses.enumerated() {
            let touched = Set(access.reads).union(access.writes)
            if !touched.isDisjoint(with: written) {
                groups.append(start..<index)
                start = index
                written = []
            }
            written.formUnion(access.writes)
        }
        if start < accesses.count { groups.append(start..<accesses.count) }
        return groups
    }

    // MARK: - 断る

    private func warnComputeOutsideFrame() {
        guard !warnedComputeOutsideFrame else { return }
        warnedComputeOutsideFrame = true
        Diagnostics.warn(
            "計算は描くところ (draw) の前置きなので、そこで頼んでください。"
                + "初期化のときに頼んだ計算はどのフレームにも属さないため、無視しました")
    }

    private func warnTooManyBuffers(_ count: Int) {
        guard !warnedTooManyComputeBuffers else { return }
        warnedTooManyComputeBuffers = true
        Diagnostics.warn(
            "1 回の計算に束ねられる並びは \(ComputePipeline.maximumBufferCount) 本までです "
                + "(\(count) 本頼まれました)。この計算は無視しました")
    }
}

// 塗りが読む数の並び。意味の説明は `Sketch` が正本。
extension Canvas {
    /// これから描くものが読む並びを差し替える。**溜めている列をその場で閉じる。**
    public func numbers(_ numbers: Numbers) {
        guard numbers !== currentNumbers else { return }
        closeBatch()
        currentNumbers = numbers
    }

    public func resetNumbers() {
        guard currentNumbers != nil else { return }
        closeBatch()
        currentNumbers = nil
    }
}
