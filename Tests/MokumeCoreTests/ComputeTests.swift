// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 依存の宣言から口の切れ目を導くところ。**GPU は要らない。**
///
/// 新しいコマンド構造には同じ口の中で待つ手段が無いので、依存は口を分けることでしか
/// 表せない。だから「どこで切るか」がそのまま依存の宣言の効き目になる — ここが
/// このフェーズの出口条件を機械で判定できる唯一の場所である。
@Suite("計算の依存")
struct ComputeDependencyTests {
    private func groups(_ accesses: [(reads: [Int], writes: [Int])]) -> [Range<Int>] {
        Canvas.groups(of: accesses)
    }

    @Test("ぶつからない計算は同じ口に残る")
    func keepsIndependentWorkTogether() {
        // 別々の並びへ書くだけなら順序は要らない。**並行に走ってよい**
        #expect(groups([(reads: [], writes: [1]), (reads: [], writes: [2])]) == [0..<2])
        // 同じものを読むだけなら、いくつ並んでも切れない
        #expect(
            groups([(reads: [1], writes: [2]), (reads: [1], writes: [3])]) == [0..<2])
    }

    @Test("前が書いたものを読む計算が来たら、そこで切れる")
    func splitsOnReadAfterWrite() {
        #expect(groups([(reads: [], writes: [1]), (reads: [1], writes: [2])]) == [0..<1, 1..<2])
    }

    @Test("同じものへ 2 度書くのも切れる")
    func splitsOnWriteAfterWrite() {
        // 2 つが同時に同じ並びへ書くのも、読み書きが重なるのと同じく順序が要る
        #expect(groups([(reads: [], writes: [1]), (reads: [], writes: [1])]) == [0..<1, 1..<2])
    }

    @Test("繋がった計算は、繋がった数だけ口が要る")
    func splitsEveryLinkOfAChain() {
        let chain: [(reads: [Int], writes: [Int])] = [
            (reads: [0], writes: [1]),
            (reads: [1], writes: [2]),
            (reads: [2], writes: [3]),
        ]
        #expect(groups(chain) == [0..<1, 1..<2, 2..<3])
    }

    @Test("切れた後は、そこから数え直す")
    func startsCountingAgainAfterASplit() {
        // 3 番目は 1 番目が書いたものに触れるが、**2 番目とはぶつからない**。
        // 切れ目のあとで「まだ書かれていない」に戻せていないと、ここで余計に切れる
        let work: [(reads: [Int], writes: [Int])] = [
            (reads: [], writes: [1]),
            (reads: [1], writes: [2]),
            (reads: [], writes: [3]),
        ]
        #expect(groups(work) == [0..<1, 1..<3])
    }

    @Test("何も頼まれていなければ口も要らない")
    func asksForNothingWhenNothingWasAsked() {
        #expect(groups([]).isEmpty)
    }

    @Test("計算の名前は、断片の入口として名乗れるものだけ")
    func acceptsOnlyNamesAFunctionCanCarry() {
        // 名前はそのまま `kernel void <name>` になるので、名乗れない名前を通すと
        // 「そんな関数は無い」という遠い形で失敗する
        #expect(Canvas.isUsableComputationName("step"))
        #expect(Canvas.isUsableComputationName("_step2"))
        #expect(!Canvas.isUsableComputationName(""))
        #expect(!Canvas.isUsableComputationName("2step"))
        #expect(!Canvas.isUsableComputationName("my step"))
        #expect(!Canvas.isUsableComputationName("ステップ"))
    }
}

