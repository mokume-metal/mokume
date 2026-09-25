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

    @Test("前が読んだ並びを後から書くのも切れる")
    func splitsOnWriteAfterRead() {
        // 1 本目が並び 1 を読み終える前に、2 本目がそこを上書きしてはいけない。
        // **前の書き込みだけを追っていると、この組み合わせだけが素通りする** (#933)
        #expect(groups([(reads: [1], writes: [2]), (reads: [], writes: [1])]) == [0..<1, 1..<2])
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

    /// 渡された値をそのまま並びへ書く。**頼んだ時点の値が効いているか**を見るための断片。
    private static let stamp = """
        kernel void stamp(device float *out [[buffer(0)]],
                          constant Values &values [[buffer(MOKUME_VALUES)]],
                          uint id [[thread_position_in_grid]])
        {
            out[id] = values.amount;
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

    /// 並びの**先頭だけ**を読む塗り。
    ///
    /// 渡していない列に束ねられるのは 1 個の置き場 (``Canvas`` の `emptyNumbers`) なので、
    /// `show` のように添字を振って読むと**範囲外読み出し**になる — 返る値は保証されず、
    /// 実行ごとに変わる ([#919](https://github.com/mokume-metal/mokume/issues/919))。
    /// 「渡していない並びを読んでも落ちない」を見るのに、範囲外まで読む必要は無い。
    private static let showFirst = """
        float4 paint(Fragment in, Values values) {
            float v = in.numbers[0];
            return float4(v, v, v, 1);
        }
        """

    private func makeCanvas(width: Int = 32, height: Int = 8) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
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

    @Test("値は、頼んだ時点のものが効く")
    func carriesTheValuesTheWorkWasAskedWith() throws {
        let canvas = try makeCanvas()
        let first = try canvas.makeNumbers(count: 1)
        let second = try canvas.makeNumbers(count: 1)
        let stamp = try canvas.makeComputation(Self.stamp, name: "stamp", values: ["amount": 0])

        try canvas.draw {
            stamp.set("amount", 1)
            canvas.compute(stamp, over: 1, writes: [first])
            stamp.set("amount", 2)
            canvas.compute(stamp, over: 1, writes: [second])
        }

        // 頼みごとに値が焼き付いていなければ、溜めた頼みは流す段で**最後の値だけ**を
        // 読むので、両方に 2 が出る (#932)
        #expect(canvas.read(first) == [1])
        #expect(canvas.read(second) == [2])
    }

    /// **区画に収まらない値は、作るときに断る。** 塗りと同じ理由 (#348) — 宣言した数は
    /// 後から直せないので、切り詰めると断片の `Values` に一度も書かれない欄が残る。
    ///
    /// 見るのは `makeComputation` だけでよい。`loadComputation` も同じ入口へ落ちるので、
    /// 断る場所は 1 か所しかない。
    @Test("区画に収まらない数の値を宣言すると、作る時点で断られる")
    func refusesMoreValuesThanASlotHolds() throws {
        let canvas = try makeCanvas()
        // 数を 65 個。詰め物込みで 68 個になり、区画 (64) を超える
        var values: [String: ShaderValue] = [:]
        for index in 0...Canvas.valueSlotCapacity { values["v\(index)"] = 0 }

        // 何個で上限が何個かが、断る文から読めること
        #expect(
            throws: ShaderFailure.tooManyValues(path: "overflowing", count: 68, capacity: 64)
        ) {
            try canvas.makeComputation(Self.stamp, name: "overflowing", values: values)
        }
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

    @Test("待てない間は、数の並びへ書いた値を置き場へ届けず、待てたときに届ける")
    func holdsNumberWritesBackWhileTheWaitFails() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 4)
        heat.fill(3)
        #expect(canvas.read(heat) == [3, 3, 3, 3])

        // **読み戻しが待てない。** 書く口は 3 つあり、どれも控えに積むだけで待たない (#749)。
        // 届けるのは読み戻しか描き切りで、そこが待てなければ置き場へは触らない
        canvas.gpu.failSettleForTesting = .timedOut(seconds: 5)
        heat.set(9, at: 0)
        heat.set([8, 8])
        heat.set(7, at: 3)
        let whileStuck = canvas.read(heat)
        canvas.gpu.failSettleForTesting = nil

        #expect(
            whileStuck == [3, 3, 3, 3],
            """
            GPU の完了を待てなかったのに、共有しているメモリへ書いている。

            待ちが期限切れになったことは、GPU がそのメモリを使い終えた証拠ではない
            ([#934](https://github.com/mokume-metal/mokume/issues/934))。
            """)
        #expect(canvas.read(heat) == [8, 8, 3, 7], "待てるようになった後、控えが届いていない")

        // **描き切りが待てない。** 投げたフレームは置き場へ触らず、控えは次の描き切りへ残る
        heat.fill(5)
        canvas.failureForTesting = .timedOut(seconds: 5)
        #expect(throws: RenderFailure.self) { try canvas.draw {} }
        canvas.failureForTesting = nil
        try canvas.gpu.settle()
        #expect(heat.snapshot() == [8, 8, 3, 7], "描き切りが投げたのに、置き場へ書いている")

        try canvas.draw {}
        try canvas.gpu.settle()
        #expect(heat.snapshot() == [5, 5, 5, 5], "次の描き切りが控えを届けていない")
    }

    @Test("汚れ区間が上限を超えたら、その場で待って書き、区間を溜めない")
    func scatteredWritesFallBackToWaitingAndWriting() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 16)
        heat.dirtyRangeLimit = 3

        // 1 つおきに書くので、区間は畳めずに増える
        for index in stride(from: 0, to: 8, by: 2) { heat.set(Float(index + 1), at: index) }
        #expect(heat.directUploads == 1, "上限を超えたのに、その場で書いていない")
        #expect(heat.pendingUploadByteCount == 0, "書いた区間を控えに残している")
        try canvas.gpu.settle()
        #expect(Array(heat.snapshot().prefix(8)) == [1, 0, 3, 0, 5, 0, 7, 0])
    }

    @Test("同じフレームで書いては読むのを繰り返しても、そのつど書いた値が返る")
    func interleavedWritesAndReadsSeeEachWrite() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 8)
        var seen: [[Float]] = []
        try canvas.draw {
            heat.set([1, 2, 3])
            seen.append(canvas.read(heat))
            heat.set(9, at: 1)
            heat.set(7, at: 6)
            seen.append(canvas.read(heat))
            heat.fill(4)
            heat.set(5, at: 7)
            seen.append(canvas.read(heat))
        }
        #expect(
            seen == [
                [1, 2, 3, 0, 0, 0, 0, 0], [1, 9, 3, 0, 0, 0, 7, 0], [4, 4, 4, 4, 4, 4, 4, 5],
            ])
        #expect(heat.shadowAllocations == 1, "書くたびに影を確保し直している")
    }

    @Test("待てなかったら、計算の値を書かず、口も開かない")
    func doesNotOpenAnEncoderWhenTheWaitFails() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])
        var opened = -1
        var pending = -1

        // 読み戻しの経路は描き切りを通らない (環の待ちが効かない) ので、値の区画へ書く
        // 前の待ちはこちらが自分で持っている
        canvas.gpu.failSettleForTesting = .timedOut(seconds: 5)
        try canvas.draw {
            canvas.compute(ramp, over: 32, writes: [heat])
            _ = canvas.read(heat)
            opened = canvas.computeEncodersOpened
            pending = canvas.pendingComputations.count
        }
        canvas.gpu.failSettleForTesting = nil

        #expect(opened == 0, "値を書けないのに口を開いて流している")
        #expect(pending == 1, "投入していないのに、頼みが溜め場から消えている")
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
        let show = try canvas.makeShader(Self.showFirst)

        // 何も束ねない口を作らない — 束ねずに走らせると、読んだ断片が
        // 絵の乱れではなく異常終了になる
        try canvas.draw {
            canvas.background(.display(red: 1, green: 1, blue: 1))
            canvas.shader(show)
            canvas.rect(0, 0, 32, 8)
        }
        // **束ねた置き場の 1 個目は 0** なので黒が出る。ここで添字を振って読むと
        // 範囲外になり、返る値が実行ごとに変わる (`showFirst` の doc・#919)
        let image = try canvas.target.encodeForDisplay()
        #expect(gray(image, atColumn: 16) < 0.1)
    }

    // MARK: - 並びの寿命 (#1470)
    //
    // 並びは断片と一組の塗りで、断片と同じ**描き方**の側に居る — フレームを越え、
    // 書き換えるまで残る (``Sketch/numbers(_:)`` の Note)。2 枚目でも断片を置き直して
    // いるのは、見ているのが並びの寿命だけであることをはっきりさせるため
    // (断片はもとから越える)。

    @Test("1 度だけ渡した並びを、次のフレームの断片も読む")
    func numbersCrossFrames() throws {
        let canvas = try makeCanvas()
        let level = try canvas.makeNumbers(count: 1)
        let show = try canvas.makeShader(Self.showFirst)

        level.set(0.25, at: 0)
        try canvas.draw {
            canvas.shader(show)
            canvas.numbers(level)
            canvas.rect(0, 0, 32, 8)
        }
        let first = written(try canvas.target.encodeForDisplay(), atColumn: 16)
        #expect(abs(first - 0.25) < 0.01)

        // **渡し直さない。** 中身だけを差し替える — `Numbers.set` で書き換える作りが
        // 自然に誘う書き方で、フレームの頭で外れると 2 枚目は 1 個の 0 を読む
        level.set(0.75, at: 0)
        try canvas.draw {
            canvas.shader(show)
            canvas.rect(0, 0, 32, 8)
        }
        let second = written(try canvas.target.encodeForDisplay(), atColumn: 16)
        #expect(abs(second - 0.75) < 0.01)
    }

    /// `setup()` に当たる、最初のフレームの前。**描き方なのでフレームの外でも効き、
    /// 何も言わない** — シーンの記述と違って、どのフレームにも属さないことが問題にならない。
    @Test("フレームの外で渡した並びを、最初のフレームの断片が読む")
    func numbersGivenOutsideTheFrameReachTheFirstFrame() throws {
        let canvas = try makeCanvas()
        let level = try canvas.makeNumbers(count: 1)
        let show = try canvas.makeShader(Self.showFirst)
        level.set(0.5, at: 0)
        canvas.numbers(level)

        try canvas.draw {
            canvas.shader(show)
            canvas.rect(0, 0, 32, 8)
        }
        let read = written(try canvas.target.encodeForDisplay(), atColumn: 16)
        #expect(abs(read - 0.5) < 0.01)
        #expect(
            Canvas.OutsideFrame.allCases.allSatisfy { !canvas.warnings.hasWarned($0.warning) },
            "描き方を置いただけで、フレームの外の注意が出ている")
    }

    /// 並びを `setup()` で渡す、利用者が実際に書く形。`setup()` はフレームの外で走り
    /// (``SketchRuntime/start()``)、最初の `draw()` の頭をくぐってから描く。
    final class GivenInSetup: Sketch {
        var level: Numbers!
        var show: Shader!
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 8) }
        func setup() {
            level = try! makeNumbers(count: 1)
            show = try! makeShader(ComputeTests.showFirst)
            level.set(0.5, at: 0)
            numbers(level)
        }
        func draw() {
            shader(show)
            rect(0, 0, 32, 8)
        }
    }

    @Test("setup() で渡した並びを、最初の draw() の断片が読む")
    func numbersGivenInSetupReachTheFirstDraw() throws {
        let runtime = try SketchRuntime(sketch: GivenInSetup(), gpu: try RenderDevice())
        try runtime.advance()

        let read = written(try runtime.target.encodeForDisplay(), atColumn: 16)
        #expect(abs(read - 0.5) < 0.01)
        #expect(
            Canvas.OutsideFrame.allCases.allSatisfy { !runtime.canvas.warnings.hasWarned($0.warning) })
    }

    /// 越えるのは渡した並びだけではない。**外した状態も越える** — そうでないと、外した
    /// つもりの並びが次のフレームで戻ってくる。
    @Test("resetNumbers() で外した状態も、次のフレームへ越える")
    func resetNumbersCrossesFrames() throws {
        let canvas = try makeCanvas()
        let level = try canvas.makeNumbers(count: 1)
        let show = try canvas.makeShader(Self.showFirst)
        level.fill(1)

        try canvas.draw {
            canvas.shader(show)
            canvas.numbers(level)
            canvas.rect(0, 0, 32, 8)
            canvas.resetNumbers()
        }
        let first = written(try canvas.target.encodeForDisplay(), atColumn: 16)
        #expect(abs(first - 1) < 0.01)

        try canvas.draw {
            canvas.shader(show)
            canvas.rect(0, 0, 32, 8)
        }
        // 外した列が読むのは 1 個の 0 (「並びを渡していない塗りは、読んでも落ちない」と同じ)
        let second = gray(try canvas.target.encodeForDisplay(), atColumn: 16)
        #expect(second < 0.1)
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
        // **書いた値を置き場へ届けておく。** 書く口は控えに積むだけ (#749) なので、届けずに
        // 生の置き場を覗くと、書く前の 0 が見えて「古い」の意味がずれる
        #expect(canvas.read(field)[0] == -1)

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

    // MARK: - 投入されなかった計算 (#1183)

    /// **途中の描き切りが計算を積んだ後で投げても、頼みを溜め場から降ろさない。**
    /// `flush` は「途中の描き切りが一時的に失敗しただけなら、溜めたものはフレーム末尾の
    /// 描き切りに残す」と約束している。降ろすとフレーム末尾の描き切りは何も流さず、
    /// 計算は走らないまま読める ([#1183])。
    ///
    /// 投げさせるのは計算を積んだ後 — 形の置き場を伸ばし、その取り直しの待ちで投げる。
    /// **読み戻し (`read(_:)`) の経路には差し込めない**: 値を書く前の待ちが同じ差し込みで
    /// 先に断るので、組み立ての後まで進まない。溜め場を降ろす行は同じなので、ここで守る。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    @Test("途中の描き切りが計算を積んだ後で投げても、頼みはフレーム末尾で流れる")
    func workSurvivesAMidFrameFlushThatThrowsAfterEncodingIt() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        let ramp = try canvas.makeComputation(Self.ramp, name: "ramp", values: ["scale": 1])
        // 形の置き場を 1 度取らせる。面の外に置くので絵には出ない
        try canvas.draw { canvas.rect(1000, 1000, 1, 1) }

        var pending = -1
        var opened = -1
        try canvas.draw {
            canvas.compute(ramp, over: 32, writes: [heat])
            for index in 0..<5000 { canvas.rect(1000 + index % 16, 1000, 1, 1) }
            canvas.gpu.failSettleForTesting = .timedOut(seconds: RenderDevice.waitLimitSeconds)
            canvas.loadPixels()
            canvas.gpu.failSettleForTesting = nil
            pending = canvas.pendingComputations.count
            opened = canvas.computeEncodersOpened
        }
        #expect(opened == 1, "計算を積む前に投げている — この検査は計算の後で投げる経路を見ていない")
        #expect(pending == 1, "投入されなかった計算の頼みが、溜め場から消えている")
        // GPU の割り算は CPU と最後の桁で揃わないことがあるので、ずれは許して比べる
        let read = canvas.read(heat)
        #expect(
            read.indices.allSatisfy { abs(read[$0] - Float($0) / 31) < 1e-5 },
            "フレーム末尾の描き切りで計算が流れていない")
    }

    /// 同じ作法を控えにも効かせる。**積んだ後で描き切りが投げても、控えを下ろさない**
    /// ([#749])。下ろすと、書いた値は置き場へ届かないまま「届いた」ことになる。
    ///
    /// [#749]: https://github.com/mokume-metal/mokume/issues/749
    @Test("途中の描き切りが控えを積んだ後で投げても、書いた値はフレーム末尾で届く")
    func uploadsSurviveAMidFrameFlushThatThrowsAfterEncodingThem() throws {
        let canvas = try makeCanvas()
        let heat = try canvas.makeNumbers(count: 32)
        // 形の置き場を 1 度取らせる。面の外に置くので絵には出ない
        try canvas.draw { canvas.rect(1000, 1000, 1, 1) }

        var barriers = -1
        try canvas.draw {
            heat.fill(5)
            for index in 0..<5000 { canvas.rect(1000 + index % 16, 1000, 1, 1) }
            canvas.gpu.failSettleForTesting = .timedOut(seconds: RenderDevice.waitLimitSeconds)
            canvas.loadPixels()
            canvas.gpu.failSettleForTesting = nil
            barriers = canvas.uploadBarriersEncoded
        }
        #expect(barriers == 1, "控えを積む前に投げている — この検査は控えの後で投げる経路を見ていない")
        #expect(canvas.uploadBarriersEncoded == 2, "フレーム末尾の描き切りが控えを積み直していない")
        try canvas.gpu.settle()
        #expect(heat.snapshot() == Array(repeating: 5, count: 32), "投入されなかった控えが、届かないまま下ろされている")
    }
}
