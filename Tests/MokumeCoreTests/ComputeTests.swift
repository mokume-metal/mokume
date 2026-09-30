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

    /// 面をまたぐ順 ([#1870]) が使う規則。**口を切る規則 (`groups`) と同じ 1 つの定義**なので、
    /// 3 通りのぶつかり方のどれも、先に頼んだ側が先に走らなければならない。
    ///
    /// [#1870]: https://github.com/mokume-metal/mokume/issues/1870
    @Test("先に頼んだ計算と後の頼みは、読み書きが重なるときだけ順序が要る")
    func decidesWhenAnEarlierAskMustRunFirst() {
        typealias Access = ComputeAccess<Int>
        let wroteA = Access(writes: [1])
        let readA = Access(reads: [1])
        // 前が書いたものを読む・前が書いたものへ書く・前が読んだものへ書く
        #expect(wroteA.mustPrecede(readA))
        #expect(wroteA.mustPrecede(wroteA))
        #expect(readA.mustPrecede(wroteA))
        // 読みどうしや、重ならない並びは、どちらが先でもよい
        #expect(!readA.mustPrecede(readA))
        #expect(!wroteA.mustPrecede(Access(reads: [2], writes: [3])))
        // 何も頼まれていない側とは、順序が要らない
        #expect(!Access().mustPrecede(wroteA))
        #expect(!wroteA.mustPrecede(Access()))
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

    /// 読んだ 2 本の値を足して書く。**2 つの面が書いた並びを 1 度に読む**検査が使う。
    private static let sum = """
        kernel void sum(device const float *x [[buffer(0)]],
                        device const float *y [[buffer(1)]],
                        device float *out [[buffer(2)]],
                        uint id [[thread_position_in_grid]])
        {
            out[id] = x[id] + y[id];
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

    /// 形は `ParticleTests.refusesACountItCannotHold` と揃えている ([#1589])。
    ///
    /// [#1589]: https://github.com/mokume-metal/mokume/issues/1589
    @Test("持てない数の指定は、確保の失敗として返る")
    func refusesACountItCannotHold() throws {
        let canvas = try makeCanvas()
        let stride = MemoryLayout<Float>.stride
        // 数え切れない (バイト数の掛け算が回り込む)。溢れる最小の数も同じに断る
        for count in [Int.max, Int.max / stride + 1] {
            #expect(throws: RenderFailure.bufferUnavailable(byteCount: Int.max)) {
                try canvas.makeNumbers(count: count)
            }
        }
        // 数えられるが確保できない (上限の検めで断る)。溢れない最大の数も含める
        for count in [Int.max / stride, 1 << 40] {
            #expect(throws: RenderFailure.self) { try canvas.makeNumbers(count: count) }
        }
        // **途中で止まらない。** 断ったあとも普通に使える
        let heat = try canvas.makeNumbers(count: 8)
        #expect(heat.count == 8)
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

    // MARK: - 面をまたぐ順 (#1870)
    //
    // 計算は面ごとに溜まり、その面の描き切りで流れる。だから本体で先に頼んだ計算より、描き場所で
    // 後から頼んだ計算のほうが先に走っていた (描き場所の `endDraw()` が先に描き切るため)。頼んだ順に
    // 効く — 別の面の未投入の計算とぶつかる頼みが来たら、その面の計算を先に投入する。

    /// 1 つの値を書く断片 (`stamp`) と、読んだ値を書き写す断片 (`copy`) を持つ、本体と描き場所。
    private struct Surfaces {
        let canvas: Canvas
        let layer: Canvas
        let stamp: Computation
        let copy: Computation
        let first: Numbers
        let second: Numbers
    }

    private func makeSurfaces() throws -> Surfaces {
        let canvas = try makeCanvas()
        return Surfaces(
            canvas: canvas, layer: try canvas.createGraphics(32, 8),
            stamp: try canvas.makeComputation(Self.stamp, name: "stamp", values: ["amount": 0]),
            copy: try canvas.makeComputation(Self.copy, name: "copy"),
            first: try canvas.makeNumbers(count: 1), second: try canvas.makeNumbers(count: 1))
    }

    /// 1 フレームで、本体と描き場所が 1 つずつ頼む。`layerFirst` なら描き場所で先に頼んで描き切る。
    private func frame(
        _ surfaces: Surfaces, layerFirst: Bool, onCanvas: () -> Void, onLayer: () -> Void
    ) throws {
        let (canvas, layer) = (surfaces.canvas, surfaces.layer)
        func placeOnLayer() {
            layer.beginDraw()
            onLayer()
            layer.endDraw()
        }
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0))
            if layerFirst { placeOnLayer() }
            onCanvas()
            if !layerFirst { placeOnLayer() }
        }
    }

    /// 書く値を決めてから頼む (値は頼んだ時点のものが効く・#932)。
    private func stamp(_ amount: Float, into numbers: Numbers, on surface: Canvas, using s: Surfaces) {
        s.stamp.set("amount", .number(amount))
        surface.compute(s.stamp, over: 1, writes: [numbers])
    }

    @Test("本体で先に書いた並びを描き場所で後から読む計算は、書いた値を読む", arguments: [true, false])
    func laterReadOnTheLayerSeesTheEarlierWriteOnTheBody(layerFirst: Bool) throws {
        let s = try makeSurfaces()
        s.first.fill(-1)
        try frame(
            s, layerFirst: layerFirst,
            onCanvas: { stamp(3, into: s.first, on: s.canvas, using: s) },
            onLayer: { s.layer.compute(s.copy, over: 1, reads: [s.first], writes: [s.second]) })
        // 本体が先なら書いた 3 を、描き場所が先なら書く前の -1 を写す。頼んだ順のとおり
        #expect(s.canvas.read(s.second) == [layerFirst ? -1 : 3])
    }

    @Test("本体で先に書いた並びへ描き場所で後から書く計算は、後から書いた値が残る", arguments: [true, false])
    func laterWriteOnTheLayerOverwritesTheEarlierWriteOnTheBody(layerFirst: Bool) throws {
        let s = try makeSurfaces()
        try frame(
            s, layerFirst: layerFirst,
            onCanvas: { stamp(1, into: s.first, on: s.canvas, using: s) },
            onLayer: { stamp(2, into: s.first, on: s.layer, using: s) })
        #expect(s.canvas.read(s.first) == [layerFirst ? 1 : 2])
    }

    @Test("本体で先に読んだ並びへ描き場所で後から書く計算は、読んだ後に書く", arguments: [true, false])
    func laterWriteOnTheLayerWaitsForTheEarlierReadOnTheBody(layerFirst: Bool) throws {
        let s = try makeSurfaces()
        s.first.fill(5)
        try frame(
            s, layerFirst: layerFirst,
            onCanvas: { s.canvas.compute(s.copy, over: 1, reads: [s.first], writes: [s.second]) },
            onLayer: { stamp(2, into: s.first, on: s.layer, using: s) })
        // 本体が先なら書き換わる前の 5 を写し、描き場所が先なら書き換えた後の 2 を写す
        #expect(s.canvas.read(s.second) == [layerFirst ? 2 : 5])
        #expect(s.canvas.read(s.first) == [2])
    }

    @Test("描き場所の続きで、本体が先に頼んだ計算の結果を読める")
    func readingOnTheLayerSeesWhatTheBodyAskedFor() throws {
        let s = try makeSurfaces()
        var seen: [Float] = []
        try frame(
            s, layerFirst: false,
            onCanvas: { stamp(3, into: s.first, on: s.canvas, using: s) },
            onLayer: { seen = s.layer.read(s.first) })
        #expect(seen == [3])
    }

    @Test("本体から、描き場所が先に頼んだ計算の結果を読める")
    func readingOnTheBodySeesWhatTheLayerAskedFor() throws {
        let s = try makeSurfaces()
        var seen: [Float] = []
        try s.canvas.draw {
            s.layer.beginDraw()
            stamp(4, into: s.first, on: s.layer, using: s)
            // 描き場所はまだ開いている。頼んだ計算は描き場所の描き切りを待たずに読める
            seen = s.canvas.read(s.first)
            s.layer.endDraw()
        }
        #expect(seen == [4])
    }

    @Test("ぶつからない頼みは、面をまたいでもそのまま各面で流れる")
    func independentWorkOnEachSurfaceIsLeftToItsOwnFlush() throws {
        let s = try makeSurfaces()
        var laterOnLayer = -1
        try frame(
            s, layerFirst: false,
            onCanvas: { stamp(6, into: s.first, on: s.canvas, using: s) },
            onLayer: {
                stamp(7, into: s.second, on: s.layer, using: s)
                // 描き場所の頼みが、本体の未投入の頼みを引き出していない
                laterOnLayer = s.canvas.pendingComputations.count
            })
        #expect(laterOnLayer == 1)
        #expect(s.canvas.read(s.first) == [6])
        #expect(s.canvas.read(s.second) == [7])
    }

    /// [#1870] の完了条件 2。早い投入は計算だけを流し、**途中の描き切りを挟まない** (途中の描き切りには
    /// 既知の破れがある・#1656・#1657)。溜めている図形は残り、フレーム末尾の描き切りが 1 回で描く。
    ///
    /// [#1870]: https://github.com/mokume-metal/mokume/issues/1870
    @Test("面をまたぐ順のための早い投入は、溜めている図形を描き切らない")
    func theEarlySubmissionLeavesTheAccumulatedShapesAlone() throws {
        let s = try makeSurfaces()
        var pendingAfterEarlySubmission = false
        try frame(
            s, layerFirst: false,
            onCanvas: {
                s.canvas.fill(.display(red: 1, green: 1, blue: 1))
                s.canvas.rect(0, 0, 32, 8)
                stamp(3, into: s.first, on: s.canvas, using: s)
            },
            onLayer: {
                s.layer.compute(s.copy, over: 1, reads: [s.first], writes: [s.second])
                // 本体の計算は投入済み (溜め場は空) で、図形はまだ溜まっている
                pendingAfterEarlySubmission =
                    s.canvas.pendingComputations.isEmpty && s.canvas.hasPendingDrawing
            })
        #expect(pendingAfterEarlySubmission, "早い投入が図形を描き切った (か、計算を投入していない)")
        #expect(s.canvas.drawCallsInLastFrame == 1)
        #expect(!s.canvas.hasLoadedPixels)
        #expect(gray(try s.canvas.target.encodeForDisplay(), atColumn: 16) > 0.9)
        #expect(s.canvas.read(s.second) == [3])
    }

    /// 描き場所を**開いたまま**、本体と交互に頼む。描き場所の頼みが本体の頼みに、本体の頼みが
    /// 次の描き場所の頼みに、それぞれ先に投入される。直す前は描き場所の `endDraw()` で 2 つ目までが
    /// まとめて流れ、本体の頼みが最後になった。
    @Test("描き場所を開いたまま本体と交互に頼んでも、頼んだ順に効く")
    func aLayerLeftOpenWhileTheBodyAsksKeepsTheCallOrder() throws {
        let s = try makeSurfaces()
        let third = try s.canvas.makeNumbers(count: 1)
        s.second.fill(-1)
        third.fill(-1)
        try s.canvas.draw {
            s.canvas.background(.display(red: 0, green: 0, blue: 0))
            s.layer.beginDraw()
            // 1. 描き場所が first へ書く
            stamp(1, into: s.first, on: s.layer, using: s)
            // 2. 描き場所が開いたまま、本体が first を読んで second へ書く
            s.canvas.compute(s.copy, over: 1, reads: [s.first], writes: [s.second])
            // 3. 描き場所が、本体の書いた second を読んで third へ書く
            s.layer.compute(s.copy, over: 1, reads: [s.second], writes: [third])
            s.layer.endDraw()
        }
        #expect(s.canvas.read(s.second) == [1])
        #expect(s.canvas.read(third) == [1], "3 番目の頼みが、2 番目の結果より先に走った")
    }

    /// 本体 → 描き場所 A → 描き場所 B と、3 つの面が連なって頼む。A も B も開いたままなので、B の
    /// 頼みは A の未投入の計算を、A の頼みは本体の未投入の計算を、順に引き出す。
    @Test("本体 → 描き場所 A → 描き場所 B と 3 つの面が連なる頼みは、頼んだ順に効く")
    func aChainAcrossThreeSurfacesKeepsTheCallOrder() throws {
        let s = try makeSurfaces()
        let layerB = try s.canvas.createGraphics(32, 8)
        let third = try s.canvas.makeNumbers(count: 1)
        s.second.fill(-1)
        third.fill(-1)
        try s.canvas.draw {
            s.canvas.background(.display(red: 0, green: 0, blue: 0))
            stamp(3, into: s.first, on: s.canvas, using: s)
            s.layer.beginDraw()
            s.layer.compute(s.copy, over: 1, reads: [s.first], writes: [s.second])
            layerB.beginDraw()
            layerB.compute(s.copy, over: 1, reads: [s.second], writes: [third])
            layerB.endDraw()
            s.layer.endDraw()
        }
        #expect(s.canvas.read(s.second) == [3])
        #expect(s.canvas.read(third) == [3], "連なりの最後の頼みが、途中の結果より先に走った")
    }

    @Test("1 つの頼みがぶつかる面を複数引くとき、その全部が先に走る")
    func oneAskPullsEveryConflictingSurface() throws {
        let s = try makeSurfaces()
        let layerB = try s.canvas.createGraphics(32, 8)
        let third = try s.canvas.makeNumbers(count: 1)
        let sum = try s.canvas.makeComputation(Self.sum, name: "sum")
        try s.canvas.draw {
            s.canvas.background(.display(red: 0, green: 0, blue: 0))
            // 本体は first へ、描き場所 A は second へ書く。互いにぶつからないので、ここでは引き合わない
            stamp(1, into: s.first, on: s.canvas, using: s)
            s.layer.beginDraw()
            stamp(10, into: s.second, on: s.layer, using: s)
            // 描き場所 B が 2 つを読む。本体も描き場所 A も先に走る
            layerB.beginDraw()
            layerB.compute(sum, over: 1, reads: [s.first, s.second], writes: [third])
            layerB.endDraw()
            s.layer.endDraw()
        }
        #expect(s.canvas.read(third) == [11])
    }

    /// [#1870] の指摘への応え。**早い投入に失敗したら、そのフレームの間は同じ面へ試し直さない。**
    /// 環の待ちは最長 5 秒で投げるので、頼むたびに試すと、詰まった GPU で 1 回の `particles()`
    /// (計算が 3 本以上) が「5 秒 × 本数」止まる。注意は 1 度、溜めた計算は残り、次のフレームからは
    /// また試す。失敗は検査から差し込む (`failEarlySubmissionForTesting`) — 環の待ちが期限切れになる
    /// のは GPU が 5 秒返らないときだけで、自然には作れない。
    ///
    /// [#1870]: https://github.com/mokume-metal/mokume/issues/1870
    @Test("早い投入に失敗したら、1 度だけ注意し、そのフレームの間は試し直さず、次のフレームから試す")
    func aFailedEarlySubmissionIsNotRetriedInTheSameFrame() throws {
        let s = try makeSurfaces()
        let third = try s.canvas.makeNumbers(count: 1)
        let fourth = try s.canvas.makeNumbers(count: 1)
        s.first.fill(-1)
        s.canvas.failEarlySubmissionForTesting = .timedOut(seconds: RenderDevice.waitLimitSeconds)

        var stillPending = -1
        try s.canvas.draw {
            s.canvas.background(.display(red: 0, green: 0, blue: 0))
            stamp(3, into: s.first, on: s.canvas, using: s)
            s.layer.beginDraw()
            // 3 本とも、本体の未投入の計算が書く first を読む。直す前の作りなら 3 回試す
            s.layer.compute(s.copy, over: 1, reads: [s.first], writes: [s.second])
            s.layer.compute(s.copy, over: 1, reads: [s.first], writes: [third])
            s.layer.compute(s.copy, over: 1, reads: [s.first], writes: [fourth])
            stillPending = s.canvas.pendingComputations.count
            s.layer.endDraw()
        }
        #expect(s.canvas.earlySubmissionsAttempted == 1, "同じフレームの間に、失敗した面へ試し直している")
        #expect(s.canvas.warnings.hasWarned(.computationsSentAheadFailed))
        #expect(stillPending == 1, "失敗したのに、溜めた計算が降ろされている")
        // 描き切りは溜めた計算を流した (絵も計算も落ちていない)。頼んだ順は守れなかった
        #expect(s.canvas.read(s.first) == [3])
        #expect(s.canvas.read(s.second) == [-1])

        // 次のフレームからはまた試し、頼んだ順に効く
        s.canvas.failEarlySubmissionForTesting = nil
        try s.canvas.draw {
            s.canvas.background(.display(red: 0, green: 0, blue: 0))
            stamp(5, into: s.first, on: s.canvas, using: s)
            s.layer.beginDraw()
            s.layer.compute(s.copy, over: 1, reads: [s.first], writes: [s.second])
            s.layer.endDraw()
        }
        #expect(s.canvas.earlySubmissionsAttempted == 2)
        #expect(s.canvas.read(s.second) == [5])
    }

    /// **絵にも投入の数にも出ない費用を数で見る。** 単一の面と、相手が何も溜めていない頼みは、相手の
    /// 読み書きを集めずに抜ける (`accessLookups` は相手の溜めを引いた回数)。
    @Test("相手が何も溜めていない頼みは、名簿の相手の並びを集めない")
    func askingWhenNoOneElseHasAnythingPendingCollectsNothing() throws {
        let s = try makeSurfaces()
        let lookups = { s.canvas.gpu.pendingComputationHolders.accessLookups }

        // 単一の面: 何度頼んでも、読んでも引かない
        try s.canvas.draw {
            for _ in 0..<5 {
                stamp(1, into: s.first, on: s.canvas, using: s)
                s.canvas.compute(s.copy, over: 1, reads: [s.first], writes: [s.second])
            }
            _ = s.canvas.read(s.second)
        }
        #expect(lookups() == 0, "単一の面の頼みが、相手を引いている")

        // 描き場所が先: 本体が頼む時点で描き場所は描き切り済み、描き場所が頼む時点で本体は何も溜めていない
        try frame(
            s, layerFirst: true,
            onCanvas: { stamp(2, into: s.first, on: s.canvas, using: s) },
            onLayer: { stamp(3, into: s.first, on: s.layer, using: s) })
        #expect(lookups() == 0, "相手が何も溜めていないのに、引いている")

        // 本体が先でぶつかる: ここでは引く
        try frame(
            s, layerFirst: false,
            onCanvas: { stamp(2, into: s.first, on: s.canvas, using: s) },
            onLayer: { stamp(3, into: s.first, on: s.layer, using: s) })
        #expect(lookups() > 0)
    }

    /// **費用を絵ではなく数で見る。** 面をまたいでぶつかる形だけが投入を 1 本増やし、単一の面や、
    /// ぶつからない形、描き場所が先の順は今のまま。どれも投入済みの全部を待たない。
    @Test("投入が増えるのは、面をまたいでぶつかる頼みの 1 本だけで、全完了は待たない")
    func onlyACrossingConflictAddsASubmission() throws {
        let s = try makeSurfaces()
        s.first.fill(0)
        func submissions(_ run: () throws -> Void) throws -> (count: UInt64, drains: Int) {
            // 1 度目は置き場の確保などがあるので、数える前に同じものを回しておく
            try run()
            try s.canvas.gpu.settle()
            let (before, drains) = (s.canvas.gpu.submissionCount, s.canvas.gpu.blockingWaits)
            try run()
            return (s.canvas.gpu.submissionCount - before, s.canvas.gpu.blockingWaits - drains)
        }
        func chain(on surface: Canvas) {
            stamp(1, into: s.first, on: surface, using: s)
            surface.compute(s.copy, over: 1, reads: [s.first], writes: [s.second])
        }

        // 単一の面: 計算を頼んでも、頼まないフレームと同じ本数
        let plain = try submissions { try s.canvas.draw { s.canvas.background(.display(red: 0, green: 0, blue: 0)) } }
        let single = try submissions { try s.canvas.draw { chain(on: s.canvas) } }
        #expect(single.count == plain.count, "単一の面の計算が投入を増やしている")

        // 描き場所が先: 描き場所の描き切りで流れ切っているので、本体の頼みとぶつからない
        let layerFirst = try submissions {
            try frame(s, layerFirst: true, onCanvas: { chain(on: s.canvas) }, onLayer: { chain(on: s.layer) })
        }
        // ぶつからない頼み: 本体は first を書き、描き場所は second を書く
        let disjoint = try submissions {
            try frame(
                s, layerFirst: false,
                onCanvas: { stamp(1, into: s.first, on: s.canvas, using: s) },
                onLayer: { stamp(2, into: s.second, on: s.layer, using: s) })
        }
        // 本体が先でぶつかる: 描き場所の頼みが、本体の未投入の計算を先に投入させる
        let crossing = try submissions {
            try frame(s, layerFirst: false, onCanvas: { chain(on: s.canvas) }, onLayer: { chain(on: s.layer) })
        }

        #expect(disjoint.count == layerFirst.count, "ぶつからない頼みが投入を増やしている")
        #expect(crossing.count == layerFirst.count + 1, "面をまたいでぶつかる頼みは、投入を 1 本だけ増やす")
        for (name, cost) in [("単一", single), ("描き場所が先", layerFirst), ("ぶつからない", disjoint), ("ぶつかる", crossing)] {
            #expect(cost.drains == 0, "\(name): 投入済みの全部を待っている")
        }
    }

    /// 閉じ忘れた描き場所の頼みは、次のフレームの `beginDraw()` が描かずに捨てる (#1622)。
    /// その頼みを、ぶつかる頼みが復活させて走らせない。
    @Test("閉じ忘れたまま本体のフレームを越えた描き場所の頼みは、ぶつかる頼みでも走らない")
    func aLayerLeftOpenPastTheBodyFrameKeepsItsAskDropped() throws {
        let s = try makeSurfaces()
        s.first.fill(-1)
        // 1 フレーム目: 描き場所で頼み、`endDraw()` を忘れる
        try s.canvas.draw {
            s.layer.beginDraw()
            stamp(9, into: s.first, on: s.layer, using: s)
        }
        // 2 フレーム目: 本体が同じ並びを読む頼みをする。閉じ忘れた頼みは走らないので -1 のまま
        try s.canvas.draw {
            s.canvas.compute(s.copy, over: 1, reads: [s.first], writes: [s.second])
        }
        #expect(s.canvas.read(s.second) == [-1])
        #expect(s.canvas.read(s.first) == [-1])
    }
}