/// 描く前の計算。GPU を要する。
@Suite(
    "描く前の計算",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ComputeTests {
    /// 位置に応じた明るさを並びへ書く。
    private static let ramp = """
        kernel void ramp(device float *out [[buffer(0)]],
                         constant Values &values [[buffer(MOKUME_VALUES)]],
                         uint id [[thread_position_in_grid]])
        {
            out[id] = float(id) / 31.0 * values.scale;
        }
        """

    /// 読んだ値をそのまま書き写す。
    private static let copy = """
        kernel void copy(device const float *from [[buffer(0)]],
                         device float *to [[buffer(1)]],
                         uint id [[thread_position_in_grid]])
        {
            to[id] = from[id];
        }
        """

    /// 並びの値をそのまま灰色にする塗り。
    private static let show = """
        float4 paint(Fragment in, Values values) {
            uint index = uint(clamp(in.place.x, 0.0, 0.999) * 32.0);
            float v = in.numbers[index];
            return float4(v, v, v, 1);
        }
        """

    private func makeCanvas(width: Int = 32, height: Int = 8) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    private func gray(_ image: DisplayImage, atColumn column: Int) -> Double {
        let row = image.height / 2
        let offset = (row * image.width + column) * 4
        return Double(image.bytes[offset]) / 255
    }

    /// 絵から読んだ明るさを、断片が返した値へ戻す。
    ///
    /// 画素は**出力段を通したあとの 8 bit** で並んでいる ([ADR-0011] 決定 6 の量子化点)
    /// ので、そのまま比べると「計算が書いた値」とは別の数になる。戻してから比べると、
    /// 検査に書く数が断片の書いた式とそのまま対応する。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    private func written(_ image: DisplayImage, atColumn column: Int) -> Double {
        let encoded = gray(image, atColumn: column)
        return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    @Test("計算が書いた値で絵が出る")
    func drawsWhatTheComputationWrote() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(
            Self.ramp, name: "ramp", values: ["scale": 1])
        let show = try canvas.makeShader(Self.show)

        try canvas.draw {
            canvas.compute(ramp, over: 32, writes: [heat])
            canvas.background(.display(red: 0, green: 0, blue: 0))
            canvas.numbers(heat)
            canvas.shader(show)
            canvas.rect(0, 0, 32, 8)
        }

        // 断片は `id / 31` を書いた。**その数がそのまま絵になっている**
        let image = try canvas.target.encodeForDisplay()
        #expect(abs(written(image, atColumn: 1) - 1.0 / 31) < 0.01)
        #expect(abs(written(image, atColumn: 16) - 16.0 / 31) < 0.01)
        #expect(abs(written(image, atColumn: 30) - 30.0 / 31) < 0.01)
    }

    @Test("渡した値が計算に届く")
    func carriesTheValuesIntoTheComputation() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])
        let show = try canvas.makeShader(Self.show)

        func brightest() throws -> Double {
            try canvas.draw {
                canvas.compute(ramp, over: 32, writes: [heat])
                canvas.background(.display(red: 0, green: 0, blue: 0))
                canvas.numbers(heat)
                canvas.shader(show)
                canvas.rect(0, 0, 32, 8)
            }
            return written(try canvas.target.encodeForDisplay(), atColumn: 30)
        }

        let full = try brightest()
        ramp.set("scale", 0.25)
        let quarter = try brightest()
        #expect(abs(full - 30.0 / 31) < 0.01)
        #expect(abs(quarter - 30.0 / 31 * 0.25) < 0.01)
    }

    @Test("繋がった計算は、順に効く")
    func runsChainedWorkInOrder() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let copied = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])
        let copy = try canvas.makeComputation(Self.copy, name: "copy")
        let show = try canvas.makeShader(Self.show)

        try canvas.draw {
            canvas.compute(ramp, over: 32, writes: [heat])
            canvas.compute(copy, over: 32, reads: [heat], writes: [copied])
            canvas.background(.display(red: 0, green: 0, blue: 0))
            canvas.numbers(copied)
            canvas.shader(show)
            canvas.rect(0, 0, 32, 8)
        }

        // 写した先を見ている。順序が守られていなければ 0 のままになる
        let image = try canvas.target.encodeForDisplay()
        #expect(abs(written(image, atColumn: 30) - 30.0 / 31) < 0.01)
        // 依存があるので口は 2 本。ぶつからない組み方なら 1 本で済む
        #expect(canvas.computeEncodersOpened == 2)
    }

    @Test("待つ仕掛けは、計算を頼んだフレームにだけ積まれる")
    func encodesTheBarrierOnlyWhenThereIsWorkToWaitFor() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])

        // 頼まなかったフレームでは口も開かず、仕掛けも積まれない —
        // **計算を使わないスケッチが計算の段の重さを払わない**
        try canvas.draw { canvas.background(.display(red: 0, green: 0, blue: 0)) }
        #expect(canvas.computeBarriersEncoded == 0)
        #expect(canvas.computeEncodersOpened == 0)

        try canvas.draw {
            canvas.compute(ramp, over: 32, writes: [heat])
            canvas.background(.display(red: 0, green: 0, blue: 0))
        }
        #expect(canvas.computeBarriersEncoded == 1)

        // もう一度頼まないフレームを挟んでも増えない
        try canvas.draw { canvas.background(.display(red: 0, green: 0, blue: 0)) }
        #expect(canvas.computeBarriersEncoded == 1)
    }

    @Test("開いた口は、フレームを閉じる前に必ず閉じている")
    func closesEveryEncoderItOpened() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let copied = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])
        let copy = try canvas.makeComputation(Self.copy, name: "copy")

        for _ in 0..<5 {
            try canvas.draw {
                canvas.compute(ramp, over: 32, writes: [heat])
                canvas.compute(copy, over: 32, reads: [heat], writes: [copied])
                canvas.background(.display(red: 0, green: 0, blue: 0))
            }
        }
        #expect(canvas.computeEncodersOpened == 10)
        #expect(canvas.computeEncodersClosed == canvas.computeEncodersOpened)
    }

    @Test("毎フレーム頼んでも、引数のテーブルは取り直されない")
    func reusesTheArgumentTablesAcrossFrames() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])

        try canvas.draw { canvas.compute(ramp, over: 32, writes: [heat]) }
        let built = try canvas.computePipeline().tablesBuilt
        for _ in 0..<10 {
            try canvas.draw { canvas.compute(ramp, over: 32, writes: [heat]) }
        }
        // 伸ばした先はそのまま使い回す (ADR-0023 決定 5)
        #expect(try canvas.computePipeline().tablesBuilt == built)
    }

    @Test("描くところの外から頼んでも、何も起きない")
    func ignoresWorkAskedForOutsideTheFrame() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])

        canvas.compute(ramp, over: 32, writes: [heat])
        #expect(canvas.pendingComputations.isEmpty)
        // **黙って何も起きるのではない** — 理由を 1 度知らせたことが残る
        #expect(canvas.warnings.hasWarned(.computeOutsideFrame))

        try canvas.draw { canvas.background(.display(red: 0, green: 0, blue: 0)) }
        #expect(canvas.computeEncodersOpened == 0)
    }

    @Test("描けなかったフレームの頼みは、次のフレームへ持ち越さない")
    func dropsTheWorkOfAFrameThatCouldNotBeDrawn() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])

        canvas.failureForTesting = .encoderUnavailable
        #expect(throws: RenderFailure.self) {
            try canvas.draw { canvas.compute(ramp, over: 32, writes: [heat]) }
        }
        canvas.failureForTesting = nil
        #expect(canvas.pendingComputations.isEmpty)

        try canvas.draw { canvas.background(.display(red: 0, green: 0, blue: 0)) }
        #expect(canvas.computeEncodersOpened == 0)
    }

    @Test("束ねられる本数を超えた頼みは、断って何もしない")
    func refusesToBindMoreThanItCan() throws {
        let canvas = try makeCanvas()
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])
        let many = try (0...ComputePipeline.maximumBufferCount).map { _ in
            try canvas.makeNumbers(count: 1)
        }

        try canvas.draw { canvas.compute(ramp, over: 32, writes: many) }
        #expect(canvas.computeEncodersOpened == 0)
        #expect(canvas.warnings.hasWarned(.tooManyComputeBuffers))
    }

    @Test("並びを渡していない塗りは、読んでも落ちない")
    func survivesAShaderThatReadsNumbersItWasNeverGiven() throws {
        let canvas = try makeCanvas()
        let show = try canvas.makeShader(Self.show)

        // 何も束ねない口を作らない — 束ねずに走らせると、読んだ断片が
        // 絵の乱れではなく異常終了になる
        try canvas.draw {
            canvas.background(.display(red: 1, green: 1, blue: 1))
            canvas.shader(show)
            canvas.rect(0, 0, 32, 8)
        }
        let image = try canvas.target.encodeForDisplay()
        #expect(gray(image, atColumn: 16) < 0.1)
    }

    // MARK: - 読み戻し

    /// 種を足して並べる。**フレームごとに違う値**を書かせるため。
    private static let seeded = """
        kernel void seeded(device float *out [[buffer(0)]],
                           constant Values &values [[buffer(MOKUME_VALUES)]],
                           uint id [[thread_position_in_grid]])
        {
            out[id] = values.seed + float(id);
        }
        """

    /// 1 だけ足す。**走った回数がそのまま値になる。**
    private static let bump = """
        kernel void bump(device float *out [[buffer(0)]],
                         uint id [[thread_position_in_grid]])
        {
            out[id] = out[id] + 1;
        }
        """

    @Test("読み戻した値は、そのフレームの結果")
    func readsWhatThisFrameComputed() throws {
        let canvas = try makeCanvas()
        let field = try canvas.makeNumbers(count: 32)
        let seeded = try canvas.makeComputation(Self.seeded, name: "seeded", values: ["seed": 0])

        for frame in 1...3 {
            seeded.set("seed", .number(Float(frame * 100)))
            var read: [Float] = []
            try canvas.draw {
                canvas.compute(seeded, over: 32, writes: [field])
                read = canvas.read(field)
            }
            // ひとつ前のフレームの値でも、蒔いた種でもない。**この回の結果**
            #expect(read[0] == Float(frame * 100))
            #expect(read[31] == Float(frame * 100 + 31))
        }
    }

    /// 口がある理由そのもの。**待つ実装を外すと、ここが赤くなる。**
    ///
    /// ずれの正体は競合ではない。頼んだ計算は溜まっているだけで**走ってすらいない**ので、
    /// 生の置き場は決定論的に必ず古い。だから再現率に振れが無く、検査に書ける。
    @Test("積んだ直後の生の置き場は古く、読み戻した値は新しい")
    func theRawStorageIsStaleUntilItIsRead() throws {
        let canvas = try makeCanvas()
        let field = try canvas.makeNumbers(count: 32)
        let seeded = try canvas.makeComputation(Self.seeded, name: "seeded", values: ["seed": 7])
        field.fill(-1)

        var raw: Float = 0
        var read: [Float] = []
        try canvas.draw {
            canvas.compute(seeded, over: 32, writes: [field])
            raw = field.storage.contents().assumingMemoryBound(to: Float.self)[0]
            read = canvas.read(field)
        }
        #expect(raw == -1)
        #expect(read[0] == 7)
    }

    @Test("頼んだ計算が残っていなければ、読んでも走らせない")
    func doesNotRunAnythingWhenNothingIsPending() throws {
        let canvas = try makeCanvas()
        let field = try canvas.makeNumbers(count: 32)
        let seeded = try canvas.makeComputation(Self.seeded, name: "seeded", values: ["seed": 1])

        var once = 0
        var twice = 0
        try canvas.draw {
            canvas.compute(seeded, over: 32, writes: [field])
            _ = canvas.read(field)
            once = canvas.computeEncodersOpened
            // 同じフレームで 2 度読んでも、走らせるのは 1 度きり
            _ = canvas.read(field)
            twice = canvas.computeEncodersOpened
        }
        #expect(once == 1)
        #expect(twice == 1)

        // フレームの外でも読める。**溜まっていない = 全部終わっている**ので待ちは起きない
        #expect(canvas.read(field)[0] == 1)
        #expect(canvas.computeEncodersOpened == 1)
    }

    @Test("読んでも、溜めている図形は描き切られない")
    func leavesTheAccumulatedShapesAlone() throws {
        let canvas = try makeCanvas()
        let field = try canvas.makeNumbers(count: 32)
        let seeded = try canvas.makeComputation(Self.seeded, name: "seeded", values: ["seed": 1])

        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0))
            canvas.fill(.display(red: 1, green: 1, blue: 1))
            canvas.rect(0, 0, 32, 8)
            canvas.compute(seeded, over: 32, writes: [field])
            _ = canvas.read(field)
        }

        // 画素の読み戻しに相乗りしていれば、ここで溜めた図形が描き切られ、フレーム
        // 末尾の描き切りは 0 回になる。**別の経路の副作用に頼っていない**ことの裏
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(!canvas.hasLoadedPixels)
        #expect(gray(try canvas.target.encodeForDisplay(), atColumn: 16) > 0.9)
    }

    @Test("読んだ後に頼んだ計算も描く前に流れ、同じ計算は 2 度走らない")
    func runsLaterWorkWithoutRepeatingWhatWasAlreadyRun() throws {
        let canvas = try makeCanvas()
        let counter = try canvas.makeNumbers(count: 1)
        let bump = try canvas.makeComputation(Self.bump, name: "bump")

        var afterRead: [Float] = []
        try canvas.draw {
            canvas.compute(bump, over: 1, writes: [counter])
            afterRead = canvas.read(counter)
            // 読んだ後に頼んだぶん。**フレームを閉じる前に流れる**
            canvas.compute(bump, over: 1, writes: [counter])
        }
        #expect(afterRead == [1])
        // 流したものを溜め場から降ろしていなければ、末尾で 1 回目がもう一度走って 3 になる
        #expect(canvas.read(counter) == [2])
    }

    @Test("読み続けても、取り出し先は取り直されない")
    func reusesTheReadbackStorage() throws {
        let canvas = try makeCanvas()
        let field = try canvas.makeNumbers(count: 32)
        let seeded = try canvas.makeComputation(Self.seeded, name: "seeded", values: ["seed": 1])

        // 読まないうちは置き場を持たない
        #expect(field.readbackAllocations == 0)
        for _ in 0..<200 {
            try canvas.draw {
                canvas.compute(seeded, over: 32, writes: [field])
                _ = canvas.read(field)
            }
        }
        // 長回しでしか出ない (ADR-0023 決定 5)。フレームごとに確保していれば 200 になる
        #expect(field.readbackAllocations == 1)
    }

    /// 依存を無視して同じ口へ並べると、結果が壊れることを見る。
    ///
    /// **落ちたときだけ意味がある検査。** 通っても「壊れない」ことの証明にはならない —
    /// 重なるかどうかは混み具合で決まり、1 プロセスでは素通りしやすい ([#341] で実測)。
    /// だから既定では走らせず、`MOKUME_COMPUTE_STRESS=<回数>` で開く。
    ///
    /// [#341]: https://github.com/mokume-metal/mokume/issues/341
    @Test(
        "依存を伏せて並べると、写した先が揃わない",
        .enabled(if: ProcessInfo.processInfo.environment["MOKUME_COMPUTE_STRESS"] != nil))
    func showsTheHazardWhenTheDeclarationIsIgnored() throws {
        let rounds =
            Int(ProcessInfo.processInfo.environment["MOKUME_COMPUTE_STRESS"] ?? "") ?? 100
        let size = 65536
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: size)
        let copied = try canvas.makeNumbers(count: size)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])
        let copy = try canvas.makeComputation(Self.copy, name: "copy")

        var mismatches = 0
        for _ in 0..<rounds {
            heat.fill(0)
            copied.fill(-1)
            try canvas.draw {
                // **宣言を伏せる** — 読んでいるのに reads へ書かない。導出はぶつからないと
                // 見なし、2 つを同じ口へ並べる (= 並行に走りうる)
                canvas.compute(ramp, over: size, writes: [heat])
                canvas.compute(copy, over: size, writes: [copied])
            }
            if !Self.matchesTheRamp(copied) { mismatches += 1 }
        }

        // 伏せると同じ口に畳まれる。宣言が効いていることの前提
        #expect(canvas.computeEncodersOpened == rounds)
        // 何回に 1 回壊れるかは混み具合で振れる。**1 度でも食い違えば裏が取れる**
        #expect(mismatches > 0, "\(rounds) 回とも揃った。混ませて (別プロセスと同時に) もう一度")
    }

    /// 写した先が、書いたはずの並びと一致しているか。
    private static func matchesTheRamp(_ numbers: Numbers) -> Bool {
        let values = numbers.storage.contents().assumingMemoryBound(to: Float.self)
        for index in 0..<numbers.count where values[index] != Float(index) / 31 {
            return false
        }
        return true
    }
}
