// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreVideo
import Foundation
import MokumeTestSupport
import Synchronization
import Testing

@testable import MokumeCore

/// 器を取れなかった枚は、writer が転んでいれば writer の理由で書き損じになる ([#2944])。
///
/// `MovieFile.append` は writer が `.writing` であることを確かめてから画素の器の池を取る。確かめた直後に
/// writer が転ぶと、池は `nil` になり器も借りられない。本物の writer ではその瞬間を決まった所に作れない
/// (転ぶのは符号化器の側で、いつ起きるかは負荷しだい) ので、読む所だけを差し替える
/// (``MovieFile/ReadsForTesting``)。**GPU は要らない。**
///
/// [#2944]: https://github.com/mokume-metal/mokume/issues/2944
@Suite(
    "止まった writer へ書く枚の理由",
    .serialized,
    .enabled(if: MovieFile.isAvailable, "この機械には ProRes 4444 の符号化器が無い")
)
nonisolated struct MovieFileReadsTests {
    private static let reason = "Disk Full (injected)"

    /// 一色で塗った 1 枚。
    private func image(width: Int = 64, height: Int = 48) -> DisplayImage {
        DisplayImage(
            width: width, height: height,
            bytes: [UInt8](repeating: 120, count: width * height * 4))
    }

    /// 本物の `MovieFile` を開き、`body` の後に必ず閉じる。
    private func withMovieFile(
        _ body: (MovieFile, String) async throws -> Void
    ) async throws {
        let directory = TestScratch.path("mokume-movie-reads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reads.mov").path
        let file = try MovieFile(path: path, width: 64, height: 48, frameRate: 30)
        do {
            try await body(file, path)
        } catch {
            try? await file.finish(lastFrameAt: 0)
            throw error
        }
        try? await file.finish(lastFrameAt: 0)
    }

    /// 1 枚書き足して、投げられた失敗を返す。投げなければ `nil`。
    private func failure(of file: MovieFile, at time: Double = 0) async -> MovieWriteFailure? {
        do {
            try await file.append(image(), at: time)
            return nil
        } catch {
            return error
        }
    }

    /// 閉じて、投げられた失敗を返す。投げなければ `nil`。
    private func closeFailure(of file: MovieFile) async -> MovieWriteFailure? {
        do {
            try await file.finish(lastFrameAt: 0)
            return nil
        } catch {
            return error
        }
    }

    /// 状態を `.writing` と読ませ、**池を取りに行った瞬間に** 転んだことにする箱。
    private final class Tripwire: Sendable {
        private let tripped = Mutex(false)
        var status: AVAssetWriter.Status { tripped.withLock { $0 } ? .failed : .writing }
        func trip() { tripped.withLock { $0 = true } }
    }

    @Test("確かめた後に writer が転んで池が無くなれば、bufferUnavailable ではなく writer の理由で書き損じになる")
    func aVanishedPoolAfterTheCheckCarriesTheWritersReason() async throws {
        try await withMovieFile { file, path in
            let wire = Tripwire()
            file.readsForTesting.status = { wire.status }
            file.readsForTesting.error = { Self.reason }
            // 状態を確かめた直後に池を取りに来る。その瞬間に転び、池は無い
            file.readsForTesting.pool = {
                wire.trip()
                return nil
            }
            #expect(await failure(of: file) == .writeFailed(path: path, reason: Self.reason))
        }
    }

    @Test("確かめた後に writer が転んで器を借りられなければ、bufferUnavailable ではなく writer の理由で書き損じになる")
    func aRefusedBorrowAfterTheCheckCarriesTheWritersReason() async throws {
        try await withMovieFile { file, path in
            let wire = Tripwire()
            file.readsForTesting.status = { wire.status }
            file.readsForTesting.error = { Self.reason }
            file.readsForTesting.borrow = { _ in
                wire.trip()
                return nil
            }
            #expect(await failure(of: file) == .writeFailed(path: path, reason: Self.reason))
        }
    }

    @Test("状態がまだ .writing と読めても、writer が失敗の理由を言っていれば、取れなかった枚はその理由で書き損じになる")
    func aReasonTheWriterGaveCountsEvenWhileTheStatusStillReadsWriting() async throws {
        // 状態は非同期に変わる。`error` が先に立って状態が追いつかない読みでも、転んだと読む
        try await withMovieFile { file, path in
            file.readsForTesting.error = { Self.reason }
            file.readsForTesting.pool = { nil }
            #expect(await failure(of: file) == .writeFailed(path: path, reason: Self.reason))
        }
        try await withMovieFile { file, path in
            file.readsForTesting.error = { Self.reason }
            file.readsForTesting.borrow = { _ in nil }
            #expect(await failure(of: file) == .writeFailed(path: path, reason: Self.reason))
        }
    }

    @Test("転んだと読めるが理由が無ければ、取れなかった枚は bufferUnavailable ではなく writeFailed(unknown) になる")
    func aFailedWriterWithoutAReasonIsStillAWriteFailure() async throws {
        try await withMovieFile { file, path in
            // 最初の 1 枚は本物で書く。2 枚目で、池を取りに行った瞬間に状態だけが転ぶ
            #expect(await failure(of: file, at: 0) == nil)
            let wire = Tripwire()
            file.readsForTesting.status = { wire.status }
            file.readsForTesting.error = { nil }
            file.readsForTesting.pool = {
                wire.trip()
                return nil
            }
            #expect(await failure(of: file, at: 1.0 / 30) == .writeFailed(path: path, reason: "unknown"))
        }
    }

    @Test("最初の 1 枚の前に writer が転んでいれば、区間を始めずに writer の理由で断り、閉じるときもその理由を名乗る")
    func aWriterThatFailedBeforeTheFirstFrameIsNotStarted() async throws {
        try await withMovieFile { file, path in
            file.readsForTesting.status = { .failed }
            file.readsForTesting.error = { Self.reason }
            #expect(await failure(of: file) == .writeFailed(path: path, reason: Self.reason))
            // 止まった writer へ `startSession` を呼ばない (呼ぶと AVFoundation が例外を投げうる)
            #expect(!file.hasStarted)
            // 閉じるときも「1 枚も無い」で覆わず、writer の理由を名乗る
            #expect(await closeFailure(of: file) == .writeFailed(path: path, reason: Self.reason))
        }
    }

    @Test("writer が .writing のまま池が無ければ、これまでどおり bufferUnavailable")
    func aMissingPoolOnAHealthyWriterIsStillBufferUnavailable() async throws {
        try await withMovieFile { file, _ in
            file.readsForTesting.pool = { nil }
            #expect(await failure(of: file) == .bufferUnavailable)
        }
    }

    @Test("writer が .writing のまま器を借りられなければ、これまでどおり bufferUnavailable")
    func aRefusedBorrowOnAHealthyWriterIsStillBufferUnavailable() async throws {
        try await withMovieFile { file, _ in
            file.readsForTesting.borrow = { _ in nil }
            #expect(await failure(of: file) == .bufferUnavailable)
        }
    }

    /// writer へ渡した回数を数える箱。
    private final class Handed: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func note() { count.withLock { $0 += 1 } }
    }

    @Test("器の番地を取れなければ、その枚は writer へ渡さず、bufferUnavailable で書き損じになる")
    func anUnaddressableBufferIsNotHandedToTheWriter() async throws {
        try await withMovieFile { file, _ in
            let handed = Handed()
            file.readsForTesting.baseAddress = { _ in nil }
            file.readsForTesting.appendBuffer = { _, _ in
                handed.note()
                return true
            }
            #expect(await failure(of: file) == .bufferUnavailable)
            #expect(handed.value == 0, "番地の無い器を writer へ渡した")
        }
    }

    @Test("器の番地を取る瞬間に writer が転んでいれば、writer の理由で書き損じになり、writer へ渡さない")
    func anUnaddressableBufferOnAFailedWriterCarriesTheWritersReason() async throws {
        try await withMovieFile { file, path in
            let wire = Tripwire()
            let handed = Handed()
            file.readsForTesting.status = { wire.status }
            file.readsForTesting.error = { Self.reason }
            file.readsForTesting.baseAddress = { _ in
                wire.trip()
                return nil
            }
            file.readsForTesting.appendBuffer = { _, _ in
                handed.note()
                return true
            }
            #expect(await failure(of: file) == .writeFailed(path: path, reason: Self.reason))
            #expect(handed.value == 0)
        }
    }

    @Test("番地が取れる器は、1 回だけ writer へ渡す")
    func anAddressableBufferIsHandedOnce() async throws {
        try await withMovieFile { file, _ in
            let handed = Handed()
            file.readsForTesting.appendBuffer = { _, _ in
                handed.note()
                return true
            }
            #expect(await failure(of: file) == nil)
            #expect(handed.value == 1)
        }
    }

    @Test("差し込まなければ本物を読み、健やかな writer へは書き足せる")
    func withoutReadsTheRealWriterTakesTheFrame() async throws {
        try await withMovieFile { file, _ in
            #expect(await failure(of: file) == nil)
        }
    }
}
