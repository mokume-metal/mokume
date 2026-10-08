// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

// 裏面が絵に出うる置き場所の裏 → 表を、置き場所の連なりごとに 1 回の描く呼び出しへ畳む
// ([#1947])。畳み方の理由と、置き場所どうしの順の扱いは ``SolidSweep`` が持つ。
//
// [#1947]: https://github.com/mokume-metal/mokume/issues/1947
extension Canvas {
    /// 添字の列で描く置き場所の連なり 1 つ。
    struct SweepDraw: Equatable {
        /// 列の中での置き場所の番号 (列の先頭から数える)。
        var instances: Range<Int>
        /// 添字の列の、置き場 (``SweepUploads/buffer``) の中での位置 (添字の数)。
        var indexStart: Int
        /// 添字の数。置き場所 1 つぶんで、連なりの置き場所はどれもこれを繰り返して描く。
        var indexCount: Int
    }

    /// 描き切り 1 回ぶんの、添字の列の置き場と、列ごとの連なり。
    struct SweepUploads {
        /// 添字の列を並べた置き場。畳める連なりが 1 つも無ければ `nil`。
        var buffer: (any MTLBuffer)?
        /// 列の番号 (`batches` の並び) → 連なりの先頭の置き場所の番号 → 描き方。畳める列だけが載る。
        var draws: [Int: [Int: SweepDraw]]

        static let none = SweepUploads(buffer: nil, draws: [:])

        /// 列 `index` の連なり。
        func draws(forBatch index: Int) -> [Int: SweepDraw] { draws[index] ?? [:] }
    }

    /// 溜めた列のうち、裏 → 表で描く置き場所の連なりを添字の列にして、置き場へ写す。
    ///
    /// **畳めない連なりは何も足さない** — 置き場所ごとに描く (``encodeBackThenFront``)。畳めないのは、
    /// 描く呼び出しを省ける数が添字の列を組む費用に見合わないとき
    /// (``SolidSweep/paysOff(instances:passes:programLength:vertices:)``)、頂点が形から求めた向きを
    /// 持つとき (巻き方を入れ替えた写しでは光の当たり方が変わる)、頂点を自分の置き場から読む列
    /// (GPU が持つモデル) と引数を GPU が書く列 (粒) のときである。
    func uploadSweeps() throws(RenderFailure) -> SweepUploads {
        guard sweepPolicy != .never else { return .none }
        var program: [UInt32] = []
        var draws: [Int: [Int: SweepDraw]] = [:]
        for (index, batch) in batches.enumerated() where batch.drawsBackThenFront {
            let built = sweepDraws(for: batch, into: &program)
            if !built.isEmpty { draws[index] = built }
        }
        guard !draws.isEmpty else { return .none }
        let buffer = try solidSweepStorage.write(program, holding: max(program.count, 1))
        return SweepUploads(buffer: buffer, draws: draws)
    }

    /// 列 1 本の、添字の列で描く連なり。組んだ添字は `program` の後ろへ足す。
    private func sweepDraws(
        for batch: Batch, into program: inout [UInt32]
    ) -> [Int: SweepDraw] {
        guard batch.ownVertices == nil, batch.indirectArguments == nil else { return [:] }
        let run = batch.run
        let parts = SolidSweep.Parts(run: run, backFaceParts: batch.backFaceParts)
        let runs = SolidSweep.runs(
            instanceCount: batch.instanceCount, marks: batch.backFaceInstances, parts: parts)

        /// 描き方 (`Run.Kind`) ごとの、添字の列の状態。同じ描き方の連なりは同じ列を使う。
        enum Built {
            case unbuilt
            case impossible
            case ready(start: Int, count: Int)
        }
        var allParts = Built.unbuilt
        var someParts = Built.unbuilt
        var draws: [Int: SweepDraw] = [:]
        let indices: [UInt32]? = run.isIndexed ? solidIndices : nil
        /// 頂点ごとの描くときの番号 (最初に要るとき 1 度だけ作る)。
        var vertices: [UInt32]?

        for item in runs where item.kind != .plain {
            let passes = SolidSweep.passes(
                whole: parts.whole, shown: parts.shown(for: item.kind), plainCull: batch.cullMode)
            let state = item.kind == .allParts ? allParts : someParts
            let ready: (start: Int, count: Int)
            switch state {
            case .impossible:
                continue
            case .ready(let start, let count):
                ready = (start, count)
            case .unbuilt:
                let length = SolidSweep.programLength(of: passes)
                guard length > 0,
                    sweepPolicy == .always
                        || SolidSweep.paysOff(
                            instances: item.instances.count, passes: passes.count,
                            programLength: length, vertices: run.count)
                else { continue }
                let table = vertices ?? sweepVertexTable(for: run)
                vertices = table
                let start = program.count
                let usable = SolidSweep.appendProgram(
                    passes, indices: indices, vertexBase: run.start, vertices: table, to: &program)
                guard usable else {
                    program.removeLast(program.count - start)
                    if item.kind == .allParts { allParts = .impossible } else { someParts = .impossible }
                    continue
                }
                ready = (start, program.count - start)
                if item.kind == .allParts {
                    allParts = .ready(start: ready.start, count: ready.count)
                } else {
                    someParts = .ready(start: ready.start, count: ready.count)
                }
            }
            draws[item.instances.lowerBound] = SweepDraw(
                instances: item.instances, indexStart: ready.start, indexCount: ready.count)
        }
        return draws
    }

    /// 列の頂点ごとの、添字の列で描くときの番号 (``SolidSweep/appendProgram(_:indices:vertexBase:vertices:to:)``)。
    ///
    /// 添字を持たない列は、同じ値の頂点を最初の頂点の番号へ寄せる (``SolidVertexSharing``)。添字を持つ
    /// 列は作った人が頂点を使い回しているので、そのまま。**形から求めた向きを持つ頂点は
    /// ``SolidSweep/unusable``** — 断片は求めた向きを巻き方 (`front_facing`) で裏返すので、巻き方を入れ替えた
    /// 写しでは光の当たり方が変わる。
    private func sweepVertexTable(for run: Shape.Run) -> [UInt32] {
        let range = run.start..<(run.start + run.count)
        guard range.lowerBound >= 0, range.upperBound <= solidVertices.count else { return [] }
        let block = solidVertices[range]
        var table: [UInt32]
        if run.isIndexed {
            table = Array(UInt32(range.lowerBound)..<UInt32(range.upperBound))
        } else {
            let first = UInt32(range.lowerBound)
            table = block.withUnsafeBufferPointer { SolidVertexSharing.firsts(of: $0) }
            for local in table.indices { table[local] += first }
        }
        for (local, vertex) in block.enumerated() where vertex.normal.w > 0.5 {
            table[local] = SolidSweep.unusable
        }
        return table
    }
}
