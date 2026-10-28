// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics
import Testing

@testable import MokumeCore

/// 環に載った置き場へ書いてよい時刻を、規約ではなく表明で閉じる (#2258)。GPU を要する。
///
/// 書いてよいのは、**環を進めて待った後** (``FrameRing/advance()``) か、**投入済みの全部を待った
/// 後** (読み戻しの経路の `gpu.settleBeforeWriting`) だけで、そのスロットを読む投入
/// (``FrameRing/noteSubmission()``) の後は次に待つまで書けない。書き込み口
/// (``GrowableBuffer/buffer(holding:)``・`write(_:holding:)`・`writableBytes(holding:)`) が
/// その印を見る。印が無ければ、mokume の検査の中では止まり、外では止めずに 1 度だけ言って書く
/// (#1682 の作法・絵を欠かさない)。
@Suite(
    "環の置き場へ書いてよい時刻",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FrameRingWriteGateTests {
    /// 書き込み口。
    enum Port: CaseIterable, Sendable {
        case buffer, write, writableBytes
    }

    /// 環と、その上の置き場。**置き場は先に 1 度取っておく** — 取り直した直後の置き場はまだどの
    /// 投入にも読まれていないので、印が無くても書いてよい (``GrowableBuffer/buffer(holding:)``)。
    @MainActor
    static func makeStorage() throws -> (gpu: RenderDevice, ring: FrameRing, storage: GrowableBuffer) {
        let gpu = try RenderDevice()
        let ring = FrameRing(gpu: gpu)
        let storage = GrowableBuffer(
            gpu: gpu, ring: ring, stride: MemoryLayout<Float>.stride, minimumCapacity: 4,
            label: "mokume.test.gate")
        try ring.advance()
        _ = try storage.buffer(holding: 4)
        return (gpu, ring, storage)
    }

    /// 書き込み口を 1 度呼ぶ。`write` は `values` を写す。
    @MainActor
    @discardableResult
    static func call(_ port: Port, on storage: GrowableBuffer, values: [Float] = [1, 2, 3])
        throws -> any MTLBuffer
    {
        switch port {
        case .buffer: try storage.buffer(holding: values.count)
        case .write: try storage.write(values, holding: values.count)
        case .writableBytes: try storage.writableBytes(holding: values.count).buffer
        }
    }

    /// 子のプロセスで、印を落としてから書き込み口を呼ぶ。止まらなければ 0 で終わる。
    @MainActor
    static func writeWithoutMark(_ port: Port) throws {
        let (_, ring, storage) = try makeStorage()
        // 子のプロセスでも mokume の検査の中かは引数で決まるが、ここで見たいのは止まり方なので立てる
        ring.stopsOnUnguardedWrite = true
        // このスロットを読む投入を覚えた = 次に待つまで書けない
        ring.noteSubmission()
        try call(port, on: storage)
    }

    /// 止まったことは、**組み方によらず子に残る 2 つの印**で確かめる。1 つは終わり方 (信号で落ちた
    /// こと。終了コード 0 で戻った子と、`exit(n)` で終わった子を除く)、もう 1 つは止まる直前に
    /// `checkWritable` が必ず言う注意 (``FrameRing/unguardedWriteNotice``)。`preconditionFailure` の
    /// 文面は見ない — 文面は `-Onone` でしか出ず、`-O` (定期の release の検査・`make test-release`)
    /// では出さずに止まる (#3365)。
    ///
    /// **信号だけでは表明の停止と見分けられない。** exit test の本体が `throw` した子も信号
    /// (SIGTRAP) で終わることを手元で確かめてある。止まったのが印の
    /// 検査の直後であることは、その直前に出る注意の行で見る。表明を外すと子は書いて 0 で戻るので、
    /// 終わり方の `#expect` が赤になる。
    @Test("印が無いまま書き込み口を呼ぶと、mokume の検査の中では止まる")
    func anUnguardedWriteStopsInsideTheTests() async throws {
        let results = [
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                try await MainActor.run { try FrameRingWriteGateTests.writeWithoutMark(.buffer) }
            },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                try await MainActor.run { try FrameRingWriteGateTests.writeWithoutMark(.write) }
            },
            await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                try await MainActor.run { try FrameRingWriteGateTests.writeWithoutMark(.writableBytes) }
            },
        ]
        for result in results {
            // 終わり方が違えば、赤は上の `#expect` が記録済みである
            guard let result else { continue }
            let errors = String(decoding: result.standardErrorContent, as: UTF8.self)
            guard case .signal = result.exitStatus else {
                Issue.record("信号で落ちていない (終了コードで終わった): \(result.exitStatus)。標準エラー:\n\(errors)")
                continue
            }
            #expect(
                errors.contains(FrameRing.unguardedWriteNotice),
                "印の検査まで来ていない (別の理由で落ちた)。標準エラー:\n\(errors)")
        }
    }

    @Test("止まるのは、既定では mokume の検査の中だけである")
    @MainActor
    func stoppingFollowsTheSelfTest() throws {
        let ring = FrameRing(gpu: try RenderDevice())
        #expect(SelfTest.isRunning)
        #expect(ring.stopsOnUnguardedWrite == SelfTest.isRunning)
    }

    /// 利用者の作品の中 (検査の外) を模す。止めずに書き、注意は 1 度だけ。
    @Test("検査の外では止めずに書き、1 度だけ注意する", arguments: Port.allCases)
    @MainActor
    func outsideTheTestsItWritesAndSaysSoOnce(_ port: Port) throws {
        let (_, ring, storage) = try Self.makeStorage()
        ring.stopsOnUnguardedWrite = false
        ring.noteSubmission()
        let digest = WarningDigest()
        try Diagnostics.$digest.withValue(digest) {
            let buffer = try Self.call(port, on: storage, values: [1, 2, 3])
            try Self.call(port, on: storage, values: [4, 5, 6])
            if port == .write {
                // 書くのはやめない (絵を欠かさない)
                let written = buffer.contents().assumingMemoryBound(to: Float.self)
                #expect([written[0], written[1], written[2]] == [4, 5, 6])
            }
        }
        #expect(ring.unguardedWrites == 2)
        let notices = digest.takeUnreported().filter { $0 == FrameRing.unguardedWriteNotice }
        #expect(notices.count == 1, "注意が 1 度ではない: \(notices)")
    }

    @Test("環を進めて待てば印が立ち、次の投入で落ちる", arguments: Port.allCases)
    @MainActor
    func advancingRaisesTheMarkAndASubmissionDropsIt(_ port: Port) throws {
        let (_, ring, storage) = try Self.makeStorage()
        ring.stopsOnUnguardedWrite = false
        try Self.call(port, on: storage)
        #expect(ring.unguardedWrites == 0)
        ring.noteSubmission()
        try Self.call(port, on: storage)
        #expect(ring.unguardedWrites == 1)
        try ring.advance()
        try Self.call(port, on: storage)
        #expect(ring.unguardedWrites == 1)
    }

    @Test("投入済みの全部を待った後も印が立つ", arguments: Port.allCases)
    @MainActor
    func settlingRaisesTheMark(_ port: Port) throws {
        let (gpu, ring, storage) = try Self.makeStorage()
        ring.stopsOnUnguardedWrite = false
        ring.noteSubmission()
        try gpu.settle()
        ring.noteSettled()
        try Self.call(port, on: storage)
        #expect(ring.unguardedWrites == 0)
    }

    /// 読み戻し (`read`) は描き切りを通らないので環の待ちが効かず、全部を待ってから控えを書く
    /// (`runPendingComputations`)。**1 度目の読み戻しで控えの置き場を取っておく** — 取り直した直後は
    /// 印を見ないので、2 度目 (1 度目の投入でスロットの印が落ちた後) で見る。
    @Test("読み戻しの経路は、全部を待ってから書くので印を通る")
    @MainActor
    func theReadBackPathPassesTheMark() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 4, height: 4)
        canvas.frameRing.stopsOnUnguardedWrite = false
        let numbers = try canvas.makeNumbers(count: 4)
        numbers.set([1, 2, 3, 4])
        #expect(canvas.read(numbers) == [1, 2, 3, 4])
        #expect(!canvas.frameRing.isWritable, "1 度目の読み戻しの投入で、スロットの印が落ちていない")
        numbers.set([5, 6, 7, 8])
        #expect(canvas.read(numbers) == [5, 6, 7, 8])
        #expect(canvas.frameRing.unguardedWrites == 0)
    }
}
